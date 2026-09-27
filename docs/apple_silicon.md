# Apple Silicon constraints (Shuverse Editor)

## UI / Metal (UI Canvas)
- Use unified memory: `MTLStorageModeShared` for metatile grid buffers (CPU write, GPU read, no copy).
- Target TBDR: single-pass batched tile geometry; let hardware discard occluded fragments before the fragment shader.
- Grid/collision overlays: Metal tile shaders + imageblocks to keep intermediates in on-chip tile memory.

## Data Parser
- Hot paths through `.c` arrays / pixel data: ARM NEON SIMD (LD3/LD4 for interleaved RGB/RGBA).
- Align structs/allocations to **128-byte** cache lines (Apple Silicon), not 64-byte x86 assumptions.
- RGB24 → GBA RGB555: fixed-point NEON, not floating point.

## Serializer
- 4bpp indexed writes: NEON-pack two 4-bit pixels per byte across 128-bit vectors.
- Async I/O: GCD / std::async on efficiency cores; never block the UI thread on disk writes.
- Target: smooth 60/120 FPS canvas with Shared Metal + NEON + TBDR on large maps.
