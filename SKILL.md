---
name: cowork-project-system
description: Drives Peter's Cowork project source-of-truth system (git-sot-bootstrap v2). Trigger whenever Peter asks to open a project, resume project work, start a new project, migrate a project, restore projects onto a machine, clean a project, save/close the session, prepare work for another computer, find prior project decisions, or find project assets. Also trigger on "pick up where we left off", "what were we doing on X", "new client project", "adopt this folder", "is everything pushed", or any mention of ~/Projects project lifecycle. GitHub (account pasolomon) is the durable source of truth; ~/Projects holds working clones; ubuntu-sumrall holds pull-only fallback clones.
---

# Cowork Project System

Projects live under `~/Projects` (categories → repos). The registry
`pasolomon/cowork-project-registry` (clone: `~/Projects/_registry`,
`PROJECTS.yaml`) maps every project. The tooling is
`~/Projects/_Tooling/git-sot-bootstrap/bootstrap.sh`:

```
new --repo NAME [--category CAT]   adopt --path PATH --repo NAME
migrate --all [--dry-run]          restore --repo NAME | --active
validate --all | --repo NAME       repair --repo NAME
```

All modes are idempotent and log to `~/.local/state/git-sot-bootstrap/`.
Never use `git reset --hard`, force-push, or history rewrites. Never commit
secrets or unlicensed fonts. Never push from the server clone.

## Identify the project

1. Match what Peter said against `~/Projects/_registry/PROJECTS.yaml` keys,
   then against `~/Projects/*/` folder names, then `README`s. Ask only if
   genuinely ambiguous.
2. `cd` to the project's `local_path`.

## Project startup (run in order, silently)

1. Confirm the working directory (`pwd` = the project's local_path).
2. Read `.cowork/project.yaml`.
3. Confirm `git remote get-url origin` matches the yaml's github entry.
4. `git fetch origin`.
5. Inspect uncommitted changes (`git status --porcelain`).
6. Detect divergence (`git rev-list --left-right --count @{upstream}...HEAD`).
   Diverged? Stop and tell Peter — do not auto-merge, never reset/force.
7. Read `COWORK.md` (project-specific discipline — it wins on conflicts).
8. Read `README.md`.
9. Read `SESSION_STATE.md`.
10. Read `DECISIONS.md`.
11. Read `ASSET_INDEX.md`.
12. Read `TOOL_MANIFEST.md`.
13. Read the newest file in `sessions/`.
14. `gh issue list` (open Issues) + relevant PRs (`gh pr list`).
15. Verify critical tools from TOOL_MANIFEST (git-lfs, Adobe apps as needed).
16. Resume from the documented state. Do NOT ask Peter to repeat anything
    already recorded in these files.

## Adobe safety (before ANY file move/rename)

```bash
osascript -e 'tell application "System Events" to (name of processes) contains "Adobe Illustrator"'
osascript -e 'tell application "Adobe Illustrator" to get name of every document'
```

Open documents = do not move their files or anything they might link. Same
check for Photoshop/InDesign. Never move files under `assets/linked/` without
relinking. Run the project's link scan (e.g. JL-Soaps `scripts/linkscan.py`)
after any asset reorganization.

## Session close ("save the session", "wrap up", end of work)

1. Save active files (if Adobe apps have unsaved docs, prompt Peter to save).
2. Move new assets into the correct project folders (Adobe check first).
3. Update `ASSET_INDEX.md` for anything added/moved (with SHA-256).
4. Record new decisions in `DECISIONS.md`.
5. Update `SESSION_STATE.md` to the exact current state.
6. Create `sessions/YYYY-MM-DD-HHMM.md` from the session-record template.
7. Update GitHub Issues (close done, open discovered).
8. Review `git status` in the project AND its submodules.
9. Commit meaningful work — meaningful messages, no `final-final-v2` naming.
10. `git push` (submodules first, then bump pointers in the umbrella).
11. Verify: `git rev-list --left-right --count @{upstream}...HEAD` → `0 0`,
    and `git lfs ls-files` uploads completed.
12. Report anything remaining local-only, explicitly (cross-check the
    project's `RECOVERY.md` disclosure list and update it).

## Lifecycle requests

- **Start/new project** → `bootstrap.sh new --repo NAME [--category CAT]`
  (private by default; confirm name/category with Peter first).
- **Adopt existing folder** → `bootstrap.sh adopt --path PATH --repo NAME`.
- **Migrate everything** → `migrate --all --dry-run`, show Peter the report,
  get approval, then `migrate --all`.
- **Restore on this/another computer** → `restore --repo NAME` or
  `restore --active` (reads the registry; see registry `RESTORE.md`).
- **Clean a project** → follow the Phase-6 pattern: safe deletions only
  (OS metadata, lock files, empty dirs, zero-byte, verified exact dupes),
  archive meaningful versions, quarantine anything uncertain, write a
  quarantine report, surface uncertain items to Peter. Never delete client
  assets, masters, approved artwork, production files, dielines, licensing
  records, linked assets, or sole copies.
- **Find decisions** → `DECISIONS.md` (+ product SourceOfTruth docs listed
  there); **find assets** → `ASSET_INDEX.md`, then `git log --follow`.
- **Health check** → `bootstrap.sh validate --all` and read the report.

## GitHub standards

Issues for outstanding work/missing assets/client changes/printer questions.
Branches + PRs for substantial or structural work. Milestones for phases.
Tags/releases for approved and production-ready states. `main` = stable.
