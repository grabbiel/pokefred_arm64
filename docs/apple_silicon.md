# Apple Silicon constraints (Shuverse Editor)

## UI shell (Editor UI / Dear ImGui)
Shipped dock shell is described in `ShuverseEditor/README.md` (PR #8).

- Dear ImGui **v1.91.9b docking** is vendored under `ShuverseEditor/ImGuiHost/imgui` and built as the macOS-only `CImGuiHost` SwiftPM target. Official Metal/OSX `.mm` backends are not used; Swift hosts the overlay (`ImGuiOverlayView`, `ImGuiMetalRenderer`) on a **separate** command queue from the map canvas.
- Transparent overlay docks: **Map List**, **Inspector**, **Status**, **Tileset**. Central dock node is a pass-through hole (`hitTest` returns nil) so pan / zoom / pinch / click-inspect stay on `MapCanvasView`.
- Dock layout is session-only (no ini). Tileset dock is still a placeholder swatch grid — it does not drive the 4bpp ground pass.
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

## Serializer
- 4bpp indexed writes: NEON-pack two 4-bit pixels per byte across 128-bit vectors (graphics path when dirty).
- Async I/O: GCD / `std::async` on efficiency cores; never block the UI / ImGui / Metal present path on disk writes.
- Target: smooth 60/120 FPS canvas with Shared Metal + NEON + TBDR on large maps.
