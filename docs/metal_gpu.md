# Metal canvas (Apple Silicon)

The map view is Swift, AppKit, and `MTKView`. It stays on unified memory and draws the metatile grid in one render pass. There is no GLFW path and no per-cell triangle remesh.

## Shared grid

`MapMetatileGrid` is one `UInt32` per cell, row-major. The low 16 bits are `MapCell.raw` (metatile id in bits 0–9, map attribute in bits 10–15). Buffers are created with `MTLStorageModeShared`. On Apple Silicon that is the UMA path: the CPU writes the same pages the GPU reads, with no managed-buffer blit.

The draw is instanced. A static 6-vertex quad covering the full metatile is the `[[stage_in]]` vertex. `instance_id` reads the grid. Pallet Town does not upload `MetatileColor`. That ramp remains a debug helper and is not the sample load path.

Selection does not rebuild that grid. Markers and the gold outline are small `MapQuadInstance` lists (14 markers on Pallet Town, 4 outline quads). Pan and zoom only rewrite the 64-byte uniform struct.

## Pallet Town tiles

Pallet Town (`gTileset_General` + `gTileset_PalletTown`) samples real GBA graphics. `GBATileset` loads the files under `ShuverseEditor/Samples/tilesets/pallet_town/` (the app target copies the same tree). Tile bytes follow [tools/pixel_pipeline/CONTRACT.md](../tools/pixel_pipeline/CONTRACT.md): `.4bpp` is 32 bytes per 8×8 tile, low nibble = left pixel, and each `.pal` bank is 32 bytes of little-endian RGB555 (`0bbbbbgggggrrrrr`, `c5 = (c8 * 32) >> 8`). `ShuverseEditor/Scripts/bake_pallet_town_tiles.py` runs the CLI (`pixel_pipeline <png> <4bpp> <pal>`) on a pret checkout. The gray `.pal` that the CLI writes beside `tiles.png` is not loaded; color banks come from the JASC palettes in that same 32-byte layout. The editor does not link `libpixel_pipeline.a`. `metatiles.bin` is pret's table, not a pixel_pipeline file: 8 little-endian screen entries per metatile (bottom 2×2, then top 2×2; bits 0–9 tile, bit 10 hflip, bit 11 vflip, bits 12–15 palette).

The GPU resources are all `MTLStorageModeShared`:

| Resource | Storage | Contents |
|---|---|---|
| `tileset-indices` | shared buffer, viewed as `r8Uint` | one byte per texel, values 0…15, 16 tiles per row |
| `tileset-rgb555` | shared buffer | 16 banks × 16 `ushort` RGB555 colors |
| `metatile-entries` | shared buffer | 1024 × 8 screen entries |

The index buffer's row stride is a multiple of `minimumLinearTextureAlignment(for: .r8Uint)`. The CPU writes that buffer with `contents()`; the texture is a view of the same allocation. There is no managed-buffer blit. A failed `makeBuffer` or `makeTexture` sets `MapGPUState.note` (`Shared tileset upload failed. …`). Debug builds also hit `assertionFailure` in the canvas.

`map_tile_fragment` matches `GBATileset.sample`. Index 0 is transparent on both layers. Primary tiles sit at ids 0–639 and secondary tiles at 640+. BG banks follow pret: primary palettes 0–6 (color 0 forced black) and secondary palettes 7–12 in slots 7–12. Other maps leave the ground undrawn and set a note; they do not fall back to `MetatileColor`.

Tileset animations, metatile behavior, and layer-type versus sprite priority are not applied. Both layers are composited in the ground fragment at depth 0.70. `EditorDocument.sharedTilesets` is still an id-only record.

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
