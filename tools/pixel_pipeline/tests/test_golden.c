#include "png_decode.h"
#include "quantize.h"
#include "rgb555_scalar.h"
#include "test_common.h"
#include "tile_pack.h"
#include "writer.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *read_file(const char *path, size_t *out_n)
{
    FILE *f = fopen(path, "rb");
    long n;
    uint8_t *buf;

    if (!f) {
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    n = ftell(f);
    if (n < 0) {
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }
    buf = (uint8_t *)malloc((size_t)n + 1u);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_n = (size_t)n;
    return buf;
}

static int expect_bytes(const char *label, const uint8_t *got, size_t got_n, const uint8_t *want, size_t want_n)
{
    size_t i;
    size_t n;

    if (got_n == want_n && memcmp(got, want, got_n) == 0) {
        return 0;
    }
    fprintf(stderr, "FAIL %s length got %zu want %zu\n", label, got_n, want_n);
    n = got_n < want_n ? got_n : want_n;
    for (i = 0; i < n; i++) {
        if (got[i] != want[i]) {
            fprintf(stderr, "  first diff at %zu: got %02x want %02x\n", i, got[i], want[i]);
            break;
        }
    }
    g_failures++;
    return -1;
}

static int unpack_matches(const uint8_t *tiles, const uint8_t *indices, int w, int h)
{
    int tiles_x = w / 8;
    int tiles_y = h / 8;
    int ty;
    int tx;
    size_t o = 0;

    for (ty = 0; ty < tiles_y; ty++) {
        for (tx = 0; tx < tiles_x; tx++) {
            int row;
            for (row = 0; row < 8; row++) {
                int col;
                for (col = 0; col < 8; col += 2) {
                    uint8_t b = tiles[o++];
                    int x = tx * 8 + col;
                    int y = ty * 8 + row;
                    if (indices[(size_t)y * (size_t)w + (size_t)x] != (b & 0x0Fu)) {
                        return -1;
                    }
                    if (indices[(size_t)y * (size_t)w + (size_t)(x + 1)] != (b >> 4)) {
                        return -1;
                    }
                }
            }
        }
    }
    return 0;
}

int main(void)
{
    static const char origin_expect[] = "data/tilesets/secondary/tanoby_ruins/tiles.png\n";
    pp_image img;
    pp_indexed indexed;
    pp_gba gba;
    uint8_t *origin = NULL;
    size_t origin_n = 0;
    uint8_t *gold_bpp = NULL;
    size_t gold_bpp_n = 0;
    uint8_t *gold_pal = NULL;
    size_t gold_pal_n = 0;
    uint8_t *scalar_tiles = NULL;
    uint8_t written_pal[32];
    int i;
    const char *err;

    origin = read_file("testdata/ORIGIN.txt", &origin_n);
    REQUIRE(origin != NULL);
    EXPECT(origin_n == sizeof origin_expect - 1u);
    EXPECT(memcmp(origin, origin_expect, sizeof origin_expect - 1u) == 0);

    err = NULL;
    if (pp_png_decode_file("testdata/tanoby_ruins_tiles.png", &img) != 0) {
        err = pp_png_last_error();
        fprintf(stderr, "decode failed: %s\n", err ? err : "");
        free(origin);
        return 1;
    }
    EXPECT(img.width == 128);
    EXPECT(img.height == 40);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(img.rgba != NULL);
    EXPECT(((uintptr_t)img.rgba % 128u) == 0);

    REQUIRE(pp_quantize(&img, &indexed) == 0);
    REQUIRE(indexed.indices != NULL);
    EXPECT(((uintptr_t)indexed.indices % 128u) == 0);
    EXPECT(indexed.color_count == 16);
    EXPECT(indexed.rgb[0][0] == 255 && indexed.rgb[0][1] == 255 && indexed.rgb[0][2] == 255);
    EXPECT(indexed.rgb[1][0] == 238 && indexed.rgb[1][1] == 238 && indexed.rgb[1][2] == 238);
    EXPECT(indexed.rgb[15][0] == 0 && indexed.rgb[15][1] == 0 && indexed.rgb[15][2] == 0);

    REQUIRE(pp_build_gba(&indexed, &gba) == 0);
    REQUIRE(gba.tiles != NULL);
    EXPECT(((uintptr_t)gba.tiles % 128u) == 0);
    EXPECT(gba.tiles_size == 2560u);
    /* Top-left tile is index 0, so the first row is four zero bytes.
     * The next tile's first row is index 12, low|high = 0xCC. */
    EXPECT(gba.tiles[0] == 0x00 && gba.tiles[1] == 0x00 && gba.tiles[2] == 0x00 && gba.tiles[3] == 0x00);
    EXPECT(gba.tiles[32] == 0xCC && gba.tiles[33] == 0xCC && gba.tiles[34] == 0xCC && gba.tiles[35] == 0xCC);
    EXPECT(gba.palette[0] == 0x7FFFu);
    EXPECT(gba.palette[1] == 0x77BDu);
    EXPECT(gba.palette[15] == 0x0000u);

    scalar_tiles = (uint8_t *)malloc(gba.tiles_size);
    REQUIRE(scalar_tiles != NULL);
    REQUIRE(pp_tile_pack_scalar(indexed.indices, indexed.width, indexed.height, scalar_tiles) == 0);
    EXPECT(memcmp(scalar_tiles, gba.tiles, gba.tiles_size) == 0);
    for (i = 0; i < 16; i++) {
        uint16_t scalar = pp_rgb555_from_rgb8(indexed.rgb[i][0], indexed.rgb[i][1], indexed.rgb[i][2]);
        EXPECT(gba.palette[i] == scalar);
    }
    EXPECT(unpack_matches(gba.tiles, indexed.indices, img.width, img.height) == 0);

    gold_bpp = read_file("tests/golden/tanoby_ruins_tiles.4bpp", &gold_bpp_n);
    gold_pal = read_file("tests/golden/tanoby_ruins_tiles.pal", &gold_pal_n);
    REQUIRE(gold_bpp != NULL && gold_pal != NULL);
    expect_bytes("4bpp", gba.tiles, gba.tiles_size, gold_bpp, gold_bpp_n);
    for (i = 0; i < 16; i++) {
        written_pal[i * 2] = (uint8_t)(gba.palette[i] & 0xFFu);
        written_pal[i * 2 + 1] = (uint8_t)(gba.palette[i] >> 8);
    }
    expect_bytes("pal", written_pal, sizeof written_pal, gold_pal, gold_pal_n);

    REQUIRE(pp_write_outputs(&gba, "/tmp/pp_tanoby.4bpp", "/tmp/pp_tanoby.pal") == 0);
    {
        size_t n = 0;
        uint8_t *disk = read_file("/tmp/pp_tanoby.4bpp", &n);
        REQUIRE(disk != NULL);
        expect_bytes("written 4bpp", disk, n, gold_bpp, gold_bpp_n);
        free(disk);
        disk = read_file("/tmp/pp_tanoby.pal", &n);
        REQUIRE(disk != NULL);
        expect_bytes("written pal", disk, n, gold_pal, gold_pal_n);
        free(disk);
    }

    free(scalar_tiles);
    free(gold_bpp);
    free(gold_pal);
    free(origin);
    pp_gba_free(&gba);
    pp_indexed_free(&indexed);
    pp_image_free(&img);

    if (g_failures) {
        fprintf(stderr, "test_golden: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_golden: ok\n");
    return 0;
}
