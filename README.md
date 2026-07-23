# git-sot-bootstrap

**v2 — the Cowork Project Source-of-Truth System.**
GitHub is the durable source of truth. The Mac holds read/write working clones
under `~/Projects`. The server holds pull-only fallback clones authenticated by
repo-scoped read-only deploy keys with per-repo SSH aliases.

## Modes

```bash
./bootstrap.sh new      --repo NAME [--category CAT]   # create project + repo + template + server clone
./bootstrap.sh adopt    --path PATH --repo NAME        # bring an existing folder into the system
./bootstrap.sh migrate  --all [--dry-run]              # sweep ~/Projects, normalize every repo
./bootstrap.sh restore  --repo NAME | --active         # rebuild clones on a (new) machine from the registry
./bootstrap.sh validate --all | --repo NAME            # read-only health report
./bootstrap.sh repair   --repo NAME                    # idempotent re-provisioning of one project
```

Legacy `./bootstrap.sh --repo NAME` still works and maps to `new`.

## What every project gets

```
.cowork/project.yaml   README.md   COWORK.md   SESSION_STATE.md   DECISIONS.md
ASSET_INDEX.md   TOOL_MANIFEST.md   CHANGELOG.md   RECOVERY.md
sessions/   assets/{source,reference,brand,linked,fonts}/   working/
exports/{proofs,approved}/   production/   archive/   quarantine/
```

Template installation is a **merge**: existing files are never overwritten;
only missing pieces are added. Git LFS patterns (`*.ai *.aic *.psd *.psb
*.indd *.idml *.tif *.tiff *.pdf *.eps`) are written to `.gitattributes` and
apply to new commits only — existing history is never rewritten.

## Key behaviors

- **Idempotent.** Rerun any mode; each step reports `already-correct`,
  `created`, `repaired`, `requires-approval`, or `skipped`. No duplicate
  repos, keys, aliases, or folders are ever created.
- **Dry-run.** `--dry-run` on any mutating mode prints the plan and changes nothing.
- **Safe by construction.** No `git reset --hard`, no force-push, no history
  rewrites, no deletions. Adopt/migrate stage only files the script itself
  created — your untracked work is never swept into a commit.
- **Action log.** Every run appends to `~/.local/state/git-sot-bootstrap/actions.log`;
  reports land in `~/.local/state/git-sot-bootstrap/reports/`.

## The registry

`pasolomon/cowork-project-registry` (private) maps every project: repo, local
path, category, status, server clone. `restore --active` reads it to rebuild
the entire working set on a new machine. Seed files for creating it live in
`registry-seed/`. The registry stores metadata only — never project assets.

## Server fallback

Same architecture as v1: each repo gets its own ed25519 deploy key on the
server, registered on GitHub as **repo-scoped read-only**, with a per-repo
`Host github-<repo>` SSH alias so any number of repos coexist. Server clones
additionally get their push URL disabled. Never commit or push from the server.

## Prerequisites

- Mac: `git`, `gh` (authenticated), `git-lfs` (`brew install git-lfs && git lfs install`)
- Server: key-based SSH from the Mac; `git`; `git-lfs` (user-level install OK)

## Using with Claude

`SKILL.md` teaches Claude Cowork to recognize project open/resume/migrate/
restore/save requests and drive these modes. Install it as a Claude skill.

## History

v1 (2026-05-01) was a one-shot `--repo` bootstrapper with no rerun support.
v2 (2026-07) adds adopt/migrate/restore/validate/repair, idempotency, dry-run,
Git LFS, the standard project template, and the project registry.

## License

Public-domain / CC0.
