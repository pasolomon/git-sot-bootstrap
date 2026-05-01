# git-sot-bootstrap

One-command setup for "source of truth" GitHub repos with a Mac working clone and a server pull-only fallback clone.

## What it does

For a given project name, automates this entire pattern:

1. Creates a private (or public) GitHub repo
2. Initializes a working clone on your Mac with a templated README + `.gitignore`
3. Pushes the initial commit
4. Generates an ed25519 deploy key on your server
5. Registers it on the GitHub repo as **read-only, repo-scoped** (not account-level)
6. Adds a per-repo SSH `Host` alias on the server (so multiple bootstrapped repos coexist)
7. Clones to the server using that alias
8. Verifies end-to-end with `ssh -T` + `git pull`

The whole thing runs in roughly 30 seconds with no prompts beyond a single confirmation.

## Why per-repo SSH aliases

Using a single `Host github.com` block on the server only works for one repo at a time — a second deploy key would clash. This script gives every bootstrapped repo its own alias (e.g., `github-myproject`) and matching `IdentityFile`, so any number of source-of-truth repos can live on one server without stepping on each other.

## Prerequisites

- **On the Mac:**
  - [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth status`)
  - `git` installed
- **Server:**
  - Reachable via key-based SSH (no password) from the Mac
  - The `--server-clone-base` directory (default `/home/USER/docker`) must exist

## Quick start

```bash
git clone https://github.com/pasolomon/git-sot-bootstrap.git
cd git-sot-bootstrap
./bootstrap.sh --repo my-new-project
```

That's it. Defaults assume the homelab setup (server `192.168.1.253`, user `psolomon`, base `/home/psolomon/docker`).

## All options

```
--repo NAME              Required. Name of the new GitHub repo.
--server HOST            Server hostname or IP. Default: 192.168.1.253
--user USER              Server SSH user. Default: psolomon
--mac-clone-base PATH    Where to put the Mac clone. Default: $HOME
                         Final Mac path = PATH/REPO_NAME
--server-clone-base PATH Where to put the server clone. Default: /home/USER/docker
                         Final server path = PATH/REPO_NAME
--visibility V           "private" or "public". Default: private
--description TEXT       GitHub repo description. Default: "Source of truth for REPO"
--no-confirm             Skip the confirmation prompt
-h, --help               Show help
```

## Safety / pre-flight checks

The script aborts before making any changes if:

- `gh` is not installed or not authenticated
- The target GitHub repo name already exists under your account
- The Mac clone path already exists
- SSH to the target server fails
- The server-side base directory is missing
- A deploy key with the same name already exists on the server
- An SSH `Host` alias with the same name already exists on the server

Once preconditions pass, it shows you a summary and asks for confirmation (unless `--no-confirm`).

## What ends up where

After a successful run with `--repo myproject` against the default server:

| Where | What |
|---|---|
| GitHub | `pasolomon/myproject` (private), with one initial commit |
| Mac | `~/myproject/` — full read/write working clone |
| Server | `/home/psolomon/docker/myproject/` — pull-only clone |
| Server | `~/.ssh/github_myproject_deploy` — ed25519 keypair |
| Server | `~/.ssh/config` — appended `Host github-myproject` block |
| GitHub | Repo "Deploy keys" page — entry titled `<server> (read-only, YYYY-MM-DD)` |

## Workflow after bootstrapping

```
# Edit on Mac
cd ~/myproject
# ...edit files...
git add .
git commit -m "..."
git push

# On server
cd /home/psolomon/docker/myproject
git pull
```

## What it does NOT do

- **No idempotency / re-run support.** If a step half-completes and you re-run, you'll hit one of the pre-flight checks. Clean up manually and try again.
- **No teardown.** There's no `--undo`. If you bootstrapped wrong: delete the GitHub repo, delete the Mac directory, `rm` the deploy key files on the server, edit `~/.ssh/config` to remove the alias block, `rm -rf` the server clone.
- **No backup of canonical files.** The bootstrap creates an empty repo with only a README and `.gitignore`. Adding actual canonical files (state JSON, runbook, changelog, configs) is project-specific work you do after.
- **Does not migrate existing repos.** If you have a source-of-truth set up the old way (e.g., `Host github.com` with no alias), this script won't refactor it. New repos get aliases; existing repos keep whatever you set up before.

## Using with Claude

A `SKILL.md` ships with this repo. Install it as a Claude skill (per-account, via Claude.ai's skill management UI) and Claude will recognize source-of-truth setup requests in any future conversation and run this script for you.

## License

Public-domain / CC0. Use however you want.
