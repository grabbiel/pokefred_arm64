#ifndef PP_RGB555_SCALAR_H
#define PP_RGB555_SCALAR_H

#include <stddef.h>
#include <stdint.h>

/* GBA RGB555, stored in a host uint16. Memory files are little-endian.
 *
 *   bit 0..4   red
 *   bit 5..9   green
 *   bit 10..14 blue
 *   bit 15     clear
 *
 * Channel reduction is fixed-point truncation, no float and no rounding:
 *
 *   c5 = ((unsigned)c8 * 32u) >> 8
 *
 * which is identical to (c8 >> 3) for every c8 in 0..255, then masked with
 * 0x1F. 0 maps to 0 and 255 maps to 31. This matches the shift used by
 * pret gbagfx (RGB8 >> 3).
 */
uint16_t pp_rgb555_from_rgb8(uint8_t r, uint8_t g, uint8_t b);

/* rgb is tightly packed R,G,B triples (count * 3 bytes). */
void pp_rgb555_from_rgb8_n(const uint8_t *rgb, size_t count, uint16_t *dst);

#endif
