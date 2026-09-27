#ifndef PP_WRITER_H
#define PP_WRITER_H

#include "quantize.h"

#include <stddef.h>
#include <stdint.h>

/* tiles is 128-byte aligned 4bpp. palette[] is host-endian RGB555.
 * The .pal file is 16 little-endian uint16 values (32 bytes). Unused slots
 * are 0. */
typedef struct pp_gba {
    int width;
    int height;
    uint8_t *tiles;
    size_t tiles_size;
    uint16_t palette[16];
} pp_gba;

int pp_build_gba(const pp_indexed *idx, pp_gba *out);
int pp_write_outputs(const pp_gba *gba, const char *bpp_path, const char *pal_path);
void pp_gba_free(pp_gba *gba);

#endif
