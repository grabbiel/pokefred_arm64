# Asset Serializer plan

Owns round-trip from `EditorDocument` back into pret/pokefirered. Parser reads; UI mutates; Serializer alone writes.

## Architecture (canvas → bins)

Serialization is the reverse of parsing: `EditorDocument` / canvas edits → C structs and layout bins. Parser reads; UI mutates; Serializer alone writes.

### Runtime constraints (native Metal editor)
1. **NEON packing (4bpp graphics path):** when writing 4bpp indexed color arrays, pack two 4-bit pixels into one byte concurrently across 128-bit NEON vectors. Applies to tileset / graphics binary write paths once those assets are marked dirty — not required for the current LE `u16` `map.bin` / `border.bin` cell packing.
2. **Async I/O:** never block the main UI thread on file writes. Run serialization on efficiency cores via GCD (`libdispatch`) or C++ `std::async`; leave performance cores for UI render + parse.
3. **Frame budget:** with Shared Metal buffers + NEON + TBDR, keep a locked 60/120 FPS canvas even on large seamless maps. Serialize off the render path; dry-run / patch planning must not stall MTKView.

Until 4bpp asset writes land, the Python `tools/serialize_map.py` `map.bin` path may stay simple (scalar LE `u16` pack). The constraints above bind the native Swift/C++ serializer and any future graphics milestone.

## Inputs
- Dirty `MapDocument`s + last-loaded snapshots (for diff).
- Paths: `decompRoot`, layout `blockdata_filepath` / `border_filepath`, `data/maps/<Name>/map.json`.
- Flags: `--dry-run`, `--force` (allow dirty git), `--maps MAP_A,MAP_B`.

## Output artifacts (per dirty map)
| Artifact | When | Format |
|---|---|---|
| `map.bin` | cells dirty | `width*height` LE `u16`; `(mapAttribute << 10) \| (metatileId & 0x3FF)` |
| `border.bin` | border dirty | same packing; size `border_width * border_height` from layouts.json |
| `map.json` | events/header dirty | object/warp/coord/bg events + connections + music/weather/etc.; leave unknown keys intact |
| never | — | tileset `.png`/`.pal`/headers unless a later graphics milestone marks them dirty |

## Validation (fail closed)
1. `cells.count == width * height`; each `metatileId` in 0…1023; `mapAttribute` in 0…63.
2. Every event `x,y` inside map bounds, except `object_events` with `type: "clone"` (pret border clones may sit outside the layout). All other events (normal object_events without type clone, warps, coord, bg) remain fail-closed on OOB. Warp `dest_map` / `dest_warp_id` present as strings.
3. Connection `direction` ∈ {up,down,left,right}; `offset` int.
4. If secondary tileset local metatiles used, ids must be legal for that tileset bank (once tileset metadata is loaded).
5. Graphics path (later): RGB555, 4bpp, palette index 0 transparent; pack with NEON (see Architecture).

## Write algorithm
1. Build planned patch set (paths + byte/JSON diffs).
2. If any target path is git-dirty and not `--force`, abort with list.
3. `--dry-run`: print patch summary; exit 0.
4. Else for each file: write `*.tmp` → `fsync` → rename over target.
5. Clear dirty flags only after all renames for that map succeed; on failure leave prior files and report which step failed.

## Round-trip gate
`parse_map.py PalletTown` → load → serialize → `cmp` original `map.bin`; JSON events semantically equal (order-insensitive lists OK). Same for `PalletTown_ProfessorOaksLab`.

## CLI sketch
`tools/serialize_map.py --decomp …/pokefirered --doc editor_state.json [--dry-run] [MAP_ID…]`

## Non-goals (v1)
- No script/C regeneration beyond map JSON + layout bins.
- No auto-commit; user commits.
- No multi-map atomic transaction across repos; best-effort per map with rollback of that map’s temps.

### Python reference (`tools/serialize_map.py`)
- Default mode is dry-run (compare only). Pass `--write` to atomically write
  `map.bin`, `border.bin`, and `map.json` (`*.tmp` → fsync → rename).
- `border.bin`: LE `u16` same packing as `map.bin`; size `border_width *
  border_height` from `layouts.json`. Arrays come from `doc["border"]` when
  present; otherwise the existing on-disk `border.bin` is unpacked and
  re-packed (identity when the parser omitted border).
- `map.json`: merge parsed header/events/connections into the existing pret
  file, preserving unknown top-level keys and per-event fields the parser
  dropped (e.g. `movement_range_*`, `trainer_*`). Dump is `json.dumps(...,
  indent=2) + "\n"` (pret style; byte-stable on reload when order is kept).
- Empty indoor `connections` stay `null` when pret stored null (not `[]`),
  so round-trip stays byte-identical.
- Refuse git-dirty targets unless `--force`.
