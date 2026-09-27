# Apple Silicon constraints (Shuverse Editor)

## UI shell (Editor UI / Dear ImGui)
Shipped dock shell is described in `ShuverseEditor/README.md` (PR #8). Editor UI / ImGuiHost owns the docks and the Tileset swatches. Metal Render owns the map GPU path (`MapCanvasView`, `MapGPUState`, `MapShaders`).

- Dear ImGui **v1.91.9b docking** is vendored under `ShuverseEditor/ImGuiHost/imgui` and built as the macOS-only `CImGuiHost` SwiftPM target. Official Metal/OSX `.mm` backends are not used; Swift hosts the overlay (`ImGuiOverlayView`, `ImGuiMetalRenderer`) on a **separate** command queue (`imgui-queue`) from the map canvas.
- Transparent overlay docks: **Map List**, **Inspector**, **Status**, **Tileset**. Central dock node is a pass-through hole (`hitTest` returns nil) so pan / zoom / pinch / click-inspect stay on `MapCanvasView`.
- Dock layout is session-only (no ini). The Tileset dock draws metatiles from the loaded 4bpp atlas and RGB555 palette (`MetatileSwatchSheet` / `GBATileset.sample`: bottom layer, then top; index 0 transparent). `ImGuiMetalRenderer.uploadSwatch` fills a shared RGBA texture on the ImGui path and the overlay draws it on `imgui-queue`. That sheet is not a map `FrameRing` slot and is not a `MapGPUState` tileset upload. A click shows the metatile id. Maps without a loaded 4bpp atlas keep the tileset names and a short note. The swatches do not drive the ground pass.
- Do not block the UI thread on disk I/O (see Serializer). Map GPU work and ImGui draw stay on efficiency vs performance cores as appropriate; never stall the `MTKView` present path for serialization.

## Metal canvas (real 4bpp path)
Canonical detail: `docs/metal_gpu.md` (updated in PR #9). This section is the short Apple Silicon contract.

- Shared grid: `MapMetatileGrid`, one `UInt32` per cell, `MTLStorageModeShared`. Triple-slot `FrameRing` + semaphore so the CPU does not write a buffer the GPU is still reading.
- Vertices: `[[stage_in]]` on map, canopy, and sprite paths; depth-stencil layers (ground 0.70, sprite stub 0.55, canopy leaves 0.40, markers 0.28, selection 0.15). One encoder batches canopy, the sprite stub, tiles, markers, and selection. Canopy is submitted before ground; less-than depth keeps the leaves in front. Depth `storeAction` is `.dontCare`.
- **Pallet Town ground is real GBA graphics**, not `MetatileColor`. Shared uploads (all `MTLStorageModeShared`, no managed blit):
  - `tileset-indices` — unpacked `.4bpp` nibbles as `r8Uint` (0…15), row stride ≥ `minimumLinearTextureAlignment`
  - `tileset-rgb555` — 16 banks × 16 little-endian RGB555 (`0bbbbbgggggrrrrr`)
  - `metatile-entries` — pret table, 1024 × 8 screen entries (flip + palette bits)
- Index 0 is transparent. Primary tiles 0–639, secondary from 640. Other maps leave ground undrawn (no fake-color fallback). Editor does **not** link `libpixel_pipeline.a`; bake via `Scripts/bake_pallet_town_tiles.py` + `tools/pixel_pipeline` CLI (`CONTRACT.md`).
- Imageblock `map_tile_overlay` remains a macOS stub only (not dispatched; no tile render pipeline; `overlayFlags` defaults to 0).

## Data Parser / Pixel Pipeline
- Hot paths through `.c` arrays / pixel data: ARM NEON SIMD (LD3/LD4 for interleaved RGB/RGBA).
- Align structs/allocations to **128-byte** cache lines (Apple Silicon), not 64-byte x86 assumptions.
- RGB24 → GBA RGB555: fixed-point NEON, not floating point. 4bpp pack: two 4-bit pixels per byte across 128-bit vectors where applicable.
- `make test` in `tools/pixel_pipeline/` checks nine pret FireRed tileset goldens: tanoby ruins, game corner, pallet town, mart, school, underground path, generic building 1, bike shop, and saffron gym. Pallet town is the third pret sheet: `data/tilesets/secondary/pallet_town/tiles.png` (128×40, 4-bit colormap, 16 grays, no tRNS) against `tests/golden/pallet_town_tiles.4bpp` (2560 bytes) and `.pal` (32 bytes). Mart (#17) is the fourth: `data/tilesets/secondary/mart/tiles.png` (128×24, 4-bit, 16 grays, no tRNS) against `tests/golden/mart_tiles.4bpp` (1536 bytes, 16×3 tiles) and `.pal` (32 bytes). School (#22) is the fifth: `data/tilesets/secondary/school/tiles.png` (128×32, 4-bit colormap, 16 grays, no tRNS) against `tests/golden/school_tiles.4bpp` (2048 bytes, 16×4 tiles) and `.pal` (32 bytes). Underground path (#24) is the sixth: `data/tilesets/secondary/underground_path/tiles.png` (128×32, 4-bit colormap, 16 grays, no tRNS) against `tests/golden/underground_path_tiles.4bpp` (2048 bytes, 16×4 tiles) and `.pal` (32 bytes). Generic building 1 (#26) is the seventh: `data/tilesets/secondary/generic_building_1/tiles.png` (128×32, 4-bit colormap, 16 grays, no tRNS) against `tests/golden/generic_building_1_tiles.4bpp` (2048 bytes, 16×4 tiles) and `.pal` (32 bytes). Bike shop (#28) is the eighth: `data/tilesets/secondary/bike_shop/tiles.png` (128×32, 4-bit colormap, 16 grays, no tRNS) against `tests/golden/bike_shop_tiles.4bpp` (2048 bytes, 16×4 tiles) and `.pal` (32 bytes). Saffron gym (#29) is the ninth: `data/tilesets/secondary/saffron_gym/tiles.png` (128×48, 4-bit, 16 colors, no tRNS) against `tests/golden/saffron_gym_tiles.4bpp` (3072 bytes, 16×6 tiles) and `.pal` (32 bytes). Provenance is `testdata/ORIGIN.txt`. The pixel-pipeline CI job already runs `make && make test`. Fixture tables stay in `tools/pixel_pipeline/README.md`.

## Serializer
- 4bpp indexed writes: NEON-pack two 4-bit pixels per byte across 128-bit vectors (graphics path when dirty).
- Async I/O: GCD / `std::async` on efficiency cores; never block the UI / ImGui / Metal present path on disk writes.
- Target: smooth 60/120 FPS canvas with Shared Metal + NEON + TBDR on large maps.
