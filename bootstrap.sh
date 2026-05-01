#!/usr/bin/env bash
#
# git-sot-bootstrap — Create a "source of truth" GitHub repo with:
#   - Mac working clone (read/write)
#   - Server fallback clone (pull-only via repo-scoped read-only deploy key)
#
# Usage:
#   ./bootstrap.sh --repo NAME [options]
#
# Required:
#   --repo NAME              Name of the new repo (must not already exist)
#
# Optional:
#   --server HOST            Server hostname or IP (default: 192.168.1.253)
#   --user USER              Server SSH user (default: psolomon)
#   --mac-clone-base PATH    Base directory for Mac clone (default: $HOME)
#                            Final path will be: PATH/REPO_NAME
#   --server-clone-base PATH Base directory for server clone
#                            (default: /home/USER/docker)
#   --visibility V           "private" or "public" (default: private)
#   --description TEXT       Repo description (default: "Source of truth for REPO")
#   --no-confirm             Skip the confirmation prompt
#   -h, --help               Show this help
#
# Prerequisites (checked at runtime):
#   - gh CLI installed and authenticated (gh auth status)
#   - git installed
#   - SSH access to the target server (key-based, no password)
#
# Effects:
#   1. Creates GitHub repo under your authenticated account
#   2. Creates ~/REPO_NAME on Mac, initializes git, adds README + .gitignore
#   3. Pushes initial commit to GitHub
#   4. Generates ed25519 deploy key on server (~/.ssh/github_REPO_deploy)
#   5. Registers deploy key on GitHub repo as read-only (NOT account-level)
#   6. Adds Host alias to server's ~/.ssh/config (Host github-REPO_NAME)
#   7. Clones repo to /home/USER/docker/REPO_NAME on server using the alias
#   8. Verifies end-to-end with a git pull
#
# Per-repo SSH aliases mean multiple bootstrapped repos can coexist on the
# same server without collision. Each gets its own Host alias and its own
# deploy key.

set -euo pipefail

# ---------- Defaults ----------
REPO_NAME=""
SERVER_HOST="192.168.1.253"
SERVER_USER="psolomon"
MAC_CLONE_BASE="${HOME}"
SERVER_CLONE_BASE=""  # computed from SERVER_USER if not set
VISIBILITY="private"
DESCRIPTION=""
NO_CONFIRM=0

# ---------- Helpers ----------
err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }
info(){ printf '\033[34m→\033[0m %s\n' "$*"; }
die() { err "$*"; exit 1; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------- Parse args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)               REPO_NAME="$2"; shift 2 ;;
    --server)             SERVER_HOST="$2"; shift 2 ;;
    --user)               SERVER_USER="$2"; shift 2 ;;
    --mac-clone-base)     MAC_CLONE_BASE="$2"; shift 2 ;;
    --server-clone-base)  SERVER_CLONE_BASE="$2"; shift 2 ;;
    --visibility)         VISIBILITY="$2"; shift 2 ;;
    --description)        DESCRIPTION="$2"; shift 2 ;;
    --no-confirm)         NO_CONFIRM=1; shift ;;
    -h|--help)            usage 0 ;;
    *)                    err "Unknown arg: $1"; usage 1 ;;
  esac
done

[ -z "$REPO_NAME" ] && { err "--repo is required"; usage 1; }
[ -z "$SERVER_CLONE_BASE" ] && SERVER_CLONE_BASE="/home/${SERVER_USER}/docker"
[ -z "$DESCRIPTION" ] && DESCRIPTION="Source of truth for ${REPO_NAME}"

case "$VISIBILITY" in
  private|public) ;;
  *) die "--visibility must be 'private' or 'public', got: $VISIBILITY" ;;
esac

# Sanitize repo name for use in deploy key filename (replace - with _)
DEPLOY_KEY_NAME="github_${REPO_NAME//-/_}_deploy"
SSH_ALIAS="github-${REPO_NAME}"
MAC_CLONE_PATH="${MAC_CLONE_BASE}/${REPO_NAME}"

# ---------- Pre-flight checks ----------
info "Pre-flight checks"

command -v gh  >/dev/null 2>&1 || die "gh CLI not found. Install: https://cli.github.com"
command -v git >/dev/null 2>&1 || die "git not found"

gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
GH_ACCOUNT=$(gh api user --jq .login)
ok "GitHub auth: $GH_ACCOUNT"

# Check repo doesn't already exist
if gh repo view "${GH_ACCOUNT}/${REPO_NAME}" >/dev/null 2>&1; then
  die "Repo ${GH_ACCOUNT}/${REPO_NAME} already exists. Pick a different --repo name."
fi
ok "Repo name available: ${GH_ACCOUNT}/${REPO_NAME}"

# Check Mac clone path doesn't exist
[ -e "$MAC_CLONE_PATH" ] && die "Mac clone path already exists: $MAC_CLONE_PATH"
ok "Mac path clear: $MAC_CLONE_PATH"

# Check SSH to server works
ssh -o BatchMode=yes -o ConnectTimeout=5 "${SERVER_USER}@${SERVER_HOST}" "true" 2>/dev/null \
  || die "SSH to ${SERVER_USER}@${SERVER_HOST} failed (need key-based auth, no password)"
ok "SSH reachable: ${SERVER_USER}@${SERVER_HOST}"

# Check server-side preconditions
SERVER_CHECKS=$(ssh "${SERVER_USER}@${SERVER_HOST}" bash -s <<EOF
set -e
[ -d "${SERVER_CLONE_BASE}" ] || { echo "MISSING_BASE"; exit 0; }
[ -e "${SERVER_CLONE_BASE}/${REPO_NAME}" ] && { echo "CLONE_EXISTS"; exit 0; }
[ -e "\$HOME/.ssh/${DEPLOY_KEY_NAME}" ] && { echo "KEY_EXISTS"; exit 0; }
if [ -f "\$HOME/.ssh/config" ] && grep -q "^Host ${SSH_ALIAS}\$" "\$HOME/.ssh/config"; then
  echo "ALIAS_EXISTS"; exit 0
fi
echo "OK"
EOF
)

case "$SERVER_CHECKS" in
  OK)            ok "Server preconditions clear" ;;
  MISSING_BASE)  die "Server base directory missing: ${SERVER_CLONE_BASE}" ;;
  CLONE_EXISTS)  die "Server clone path already exists: ${SERVER_CLONE_BASE}/${REPO_NAME}" ;;
  KEY_EXISTS)    die "Deploy key already exists on server: ~/.ssh/${DEPLOY_KEY_NAME}" ;;
  ALIAS_EXISTS)  die "SSH config alias already exists on server: Host ${SSH_ALIAS}" ;;
  *)             die "Unknown server pre-flight result: $SERVER_CHECKS" ;;
esac

# ---------- Confirmation ----------
echo
echo "========================================"
echo "About to bootstrap: ${GH_ACCOUNT}/${REPO_NAME}"
echo "========================================"
echo "  Visibility:        ${VISIBILITY}"
echo "  Description:       ${DESCRIPTION}"
echo "  Mac clone:         ${MAC_CLONE_PATH}"
echo "  Server:            ${SERVER_USER}@${SERVER_HOST}"
echo "  Server clone:      ${SERVER_CLONE_BASE}/${REPO_NAME}"
echo "  Deploy key (server): ~/.ssh/${DEPLOY_KEY_NAME}"
echo "  SSH alias:         ${SSH_ALIAS}"
echo "========================================"
echo

if [ "$NO_CONFIRM" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " response
  case "$response" in
    [yY]|[yY][eE][sS]) ;;
    *) die "Aborted by user." ;;
  esac
fi

# ---------- Step 1: Mac working clone ----------
info "Creating Mac working clone at ${MAC_CLONE_PATH}"
mkdir -p "$MAC_CLONE_PATH"
cd "$MAC_CLONE_PATH"
git init -q -b main

# Find templates relative to this script
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

if [ -d "$TEMPLATE_DIR" ]; then
  # Render templates with substitution
  sed -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
      -e "s|{{GH_ACCOUNT}}|${GH_ACCOUNT}|g" \
      -e "s|{{MAC_CLONE_PATH}}|${MAC_CLONE_PATH}|g" \
      -e "s|{{SERVER_HOST}}|${SERVER_HOST}|g" \
      -e "s|{{SERVER_USER}}|${SERVER_USER}|g" \
      -e "s|{{SERVER_CLONE_PATH}}|${SERVER_CLONE_BASE}/${REPO_NAME}|g" \
      -e "s|{{SSH_ALIAS}}|${SSH_ALIAS}|g" \
      "${TEMPLATE_DIR}/README.md.template" > README.md
  cp "${TEMPLATE_DIR}/.gitignore.template" .gitignore
else
  # Fallback minimal templates if templates/ missing
  printf '# %s\n\n%s\n' "$REPO_NAME" "$DESCRIPTION" > README.md
  printf '.DS_Store\n.env\n*.pem\n*.key\n' > .gitignore
fi

git add .
git commit -q -m "Initial commit: ${REPO_NAME} bootstrap"
ok "Mac clone initialized + initial commit made"

# ---------- Step 2: Create GitHub repo + push ----------
info "Creating GitHub repo: ${GH_ACCOUNT}/${REPO_NAME} (${VISIBILITY})"
gh repo create "$REPO_NAME" \
  "--${VISIBILITY}" \
  --source=. \
  --push \
  --description "$DESCRIPTION" >/dev/null
ok "GitHub repo created + initial commit pushed"

# ---------- Step 3: Generate deploy key on server ----------
info "Generating deploy key on ${SERVER_HOST}: ~/.ssh/${DEPLOY_KEY_NAME}"
ssh "${SERVER_USER}@${SERVER_HOST}" bash -s <<EOF
set -e
ssh-keygen -t ed25519 \
  -f "\$HOME/.ssh/${DEPLOY_KEY_NAME}" \
  -N "" \
  -C "${REPO_NAME} deploy key (\$(hostname))" \
  >/dev/null
EOF

PUB_KEY=$(ssh "${SERVER_USER}@${SERVER_HOST}" "cat ~/.ssh/${DEPLOY_KEY_NAME}.pub")
KEY_FP=$(ssh "${SERVER_USER}@${SERVER_HOST}" "ssh-keygen -lf ~/.ssh/${DEPLOY_KEY_NAME}.pub" | awk '{print $2}')
ok "Deploy key generated. Fingerprint: $KEY_FP"

# ---------- Step 4: Register as repo-scoped read-only deploy key ----------
info "Registering deploy key on GitHub (read-only, repo-scoped)"
DEPLOY_KEY_TITLE="${SERVER_HOST} (read-only, $(date -u +%Y-%m-%d))"
gh api "repos/${GH_ACCOUNT}/${REPO_NAME}/keys" \
  -f "title=${DEPLOY_KEY_TITLE}" \
  -f "key=${PUB_KEY}" \
  -F "read_only=true" >/dev/null
ok "Deploy key registered as repo-scoped read-only"

# ---------- Step 5: Add per-repo SSH alias on server ----------
info "Adding SSH alias '${SSH_ALIAS}' to server's ~/.ssh/config"
ssh "${SERVER_USER}@${SERVER_HOST}" bash -s <<EOF
set -e
touch ~/.ssh/config
chmod 600 ~/.ssh/config
cat >> ~/.ssh/config <<CFG

# ${REPO_NAME} (auto-added by git-sot-bootstrap on \$(date -u +%Y-%m-%d))
Host ${SSH_ALIAS}
    HostName github.com
    User git
    IdentityFile ~/.ssh/${DEPLOY_KEY_NAME}
    IdentitiesOnly yes
CFG
EOF
ok "SSH alias added"

# ---------- Step 6: Verify auth ----------
info "Verifying SSH auth (expect 'Hi ${GH_ACCOUNT}/${REPO_NAME}!')"
RESP=$(ssh "${SERVER_USER}@${SERVER_HOST}" "ssh -T ${SSH_ALIAS} 2>&1 || true")
if printf '%s' "$RESP" | grep -q "Hi ${GH_ACCOUNT}/${REPO_NAME}!"; then
  ok "Auth verified: repo-scoped deploy key working"
elif printf '%s' "$RESP" | grep -q "Hi ${GH_ACCOUNT}!"; then
  err "Auth response shows account-level (Hi ${GH_ACCOUNT}!), not repo-scoped."
  err "This means the deploy key was added at the account level, not the repo."
  die "Manual intervention required."
else
  err "Unexpected auth response:"
  printf '%s\n' "$RESP" >&2
  die "Auth verification failed."
fi

# ---------- Step 7: Clone to server ----------
info "Cloning ${REPO_NAME} to ${SERVER_CLONE_BASE}/${REPO_NAME}"
ssh "${SERVER_USER}@${SERVER_HOST}" \
  "cd ${SERVER_CLONE_BASE} && git clone -q ${SSH_ALIAS}:${GH_ACCOUNT}/${REPO_NAME}.git ${REPO_NAME}"
ok "Cloned"

# ---------- Step 8: End-to-end pull verification ----------
info "Running 'git pull' on server to verify the loop"
PULL_RESP=$(ssh "${SERVER_USER}@${SERVER_HOST}" \
  "cd ${SERVER_CLONE_BASE}/${REPO_NAME} && git pull 2>&1")
if printf '%s' "$PULL_RESP" | grep -qE "Already up to date|up-to-date"; then
  ok "End-to-end loop verified"
else
  err "Unexpected pull response:"
  printf '%s\n' "$PULL_RESP" >&2
  die "Pull verification failed."
fi

# ---------- Done ----------
echo
echo "========================================"
ok "Bootstrap complete: ${GH_ACCOUNT}/${REPO_NAME}"
echo "========================================"
cat <<SUMMARY

  Repo URL:        https://github.com/${GH_ACCOUNT}/${REPO_NAME}
  Visibility:      ${VISIBILITY}
  Mac clone:       ${MAC_CLONE_PATH}
  Server clone:    ${SERVER_USER}@${SERVER_HOST}:${SERVER_CLONE_BASE}/${REPO_NAME}
  Deploy key:      ${KEY_FP}
  SSH alias:       ${SSH_ALIAS}

  Workflow going forward:
    Edit on Mac  →  cd ${MAC_CLONE_PATH} && git add . && git commit && git push
    On server    →  cd ${SERVER_CLONE_BASE}/${REPO_NAME} && git pull

SUMMARY
