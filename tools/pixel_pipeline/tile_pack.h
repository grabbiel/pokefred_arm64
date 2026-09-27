#ifndef PP_TILE_PACK_H
#define PP_TILE_PACK_H

#include <stddef.h>
#include <stdint.h>

/* GBA 4bpp tile blob.
 *
 * Tiles are 8x8 and are emitted left-to-right, then top-to-bottom. There is
 * no metatile (2x2) swizzle. Each tile is 32 bytes: 8 rows of 4 bytes.
 *
 * Nibble order (GBATEK / gbagfx): the low nibble is the left pixel and the
 * high nibble is the right pixel.
 *
 *   byte = (index[x] & 0x0F) | ((index[x + 1] & 0x0F) << 4)
 *
 * Indices outside 0..15 are masked to 4 bits. width and height must be
 * positive multiples of 8. pp_tile_pack_size returns 0 when they are not.
 */
size_t pp_tile_pack_size(int width, int height);

int pp_tile_pack_scalar(const uint8_t *indices, int width, int height, uint8_t *dst);

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
int pp_tile_pack_neon(const uint8_t *indices, int width, int height, uint8_t *dst);
#endif

#endif
