# In-memory map model (Metal editor)

Source of truth while editing. Load from Map Parser JSON; serialize later back to `map.json` + `map.bin`.

## Coordinate system
- Grid unit: one **metatile** = 16×16 px (four 8×8 hardware tiles).
- Origin: top-left `(0, 0)`; `x` right, `y` down.
- Per-map size: `width` × `height` in metatiles (Pallet Town outdoor: 24×20).

## Multi-map document

### `EditorDocument` (workspace root)
| Field | Type | Notes |
|---|---|---|
| `decompRoot` | path | e.g. `…/pokefirered` |
| `maps` | `[MapDocument]` | open / cached maps |
| `activeMapId` | string? | currently edited `MAP_*` |
| `sharedTilesets` | `[TilesetRef:id → Tileset]` | dedupe General across maps |
| `dirtyMaps` | `Set<mapId>` | which maps need rewrite |

Opening a connection or warp loads (or focuses) another `MapDocument` into `maps` without closing the rest. Undo stacks are **per map**.

### `MapDocument`
| Field | Type | Notes |
|---|---|---|
| `mapId` | string | e.g. `MAP_PALLET_TOWN` |
| `name` | string | folder / display name |
| `layoutId` | string | e.g. `LAYOUT_PALLET_TOWN` |
| `music` / `weather` / `mapType` | string | FireRed constants |
| `tilesets` | `TilesetRef` | primary + secondary (shared store) |
| `size` | `Size` | width/height metatiles |
| `cells` | `[MapCell]` | length = width×height, row-major |
| `border` | `[MapCell]?` | optional border.bin grid |
| `objectEvents` | `[ObjectEvent]` | NPCs / sprites |
| `warpEvents` | `[WarpEvent]` | doors / exits |
| `coordEvents` | `[CoordEvent]` | triggers |
| `bgEvents` | `[BgEvent]` | signs / hidden items |
| `connections` | `[Connection]` | adjacent maps (`map`, `direction`, `offset`) |
| `dirty` | flags | cells / events / header |

### `MapCell` (one metatile)
| Field | Bits / type | Notes |
|---|---|---|
| `metatileId` | UInt16, 0…1023 | bits 0–9 of `map.bin` u16 |
| `mapAttribute` | UInt8, 0…63 | bits 10–15 |
| raw packing | `UInt16` | `(mapAttribute << 10) \| metatileId` |

### `TilesetRef` / shared `Tileset`
- Primary/secondary symbols. `EditorDocument.sharedTilesets` dedupes those ids.
- Pallet Town's atlas is not stored on `Tileset`. The canvas loads `GBATileset` from `Samples/tilesets/pallet_town/` (4bpp indices, RGB555 banks, metatile screen entries). See [metal_gpu.md](metal_gpu.md).

### Events
- `ObjectEvent`, `WarpEvent`, `CoordEvent`, `BgEvent`, `Connection` keep pret `map.json` field names for round-trip.
- Warps/connections reference other `mapId`s; resolving them may pull another `MapDocument` into the workspace.

## Edit operations
1. Paint metatile / mapAttribute on **active** map
2. Select cell; move/place/delete events
3. Follow connection/warp → set `activeMapId` (load if missing)
4. Undo — per-map patch stack

## GPU upload

The canvas uploads `MapMetatileGrid`: one `UInt32` per cell, low 16 bits `MapCell.raw`. It does not expand each cell into six vertices when the selection changes. Markers and the selection outline are small quad-instance lists. Pallet Town object sprites are a separate shared-ring list at depth 0.20, in front of the canopy leaves (0.40) and the ground (0.70). Pallet Town's ground fragment samples the shared 4bpp atlas and RGB555 palette instead of a per-id color. Water tiles 416–419 and flower tiles 508–511 (metatile 4) are rewritten in that atlas by `PalletTownTilesetAnim` (stub frames, pret's tile ids and 16-tick phases). See [metal_gpu.md](metal_gpu.md).

## Non-goals for v1
- No live C rewrite yet.
- `MetatileColor` is not the Pallet Town draw path. Other maps do not invent tiles.
