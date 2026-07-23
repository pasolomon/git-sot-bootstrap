# cowork-project-registry

**Private.** Project identity and recovery metadata for the Cowork project
source-of-truth system. This repo stores *metadata only* — never project assets.

- Source of truth for project files: each project's own GitHub repo.
- Local working copies: `~/Projects` (see `PROJECTS.yaml` for the map).
- Server: pull-only fallback clones on ubuntu-sumrall.
- Tooling: [`pasolomon/git-sot-bootstrap`](https://github.com/pasolomon/git-sot-bootstrap)
  (`new` / `adopt` / `migrate` / `restore` / `validate` / `repair`).

| File | Purpose |
|---|---|
| `PROJECTS.yaml` | Registry of every project: repo, local path, category, status |
| `MACHINES.yaml` | Machines that hold clones and their roles |
| `TOOL_CATALOG.md` | Cross-project tools, MCPs, and skills |
| `MIGRATION_STATUS.md` | Where each legacy project stands in migration |
| `RESTORE.md` | How to rebuild the whole working set on a new machine |
| `CHANGELOG.md` | Registry-level change history |
| `templates/` | Pointers to canonical templates (live in git-sot-bootstrap) |
| `migrations/` | Records of completed migrations |

## Disaster recovery, in one paragraph

Install `git`, `gh` (auth as `pasolomon`), and `git-lfs`. Clone
`git-sot-bootstrap`, then run `bootstrap.sh restore --active`. It reads
`PROJECTS.yaml` from this registry, clones every active project (with
submodules and LFS objects) to its recorded path under `~/Projects`, and
verifies remotes. Full detail: `RESTORE.md`.
