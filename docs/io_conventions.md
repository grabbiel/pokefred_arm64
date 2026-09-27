# Workspace I/O conventions (Shuverse)

Owned by Workspace I/O. Other bots follow this so concurrent Metal / Editor UI / Serializer / Pixel Pipeline / AST PRs do not stomp shared files.

## Paths

| Path | Role | Git |
|---|---|---|
| `ShuverseEditor/` | Metal map canvas + Dear ImGui dock shell (arm64) | tracked |
| `ShuverseEditor/ImGuiHost/` | Vendored ImGui + C host (Editor UI) | tracked |
| `ShuverseEditor/Samples/` | Parser JSON + baked tileset bits for demos | tracked |
| `tools/pixel_pipeline/` | GBA 4bpp pixel crunch (CLI + tanoby, game corner, pallet town, mart, and school goldens) | tracked |
| `tools/*.py` | Map/script parse + serialize CLIs | track when ready (separate PR OK) |
| `docs/` | Suite contracts | tracked |
| `/parsed/` | Generated map JSON cache (repo root) | **gitignore** |
| `/source/` | Nested RGBDS tree at repo root only | **gitignore** |
| `pallet_town_parsed.json` | Local sample dump at repo root | **gitignore** |
| `/.shuverse-locks/` | Per-path write locks | **gitignore** |
| pret `pokefirered` (sibling decomp) | Read-only source of truth | never rewrite without dry-run + user save |

Root-anchored ignores (`/source/`, `/parsed/`, `/.shuverse-locks/`) must stay anchored so they cannot case-fold into `ShuverseEditor/Sources/` or similar.

## Protected shared files

Only Workspace I/O (or an explicitly coordinated tiny PR) may change:

- root `.gitignore`
- `.github/workflows/*`
- root `CMakeLists.txt` / top-level build manifests (when present)
- this file (`docs/io_conventions.md`)

Feature bots edit only their owned trees. Need a shared-file change? Open a tiny PR that touches only that file and link it from your feature PR — do not bake `.gitignore` or workflow edits into unrelated Metal / ImGui / pixel PRs.

## Branch hygiene

- One concern per branch/PR.
- Name branches `cursor/<area>-<short-slug>` (existing convention).
- Rebase/ff onto `main` before review; do not force-push shared branches.
- Never commit `/parsed/`, `/source/`, `__pycache__/`, `.build/`, or lock files.

## Write locks (local multi-agent)

Before writing a path under this workspace:

1. Claim `.shuverse-locks/<sha1(relpath)>.lock` with agent id + expiry (~5 minutes).
2. One writer per path; readers need no lock.
3. Atomic writes: `*.tmp` → `fsync` → rename.
4. Decomp (`pokefirered`): read-only by default; Serializer dry-run first; user save intent before real writes; no auto-commit.

## Ownership (writes)

| Owner | May write |
|---|---|
| AST Parser | `parsed/` local cache only (gitignored). Script presets: Pallet→Pewter corridor (30) plus Cerulean cluster (30) via `--cerulean` / `--script-coverage` (60). No decomp writes. |
| Serializer | decomp `map.bin` / `border.bin` / `map.json` only with explicit `--write` (dry-run default). One map’s three files roll back as a group. |
| Pixel Pipeline | `tools/pixel_pipeline/` including checked goldens (tanoby, game corner, pallet town, mart, school) |
| Metal Render | map GPU path in `ShuverseEditor/` (`MapCanvasView`, `MapGPUState`, `MapShaders`, map tileset upload). Not docks or swatch sheets. |
| Editor UI | `ShuverseEditor/ImGuiHost/`, dock overlay, and Tileset metatile swatches inside `ShuverseEditor/` |
| Workspace I/O | locks, root `.gitignore`, workflows, `docs/io_conventions.md`, coordination |

Script coverage is additive `parsed/<Map>.scripts.json`. `parse_scripts.py` resolves shared labels under `data/scripts/*.inc`, then falls back to Common_* attendants in `data/event_scripts.s`. `understanding_pipeline.py --scripts-corridor` refreshes the 60-map union. Those tools do not commit `parsed/` and do not write the decomp.

ImGui and the map canvas share the window but use **separate** Metal command queues. Tileset swatches stay on the ImGui queue; the map `FrameRing` stays with Metal Render. Do not merge their buffer ownership or stall either path on disk I/O.

Hand results in chat after each batch; clear locks in a `finally` path.
