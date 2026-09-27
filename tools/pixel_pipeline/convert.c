#include "pixel_pipeline.h"

#include "png_decode.h"
#include "quantize.h"
#include "rgb555_neon.h"
#include "writer.h"

#include <stdio.h>
#include <string.h>

static char g_err[256];

const char *pp_convert_last_error(void)
{
    return g_err;
}

static void set_err(const char *msg)
{
    snprintf(g_err, sizeof g_err, "%s", msg ? msg : "unknown error");
}

int pp_convert_png_to_gba(const char *png_path, const char *out_4bpp, const char *out_pal,
                          pp_convert_result *result)
{
    pp_image img;
    pp_indexed indexed;
    pp_gba gba;

    g_err[0] = '\0';
    if (result) {
        memset(result, 0, sizeof *result);
    }
    if (!png_path || !out_4bpp || !out_pal) {
        set_err("missing path");
        return 1;
    }
    if (pp_png_decode_file(png_path, &img) != 0) {
        set_err(pp_png_last_error());
        return 1;
    }
    if (pp_quantize(&img, &indexed) != 0) {
        set_err("quantization failed");
        pp_image_free(&img);
        return 1;
    }
    if (pp_build_gba(&indexed, &gba) != 0) {
        set_err("tile pack failed (width and height must be multiples of 8)");
        pp_indexed_free(&indexed);
        pp_image_free(&img);
        return 1;
    }
    if (pp_write_outputs(&gba, out_4bpp, out_pal) != 0) {
        set_err("failed to write outputs");
        pp_gba_free(&gba);
        pp_indexed_free(&indexed);
        pp_image_free(&img);
        return 1;
    }
    if (result) {
        result->width = img.width;
        result->height = img.height;
        result->color_count = indexed.color_count;
        result->tiles_size = gba.tiles_size;
        result->neon_enabled = pp_neon_enabled();
    }
    pp_gba_free(&gba);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}
