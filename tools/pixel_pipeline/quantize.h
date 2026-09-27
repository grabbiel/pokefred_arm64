#ifndef PP_QUANTIZE_H
#define PP_QUANTIZE_H

#include "png_decode.h"

#include <stdint.h>

/* 4bpp indexed image. indices is 128-byte aligned, one byte per pixel, 0..15.
 *
 * Palette index 0 is the transparent slot.
 *
 * Indexed PNG (PLTE count <= 16, every pixel matches a unique palette key):
 *   - No fully transparent entry (tRNS alpha 0): keep PLTE order. Index 0 is
 *     GBA color 0, including its RGB, even when those pixels are opaque.
 *     This is the pret tileset round-trip (tanoby ruins has no tRNS).
 *   - One or more entries with alpha 0: those pixels become index 0. Slot 0
 *     stores the first transparent PLTE color. Opaque entries keep PLTE order
 *     in slots 1..N.
 *
 * Otherwise (truecolor, or more than 16 palette entries):
 *   - Alpha 0 pixels are transparent and use index 0. Slot 0 stores the RGB of
 *     the first transparent pixel, or (0,0,0) if the RGB was never sampled.
 *   - Opaque colors fill slots 1..15 when any pixel is transparent, or slots
 *     0..15 when the image has no transparent pixel (index 0 is then the
 *     first opaque color in raster order, the GBA color-0 slot).
 *   - More colors than that limit are reduced deterministically: if more than
 *     512 unique opaque colors exist, the 512 most frequent are kept (ties
 *     keep the earlier raster-order color) and the rest join their nearest
 *     neighbor. Survivors are then merged by closest squared RGB distance
 *     until the limit is met. Equal distances keep the earlier pair. The
 *     survivor of a pair is the higher population; equal populations keep the
 *     lexicographically smaller RGB triple. Merged colors are not averaged.
 */
typedef struct pp_indexed {
    int width;
    int height;
    int color_count;
    uint8_t rgb[16][3];
    uint8_t *indices;
} pp_indexed;

int pp_quantize(const pp_image *img, pp_indexed *out);
void pp_indexed_free(pp_indexed *idx);

#endif
