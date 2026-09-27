#include "writer.h"

#include "aligned_alloc.h"
#include "rgb555_neon.h"
#include "rgb555_scalar.h"
#include "tile_pack.h"

#include <stdio.h>
#include <string.h>

int pp_build_gba(const pp_indexed *idx, pp_gba *out)
{
    size_t nbytes;
    uint8_t *tiles;
    uint8_t *packed;
    int i;

    if (!idx || !out || !idx->indices) {
        return -1;
    }
    memset(out, 0, sizeof *out);
    nbytes = pp_tile_pack_size(idx->width, idx->height);
    if (nbytes == 0) {
        return -1;
    }
    tiles = (uint8_t *)pp_aligned_alloc(nbytes);
    packed = (uint8_t *)pp_aligned_alloc(16u * 3u);
    if (!tiles || !packed) {
        pp_aligned_free(tiles);
        pp_aligned_free(packed);
        return -1;
    }
    memset(packed, 0, 16u * 3u);
    for (i = 0; i < 16; i++) {
        packed[i * 3] = idx->rgb[i][0];
        packed[i * 3 + 1] = idx->rgb[i][1];
        packed[i * 3 + 2] = idx->rgb[i][2];
    }
#if PP_NEON_ENABLED
    pp_rgb555_neon(packed, 16, out->palette);
    if (pp_tile_pack_neon(idx->indices, idx->width, idx->height, tiles) != 0) {
        pp_aligned_free(tiles);
        pp_aligned_free(packed);
        memset(out, 0, sizeof *out);
        return -1;
    }
#else
    pp_rgb555_from_rgb8_n(packed, 16, out->palette);
    if (pp_tile_pack_scalar(idx->indices, idx->width, idx->height, tiles) != 0) {
        pp_aligned_free(tiles);
        pp_aligned_free(packed);
        memset(out, 0, sizeof *out);
        return -1;
    }
#endif
    pp_aligned_free(packed);
    out->width = idx->width;
    out->height = idx->height;
    out->tiles = tiles;
    out->tiles_size = nbytes;
    return 0;
}

static int write_bytes(const char *path, const void *data, size_t n)
{
    FILE *f;

    f = fopen(path, "wb");
    if (!f) {
        return -1;
    }
    if (fwrite(data, 1, n, f) != n) {
        fclose(f);
        return -1;
    }
    if (fclose(f) != 0) {
        return -1;
    }
    return 0;
}

int pp_write_outputs(const pp_gba *gba, const char *bpp_path, const char *pal_path)
{
    uint8_t pal[32];
    int i;

    if (!gba || !gba->tiles || !bpp_path || !pal_path) {
        return -1;
    }
    for (i = 0; i < 16; i++) {
        uint16_t v = gba->palette[i];
        pal[i * 2] = (uint8_t)(v & 0xFFu);
        pal[i * 2 + 1] = (uint8_t)(v >> 8);
    }
    if (write_bytes(bpp_path, gba->tiles, gba->tiles_size) != 0) {
        return -1;
    }
    if (write_bytes(pal_path, pal, sizeof pal) != 0) {
        return -1;
    }
    return 0;
}

void pp_gba_free(pp_gba *gba)
{
    if (!gba) {
        return;
    }
    pp_aligned_free(gba->tiles);
    gba->tiles = NULL;
}
