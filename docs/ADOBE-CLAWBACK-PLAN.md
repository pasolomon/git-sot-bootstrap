# Adobe-Clawback enhancement plan (Phase 8 — plan only, no implementation)

Prerequisite met: JL Soaps migration + restoration tests passed (2026-07-23).
Adobe-Clawback stays a separate tool in `~/Projects/_Tooling/adobe-clawback`
(repo `pasolomon/Adobe-Clawback`) — NOT merged into git-sot-bootstrap.

## Current state (audited)

Working PDF-only bulk downloader: Playwright + persistent Chromium profile →
IMS token capture → storage-API paginated walk (`type=application/pdf`) →
streamed downloads → `manifest.json` (sha256, etag, status, runs). Known gaps
the author already lists: single file type, sequential, headful-only, no tests.

## Planned enhancements

### 1. File-type expansion (the core ask)

- `--type` flag accepting repeatables / `all`, mapping to storage-API MIME
  filters: `application/illustrator` (.ai), `image/vnd.adobe.photoshop` /
  `application/photoshop` (.psd), `image/svg+xml`, `image/png`, `image/jpeg`,
  `image/tiff`, plus keep `application/pdf`.
- Verify per-type discovery against the same `:page` walk; some cloud-native
  formats (e.g. .psdc) need export-endpoint handling — flag as `needs-export`
  in the manifest rather than silently skipping.

### 2. Preserved Adobe folder structure

- Manifest already records `adobe_path`; add `--preserve-paths` to lay files
  out as `downloads/<adobe_path>` instead of flat + collision suffixes.

### 3. Project assignment

- New `assignments.yaml` (local, gitignored): glob/keyword rules mapping
  `adobe_path`/filename → registry project key (e.g. `*tibby*` → jl_soaps).
- `--assign` pass tags each manifest entry with its project; unmatched →
  `unassigned` bucket for human review (quarantine discipline).

### 4. Sanitized project-facing manifests

- Per-project export: `clawback-manifest.<project>.json` containing only
  name, adobe_path, sha256, sizes, modified — NO root URN, NO regional host,
  NO account identifiers. Safe to commit into a project's `assets/` records.

### 5. Controlled import into project asset folders

- `--import-to-project KEY` copies (never moves) assigned files into
  `<project>/assets/source/adobe-clawback/<adobe_path>`, honoring the
  project system's rules: Adobe open-document check first, SHA-256 verify
  after copy, ASSET_INDEX.md updated, committed via LFS by the normal
  session-close flow. Exact dupes already indexed are skipped.

### 6. Operational hygiene

- `manifest.json` and `assignments.yaml` stay local and gitignored (already
  true for the manifest; extend .gitignore).
- Registry TOOL_CATALOG entry documents the tool; per-project TOOL_MANIFEST
  references it where used.

## Sequencing

1. `--type` + preserved paths (pure downloader work, testable on PDFs first)
2. assignment rules + sanitized manifests
3. controlled import (depends on 1+2; uses the project system as the target)

Each step lands as a PR on a feature branch in Adobe-Clawback with a dry-run
mode, per the same safety standards as git-sot-bootstrap v2.
