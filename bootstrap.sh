#!/usr/bin/env bash
#
# git-sot-bootstrap v2.0 — Cowork Project Source-of-Truth System
#
# GitHub is the durable source of truth. The Mac holds read/write working
# clones under ~/Projects. The server holds pull-only fallback clones
# authenticated by repo-scoped read-only deploy keys with per-repo SSH aliases.
#
# Modes:
#   ./bootstrap.sh new      --repo NAME [--category CAT] [options]
#   ./bootstrap.sh adopt    --path PATH --repo NAME [options]
#   ./bootstrap.sh migrate  --all [--dry-run]
#   ./bootstrap.sh restore  --repo NAME | --active
#   ./bootstrap.sh validate --all | --repo NAME
#   ./bootstrap.sh repair   --repo NAME
#
# Legacy compatibility:
#   ./bootstrap.sh --repo NAME [options]     (treated as "new")
#
# Common options:
#   --repo NAME              Repo / project name
#   --path PATH              Existing folder (adopt)
#   --category CAT           Category folder under ~/Projects (e.g. JL-Soaps)
#   --server HOST            Server host (default: 192.168.1.253)
#   --user USER              Server SSH user (default: psolomon)
#   --server-clone-base P    Server clone base (default: /home/USER/docker)
#   --no-server              Skip server fallback provisioning
#   --visibility V           private|public (default: private)
#   --description TEXT       GitHub repo description
#   --dry-run                Print planned actions; change nothing
#   --no-confirm             Skip confirmation prompt
#   -h | --help              Help        --version   Version
#
# Safety guarantees (by construction):
#   - No `git reset --hard`, no force-push, no history rewriting, anywhere.
#   - Never deletes project files. Never overwrites existing documentation:
#     template installation only ADDS missing files.
#   - Adopt/migrate stage ONLY files this script created or extended —
#     the user's untracked work is never swept into a commit.
#   - Every mutating action is logged to the action log.
#   - Reruns are idempotent: each step reports already-correct / created /
#     repaired / requires-approval instead of failing or duplicating.

set -euo pipefail

VERSION="2.0.0"

# ---------- Defaults ----------
PROJECT_ROOT="${SOT_PROJECT_ROOT:-$HOME/Projects}"
SERVER_HOST="${SOT_SERVER_HOST:-192.168.1.253}"
SERVER_USER="${SOT_SERVER_USER:-psolomon}"
SERVER_CLONE_BASE=""
VISIBILITY="private"
DESCRIPTION=""
CATEGORY=""
REPO_NAME=""
ADOPT_PATH=""
NO_CONFIRM=0
DRY_RUN=0
WITH_SERVER=1
ALL=0
ACTIVE=0
MODE=""

STATE_DIR="$HOME/.local/state/git-sot-bootstrap"
ACTION_LOG="$STATE_DIR/actions.log"
REPORT_DIR="$STATE_DIR/reports"
REGISTRY_REPO="cowork-project-registry"
REGISTRY_PATH="$PROJECT_ROOT/_registry"

LFS_PATTERNS="*.ai *.aic *.psd *.psb *.indd *.idml *.tif *.tiff *.pdf *.eps"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
GH_ACCOUNT=""
TOUCHED_FILES=""   # newline list of files created/extended in current project

# ---------- Output helpers ----------
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[34m→\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

# step LABEL STATUS [DETAIL]
# STATUS: already-correct | created | repaired | requires-approval | skipped | missing | incorrect
step() {
  local label="$1" status="$2" detail="${3:-}"
  case "$status" in
    already-correct) ok   "$label — already correct${detail:+ ($detail)}" ;;
    created)         ok   "$label — created${detail:+ ($detail)}" ;;
    repaired)        ok   "$label — repaired${detail:+ ($detail)}" ;;
    skipped)         info "$label — skipped${detail:+ ($detail)}" ;;
    requires-approval) warn "$label — REQUIRES APPROVAL${detail:+ ($detail)}" ;;
    missing)         warn "$label — missing${detail:+ ($detail)}" ;;
    incorrect)       warn "$label — incorrect${detail:+ ($detail)}" ;;
    *)               info "$label — $status${detail:+ ($detail)}" ;;
  esac
  log_action "step: $label = $status ${detail:-}"
}

log_action() {
  mkdir -p "$STATE_DIR"
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MODE:-init}" "$*" >> "$ACTION_LOG"
}

# run "description" cmd args...  — dry-run-aware executor for mutating commands
run() {
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: $desc"
    log_action "DRY-RUN: $desc :: $*"
    return 0
  fi
  log_action "RUN: $desc :: $*"
  "$@"
}

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

touched() { TOUCHED_FILES="${TOUCHED_FILES}$1
"; }

# ---------- Argument parsing ----------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      new|adopt|migrate|restore|validate|repair) MODE="$1"; shift ;;
      --repo)              REPO_NAME="$2"; shift 2 ;;
      --path)              ADOPT_PATH="$2"; shift 2 ;;
      --category)          CATEGORY="$2"; shift 2 ;;
      --server)            SERVER_HOST="$2"; shift 2 ;;
      --user)              SERVER_USER="$2"; shift 2 ;;
      --server-clone-base) SERVER_CLONE_BASE="$2"; shift 2 ;;
      --mac-clone-base)    PROJECT_ROOT="$2"; shift 2 ;;   # legacy
      --visibility)        VISIBILITY="$2"; shift 2 ;;
      --description)       DESCRIPTION="$2"; shift 2 ;;
      --no-server)         WITH_SERVER=0; shift ;;
      --dry-run)           DRY_RUN=1; shift ;;
      --no-confirm)        NO_CONFIRM=1; shift ;;
      --all)               ALL=1; shift ;;
      --active)            ACTIVE=1; shift ;;
      --version)           echo "git-sot-bootstrap $VERSION"; exit 0 ;;
      -h|--help)           usage 0 ;;
      *)                   err "Unknown arg: $1"; usage 1 ;;
    esac
  done
  [ -z "$MODE" ] && MODE="new"   # legacy: bare --repo invocation
  [ -z "$SERVER_CLONE_BASE" ] && SERVER_CLONE_BASE="/home/${SERVER_USER}/docker"
  case "$VISIBILITY" in private|public) ;; *) die "--visibility must be private|public" ;; esac
  REGISTRY_PATH="$PROJECT_ROOT/_registry"
}

# ---------- Shared computations ----------
set_repo_vars() {
  # $1 = repo name
  local r="$1"
  DEPLOY_KEY_NAME="github_$(printf '%s' "$r" | tr '-' '_' | tr '[:upper:]' '[:lower:]')_deploy"
  SSH_ALIAS="github-$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')"
  SERVER_CLONE_PATH="$SERVER_CLONE_BASE/$r"
}

local_path_for() {
  # $1 = repo name; honors CATEGORY when set
  if [ -n "$CATEGORY" ]; then printf '%s/%s/%s' "$PROJECT_ROOT" "$CATEGORY" "$1"
  else printf '%s/%s' "$PROJECT_ROOT" "$1"; fi
}

# ---------- Pre-flight ----------
preflight() {
  command -v gh  >/dev/null 2>&1 || die "gh CLI not found. Install: https://cli.github.com"
  command -v git >/dev/null 2>&1 || die "git not found"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
  GH_ACCOUNT=$(gh api user --jq .login)
  ok "GitHub auth: $GH_ACCOUNT"
  if [ ! -d "$PROJECT_ROOT" ]; then
    run "create project root $PROJECT_ROOT" mkdir -p "$PROJECT_ROOT"
    step "project root $PROJECT_ROOT" created
  fi
  if git lfs version >/dev/null 2>&1; then
    step "git-lfs (Mac)" already-correct "$(git lfs version | awk '{print $1}')"
  else
    step "git-lfs (Mac)" missing "install with: brew install git-lfs && git lfs install"
    [ "$MODE" = "validate" ] || warn "LFS patterns will still be written to .gitattributes; binaries commit as plain blobs until git-lfs is installed."
  fi
  mkdir -p "$STATE_DIR" "$REPORT_DIR"
}

# ---------- Template installation (merge, never overwrite) ----------
render_template() {
  # $1 src template, $2 dst file — substitute {{VARS}}
  sed -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
      -e "s|{{GH_ACCOUNT}}|${GH_ACCOUNT}|g" \
      -e "s|{{CATEGORY}}|${CATEGORY:-"(none)"}|g" \
      -e "s|{{LOCAL_PATH}}|${LOCAL_PATH}|g" \
      -e "s|{{SERVER_HOST}}|${SERVER_HOST}|g" \
      -e "s|{{SERVER_USER}}|${SERVER_USER}|g" \
      -e "s|{{SERVER_CLONE_PATH}}|${SERVER_CLONE_PATH}|g" \
      -e "s|{{SSH_ALIAS}}|${SSH_ALIAS}|g" \
      -e "s|{{VISIBILITY}}|${VISIBILITY}|g" \
      -e "s|{{DATE}}|$(date +%Y-%m-%d)|g" \
      -e "s|{{VERSION}}|${VERSION}|g" \
      "$1" > "$2"
}

install_template_file() {
  # $1 template basename, $2 dst relative path (within $LOCAL_PATH)
  local src="$TEMPLATE_DIR/$1" dst="$LOCAL_PATH/$2"
  [ -f "$src" ] || { step "template $2" skipped "template source missing: $1"; return 0; }
  if [ -e "$dst" ]; then
    step "$2" already-correct "existing file preserved"
  else
    if [ "$DRY_RUN" -eq 1 ]; then step "$2" created "(dry-run)"; else
      mkdir -p "$(dirname "$dst")"
      render_template "$src" "$dst"
      touched "$2"
      step "$2" created
    fi
  fi
}

install_project_structure() {
  # Standard folders (idempotent; .gitkeep so git tracks them)
  local d
  for d in .cowork sessions assets/source assets/reference assets/brand \
           assets/linked assets/fonts working exports/proofs exports/approved \
           production archive quarantine; do
    if [ -d "$LOCAL_PATH/$d" ]; then
      step "dir $d/" already-correct
    else
      if [ "$DRY_RUN" -eq 1 ]; then step "dir $d/" created "(dry-run)"; else
        mkdir -p "$LOCAL_PATH/$d"
        case "$d" in
          .cowork) : ;;
          *) touch "$LOCAL_PATH/$d/.gitkeep"; touched "$d/.gitkeep" ;;
        esac
        step "dir $d/" created
      fi
    fi
  done

  install_template_file "project.yaml.template"    ".cowork/project.yaml"
  install_template_file "README.md.template"       "README.md"
  install_template_file "COWORK.md.template"       "COWORK.md"
  install_template_file "SESSION_STATE.md.template" "SESSION_STATE.md"
  install_template_file "DECISIONS.md.template"    "DECISIONS.md"
  install_template_file "ASSET_INDEX.md.template"  "ASSET_INDEX.md"
  install_template_file "TOOL_MANIFEST.md.template" "TOOL_MANIFEST.md"
  install_template_file "CHANGELOG.md.template"    "CHANGELOG.md"
  install_template_file "RECOVERY.md.template"     "RECOVERY.md"
}

ensure_gitignore() {
  local f="$LOCAL_PATH/.gitignore" line added=0
  if [ ! -f "$f" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then step ".gitignore" created "(dry-run)"; return 0; fi
    render_template "$TEMPLATE_DIR/gitignore.template" "$f" 2>/dev/null || cp "$TEMPLATE_DIR/gitignore.template" "$f"
    touched ".gitignore"; step ".gitignore" created; return 0
  fi
  # merge: append any template line that's missing
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if ! grep -qxF "$line" "$f"; then
      if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] .gitignore += $line"; else
        printf '%s\n' "$line" >> "$f"; added=1
      fi
    fi
  done < "$TEMPLATE_DIR/gitignore.template"
  if [ "$added" -eq 1 ]; then touched ".gitignore"; step ".gitignore" repaired "missing entries appended"
  else step ".gitignore" already-correct; fi
}

ensure_lfs_attributes() {
  local f="$LOCAL_PATH/.gitattributes" p added=0
  [ -f "$f" ] || { [ "$DRY_RUN" -eq 1 ] || touch "$f"; }
  set -f  # no pathname expansion of *.ai etc.
  for p in $LFS_PATTERNS; do
    local want="$p filter=lfs diff=lfs merge=lfs -text"
    if [ -f "$f" ] && grep -qF "$p filter=lfs" "$f"; then :; else
      if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] .gitattributes += $want"; else
        printf '%s\n' "$want" >> "$f"; added=1
      fi
    fi
  done
  set +f
  if [ "$added" -eq 1 ]; then touched ".gitattributes"; step ".gitattributes (LFS)" repaired "patterns added (applies to NEW commits only)"
  else step ".gitattributes (LFS)" already-correct; fi
}

# ---------- Registry ----------
registry_ensure() {
  if [ -d "$REGISTRY_PATH/.git" ]; then
    step "registry clone" already-correct "$REGISTRY_PATH"
    run "registry fetch" git -C "$REGISTRY_PATH" fetch -q origin || warn "registry fetch failed (offline?)"
    return 0
  fi
  if gh repo view "$GH_ACCOUNT/$REGISTRY_REPO" >/dev/null 2>&1; then
    run "clone registry" git clone -q "git@github.com:$GH_ACCOUNT/$REGISTRY_REPO.git" "$REGISTRY_PATH"
    step "registry clone" created "$REGISTRY_PATH"
  else
    step "registry repo" requires-approval "create $GH_ACCOUNT/$REGISTRY_REPO first (seed files ship with this repo's registry-seed/)"
    return 1
  fi
}

registry_update_project() {
  # Managed YAML block in PROJECTS.yaml keyed by lowercase repo name
  local key blk pf="$REGISTRY_PATH/PROJECTS.yaml"
  key=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
  registry_ensure || return 0
  [ -f "$pf" ] || { [ "$DRY_RUN" -eq 1 ] || printf '# Cowork project registry — managed by git-sot-bootstrap\nprojects:\n' > "$pf"; }
  blk=$(mktemp)
  cat > "$blk" <<EOF
# >>> $key
  $key:
    github: $GH_ACCOUNT/$REPO_NAME
    local_path: ${LOCAL_PATH/#$HOME/~}
    category: ${CATEGORY:-none}
    visibility: $VISIBILITY
    status: active
    lfs: going-forward
    server_clone: ${SERVER_ENABLED:-yes}
    server_path: $SERVER_CLONE_PATH
    ssh_alias: $SSH_ALIAS
    updated: $(date +%Y-%m-%d)
# <<< $key
EOF
  if [ "$DRY_RUN" -eq 1 ]; then step "registry entry" created "(dry-run) $key"; rm -f "$blk"; return 0; fi
  awk -v key="$key" -v bf="$blk" '
    BEGIN { skip=0; done=0 }
    $0 == "# >>> " key { skip=1; while ((getline l < bf) > 0) print l; done=1; next }
    skip && $0 == "# <<< " key { skip=0; next }
    skip { next }
    { print }
    END { if (!done) { while ((getline l < bf) > 0) print l } }
  ' "$pf" > "$pf.tmp" && mv "$pf.tmp" "$pf"
  rm -f "$blk"
  if git -C "$REGISTRY_PATH" diff --quiet -- PROJECTS.yaml 2>/dev/null && \
     git -C "$REGISTRY_PATH" ls-files --error-unmatch PROJECTS.yaml >/dev/null 2>&1; then
    step "registry entry" already-correct "$key"
  else
    git -C "$REGISTRY_PATH" add PROJECTS.yaml
    git -C "$REGISTRY_PATH" commit -q -m "registry: upsert $key ($MODE)" || true
    git -C "$REGISTRY_PATH" push -q origin HEAD || warn "registry push failed — commit is local; push later"
    step "registry entry" repaired "$key upserted + pushed"
  fi
}

registry_get() {
  # $1 = key, $2 = field  → prints value or empty
  local pf="$REGISTRY_PATH/PROJECTS.yaml"
  [ -f "$pf" ] || return 0
  awk -v key="$1" -v fld="$2" '
    $0 == "# >>> " key { inb=1; next }
    inb && $0 == "# <<< " key { inb=0 }
    inb { sub(/^[ \t]+/, ""); if (index($0, fld ": ") == 1) { print substr($0, length(fld)+3); exit } }
  ' "$pf"
}

registry_keys() {
  local pf="$REGISTRY_PATH/PROJECTS.yaml"
  [ -f "$pf" ] || return 0
  awk '/^# >>> /{print $3}' "$pf"
}

# ---------- Server fallback ----------
server_reachable() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${SERVER_USER}@${SERVER_HOST}" "true" 2>/dev/null
}

server_provision() {
  # Idempotent server-side provisioning for $REPO_NAME. Never enables push.
  [ "$WITH_SERVER" -eq 1 ] || { step "server fallback" skipped "--no-server"; return 0; }
  if ! server_reachable; then
    step "server fallback" skipped "server ${SERVER_USER}@${SERVER_HOST} unreachable — run 'repair --repo $REPO_NAME' later"
    return 0
  fi
  ok "SSH reachable: ${SERVER_USER}@${SERVER_HOST}"

  # 1) deploy key file
  local have_key
  have_key=$(ssh "${SERVER_USER}@${SERVER_HOST}" "[ -f ~/.ssh/${DEPLOY_KEY_NAME} ] && echo yes || echo no")
  if [ "$have_key" = "yes" ]; then
    step "deploy key file" already-correct "~/.ssh/${DEPLOY_KEY_NAME}"
  else
    run "generate deploy key on server" ssh "${SERVER_USER}@${SERVER_HOST}" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f ~/.ssh/${DEPLOY_KEY_NAME} -N '' -C '${REPO_NAME} deploy key (\$(hostname))' >/dev/null"
    step "deploy key file" created
  fi
  [ "$DRY_RUN" -eq 1 ] && { step "server provisioning (remaining)" skipped "(dry-run)"; return 0; }

  # 2) key registered on GitHub for this repo (match by public key material)
  local pub reg
  pub=$(ssh "${SERVER_USER}@${SERVER_HOST}" "cat ~/.ssh/${DEPLOY_KEY_NAME}.pub" | awk '{print $2}')
  reg=$(gh api "repos/${GH_ACCOUNT}/${REPO_NAME}/keys" --jq '.[].key' 2>/dev/null | awk '{print $2}' | grep -cxF "$pub" || true)
  if [ "${reg:-0}" -ge 1 ]; then
    step "deploy key on GitHub" already-correct "repo-scoped"
  else
    gh api "repos/${GH_ACCOUNT}/${REPO_NAME}/keys" \
      -f "title=${SERVER_HOST} (read-only, $(date -u +%Y-%m-%d))" \
      -f "key=$(ssh "${SERVER_USER}@${SERVER_HOST}" "cat ~/.ssh/${DEPLOY_KEY_NAME}.pub")" \
      -F "read_only=true" >/dev/null
    step "deploy key on GitHub" created "read-only, repo-scoped"
  fi

  # 3) SSH alias
  local have_alias
  have_alias=$(ssh "${SERVER_USER}@${SERVER_HOST}" "grep -qs '^Host ${SSH_ALIAS}\$' ~/.ssh/config && echo yes || echo no")
  if [ "$have_alias" = "yes" ]; then
    step "ssh alias" already-correct "Host ${SSH_ALIAS}"
  else
    ssh "${SERVER_USER}@${SERVER_HOST}" bash -s <<EOF
set -e
touch ~/.ssh/config && chmod 600 ~/.ssh/config
cat >> ~/.ssh/config <<CFG

# ${REPO_NAME} (git-sot-bootstrap $(date -u +%Y-%m-%d))
Host ${SSH_ALIAS}
    HostName github.com
    User git
    IdentityFile ~/.ssh/${DEPLOY_KEY_NAME}
    IdentitiesOnly yes
CFG
EOF
    step "ssh alias" created "Host ${SSH_ALIAS}"
  fi

  # 4) verify repo-scoped auth
  local resp
  resp=$(ssh "${SERVER_USER}@${SERVER_HOST}" "ssh -T -o StrictHostKeyChecking=accept-new ${SSH_ALIAS} 2>&1 || true")
  if printf '%s' "$resp" | grep -q "Hi ${GH_ACCOUNT}/${REPO_NAME}!"; then
    step "auth verification" already-correct "repo-scoped"
  elif printf '%s' "$resp" | grep -q "Hi ${GH_ACCOUNT}!"; then
    step "auth verification" requires-approval "key is ACCOUNT-level, not repo-scoped — remove it from account keys manually"
    return 0
  else
    step "auth verification" incorrect "unexpected: $(printf '%s' "$resp" | head -1)"
    return 0
  fi

  # 5) clone (pull-only by key design; also disable push URL as belt+braces)
  local have_clone
  have_clone=$(ssh "${SERVER_USER}@${SERVER_HOST}" "[ -d ${SERVER_CLONE_PATH}/.git ] && echo yes || echo no")
  if [ "$have_clone" = "yes" ]; then
    step "server clone" already-correct "$SERVER_CLONE_PATH"
  else
    ssh "${SERVER_USER}@${SERVER_HOST}" "mkdir -p $(dirname "$SERVER_CLONE_PATH") && git clone -q ${SSH_ALIAS}:${GH_ACCOUNT}/${REPO_NAME}.git ${SERVER_CLONE_PATH} && git -C ${SERVER_CLONE_PATH} remote set-url --push origin DISABLED"
    step "server clone" created "$SERVER_CLONE_PATH (push URL disabled)"
  fi

  # 6) LFS on server
  if ssh "${SERVER_USER}@${SERVER_HOST}" "git lfs version >/dev/null 2>&1 || ~/.local/bin/git-lfs version >/dev/null 2>&1"; then
    ssh "${SERVER_USER}@${SERVER_HOST}" "cd ${SERVER_CLONE_PATH} && (git lfs pull 2>/dev/null || ~/.local/bin/git-lfs pull 2>/dev/null) || true"
    step "server LFS" already-correct
  else
    step "server LFS" missing "run 'repair' after installing git-lfs on server (user-level ok: ~/.local/bin)"
  fi

  # 7) end-to-end pull
  local pull
  pull=$(ssh "${SERVER_USER}@${SERVER_HOST}" "cd ${SERVER_CLONE_PATH} && git pull 2>&1" || true)
  if printf '%s' "$pull" | grep -qE "Already up to date|up-to-date|Fast-forward|Updating"; then
    step "server pull verification" already-correct
  else
    step "server pull verification" incorrect "$(printf '%s' "$pull" | head -1)"
  fi
}

# ---------- Commit only what we touched ----------
commit_touched() {
  local msg="$1" f staged=0
  [ "$DRY_RUN" -eq 1 ] && { info "[dry-run] would commit: $msg"; return 0; }
  [ -z "$TOUCHED_FILES" ] && { step "commit" skipped "nothing added by bootstrap"; return 0; }
  ( cd "$LOCAL_PATH"
    printf '%s' "$TOUCHED_FILES" | while IFS= read -r f; do
      [ -n "$f" ] && git add -- "$f" 2>/dev/null || true
    done
    if git diff --cached --quiet; then
      exit 3
    fi
    git commit -q -m "$msg"
  ) && { step "commit" created "$msg"; return 0; } || {
    [ $? -eq 3 ] && step "commit" already-correct "no changes to commit" || step "commit" incorrect "commit failed"
  }
}

# ---------- Mode: new ----------
cmd_new() {
  [ -n "$REPO_NAME" ] || die "new: --repo NAME required"
  set_repo_vars "$REPO_NAME"
  LOCAL_PATH=$(local_path_for "$REPO_NAME")
  preflight

  gh repo view "$GH_ACCOUNT/$REPO_NAME" >/dev/null 2>&1 && \
    die "Repo $GH_ACCOUNT/$REPO_NAME already exists — use 'adopt' or 'repair', not 'new'."
  [ -e "$LOCAL_PATH" ] && \
    die "Local path already exists: $LOCAL_PATH — use 'adopt --path', not 'new'."
  [ -z "$DESCRIPTION" ] && DESCRIPTION="Source of truth for ${REPO_NAME}"

  echo
  echo "=============================================="
  echo "NEW project: ${GH_ACCOUNT}/${REPO_NAME} (${VISIBILITY})"
  echo "  Local:  $LOCAL_PATH"
  echo "  Server: ${SERVER_USER}@${SERVER_HOST}:${SERVER_CLONE_PATH} $( [ $WITH_SERVER -eq 1 ] || echo '(SKIPPED)')"
  echo "  Dry-run: $DRY_RUN"
  echo "=============================================="
  if [ "$NO_CONFIRM" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    read -r -p "Proceed? [y/N] " r; case "$r" in [yY]*) ;; *) die "Aborted." ;; esac
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would create $LOCAL_PATH, install template, create GitHub repo, provision server"
    return 0
  fi

  mkdir -p "$LOCAL_PATH"; cd "$LOCAL_PATH"; git init -q -b main
  step "local repo" created "$LOCAL_PATH"
  install_project_structure
  ensure_gitignore
  ensure_lfs_attributes
  commit_touched "Initial commit: ${REPO_NAME} (git-sot-bootstrap v${VERSION})"
  gh repo create "$REPO_NAME" "--${VISIBILITY}" --source=. --push --description "$DESCRIPTION" >/dev/null
  step "GitHub repo" created "$GH_ACCOUNT/$REPO_NAME ($VISIBILITY)"
  SERVER_ENABLED=$( [ $WITH_SERVER -eq 1 ] && echo yes || echo no )
  registry_update_project
  server_provision
  echo; ok "new: complete — ${GH_ACCOUNT}/${REPO_NAME}"
}

# ---------- Mode: adopt ----------
cmd_adopt() {
  [ -n "$ADOPT_PATH" ] || die "adopt: --path PATH required"
  [ -n "$REPO_NAME" ]  || die "adopt: --repo NAME required"
  ADOPT_PATH="${ADOPT_PATH/#\~/$HOME}"
  [ -d "$ADOPT_PATH" ] || die "adopt: path not found: $ADOPT_PATH"
  LOCAL_PATH="$ADOPT_PATH"
  set_repo_vars "$REPO_NAME"
  # infer category from path when under PROJECT_ROOT
  case "$LOCAL_PATH" in
    "$PROJECT_ROOT"/*/*) [ -z "$CATEGORY" ] && CATEGORY=$(basename "$(dirname "$LOCAL_PATH")") ;;
  esac
  preflight

  echo
  echo "=============================================="
  echo "ADOPT: $LOCAL_PATH → ${GH_ACCOUNT}/${REPO_NAME}"
  echo "  Category: ${CATEGORY:-none}   Dry-run: $DRY_RUN"
  echo "=============================================="
  if [ "$NO_CONFIRM" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    read -r -p "Proceed? [y/N] " r; case "$r" in [yY]*) ;; *) die "Aborted." ;; esac
  fi

  # 1) git repo
  if [ -d "$LOCAL_PATH/.git" ] || [ -f "$LOCAL_PATH/.git" ]; then
    step "git repo" already-correct
  else
    run "git init" git -C "$LOCAL_PATH" init -q -b main
    step "git repo" created
  fi

  # 2) remote
  local cur_remote=""
  cur_remote=$(git -C "$LOCAL_PATH" remote get-url origin 2>/dev/null || true)
  local want_remote="git@github.com:${GH_ACCOUNT}/${REPO_NAME}.git"
  if [ -z "$cur_remote" ]; then
    if gh repo view "$GH_ACCOUNT/$REPO_NAME" >/dev/null 2>&1; then
      run "add origin" git -C "$LOCAL_PATH" remote add origin "$want_remote"
      step "remote origin" repaired "linked to existing $GH_ACCOUNT/$REPO_NAME"
    else
      [ -z "$DESCRIPTION" ] && DESCRIPTION="Source of truth for ${REPO_NAME}"
      if [ "$DRY_RUN" -eq 1 ]; then step "GitHub repo" created "(dry-run)"; else
        gh repo create "$REPO_NAME" "--${VISIBILITY}" --description "$DESCRIPTION" >/dev/null
        git -C "$LOCAL_PATH" remote add origin "$want_remote"
        step "GitHub repo + remote" created "$GH_ACCOUNT/$REPO_NAME ($VISIBILITY)"
      fi
    fi
  elif [ "$cur_remote" = "$want_remote" ]; then
    step "remote origin" already-correct
  else
    case "$cur_remote" in
      *github.com*"${GH_ACCOUNT}/${REPO_NAME}"*)
        run "normalize remote to SSH" git -C "$LOCAL_PATH" remote set-url origin "$want_remote"
        step "remote origin" repaired "normalized to SSH" ;;
      *)
        step "remote origin" requires-approval "points to $cur_remote, expected $want_remote — not changing it" ;;
    esac
  fi

  # 3) template + hygiene (merge; never overwrites)
  install_project_structure
  ensure_gitignore
  ensure_lfs_attributes
  commit_touched "chore(sot): adopt into cowork project system (bootstrap v${VERSION})"

  # 4) push (no force, ever)
  if [ "$DRY_RUN" -ne 1 ]; then
    local pushed=1
    if git -C "$LOCAL_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      git -C "$LOCAL_PATH" push -q || pushed=0
    else
      git -C "$LOCAL_PATH" push -q -u origin "$(git -C "$LOCAL_PATH" branch --show-current)" || pushed=0
    fi
    if [ "$pushed" -eq 1 ]; then step "push" already-correct "in sync with origin"
    else step "push" requires-approval "push rejected — pull/reconcile manually (no force-push will be attempted)"; fi
  fi

  SERVER_ENABLED=$( [ $WITH_SERVER -eq 1 ] && echo yes || echo no )
  registry_update_project
  server_provision
  echo; ok "adopt: complete — $LOCAL_PATH ↔ ${GH_ACCOUNT}/${REPO_NAME}"
}

# ---------- Mode: migrate ----------
cmd_migrate() {
  [ "$ALL" -eq 1 ] || die "migrate: only '--all' is supported (with optional --dry-run)"
  preflight
  local report="$REPORT_DIR/migrate-$(date +%Y%m%d-%H%M%S).md"
  info "Migration sweep of $PROJECT_ROOT (dry-run=$DRY_RUN)"
  {
    echo "# Migration report — $(date '+%Y-%m-%d %H:%M')"
    echo "Mode: $( [ $DRY_RUN -eq 1 ] && echo DRY-RUN || echo EXECUTE ) — template merge + LFS attrs + registry only; no file moves, no deletions."
    echo
  } > "$report"

  # discover top-level repos (.git DIRECTORY = standalone repo; submodules have .git files and are governed by their parent)
  local gitdir repo_path name
  find "$PROJECT_ROOT" -maxdepth 4 -name .git -type d 2>/dev/null | sort | while read -r gitdir; do
    repo_path=$(dirname "$gitdir")
    case "$repo_path" in
      "$REGISTRY_PATH") continue ;;
      "$PROJECT_ROOT"/_Tooling/*) echo "== $repo_path — skipped (tooling repo)" | tee -a "$report"; continue ;;
    esac
    # skip repos nested inside another repo's working tree (rare; submodules excluded already)
    name=$(basename "$repo_path")
    echo "== $repo_path" | tee -a "$report"
    REPO_NAME_SAVE="$REPO_NAME"; CATEGORY_SAVE="$CATEGORY"; TOUCHED_FILES=""
    REPO_NAME=$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+)\.git$|\1|' || true)
    [ -z "$REPO_NAME" ] && REPO_NAME="$name"
    CATEGORY=""
    case "$repo_path" in
      "$PROJECT_ROOT"/*/*) CATEGORY=$(basename "$(dirname "$repo_path")") ;;
    esac
    LOCAL_PATH="$repo_path"; set_repo_vars "$REPO_NAME"
    {
      install_project_structure
      ensure_gitignore
      ensure_lfs_attributes
      commit_touched "chore(sot): install cowork project template (migrate, bootstrap v${VERSION})"
      if [ "$DRY_RUN" -ne 1 ]; then
        if git -C "$LOCAL_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
          git -C "$LOCAL_PATH" push -q 2>/dev/null || warn "push failed for $REPO_NAME (will show in validate)"
        fi
        SERVER_ENABLED=no
        registry_update_project
      fi
    } 2>&1 | tee -a "$report"
    REPO_NAME="$REPO_NAME_SAVE"; CATEGORY="$CATEGORY_SAVE"
    echo | tee -a "$report"
  done

  {
    echo "## Non-git folders found (candidates for 'adopt' — REQUIRES APPROVAL, not touched)"
    find "$PROJECT_ROOT" -mindepth 1 -maxdepth 2 -type d \
      ! -path "*/.git*" ! -name ".*" 2>/dev/null | while read -r d; do
        [ -e "$d/.git" ] && continue
        # only leaf candidates that contain files and are not category parents of repos
        find "$d" -mindepth 1 -maxdepth 1 -name .git 2>/dev/null | grep -q . && continue
        ls -A "$d" 2>/dev/null | grep -q . || continue
        case "$d" in */assets|*/sessions|*/working|*/exports*|*/production|*/archive|*/quarantine) continue ;; esac
        has_repo_child=$(find "$d" -mindepth 2 -maxdepth 3 -name .git 2>/dev/null | head -1)
        [ -n "$has_repo_child" ] && continue
        echo "- $d"
      done
  } >> "$report"
  echo; ok "migrate sweep complete — report: $report"
}

# ---------- Mode: restore ----------
restore_one() {
  local key="$1"
  local gh_path lp
  gh_path=$(registry_get "$key" github)
  lp=$(registry_get "$key" local_path); lp="${lp/#\~/$HOME}"
  [ -n "$gh_path" ] || { step "restore $key" incorrect "no registry entry"; return 0; }
  [ -n "$lp" ] || lp="$PROJECT_ROOT/$key"
  if [ -d "$lp/.git" ]; then
    local cur; cur=$(git -C "$lp" remote get-url origin 2>/dev/null || true)
    case "$cur" in
      *"$gh_path"*) step "restore $key" already-correct "$lp" ;;
      *) step "restore $key" requires-approval "$lp exists with different remote: $cur" ;;
    esac
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then step "restore $key" created "(dry-run) would clone $gh_path → $lp"; return 0; fi
  mkdir -p "$(dirname "$lp")"
  git clone -q --recurse-submodules "git@github.com:${gh_path}.git" "$lp"
  if git lfs version >/dev/null 2>&1; then git -C "$lp" lfs pull -q 2>/dev/null || true; fi
  step "restore $key" created "$lp (submodules + LFS pulled)"
}

cmd_restore() {
  preflight
  registry_ensure || die "restore requires the registry repo"
  if [ "$ACTIVE" -eq 1 ]; then
    local k
    for k in $(registry_keys); do
      [ "$(registry_get "$k" status)" = "active" ] && restore_one "$k"
    done
  elif [ -n "$REPO_NAME" ]; then
    restore_one "$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')"
  else
    die "restore: --repo NAME or --active required"
  fi
  ok "restore: done"
}

# ---------- Mode: validate ----------
validate_one() {
  local rp="$1" name dirty ab remote tmpl_missing="" f
  name=$(basename "$rp")
  remote=$(git -C "$rp" remote get-url origin 2>/dev/null || echo "NONE")
  dirty=$(git -C "$rp" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ab=$(git -C "$rp" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null | tr '\t' '/' || echo "no-upstream")
  for f in .cowork/project.yaml README.md COWORK.md SESSION_STATE.md DECISIONS.md \
           ASSET_INDEX.md TOOL_MANIFEST.md CHANGELOG.md RECOVERY.md .gitattributes; do
    [ -e "$rp/$f" ] || tmpl_missing="$tmpl_missing $f"
  done
  local junk; junk=$(find "$rp" -name '.DS_Store' -o -name '._*' -o -name '*.idlk' 2>/dev/null | grep -v '/.git/' | wc -l | tr -d ' ')
  local lfsattr="no"; [ -f "$rp/.gitattributes" ] && grep -q 'filter=lfs' "$rp/.gitattributes" && lfsattr="yes"
  local reg="no"; [ -n "$(registry_get "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" github)" ] && reg="yes"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "${rp/#$PROJECT_ROOT\//}" "$remote" "$dirty" "$ab" \
    "$( [ -z "$tmpl_missing" ] && echo complete || echo "missing:$(echo "$tmpl_missing" | wc -w | tr -d ' ')" )" \
    "$lfsattr" "$reg" "$junk"
}

cmd_validate() {
  preflight
  local report="$REPORT_DIR/validate-$(date +%Y%m%d-%H%M%S).md"
  {
    echo "# Validation report — $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "| repo | remote | dirty | behind/ahead | template | lfs-attrs | registry | junk-files |"
    echo "|---|---|---|---|---|---|---|---|"
  } > "$report"
  if [ -n "$REPO_NAME" ] && [ "$ALL" -ne 1 ]; then
    local lp; lp=$(local_path_for "$REPO_NAME")
    [ -d "$lp/.git" ] || lp=$(find "$PROJECT_ROOT" -maxdepth 4 -type d -name "$REPO_NAME" | head -1)
    validate_one "$lp" >> "$report"
  else
    find "$PROJECT_ROOT" -maxdepth 4 -name .git -type d 2>/dev/null | sort | while read -r g; do
      validate_one "$(dirname "$g")" >> "$report"
    done
  fi
  # server freshness (best effort)
  {
    echo
    echo "## Server fallback"
    if server_reachable; then
      ssh "${SERVER_USER}@${SERVER_HOST}" '
        for d in '"$SERVER_CLONE_BASE"'/*/.git; do
          [ -d "$d" ] || continue
          r=$(dirname "$d")
          echo "- $r — last commit: $(git -C "$r" log -1 --format=%ci 2>/dev/null) — remote: $(git -C "$r" remote get-url origin 2>/dev/null)"
        done' 2>/dev/null
      echo "- git-lfs on server: $(ssh "${SERVER_USER}@${SERVER_HOST}" 'git lfs version 2>/dev/null || ~/.local/bin/git-lfs version 2>/dev/null || echo NOT-INSTALLED')"
    else
      echo "- server unreachable"
    fi
  } >> "$report"
  cat "$report"
  echo; ok "validate: report saved to $report"
}

# ---------- Mode: repair ----------
cmd_repair() {
  [ -n "$REPO_NAME" ] || die "repair: --repo NAME required"
  preflight
  registry_ensure || true
  local key lp
  key=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
  lp=$(registry_get "$key" local_path); lp="${lp/#\~/$HOME}"
  [ -n "$lp" ] && [ -d "$lp" ] || lp=$(local_path_for "$REPO_NAME")
  [ -d "$lp" ] || die "repair: cannot locate local project for $REPO_NAME (try restore)"
  LOCAL_PATH="$lp"; set_repo_vars "$REPO_NAME"
  CATEGORY=$(registry_get "$key" category); [ "$CATEGORY" = "none" ] && CATEGORY=""
  info "Repairing $REPO_NAME at $LOCAL_PATH"
  install_project_structure
  ensure_gitignore
  ensure_lfs_attributes
  commit_touched "chore(sot): repair project scaffolding (bootstrap v${VERSION})"
  if [ "$DRY_RUN" -ne 1 ] && git -C "$LOCAL_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git -C "$LOCAL_PATH" push -q 2>/dev/null || step "push" requires-approval "push rejected — reconcile manually"
  fi
  SERVER_ENABLED=$( [ $WITH_SERVER -eq 1 ] && echo yes || echo no )
  registry_update_project
  server_provision
  ok "repair: complete"
}

# ---------- Dispatch ----------
main() {
  parse_args "$@"
  log_action "invoked: mode=$MODE repo=${REPO_NAME:-} path=${ADOPT_PATH:-} dry_run=$DRY_RUN args: $*"
  case "$MODE" in
    new)      cmd_new ;;
    adopt)    cmd_adopt ;;
    migrate)  cmd_migrate ;;
    restore)  cmd_restore ;;
    validate) cmd_validate ;;
    repair)   cmd_repair ;;
    *)        usage 1 ;;
  esac
}

main "$@"
