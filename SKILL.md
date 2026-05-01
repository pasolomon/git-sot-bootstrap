---
name: source-of-truth-bootstrap
description: Use this skill whenever the user wants to set up version control + GitHub as the canonical source of truth for a project's documentation/state files, with a Mac working clone and a server pull-only fallback. Triggers include "set up source of truth", "git-ify this project", "make this a GitHub repo", "version control my runbook/state/configs", "do what we did for the homelab but for X", "bootstrap a new project repo", or any request to standardize this pattern across a new system. Particularly relevant when the user already has canonical documentation files (runbook, state JSON, changelog, configs) sitting on a server or Mac that should move into git.
---

# Source of Truth Bootstrap

Automates the pattern of standing up a private (or public) GitHub repo as the source of truth for a project, with a Mac working clone and a server pull-only fallback clone authenticated by a repo-scoped read-only deploy key.

## When to invoke

Trigger when the user wants to:

- Set up GitHub version control for a project's canonical files
- Standardize the source-of-truth pattern across multiple systems
- "Do what we did for X but for Y" (where X used this same pattern)
- Migrate canonical files off a server into git for backup + version history
- Set up a new project that should follow the established homelab pattern

## What this skill knows

The user has a script at `https://github.com/pasolomon/git-sot-bootstrap` that automates the entire bootstrap. The script:

1. Creates a private/public GitHub repo
2. Initializes a Mac working clone with templated README + `.gitignore`
3. Pushes the initial commit
4. Generates an ed25519 deploy key on the target server
5. Registers it as **read-only, repo-scoped** (this is critical — not account-level)
6. Adds a per-repo SSH `Host` alias on the server so multiple repos coexist
7. Clones to the server using that alias
8. Verifies end-to-end

## How to use

### Step 1 — Confirm the parameters with the user

Required:
- **Repo name** (will become both GitHub repo name and local directory name)

Defaults that should be confirmed (or overridden):
- Server host (default `192.168.1.253`)
- Server user (default `psolomon`)
- Mac clone base path (default `$HOME`, so final path = `~/REPO_NAME`)
- Server clone base path (default `/home/USER/docker`)
- Visibility (default `private`)
- Description (default `Source of truth for REPO`)

Confirm all relevant defaults before running. If the user is bootstrapping for a different server or non-homelab system, the defaults likely need to change.

### Step 2 — Ensure the bootstrap script is available locally

Either clone the repo:
```bash
git clone https://github.com/pasolomon/git-sot-bootstrap.git /tmp/git-sot-bootstrap
```

Or `cd` to an existing checkout if the user already has one.

### Step 3 — Run the script

```bash
cd /tmp/git-sot-bootstrap
./bootstrap.sh --repo NAME [--server HOST] [--user USER] [--visibility public|private] [other options]
```

The script will print a summary and ask for confirmation before making changes. Pass `--no-confirm` only if the user has already confirmed in chat.

### Step 4 — Verify success

The script prints a final summary on success. Confirm with the user that:
- The GitHub repo URL is reachable
- The Mac clone has the templated files
- A `git pull` on the server returns "Already up to date"

### Step 5 — Next steps after bootstrap

The bootstrap creates an *empty* repo (just README + `.gitignore`). The user almost certainly wants to:

1. Add their actual canonical files (state JSON, runbook, changelog, configs)
2. Update README to describe what's tracked in *this* particular repo
3. Commit and push from Mac, pull on server

Offer to do these steps if the user has source files in mind.

## Critical correctness checks

- **The deploy key must be repo-scoped, not account-level.** The script verifies this by checking that `ssh -T <alias>` responds `Hi USER/REPO!` (with the `/REPO` suffix). If it responds with just `Hi USER!`, the key was added at the account level — which gives the server access to *every* repo the account can reach. The script will detect this and abort.

- **Per-repo SSH aliases are mandatory.** Using a generic `Host github.com` block breaks when a second repo is bootstrapped on the same server. The script always uses `Host github-REPO_NAME`.

- **The server clone is pull-only by design.** The deploy key is read-only, so pushes from the server would be rejected anyway. Never instruct the user to `git commit` or `git push` from the server.

## What this skill does NOT do

- Does not migrate existing source-of-truth setups to the alias pattern. If the user has an old setup (e.g., a single `Host github.com` block from before this script existed), suggest a separate manual refactor — don't try to do it as part of bootstrapping a new repo.
- Does not delete or undo. If something goes wrong, walk the user through manual cleanup; the script has no `--undo`.
- Does not handle non-default Git providers (GitLab, Gitea, self-hosted Git). Tied to GitHub via `gh` CLI.

## Reference

- Source: https://github.com/pasolomon/git-sot-bootstrap
- Original pattern (the homelab implementation): https://github.com/pasolomon/homelab-source-of-truth
