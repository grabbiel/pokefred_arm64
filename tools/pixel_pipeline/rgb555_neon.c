#include "rgb555_neon.h"

#include "rgb555_scalar.h"

int pp_neon_enabled(void)
{
    return PP_NEON_ENABLED;
}

int pp_rgb555_neon_compiled(void)
{
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    return 1;
#else
    return 0;
#endif
}

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>

void pp_rgb555_neon(const uint8_t *rgb, size_t count, uint16_t *dst)
{
    size_t i = 0;

    /* Eight RGB triples per iteration. vshr_n_u8(..., 3) matches
     * ((c * 32) >> 8) & 0x1F for 8-bit channels. */
    for (; i + 8 <= count; i += 8) {
        uint8x8x3_t pix = vld3_u8(rgb + i * 3u);
        uint16x8_t r = vmovl_u8(vshr_n_u8(pix.val[0], 3));
        uint16x8_t g = vmovl_u8(vshr_n_u8(pix.val[1], 3));
        uint16x8_t b = vmovl_u8(vshr_n_u8(pix.val[2], 3));
        uint16x8_t rgb555 = vorrq_u16(r, vshlq_n_u16(g, 5));
        rgb555 = vorrq_u16(rgb555, vshlq_n_u16(b, 10));
        vst1q_u16(dst + i, rgb555);
    }
    if (i < count) {
        pp_rgb555_from_rgb8_n(rgb + i * 3u, count - i, dst + i);
    }
}
#endif
