#include "pixel_pipeline.h"
#include "png_decode.h"
#include "quantize.h"
#include "rgb555_neon.h"
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

static int check_origin(void)
{
    static const char origin_expect[] =
        "# pret/pokefirered fixtures. One record per line: <basename> <source path>\n"
        "tanoby_ruins_tiles.png data/tilesets/secondary/tanoby_ruins/tiles.png\n"
        "game_corner_tiles.png data/tilesets/secondary/game_corner/tiles.png\n"
        "pallet_town_tiles.png data/tilesets/secondary/pallet_town/tiles.png\n"
        "mart_tiles.png data/tilesets/secondary/mart/tiles.png\n"
        "school_tiles.png data/tilesets/secondary/school/tiles.png\n"
        "underground_path_tiles.png data/tilesets/secondary/underground_path/tiles.png\n";
    uint8_t *origin = NULL;
    size_t origin_n = 0;

    origin = read_file("testdata/ORIGIN.txt", &origin_n);
    REQUIRE(origin != NULL);
    EXPECT(origin_n == sizeof origin_expect - 1u);
    EXPECT(memcmp(origin, origin_expect, sizeof origin_expect - 1u) == 0);
    free(origin);
    return 0;
}

/* In-memory scalar pipeline vs the committed golden, then the public API
 * writes the same bytes under build/ (gitignored). */
static int check_fixture(const char *label, const char *png, const char *gold_bpp_path, const char *gold_pal_path,
                         const char *out_bpp, const char *out_pal, int width, int height, size_t tiles_size)
{
    pp_image img;
    pp_indexed indexed;
    pp_gba gba;
    pp_convert_result info;
    uint8_t *gold_bpp = NULL;
    size_t gold_bpp_n = 0;
    uint8_t *gold_pal = NULL;
    size_t gold_pal_n = 0;
    uint8_t *scalar_tiles = NULL;
    uint8_t *disk = NULL;
    uint8_t written_pal[32];
    size_t n = 0;
    int i;
    const char *err;
    char bpp_label[64];
    char pal_label[64];

    err = NULL;
    if (pp_png_decode_file(png, &img) != 0) {
        err = pp_png_last_error();
        fprintf(stderr, "%s decode failed: %s\n", label, err ? err : "");
        return 1;
    }
    EXPECT(img.width == width);
    EXPECT(img.height == height);
    REQUIRE(img.rgba != NULL);
    EXPECT(((uintptr_t)img.rgba % 128u) == 0);

    REQUIRE(pp_quantize(&img, &indexed) == 0);
    REQUIRE(indexed.indices != NULL);
    EXPECT(((uintptr_t)indexed.indices % 128u) == 0);

    REQUIRE(pp_build_gba(&indexed, &gba) == 0);
    REQUIRE(gba.tiles != NULL);
    EXPECT(((uintptr_t)gba.tiles % 128u) == 0);
    EXPECT(gba.tiles_size == tiles_size);

    scalar_tiles = (uint8_t *)malloc(gba.tiles_size);
    REQUIRE(scalar_tiles != NULL);
    REQUIRE(pp_tile_pack_scalar(indexed.indices, indexed.width, indexed.height, scalar_tiles) == 0);
    EXPECT(memcmp(scalar_tiles, gba.tiles, gba.tiles_size) == 0);
    for (i = 0; i < 16; i++) {
        uint16_t scalar = pp_rgb555_from_rgb8(indexed.rgb[i][0], indexed.rgb[i][1], indexed.rgb[i][2]);
        EXPECT(gba.palette[i] == scalar);
    }
    EXPECT(unpack_matches(gba.tiles, indexed.indices, img.width, img.height) == 0);

    gold_bpp = read_file(gold_bpp_path, &gold_bpp_n);
    gold_pal = read_file(gold_pal_path, &gold_pal_n);
    REQUIRE(gold_bpp != NULL && gold_pal != NULL);
    snprintf(bpp_label, sizeof bpp_label, "%s 4bpp", label);
    snprintf(pal_label, sizeof pal_label, "%s pal", label);
    expect_bytes(bpp_label, gba.tiles, gba.tiles_size, gold_bpp, gold_bpp_n);
    for (i = 0; i < 16; i++) {
        written_pal[i * 2] = (uint8_t)(gba.palette[i] & 0xFFu);
        written_pal[i * 2 + 1] = (uint8_t)(gba.palette[i] >> 8);
    }
    expect_bytes(pal_label, written_pal, sizeof written_pal, gold_pal, gold_pal_n);

    REQUIRE(pp_convert_png_to_gba(png, out_bpp, out_pal, &info) == 0);
    EXPECT(info.width == width);
    EXPECT(info.height == height);
    EXPECT(info.color_count == indexed.color_count);
    EXPECT(info.tiles_size == tiles_size);
    EXPECT(info.neon_enabled == pp_neon_enabled());

    disk = read_file(out_bpp, &n);
    REQUIRE(disk != NULL);
    snprintf(bpp_label, sizeof bpp_label, "%s written 4bpp", label);
    expect_bytes(bpp_label, disk, n, gold_bpp, gold_bpp_n);
    free(disk);
    disk = read_file(out_pal, &n);
    REQUIRE(disk != NULL);
    snprintf(pal_label, sizeof pal_label, "%s written pal", label);
    expect_bytes(pal_label, disk, n, gold_pal, gold_pal_n);
    free(disk);

    REQUIRE(pp_convert_png_to_gba(png, out_bpp, out_pal, NULL) == 0);

    free(scalar_tiles);
    free(gold_bpp);
    free(gold_pal);
    pp_gba_free(&gba);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

static int check_tanoby_details(void)
{
    pp_image img;
    pp_indexed indexed;
    pp_gba gba;

    REQUIRE(pp_png_decode_file("testdata/tanoby_ruins_tiles.png", &img) == 0);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(pp_quantize(&img, &indexed) == 0);
    EXPECT(indexed.color_count == 16);
    EXPECT(indexed.rgb[0][0] == 255 && indexed.rgb[0][1] == 255 && indexed.rgb[0][2] == 255);
    EXPECT(indexed.rgb[1][0] == 238 && indexed.rgb[1][1] == 238 && indexed.rgb[1][2] == 238);
    EXPECT(indexed.rgb[15][0] == 0 && indexed.rgb[15][1] == 0 && indexed.rgb[15][2] == 0);
    REQUIRE(pp_build_gba(&indexed, &gba) == 0);
    /* Top-left tile is index 0, so the first row is four zero bytes.
     * The next tile's first row is index 12, low|high = 0xCC. */
    EXPECT(gba.tiles[0] == 0x00 && gba.tiles[1] == 0x00 && gba.tiles[2] == 0x00 && gba.tiles[3] == 0x00);
    EXPECT(gba.tiles[32] == 0xCC && gba.tiles[33] == 0xCC && gba.tiles[34] == 0xCC && gba.tiles[35] == 0xCC);
    EXPECT(gba.palette[0] == 0x7FFFu);
    EXPECT(gba.palette[1] == 0x77BDu);
    EXPECT(gba.palette[15] == 0x0000u);
    pp_gba_free(&gba);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

static int check_game_corner_details(void)
{
    pp_image img;
    pp_indexed indexed;

    REQUIRE(pp_png_decode_file("testdata/game_corner_tiles.png", &img) == 0);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(pp_quantize(&img, &indexed) == 0);
    EXPECT(indexed.color_count == 16);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

static int check_pallet_town_details(void)
{
    pp_image img;
    pp_indexed indexed;

    REQUIRE(pp_png_decode_file("testdata/pallet_town_tiles.png", &img) == 0);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(pp_quantize(&img, &indexed) == 0);
    EXPECT(indexed.color_count == 16);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

static int check_mart_details(void)
{
    pp_image img;
    pp_indexed indexed;

    REQUIRE(pp_png_decode_file("testdata/mart_tiles.png", &img) == 0);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(pp_quantize(&img, &indexed) == 0);
    EXPECT(indexed.color_count == 16);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

static int check_school_details(void)
{
    pp_image img;
    pp_indexed indexed;

    REQUIRE(pp_png_decode_file("testdata/school_tiles.png", &img) == 0);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(pp_quantize(&img, &indexed) == 0);
    EXPECT(indexed.color_count == 16);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

static int check_underground_path_details(void)
{
    pp_image img;
    pp_indexed indexed;

    REQUIRE(pp_png_decode_file("testdata/underground_path_tiles.png", &img) == 0);
    EXPECT(img.indexed == 1);
    EXPECT(img.plte_count == 16);
    EXPECT(img.has_trns == 0);
    REQUIRE(pp_quantize(&img, &indexed) == 0);
    EXPECT(indexed.color_count == 16);
    pp_indexed_free(&indexed);
    pp_image_free(&img);
    return 0;
}

int main(void)
{
    REQUIRE(check_origin() == 0);
    REQUIRE(check_tanoby_details() == 0);
    REQUIRE(check_fixture("tanoby", "testdata/tanoby_ruins_tiles.png", "tests/golden/tanoby_ruins_tiles.4bpp",
                          "tests/golden/tanoby_ruins_tiles.pal", "build/tanoby_ruins_tiles.4bpp",
                          "build/tanoby_ruins_tiles.pal", 128, 40, 2560u) == 0);
    REQUIRE(check_game_corner_details() == 0);
    REQUIRE(check_fixture("game_corner", "testdata/game_corner_tiles.png", "tests/golden/game_corner_tiles.4bpp",
                          "tests/golden/game_corner_tiles.pal", "build/game_corner_tiles.4bpp",
                          "build/game_corner_tiles.pal", 128, 88, 5632u) == 0);
    REQUIRE(check_pallet_town_details() == 0);
    REQUIRE(check_fixture("pallet_town", "testdata/pallet_town_tiles.png", "tests/golden/pallet_town_tiles.4bpp",
                          "tests/golden/pallet_town_tiles.pal", "build/pallet_town_tiles.4bpp",
                          "build/pallet_town_tiles.pal", 128, 40, 2560u) == 0);
    REQUIRE(check_mart_details() == 0);
    REQUIRE(check_fixture("mart", "testdata/mart_tiles.png", "tests/golden/mart_tiles.4bpp",
                          "tests/golden/mart_tiles.pal", "build/mart_tiles.4bpp",
                          "build/mart_tiles.pal", 128, 24, 1536u) == 0);
    REQUIRE(check_school_details() == 0);
    REQUIRE(check_fixture("school", "testdata/school_tiles.png", "tests/golden/school_tiles.4bpp",
                          "tests/golden/school_tiles.pal", "build/school_tiles.4bpp",
                          "build/school_tiles.pal", 128, 32, 2048u) == 0);
    REQUIRE(check_underground_path_details() == 0);
    REQUIRE(check_fixture("underground_path", "testdata/underground_path_tiles.png",
                          "tests/golden/underground_path_tiles.4bpp", "tests/golden/underground_path_tiles.pal",
                          "build/underground_path_tiles.4bpp", "build/underground_path_tiles.pal", 128, 32, 2048u) == 0);

    EXPECT(pp_convert_png_to_gba(NULL, "build/x.4bpp", "build/x.pal", NULL) == 1);
    EXPECT(pp_convert_png_to_gba("testdata/missing.png", "build/x.4bpp", "build/x.pal", NULL) == 1);
    EXPECT(pp_convert_last_error()[0] != '\0');

    if (g_failures) {
        fprintf(stderr, "test_golden: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_golden: ok\n");
    return 0;
}
