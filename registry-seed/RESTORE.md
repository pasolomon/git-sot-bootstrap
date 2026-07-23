# RESTORE — rebuilding the working set on a new machine

Assumes: the Mac is gone. GitHub survives (it is the source of truth).

## 1. Prerequisites

```bash
xcode-select --install                     # git
brew install gh git-lfs
gh auth login                              # as pasolomon
git lfs install
```

## 2. Bootstrap tooling + registry

```bash
mkdir -p ~/Projects/_Tooling
git clone git@github.com:pasolomon/git-sot-bootstrap.git ~/Projects/_Tooling/git-sot-bootstrap
git clone git@github.com:pasolomon/cowork-project-registry.git ~/Projects/_registry
```

## 3. Restore projects

```bash
cd ~/Projects/_Tooling/git-sot-bootstrap
./bootstrap.sh restore --active            # everything marked active in PROJECTS.yaml
# or one project:
./bootstrap.sh restore --repo jl-soaps
```

Each restore clones with `--recurse-submodules`, pulls LFS objects, and lands
at the registry-recorded path. Then run `./bootstrap.sh validate --all` and
review the report.

## 4. Per-project recovery detail

Every project carries its own `RECOVERY.md`, including the explicit list of
anything that was local-only. Read it before assuming the restore is complete.

## 5. Server fallback (if GitHub is ALSO unreachable)

Pull-only clones live on ubuntu-sumrall (`192.168.1.253`) under
`/home/psolomon/docker/`. Copy them off; do not commit from them.

## 6. SSH keys note

Deploy keys live on the server and are repo-scoped read-only. The new Mac needs
its own SSH key added to the GitHub account (`gh ssh-key add`).
