#include "tile_pack.h"
#include "test_common.h"

#include <string.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include "rgb555_neon.h"
#endif

int main(void)
{
    uint8_t tile[64];
    uint8_t dst[128];
    uint8_t wide[16 * 8];

    EXPECT(pp_tile_pack_size(8, 8) == 32u);
    EXPECT(pp_tile_pack_size(128, 40) == 2560u);
    EXPECT(pp_tile_pack_size(7, 8) == 0u);
    EXPECT(pp_tile_pack_size(8, 0) == 0u);
    EXPECT(pp_tile_pack_scalar(tile, 7, 8, dst) != 0);

    memset(tile, 0, sizeof tile);
    tile[0] = 1;
    tile[1] = 2;
    tile[2] = 15;
    tile[3] = 15;
    tile[8] = 5;
    tile[9] = 6;
    memset(dst, 0xFF, sizeof dst);
    REQUIRE(pp_tile_pack_scalar(tile, 8, 8, dst) == 0);
    /* Low nibble is the left pixel: 1 then 2 → 0x21. */
    EXPECT(dst[0] == 0x21u);
    EXPECT(dst[1] == 0xFFu);
    EXPECT(dst[2] == 0x00u);
    EXPECT(dst[3] == 0x00u);
    /* Next row starts at byte 4. */
    EXPECT(dst[4] == 0x65u);
    EXPECT(dst[5] == 0x00u);

    memset(wide, 0, sizeof wide);
    wide[8] = 0x0A;
    wide[9] = 0x0B;
    memset(dst, 0, sizeof dst);
    REQUIRE(pp_tile_pack_scalar(wide, 16, 8, dst) == 0);
    EXPECT(pp_tile_pack_size(16, 8) == 64u);
    /* Second tile begins after the first 32 bytes. */
    EXPECT(dst[0] == 0x00u);
    EXPECT(dst[32] == 0xBAu);
    EXPECT(dst[33] == 0x00u);

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    {
        uint8_t indices[32 * 16];
        uint8_t sbuf[256];
        uint8_t nbuf[256];
        int i;

        for (i = 0; i < 32 * 16; i++) {
            indices[i] = (uint8_t)((i * 3 + 1) & 15);
        }
        REQUIRE(pp_tile_pack_scalar(indices, 32, 16, sbuf) == 0);
        REQUIRE(pp_tile_pack_neon(indices, 32, 16, nbuf) == 0);
        EXPECT(memcmp(sbuf, nbuf, sizeof sbuf) == 0);
        EXPECT(pp_neon_enabled() == PP_NEON_ENABLED);
    }
#else
    EXPECT(pp_tile_pack_size(16, 16) == 128u);
    printf("test_tile_pack: NEON not compiled (scalar-only build)\n");
#endif

    if (g_failures) {
        fprintf(stderr, "test_tile_pack: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_tile_pack: ok\n");
    return 0;
}
