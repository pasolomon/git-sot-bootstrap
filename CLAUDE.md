# CLAUDE.md — git-sot-bootstrap

Instructions for Claude Code and any other coding agent working in this repository.

## What this is
One-command setup for a "source of truth" GitHub repository with a Mac working clone and a pull-only fallback clone on a server.

## Read at session start
- `README.md` — what the script does, the prerequisites, and why each repository gets its own SSH alias.
- `SKILL.md` if you are using this as a Claude skill.

## Rules
- GitHub `main` is the source of truth. Fetch and fast-forward before working. Never force-push or rewrite history.
- This repository is public. Never commit secrets, credentials, tokens, or personal data.
- Commit only what you changed.
- `bootstrap.sh` creates repositories, deploy keys, and SSH configuration. Do not run it to test a change without the owner's go-ahead; read the code path, or use a throwaway name.
- Deploy keys are read-only and scoped to one repository. Do not widen that.
- Keep machine-specific values out of the script. They are passed as flags.
- Files in `templates/` are copied into new repositories. A change there affects every future bootstrap.

## Before you finish
- Commit and push, then confirm the local branch matches `origin/main`.
