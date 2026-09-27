#include "tile_pack.h"

#include <string.h>

size_t pp_tile_pack_size(int width, int height)
{
    size_t tiles_x;
    size_t tiles_y;

    if (width <= 0 || height <= 0) {
        return 0;
    }
    if ((width % 8) != 0 || (height % 8) != 0) {
        return 0;
    }
    tiles_x = (size_t)width / 8u;
    tiles_y = (size_t)height / 8u;
    if (tiles_y != 0 && tiles_x > (SIZE_MAX / 32u) / tiles_y) {
        return 0;
    }
    return tiles_x * tiles_y * 32u;
}

static int pack_args_ok(const uint8_t *indices, int width, int height, uint8_t *dst)
{
    if (!indices || !dst) {
        return 0;
    }
    return pp_tile_pack_size(width, height) != 0;
}

int pp_tile_pack_scalar(const uint8_t *indices, int width, int height, uint8_t *dst)
{
    int tiles_x;
    int tiles_y;
    int ty;
    int tx;
    size_t out;

    if (!pack_args_ok(indices, width, height, dst)) {
        return -1;
    }
    tiles_x = width / 8;
    tiles_y = height / 8;
    out = 0;
    for (ty = 0; ty < tiles_y; ty++) {
        for (tx = 0; tx < tiles_x; tx++) {
            int row;
            for (row = 0; row < 8; row++) {
                const uint8_t *p = indices + ((size_t)(ty * 8 + row) * (size_t)width) + (size_t)(tx * 8);
                int col;
                for (col = 0; col < 8; col += 2) {
                    uint8_t lo = (uint8_t)(p[col] & 0x0Fu);
                    uint8_t hi = (uint8_t)(p[col + 1] & 0x0Fu);
                    dst[out++] = (uint8_t)(lo | (uint8_t)(hi << 4));
                }
            }
        }
    }
    return 0;
}

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>

/* Pack eight indices into four bytes. Low nibble is the even (left) pixel.
 * vreinterpret_u16_u8 plus the 0x0F00 mask assumes little-endian lanes
 * (correct on AArch64 Apple Silicon and Linux). A big-endian port would
 * swap nibbles; the scalar packer above does not depend on host endianness.
 * Example: pixels 1,2 → 0x21. */
static void pack8_neon(const uint8_t *src, uint8_t *dst)
{
    uint8x8_t px = vand_u8(vld1_u8(src), vdup_n_u8(0x0Fu));
    uint16x4_t pairs = vreinterpret_u16_u8(px);
    uint16x4_t lo = vand_u16(pairs, vdup_n_u16(0x000Fu));
    uint16x4_t hi = vshr_n_u16(vand_u16(pairs, vdup_n_u16(0x0F00u)), 4);
    uint16x4_t packed = vorr_u16(lo, hi);
    uint8x8_t narrow = vmovn_u16(vcombine_u16(packed, vdup_n_u16(0)));
    uint8_t tmp[8] __attribute__((aligned(8)));

    vst1_u8(tmp, narrow);
    memcpy(dst, tmp, 4);
}

int pp_tile_pack_neon(const uint8_t *indices, int width, int height, uint8_t *dst)
{
    int tiles_x;
    int tiles_y;
    int ty;
    int tx;
    size_t out;

    if (!pack_args_ok(indices, width, height, dst)) {
        return -1;
    }
    tiles_x = width / 8;
    tiles_y = height / 8;
    out = 0;
    for (ty = 0; ty < tiles_y; ty++) {
        for (tx = 0; tx < tiles_x; tx++) {
            int row;
            for (row = 0; row < 8; row++) {
                const uint8_t *p = indices + ((size_t)(ty * 8 + row) * (size_t)width) + (size_t)(tx * 8);
                pack8_neon(p, dst + out);
                out += 4;
            }
        }
    }
    return 0;
}
#endif
