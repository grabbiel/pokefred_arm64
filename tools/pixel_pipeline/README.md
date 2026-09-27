# pixel_pipeline

Standalone CLI that turns a PNG into GBA **4bpp** tiles and an **RGB555** palette. It lives entirely under `tools/pixel_pipeline/` and does not link Metal, the Shuverse editor, or the map model. The editor still draws fake metatile colors; these binaries are not on the render path.

## Build and test

Requires a C11 compiler. PNG decoding is the vendored `third_party/stb_image.h` (v2.30, public domain). No system libpng.

```bash
cd tools/pixel_pipeline
make
make test
```

`make test` builds the CLI and runs the tests, including the tanoby ruins golden. On Linux x86_64 this is the scalar path (`__ARM_NEON` is not defined). Objects stay in `build/` (gitignored).

GitHub Actions workflow `pixel_pipeline`, job `linux-x86_64`, runs on `ubuntu-latest` (Linux x86_64):

```bash
cd tools/pixel_pipeline
make
make test
```

That job is scalar only. It does not run the NEON converters.

```bash
./build/pixel_pipeline testdata/tanoby_ruins_tiles.png build/tiles.4bpp build/tiles.pal
```

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

- Indexed PNG with at most 16 unique PLTE entries and no `tRNS` alpha of 0: palette order is preserved. Index 0 is GBA color 0 (the PNG's first color), even when those pixels are opaque. `testdata/tanoby_ruins_tiles.png` is this case (pret `tiles.png`, 128×40, 16 grays, no `tRNS`).
- Indexed PNG with one or more `tRNS` alphas of 0: those pixels become index 0. Slot 0 keeps the first transparent PLTE color. Remaining colors keep PLTE order.
- Truecolor, or more than 16 colors: alpha 0 is index 0. Opaque colors use slots 1..15 if anything is transparent, or slots 0..15 if nothing is. Extra colors are merged deterministically (see `quantize.h`).

## Alignment

Pipeline buffers (`rgba`, indices, 4bpp output, the RGB staging buffer) are **128-byte aligned** via `posix_memalign`, including on x86_64. Tests check the pointer alignment.

## NEON (Apple Silicon / AArch64)

AArch64 always has NEON. gcc and clang define `__ARM_NEON`, and the same sources then convert the palette with `rgb555_neon` and pack tiles with the NEON packer. Both must match the scalar path bit for bit. `make test` on an AArch64 machine checks that, including the golden. The golden files were produced independently of either C path.

The `linux-x86_64` GitHub Actions job does not run this comparison. NEON stays compiled out there.

```bash
cd tools/pixel_pipeline
make clean && make test
```

No `-mfpu` flag is required. To compile the NEON functions but keep the CLI on the scalar path:

```bash
make clean
make test EXTRA_CFLAGS=-DPP_FORCE_SCALAR=1
```

Without Apple hardware, the same bit-exact check is an AArch64 cross build run under `qemu-aarch64`. That qemu run is not part of the Linux x86_64 job.

## Fixture

`testdata/tanoby_ruins_tiles.png` is a copy of pret/pokefirered `data/tilesets/secondary/tanoby_ruins/tiles.png`. `testdata/ORIGIN.txt` records that path. Golden outputs:

- `tests/golden/tanoby_ruins_tiles.4bpp` (2560 bytes, 16×5 tiles)
- `tests/golden/tanoby_ruins_tiles.pal` (32 bytes)
