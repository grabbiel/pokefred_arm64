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
| `tileset-indices` | triple shared ring, each viewed as `r8Uint` | one byte per texel, values 0…15, 16 tiles per row |
| `tileset-rgb555` | shared buffer | 16 banks × 16 `ushort` RGB555 colors |
| `metatile-entries` | shared buffer | 1024 × 8 screen entries |

Each index buffer's row stride is a multiple of `minimumLinearTextureAlignment(for: .r8Uint)`. The CPU writes that buffer with `contents()`; the texture is a view of the same allocation. There is no managed-buffer blit. A failed `makeBuffer` or `makeTexture`, including a failed animation row rewrite, sets `MapGPUState.note` (`Shared tileset upload failed. …`). Debug builds also hit `assertionFailure` in the canvas.

`map_tile_fragment` matches `GBATileset.sample`. Index 0 is transparent on both layers. Primary tiles sit at ids 0–639 and secondary tiles at 640+. BG banks follow pret: primary palettes 0–6 (color 0 forced black) and secondary palettes 7–12 in slots 7–12. Other maps leave the ground undrawn and set a note; they do not fall back to `MetatileColor`.

Metatile behavior and a full layer-type split are not applied. Both layers are still composited in the ground fragment at depth 0.70. General-tileset tree tops add a second draw of that top layer only, on any map that uses those metatile ids; see the canopy stub below. `EditorDocument.sharedTilesets` is still an id-only record.

## Tileset animation stub

Pallet Town animates two ranges from pret's `gTileset_General` callback (`TilesetAnim_General` in `tileset_anims.c`). The counter wraps at 640. The frames are separate graphics, not extra tiles in `tiles.png`.

Water copies `water_current_landwatersedge` when `counter % 16 == 1`, frame `counter / 16`, onto 4bpp tile 416 for 48 tiles. `PalletTownTilesetAnim` does not load those frames. It stubs the four tile ids this map samples: **416…419** (metatiles 291, 298, 299, 300, 721, and 722). Eight frames, same period and phase as pret. Frame 0 is the baked atlas tile. Frame `n` rotates each of those tiles up by `n` pixels.

Flowers copy `flower` when `counter % 16 == 2`, frame `counter / 16`, onto tiles **508…511** (4 tiles, 5 frames). Those tiles are the top layer of metatile **4**. Pallet Town places that metatile eight times, in a block at cells (5…8, 12…13). The stub keeps pret's id, period, phase, and frame count. Frame 0 is the baked tile. Frame `n` rotates each of those tiles left by `n` pixels.

The shader does not animate; `map_tile_fragment` still samples the shared index atlas.

The map view stays paused (`isPaused`, `enableSetNeedsDisplay`). A 60 Hz timer stands in for the GBA vblank counter. On a tick that queues a frame, the CPU writes the new indices into its atlas copy and marks the triple ring dirty. `encode` memcpy's only the affected pixel rows into the slot the GPU has finished reading: water is tile row 26 (pixel rows 208…215), flowers are tile row 31 (pixel rows 248…255). A slot that has not flushed since the previous clip keeps both row ranges, so a flower tick does not drop a pending water rewrite. The status line shows `water frame N` and `flower frame N`.

### Known gaps

- Frame pixels are this scroll, not pret's `water_current_landwatersedge` or `flower` frames.
- The other 44 tiles of the water DMA (420…463) stay on the baked graphics.
- Sand-water edge (tile 464, 18 tiles, `counter % 8 == 0`) does not animate. Pallet Town's layout does not use those metatiles.
- Other maps still have no 4bpp atlas. Full multi-map tilesets are out of scope.
- Secondary tileset callbacks are not run.

## Canopy depth stub

Ground metatiles are unchanged: one instanced draw, both GBA layers, depth 0.70. `GeneralTilesetTreeTops` holds the six pret general-tileset tree-top ids (`METATILE_General_ThinTreeTop_*` and `METATILE_General_WideTreeTop_*`, ids 10, 11, 12, 14, 15, 19) as a set. The canopy list matches those ids on any map; they are not Pallet Town cell coordinates. On the Pallet sample that is the eight south-edge cells using ids 14 and 15. Each instance is an 8-byte `MapCanopyInstance` (cell index plus depth) in a triple `MTLStorageModeShared` ring. `map_canopy_vertex` is `[[stage_in]]` and reads the same grid and index atlas. `map_canopy_fragment` samples only the top 2×2 and `discard_fragment()`s index 0, so holes do not write depth. Canopy depth stays 0.40.

## Object sprites

The pass submits object sprites, then canopy, then ground, then markers and selection. Object sprites are a separate triple `MTLStorageModeShared` ring of `MapQuadInstance` quads (`label: "sprites"`), drawn with the same `map_sprite_vertex` `[[stage_in]]` path and the same less-than depth-stencil. Their depth is 0.20, so they cover the leaves and the later ground quads. The list is two stand-ins and only when `mapId` is `MAP_PALLET_TOWN`: a blue NPC on the south-west wide tree top (the quad overlaps the leaf half of that cell) and a red player on open ground at cell (8, 15), in front of that metatile. Those anchors are Pallet sample proof geometry, not coordinates for other maps. Markers stay at 0.28, in front of the leaves and behind the sprites. Water and flower animation still rewrite shared index rows and are not part of this layer. The status line shows `canopy N` and `sprites N`.

This is not a metatile layer-type table. Roofs, the north tree wall, and other top-layer pixels stay in the ground composite.

## Ring buffers

`FrameRing` has three slots. `draw` waits on a semaphore before taking a slot and signals it from the command-buffer completed handler, so the CPU does not write a buffer the GPU is still reading. `makeBuffer` runs when a ring is created and again only if a map outgrows `RingCapacity` (the initial grid holds 4096 cells; Pallet Town is 480). A selection change marks slots dirty and copies four instances into the existing selection ring. The index atlas uses the same three shared slots; an animation tick dirties them and the draw copies only the water and flower rows that still need a flush into the free slot.

## Stage-in and depth

`map_vertex` and `map_sprite_vertex` take `[[stage_in]]` vertices. The fragment function does too. The vertex descriptor, not `vertex_id` fetches, supplies the quad corner and the sprite instance.

The pass uses `MTLPixelFormat.depth32Float` and a less-than depth-stencil state with writes enabled. Smaller depth is closer:

| Layer | Depth | v1 |
|---|---|---|
| clear | 1.00 | cleared each pass |
| ground | 0.70 | metatile quads, both GBA layers |
| canopy | 0.40 | tree-top leaves, in front of ground |
| marker | 0.28 | event quads, in front of the leaves |
| sprite | 0.20 | Pallet Town object sprites, in front of canopy |
| selection | 0.15 | outline quads |

Sprites and canopy are submitted before ground. The depth test is what keeps the sprites in front of the leaves, and both in front of the ground quads. Depth `storeAction` is `.dontCare`: nothing samples depth after the pass, so TBDR does not write it back to memory. Color is stored for present.

## TBDR overlays

Object sprites, canopy, tiles, markers, and the selection outline are batched in a single encoder. That keeps the color attachment on-chip until the pass ends. Selection is the depth-tested quads only.

`map_tile_overlay` in `MapShaders.swift` is the future imageblock kernel: it would tint cells whose map attribute is non-zero (`MapOverlayFlags.collisionTint`, scale `MapTileOverlay.collisionTintScale`) and stamp a gold selection border (`MapOverlayFlags.selectionOutline`). World position matches `MapTileOverlay.world`. macOS builds do not create a tile render pipeline and do not dispatch that kernel. `tileFunction` / `tileWidth` on `MTLRenderPipeline*` are not the macOS path, so the app does not call them. `overlayFlags` stays in the uniform struct for that future kernel and defaults to 0. Turning on `selectionOutline` does not draw a second border.

A shared-ring grow that cannot allocate sets `MapGPUState.note` (shown in the inspector) and fails the frame. Debug builds also hit `assertionFailure`.
