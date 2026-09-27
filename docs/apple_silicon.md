# Apple Silicon constraints (Shuverse Editor)

## UI / Metal (UI Canvas)
Shipped canvas is `docs/metal_gpu.md`. This section matches that path.

- Shared grid: `MapMetatileGrid`, one `UInt32` per cell, `MTLStorageModeShared`. The CPU writes the same pages the GPU reads; no managed-buffer blit.
- Ring buffers: three-slot `FrameRing`. `draw` waits on a semaphore before taking a slot and signals it from the command-buffer completed handler, so the CPU does not write a buffer the GPU is still reading.
- Vertices: `[[stage_in]]` on `map_vertex`, `map_sprite_vertex`, and the fragment function. The vertex descriptor supplies the quad corner; the shaders do not fetch with `vertex_id`.
- Depth: `MTLPixelFormat.depth32Float`, less-than, writes enabled. Drawn layers are ground (0.70), markers (0.28), and selection (0.15). Sprite (0.55) and canopy (0.40) are reserved and not drawn. Depth `storeAction` is `.dontCare`, so TBDR does not write depth back to memory.
- Current pass: one encoder batches tiles, markers, and selection quads. Color stays on-chip until present.
- Imageblock overlay is not the live path. `map_tile_overlay` is a future kernel and a macOS stub only: it is not dispatched, there is no tile render pipeline, and `overlayFlags` is reserved and defaults to 0.

## Data Parser
- Hot paths through `.c` arrays / pixel data: ARM NEON SIMD (LD3/LD4 for interleaved RGB/RGBA).
- Align structs/allocations to **128-byte** cache lines (Apple Silicon), not 64-byte x86 assumptions.
- RGB24 → GBA RGB555: fixed-point NEON, not floating point.

## Serializer
- 4bpp indexed writes: NEON-pack two 4-bit pixels per byte across 128-bit vectors.
- Async I/O: GCD / std::async on efficiency cores; never block the UI thread on disk writes.
- Target: smooth 60/120 FPS canvas with Shared Metal + NEON + TBDR on large maps.
