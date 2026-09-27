#include "rgb555_scalar.h"

uint16_t pp_rgb555_from_rgb8(uint8_t r, uint8_t g, uint8_t b)
{
    unsigned r5 = ((unsigned)r * 32u) >> 8;
    unsigned g5 = ((unsigned)g * 32u) >> 8;
    unsigned b5 = ((unsigned)b * 32u) >> 8;
    return (uint16_t)((r5 & 0x1Fu) | ((g5 & 0x1Fu) << 5) | ((b5 & 0x1Fu) << 10));
}

void pp_rgb555_from_rgb8_n(const uint8_t *rgb, size_t count, uint16_t *dst)
{
    size_t i;

    for (i = 0; i < count; i++) {
        dst[i] = pp_rgb555_from_rgb8(rgb[i * 3u], rgb[i * 3u + 1u], rgb[i * 3u + 2u]);
    }
}
