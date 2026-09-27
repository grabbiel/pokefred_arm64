# pixel_pipeline contract

Stable surface for Shuverse Editor and Metal callers. This tree does not link Metal, the editor, or the map model. Call the binary, or link the static library, from outside `tools/pixel_pipeline/`.

## Paths

From the repo root, after `make` in `tools/pixel_pipeline` (or `make -C tools/pixel_pipeline`):

| Artifact | Path |
| --- | --- |
| CLI | `tools/pixel_pipeline/build/pixel_pipeline` |
| Static library | `tools/pixel_pipeline/build/libpixel_pipeline.a` |
| Public header | `tools/pixel_pipeline/pixel_pipeline.h` |

`build/` is gitignored. Internal headers (`png_decode.h`, `quantize.h`, `writer.h`, and the rest) are not a stable API.

## CLI

```text
pixel_pipeline <input.png> <output.4bpp> <output.pal>
```

Output paths are chosen by the caller. The tool does not invent a default directory or filename.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. Both files were written. |
| 2 | Usage. The process was not given exactly three path arguments. |
| 1 | Decode, quantize, tile pack, or write failed. |

Usage is only the argument count (`argc != 4`). A missing file, a PNG that will not decode, a width or height that is not a positive multiple of 8, or a path that cannot be written all exit 1.

stderr on usage:

```text
usage: pixel_pipeline <input.png> <output.4bpp> <output.pal>
```

stderr on failure:

```text
pixel_pipeline: <reason>
```

stdout on success is a diagnostic line (width, height, color count, 4bpp size, `neon on|off`). Callers should use the exit status and the two files, not that text.

## Output files

### `<output.pal>`

32 bytes. Sixteen little-endian RGB555 colors, host layout `0bbbbbgggggrrrrr`, bit 15 clear. Unused slots are 0. Channel reduction is `((unsigned)c8 * 32) >> 8` (the same as `c8 >> 3` for 8-bit channels), with no rounding.

### `<output.4bpp>`

32 bytes per 8×8 tile (8 rows × 4 bytes). Tiles are left-to-right, then top-to-bottom. There is no 2×2 metatile swizzle. Two pixels share a byte: **low nibble = left pixel, high nibble = right pixel**.

```text
byte = (index[x] & 0x0F) | ((index[x + 1] & 0x0F) << 4)
```

Width and height must be positive multiples of 8.

Palette index 0 follows the rules in [README.md](README.md): pret PLTE order is kept when the PNG is indexed, has at most 16 unique colors, and has no `tRNS` alpha of 0.

## Library

`pixel_pipeline.h`:

```c
int pp_convert_png_to_gba(const char *png_path,
                          const char *out_4bpp,
                          const char *out_pal,
                          pp_convert_result *result);

const char *pp_convert_last_error(void);
```

`result` may be NULL. On success a non-NULL `pp_convert_result` receives `width`, `height`, `color_count`, `tiles_size` (bytes written to `out_4bpp`), and `neon_enabled` (1 when this call used the NEON converters).

Return values:

| Code | Meaning |
| --- | --- |
| 0 | Both outputs were written. |
| 1 | Decode, quantize, tile pack, or write failed. |

The library does not return 2. The CLI maps a non-zero library return to exit code 1 and prints `pixel_pipeline: ` plus `pp_convert_last_error()`. That string is meaningful only after a failing call.

### 128-byte alignment

Pipeline allocations are 128-byte aligned via `posix_memalign`, including on x86_64:

- decoded RGBA
- per-pixel indices
- the 4bpp tile buffer
- the packed RGB staging buffer used for the palette

The files on disk are ordinary byte blobs. Alignment is a property of those library buffers.

### Link

```bash
cc -std=c11 -I tools/pixel_pipeline caller.c \
    tools/pixel_pipeline/build/libpixel_pipeline.a -lm
```

The archive contains the vendored PNG decoder, quantizer, scalar and NEON converters, and the writer. Callers do not compile those sources. `stbi_*` stays inside the decoder object and is not exported. `pixel_pipeline.h` is the stable API; other symbols in the archive are internal.

Swift bridges `pixel_pipeline.h` and calls `pp_convert_png_to_gba`. Pass `nil` for `result` when the two files are enough. This library is not on the Metal link line today.
