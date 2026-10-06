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

<!-- tool-discovery:begin -->
## Tool discovery protocol (added 2026-10-05; additive, does not override anything above)

Before saying something cannot be done, find out what tools you actually have.

1. At the start of any task, list the available tools and MCP servers. In Claude, deferred tools show up by name only and must be loaded with ToolSearch before they can be called. In other agents, use the equivalent tool or MCP listing.
2. The cloud or sandbox shell is a different machine from Peter's Mac. For local files, git, ssh, scp or osascript, use Desktop Commander (or the local device shell). Do not conclude "no access" from the sandbox.
3. For a problem on a live website, open the live URL in a real browser first. Read the console and network requests and take a screenshot before reading code. Describe what you see, then diagnose.
4. For servers and caches, use the Cloudways tools or `ssh cloudways` as described in RUNBOOK.md (if this repo has one).
5. Report "cannot do it" only after naming the specific tools you tried and the exact error each returned. If an action is denied by a permission or safety check, report it and stop. Do not retry it by another route.
6. Repo rules still apply: GitHub is the source of truth, `peter-knowledge-base.json` never goes into any repo, and nothing in a repo may contain secrets.
<!-- tool-discovery:end -->
