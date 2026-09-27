#ifndef PIXEL_PIPELINE_H
#define PIXEL_PIPELINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Stable C API for callers that link libpixel_pipeline instead of spawning
 * the CLI. This header does not pull in the internal pipeline headers.
 *
 * Working buffers inside the library (decoded RGBA, palette indices, the
 * 4bpp tile blob, and the RGB staging buffer) are 128-byte aligned. The
 * files written here are plain byte streams; alignment applies to those
 * allocations, not to the paths on disk.
 *
 * Return values match the CLI's failure class:
 *   0  both outputs were written
 *   1  decode, quantize, tile pack, or write failed
 * The library does not return 2. That code is reserved for CLI usage errors.
 */

typedef struct pp_convert_result {
    int width;
    int height;
    int color_count;
    size_t tiles_size; /* bytes written to out_4bpp */
    int neon_enabled;  /* 1 when this call used the NEON converters */
} pp_convert_result;

/* result may be NULL. On success, a non-NULL result is filled in.
 * out_4bpp and out_pal are caller-chosen paths. */
int pp_convert_png_to_gba(const char *png_path, const char *out_4bpp, const char *out_pal,
                          pp_convert_result *result);

/* Text for a preceding non-zero pp_convert_png_to_gba return. The CLI prints
 * "pixel_pipeline: " in front of this string. Empty until a call fails. */
const char *pp_convert_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
