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

Tiles, markers, and the selection outline are batched in a single encoder. That keeps the color attachment on-chip until the pass ends.

`map_tile_overlay` is a tile kernel. It reads the color imageblock, optionally tints cells whose map attribute is non-zero, optionally stamps the selection border, and writes the imageblock back. Those pixels never round-trip through a separate overlay target.

On macOS the kernel is a separate `MTLTileRenderPipelineDescriptor` (`threadgroupSizeMatchesTileSize`, color format matching the drawable). The pass asks for 32×32 tiles. `dispatchThreadsPerTile` uses the encoder’s tile size. Geometry pipelines stay free of that kernel, so skipping the dispatch still stores color. Dispatch runs only when `MapCanvasView.overlayFlags` is non-zero:

- `MapOverlayFlags.collisionTint` — darken attribute ≠ 0 by `MapTileOverlay.collisionTintScale` (0.82)
- `MapOverlayFlags.selectionOutline` — gold border in the imageblock. Leave this off while the depth-tested outline quads are drawn, or the border is drawn twice. The tile-shader border does not write depth.

Both flags default to 0, so Pallet Town looks the same as the quad path. World position in the kernel matches `MapTileOverlay.world` (`pixel / pixelScale` is a point, then the camera origin).
