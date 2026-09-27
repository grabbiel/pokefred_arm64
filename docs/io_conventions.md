# Workspace I/O conventions (Shuverse)

Owned by Workspace I/O. Other bots follow this so concurrent Metal / Editor UI / Serializer / Pixel Pipeline / AST PRs do not stomp shared files.

## Paths

| Path | Role | Git |
|---|---|---|
| `ShuverseEditor/` | Metal editor (arm64) | tracked |
| `tools/pixel_pipeline/` | GBA 4bpp pixel crunch | tracked |
| `tools/*.py` | Map/script parse + serialize CLIs | track when ready (separate PR OK) |
| `docs/` | Suite contracts | tracked |
| `parsed/` | Generated map JSON cache | **gitignore** |
| `source/` | Nested RGBDS tree (local only) | **gitignore** |
| `pallet_town_parsed.json` | Local sample dump | **gitignore** |
| `.shuverse-locks/` | Per-path write locks | **gitignore** |
| pret `pokefirered` (sibling decomp) | Read-only source of truth | never rewrite without dry-run + user save |

## Protected shared files

Only Workspace I/O (or an explicitly coordinated PR) may change:

- root `.gitignore`
- `.github/workflows/*`
- root `CMakeLists.txt` / top-level build manifests (when present)
- this file (`docs/io_conventions.md`)

Feature bots edit only their owned trees. Need a shared-file change? Open a tiny PR that touches only that file and link it from your feature PR — do not bake `.gitignore` or workflow edits into unrelated Metal/pixel PRs.

## Branch hygiene

- One concern per branch/PR.
- Name branches `cursor/<area>-<short-slug>` (existing convention).
- Rebase/ff onto `main` before review; do not force-push shared branches.
- Never commit `parsed/`, `source/`, `__pycache__/`, `.build/`, or lock files.

## Write locks (local multi-agent)

Before writing a path under this workspace:

1. Claim `.shuverse-locks/<sha1(relpath)>.lock` with agent id + expiry (~5 minutes).
2. One writer per path; readers need no lock.
3. Atomic writes: `*.tmp` → `fsync` → rename.
4. Decomp (`pokefirered`): read-only by default; Serializer dry-run first; user save intent before real writes; no auto-commit.

## Ownership (writes)

| Owner | May write |
|---|---|
| AST Parser | `parsed/` (local cache), read decomp |
| Serializer | decomp map artifacts only after dry-run + user intent |
| Pixel Pipeline | `tools/pixel_pipeline/` |
| Metal / Editor UI | `ShuverseEditor/` |
| Workspace I/O | locks, `.gitignore`, workflows, `docs/io_conventions.md`, coordination |

Hand results in chat after each batch; clear locks in a `finally` path.
