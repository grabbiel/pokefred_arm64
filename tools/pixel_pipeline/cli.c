#include "png_decode.h"
#include "quantize.h"
#include "rgb555_neon.h"
#include "writer.h"

#include <stdio.h>

int main(int argc, char **argv)
{
    pp_image img;
    pp_indexed indexed;
    pp_gba gba;

    if (argc != 4) {
        fprintf(stderr, "usage: pixel_pipeline <input.png> <output.4bpp> <output.pal>\n");
        return 2;
    }
    if (pp_png_decode_file(argv[1], &img) != 0) {
        fprintf(stderr, "pixel_pipeline: %s\n", pp_png_last_error());
        return 1;
    }
    if (pp_quantize(&img, &indexed) != 0) {
        fprintf(stderr, "pixel_pipeline: quantization failed\n");
        pp_image_free(&img);
        return 1;
    }
    if (pp_build_gba(&indexed, &gba) != 0) {
        fprintf(stderr,
                "pixel_pipeline: tile pack failed (width and height must be multiples of 8)\n");
        pp_indexed_free(&indexed);
        pp_image_free(&img);
        return 1;
    }
    if (pp_write_outputs(&gba, argv[2], argv[3]) != 0) {
        fprintf(stderr, "pixel_pipeline: failed to write outputs\n");
        pp_gba_free(&gba);
        pp_indexed_free(&indexed);
        pp_image_free(&img);
        return 1;
    }
    printf("pixel_pipeline: %dx%d, %d colors, %zu 4bpp bytes, palette 32 bytes, neon %s\n",
           img.width, img.height, indexed.color_count, gba.tiles_size,
           pp_neon_enabled() ? "on" : "off");
    pp_gba_free(&gba);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}
