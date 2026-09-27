#include "pixel_pipeline.h"

#include <stdio.h>

int main(int argc, char **argv)
{
    pp_convert_result info;
    int rc;

    if (argc != 4) {
        fprintf(stderr, "usage: pixel_pipeline <input.png> <output.4bpp> <output.pal>\n");
        return 2;
    }
    rc = pp_convert_png_to_gba(argv[1], argv[2], argv[3], &info);
    if (rc != 0) {
        fprintf(stderr, "pixel_pipeline: %s\n", pp_convert_last_error());
        return 1;
    }
    printf("pixel_pipeline: %dx%d, %d colors, %zu 4bpp bytes, palette 32 bytes, neon %s\n",
           info.width, info.height, info.color_count, info.tiles_size,
           info.neon_enabled ? "on" : "off");
    return 0;
}
