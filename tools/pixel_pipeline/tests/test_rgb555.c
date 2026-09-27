#include "rgb555_neon.h"
#include "rgb555_scalar.h"
#include "test_common.h"

#include <string.h>

int main(void)
{
    int c;
    uint8_t packed[16 * 3];
    uint16_t batch[16];
    int i;

    EXPECT(pp_rgb555_from_rgb8(0, 0, 0) == 0x0000u);
    EXPECT(pp_rgb555_from_rgb8(255, 255, 255) == 0x7FFFu);
    EXPECT(pp_rgb555_from_rgb8(255, 0, 0) == 31u);
    EXPECT(pp_rgb555_from_rgb8(0, 255, 0) == (31u << 5));
    EXPECT(pp_rgb555_from_rgb8(0, 0, 255) == (31u << 10));
    EXPECT(pp_rgb555_from_rgb8(8, 0, 0) == 1u);
    EXPECT(pp_rgb555_from_rgb8(7, 0, 0) == 0u);
    EXPECT(pp_rgb555_from_rgb8(238, 238, 238) == 0x77BDu);
    EXPECT((pp_rgb555_from_rgb8(1, 2, 3) & 0x8000u) == 0u);

    for (c = 0; c < 256; c++) {
        unsigned fixed = ((unsigned)c * 32u) >> 8;
        EXPECT(fixed == (unsigned)(c >> 3));
        EXPECT(pp_rgb555_from_rgb8((uint8_t)c, 0, 0) == (uint16_t)(fixed & 0x1Fu));
    }

    for (i = 0; i < 16; i++) {
        uint8_t v = (uint8_t)(255 - i * 17);
        packed[i * 3] = v;
        packed[i * 3 + 1] = v;
        packed[i * 3 + 2] = v;
    }
    pp_rgb555_from_rgb8_n(packed, 16, batch);
    for (i = 0; i < 16; i++) {
        EXPECT(batch[i] == pp_rgb555_from_rgb8(packed[i * 3], packed[i * 3 + 1], packed[i * 3 + 2]));
    }

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    EXPECT(pp_rgb555_neon_compiled() == 1);
    {
        uint16_t neon[16];
        pp_rgb555_neon(packed, 16, neon);
        EXPECT(memcmp(neon, batch, sizeof batch) == 0);
        /* Tail path: 8-wide loop plus scalar remainder. */
        pp_rgb555_neon(packed, 9, neon);
        EXPECT(memcmp(neon, batch, 9 * sizeof(uint16_t)) == 0);
    }
#else
    EXPECT(pp_rgb555_neon_compiled() == 0);
    EXPECT(pp_neon_enabled() == 0);
    printf("test_rgb555: NEON not compiled (scalar-only build)\n");
#endif

    if (g_failures) {
        fprintf(stderr, "test_rgb555: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_rgb555: ok\n");
    return 0;
}
