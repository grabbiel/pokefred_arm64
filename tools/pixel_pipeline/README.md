# pixel_pipeline

Standalone CLI that turns a PNG into GBA **4bpp** tiles and an **RGB555** palette. It lives entirely under `tools/pixel_pipeline/` and does not link Metal, the Shuverse editor, or the map model. The editor still draws fake metatile colors; these binaries are not on the render path.

## Build and test

Requires a C11 compiler. PNG decoding is the vendored `third_party/stb_image.h` (v2.30, public domain). No system libpng.

```bash
cd tools/pixel_pipeline
make
make test
```

`make test` builds the CLI, the static library, and the tests, including the tanoby ruins, game corner, and pallet town goldens. On Linux x86_64 this is the scalar path (`__ARM_NEON` is not defined). Objects stay in `build/` (gitignored).

GitHub Actions workflow `.github/workflows/shuverse-editor.yml`, job `pixel-pipeline`, runs on `ubuntu-latest` (Linux x86_64):

```bash
cd tools/pixel_pipeline
make
make test
```

That job is scalar only. It does not run the NEON converters.

```bash
./build/pixel_pipeline testdata/tanoby_ruins_tiles.png build/tiles.4bpp build/tiles.pal
./build/pixel_pipeline testdata/game_corner_tiles.png build/game_corner.4bpp build/game_corner.pal
./build/pixel_pipeline testdata/pallet_town_tiles.png build/pallet_town.4bpp build/pallet_town.pal
```

From the repo root the binary is `tools/pixel_pipeline/build/pixel_pipeline` after `make`. Output paths are chosen by the caller.

Exit codes: **0** success, **2** usage (`argc != 4`), **1** decode, quantize, tile pack, or write failure. The same rules, the C entry point, and the 128-byte buffer alignment are specified in [CONTRACT.md](CONTRACT.md).

The `.pal` file is 32 bytes: 16 little-endian RGB555 colors. The `.4bpp` file is one 32-byte tile per 8×8 block.

## 4bpp

- Tiles are 8×8. Width and height must be multiples of 8.
- Tile order is left-to-right, then top-to-bottom. There is no 2×2 metatile swizzle.
- Each tile is 32 bytes (8 rows × 4 bytes). Two pixels share a byte.
- **Low nibble = left pixel, high nibble = right pixel** (GBATEK / gbagfx):

```text
byte = (index[x] & 0x0F) | ((index[x + 1] & 0x0F) << 4)
```

## RGB555

Host values use GBA bit layout `0bbbbbgggggrrrrr`. The file stores them little-endian.

Channel reduction is fixed-point truncation, no float and no rounding:

```text
c5 = ((unsigned)c8 * 32) >> 8    # identical to (c8 >> 3) for c8 in 0..255
c5 &= 0x1F
```

0 maps to 0 and 255 maps to 31. Bit 15 is clear.

## Palette index 0

Index 0 is the transparent slot.

- Indexed PNG with at most 16 unique PLTE entries and no `tRNS` alpha of 0: palette order is preserved. Index 0 is GBA color 0 (the PNG's first color), even when those pixels are opaque. `testdata/tanoby_ruins_tiles.png` (128×40, 16 grays), `testdata/game_corner_tiles.png` (128×88, 16 colors), and `testdata/pallet_town_tiles.png` (128×40, 16 grays) are this case. None of these files has `tRNS`.
- Indexed PNG with one or more `tRNS` alphas of 0: those pixels become index 0. Slot 0 keeps the first transparent PLTE color. Remaining colors keep PLTE order.
- Truecolor, or more than 16 colors: alpha 0 is index 0. Opaque colors use slots 1..15 if anything is transparent, or slots 0..15 if nothing is. Extra colors are merged deterministically (see `quantize.h`).

## Alignment

Pipeline buffers (`rgba`, indices, 4bpp output, the RGB staging buffer) are **128-byte aligned** via `posix_memalign`, including on x86_64. Tests check the pointer alignment. Files written for the caller are plain byte streams; alignment is a property of those allocations.

## NEON (Apple Silicon / AArch64)

AArch64 always has NEON. gcc and clang define `__ARM_NEON`, and the same sources then convert the palette with `rgb555_neon` and pack tiles with the NEON packer. Both must match the scalar path bit for bit. `make test` on an AArch64 machine checks that, including all three goldens. The NEON tile packer documents its little-endian lane assumption in `tile_pack.c`. The tanoby golden was produced independently of either C path. The game corner and pallet town goldens were produced by this scalar pipeline and are checked the same way.

The `pixel-pipeline` job in `.github/workflows/shuverse-editor.yml` does not run this comparison. On `ubuntu-latest` NEON stays compiled out.

```bash
cd tools/pixel_pipeline
make clean && make test
```

No `-mfpu` flag is required. To compile the NEON functions but keep the CLI on the scalar path:

```bash
make clean
make test EXTRA_CFLAGS=-DPP_FORCE_SCALAR=1
```

Without Apple hardware, the same bit-exact check is an AArch64 cross build run under `qemu-aarch64`. That qemu run is not part of the `pixel-pipeline` job.

## Calling it

Metal and the editor are not linked against this code. They can spawn the binary or link `build/libpixel_pipeline.a` later. The public header is `pixel_pipeline.h`:

```c
int pp_convert_png_to_gba(const char *png_path, const char *out_4bpp, const char *out_pal,
                          pp_convert_result *result);
```

`result` may be NULL. Returns 0 on success and 1 on decode, quantize, pack, or write failure. It does not return the CLI usage code 2. Link `build/libpixel_pipeline.a` with `-lm` and include `pixel_pipeline.h`. See [CONTRACT.md](CONTRACT.md) for the full caller contract (paths, exit codes, file layouts, alignment).

## Fixtures

`testdata/ORIGIN.txt` lists each PNG basename and its pret/pokefirered source path, one record per line.

| Local file | pret/pokefirered path | Golden |
| --- | --- | --- |
| `testdata/tanoby_ruins_tiles.png` | `data/tilesets/secondary/tanoby_ruins/tiles.png` (128×40) | `tests/golden/tanoby_ruins_tiles.4bpp` (2560 bytes, 16×5 tiles) and `.pal` (32 bytes) |
| `testdata/game_corner_tiles.png` | `data/tilesets/secondary/game_corner/tiles.png` (128×88) | `tests/golden/game_corner_tiles.4bpp` (5632 bytes, 16×11 tiles) and `.pal` (32 bytes) |
| `testdata/pallet_town_tiles.png` | `data/tilesets/secondary/pallet_town/tiles.png` (128×40) | `tests/golden/pallet_town_tiles.4bpp` (2560 bytes, 16×5 tiles) and `.pal` (32 bytes) |

All three goldens are checked by `make test` on the scalar path. `game_corner` and `pallet_town` are indexed PNGs with 16 PLTE colors and no `tRNS`, so index 0 stays the first palette entry.
