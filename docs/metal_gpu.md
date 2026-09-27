# Metal canvas (Apple Silicon)

The map view is Swift, AppKit, and `MTKView`. It stays on unified memory and draws the metatile grid in one render pass. There is no GLFW path and no per-cell triangle remesh.

## Shared grid

`MapMetatileGrid` is one `UInt32` per cell, row-major. The low 16 bits are `MapCell.raw` (metatile id in bits 0–9, map attribute in bits 10–15). Buffers are created with `MTLStorageModeShared`. On Apple Silicon that is the UMA path: the CPU writes the same pages the GPU reads, with no managed-buffer blit.

The draw is instanced. A static 6-vertex quad (with the usual inset) is the `[[stage_in]]` vertex. `instance_id` samples the grid and a 1024-entry palette built by `MetatileColor`. Fake colors stay a function of metatile id.

Selection does not rebuild that grid. Markers and the gold outline are small `MapQuadInstance` lists (14 markers on Pallet Town, 4 outline quads). Pan and zoom only rewrite the 64-byte uniform struct.

## Ring buffers

`FrameRing` has three slots. `draw` waits on a semaphore before taking a slot and signals it from the command-buffer completed handler, so the CPU does not write a buffer the GPU is still reading. `makeBuffer` runs when a ring is created and again only if a map outgrows `RingCapacity` (the initial grid holds 4096 cells; Pallet Town is 480). A selection change marks slots dirty and copies four instances into the existing selection ring.

## Stage-in and depth

`map_vertex` and `map_sprite_vertex` take `[[stage_in]]` vertices. The fragment function does too. The vertex descriptor, not `vertex_id` fetches, supplies the quad corner and the sprite instance.

The pass uses `MTLPixelFormat.depth32Float` and a less-than depth-stencil state with writes enabled. Smaller depth is closer:

| Layer | Depth | v1 |
|---|---|---|
| clear | 1.00 | cleared each pass |
| ground | 0.70 | metatile quads |
| sprite | 0.55 | reserved |
| canopy | 0.40 | reserved, in front of sprites |
| marker | 0.28 | event quads |
| selection | 0.15 | outline quads |

Sprite and canopy are not drawn yet. Later draws use the same depth-stencil state and those constants so ordering does not need a second pass. Depth `storeAction` is `.dontCare`: nothing samples depth after the pass, so TBDR does not write it back to memory. Color is stored for present.

## TBDR overlays

Tiles, markers, and the selection outline are batched in a single encoder. That keeps the color attachment on-chip until the pass ends. Selection is the depth-tested quads only.

`map_tile_overlay` in `MapShaders.swift` is the future imageblock kernel: it would tint cells whose map attribute is non-zero (`MapOverlayFlags.collisionTint`, scale `MapTileOverlay.collisionTintScale`) and stamp a gold selection border (`MapOverlayFlags.selectionOutline`). World position matches `MapTileOverlay.world`. macOS builds do not create a tile render pipeline and do not dispatch that kernel. `tileFunction` / `tileWidth` on `MTLRenderPipeline*` are not the macOS path, so the app does not call them. `overlayFlags` stays in the uniform struct for that future kernel and defaults to 0. Turning on `selectionOutline` does not draw a second border.

A shared-ring grow that cannot allocate sets `MapGPUState.note` (shown in the inspector) and fails the frame. Debug builds also hit `assertionFailure`.
