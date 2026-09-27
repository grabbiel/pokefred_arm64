#include "quantize.h"
#include "test_common.h"

#include <stdlib.h>
#include <string.h>

static void put_px(uint8_t *rgba, size_t i, int r, int g, int b, int a)
{
    rgba[i * 4u] = (uint8_t)r;
    rgba[i * 4u + 1u] = (uint8_t)g;
    rgba[i * 4u + 2u] = (uint8_t)b;
    rgba[i * 4u + 3u] = (uint8_t)a;
}

static uint8_t *rgba_alloc(size_t n)
{
    uint8_t *p = (uint8_t *)malloc(n * 4u);
    if (p) {
        memset(p, 0, n * 4u);
    }
    return p;
}

static int test_transparent_exact(void)
{
    pp_image img;
    pp_indexed idx;
    uint8_t *rgba = rgba_alloc(4);

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = 2;
    img.height = 2;
    img.rgba = rgba;
    put_px(rgba, 0, 9, 9, 9, 0);
    put_px(rgba, 1, 255, 0, 0, 255);
    put_px(rgba, 2, 0, 255, 0, 255);
    put_px(rgba, 3, 0, 0, 255, 255);

    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(((uintptr_t)idx.indices % 128u) == 0);
    EXPECT(idx.color_count == 4);
    EXPECT(idx.indices[0] == 0);
    EXPECT(idx.indices[1] == 1);
    EXPECT(idx.indices[2] == 2);
    EXPECT(idx.indices[3] == 3);
    EXPECT(idx.rgb[0][0] == 9 && idx.rgb[0][1] == 9 && idx.rgb[0][2] == 9);
    EXPECT(idx.rgb[1][0] == 255 && idx.rgb[1][1] == 0 && idx.rgb[1][2] == 0);
    EXPECT(idx.rgb[2][0] == 0 && idx.rgb[2][1] == 255 && idx.rgb[2][2] == 0);
    EXPECT(idx.rgb[3][0] == 0 && idx.rgb[3][1] == 0 && idx.rgb[3][2] == 255);

    pp_indexed_free(&idx);
    free(rgba);
    return 0;
}

static int test_opaque_first_is_index0(void)
{
    pp_image img;
    pp_indexed idx;
    uint8_t *rgba = rgba_alloc(2);

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = 2;
    img.height = 1;
    img.rgba = rgba;
    put_px(rgba, 0, 255, 0, 0, 255);
    put_px(rgba, 1, 0, 0, 255, 255);
    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(idx.color_count == 2);
    EXPECT(idx.indices[0] == 0);
    EXPECT(idx.indices[1] == 1);
    EXPECT(idx.rgb[0][0] == 255 && idx.rgb[0][2] == 0);
    EXPECT(idx.rgb[1][2] == 255);
    pp_indexed_free(&idx);
    free(rgba);
    return 0;
}

/* 17 opaque grays/red. Closest pair is the first two grays; they share index 0. */
static int test_merge_seventeen(void)
{
    enum { N = 17 };
    pp_image img;
    pp_indexed idx;
    pp_indexed again;
    uint8_t *rgba = rgba_alloc(N);
    int i;

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = N;
    img.height = 1;
    img.rgba = rgba;
    for (i = 0; i < 16; i++) {
        int g = i * 16;
        put_px(rgba, (size_t)i, g, g, g, 255);
    }
    put_px(rgba, 16, 255, 0, 0, 255);
    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(idx.color_count == 16);
    EXPECT(idx.indices[0] == 0);
    EXPECT(idx.indices[1] == 0);
    EXPECT(idx.indices[2] == 1);
    EXPECT(idx.indices[16] == 15);
    EXPECT(idx.rgb[0][0] == 0 && idx.rgb[0][1] == 0 && idx.rgb[0][2] == 0);
    EXPECT(idx.rgb[1][0] == 32 && idx.rgb[1][1] == 32 && idx.rgb[1][2] == 32);
    EXPECT(idx.rgb[15][0] == 255 && idx.rgb[15][1] == 0 && idx.rgb[15][2] == 0);
    for (i = 0; i < N; i++) {
        EXPECT(idx.indices[i] <= 15);
    }

    REQUIRE(pp_quantize(&img, &again) == 0);
    EXPECT(memcmp(idx.indices, again.indices, N) == 0);
    EXPECT(memcmp(idx.rgb, again.rgb, sizeof idx.rgb) == 0);
    pp_indexed_free(&again);
    pp_indexed_free(&idx);
    free(rgba);
    return 0;
}

/* Transparent pixel plus 16 grays. Index 0 stays transparent; one gray merges. */
static int test_merge_with_transparent(void)
{
    enum { N = 17 };
    pp_image img;
    pp_indexed idx;
    uint8_t *rgba = rgba_alloc(N);
    int i;

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = N;
    img.height = 1;
    img.rgba = rgba;
    put_px(rgba, 0, 1, 2, 3, 0);
    for (i = 0; i < 16; i++) {
        int g = i * 16;
        put_px(rgba, (size_t)(i + 1), g, g, g, 255);
    }
    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(idx.color_count == 16);
    EXPECT(idx.indices[0] == 0);
    EXPECT(idx.rgb[0][0] == 1 && idx.rgb[0][1] == 2 && idx.rgb[0][2] == 3);
    EXPECT(idx.indices[1] == 1);
    EXPECT(idx.indices[2] == 1);
    EXPECT(idx.indices[3] == 2);
    EXPECT(idx.rgb[1][0] == 0 && idx.rgb[1][1] == 0 && idx.rgb[1][2] == 0);
    EXPECT(idx.rgb[2][0] == 32);
    pp_indexed_free(&idx);
    free(rgba);
    return 0;
}

static int test_indexed_identity(void)
{
    pp_image img;
    pp_indexed idx;
    uint8_t plte[9] = {255, 255, 255, 255, 0, 0, 0, 255, 0};
    uint8_t *rgba = rgba_alloc(3);

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = 3;
    img.height = 1;
    img.rgba = rgba;
    img.indexed = 1;
    img.plte_count = 3;
    img.plte = plte;
    put_px(rgba, 0, 255, 255, 255, 255);
    put_px(rgba, 1, 255, 0, 0, 255);
    put_px(rgba, 2, 0, 255, 0, 255);
    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(idx.color_count == 3);
    EXPECT(idx.indices[0] == 0 && idx.indices[1] == 1 && idx.indices[2] == 2);
    EXPECT(idx.rgb[0][0] == 255 && idx.rgb[0][1] == 255 && idx.rgb[0][2] == 255);
    EXPECT(idx.rgb[1][0] == 255 && idx.rgb[1][1] == 0);
    EXPECT(idx.rgb[2][1] == 255);
    pp_indexed_free(&idx);
    img.plte = NULL;
    free(rgba);
    return 0;
}

static int test_indexed_trns_to_zero(void)
{
    pp_image img;
    pp_indexed idx;
    uint8_t plte[12] = {
        255, 255, 255,
        255, 0, 0,
        0, 255, 0,
        0, 0, 255
    };
    uint8_t trns[4] = {0, 255, 0, 255};
    uint8_t *rgba = rgba_alloc(4);

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = 4;
    img.height = 1;
    img.rgba = rgba;
    img.indexed = 1;
    img.has_trns = 1;
    img.plte_count = 4;
    img.plte = plte;
    img.trns = trns;
    /* white (trans), red, green (trans), blue */
    put_px(rgba, 0, 255, 255, 255, 0);
    put_px(rgba, 1, 255, 0, 0, 255);
    put_px(rgba, 2, 0, 255, 0, 0);
    put_px(rgba, 3, 0, 0, 255, 255);
    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(idx.color_count == 3);
    EXPECT(idx.indices[0] == 0);
    EXPECT(idx.indices[2] == 0);
    EXPECT(idx.indices[1] == 1);
    EXPECT(idx.indices[3] == 2);
    EXPECT(idx.rgb[0][0] == 255 && idx.rgb[0][1] == 255 && idx.rgb[0][2] == 255);
    EXPECT(idx.rgb[1][0] == 255 && idx.rgb[1][1] == 0 && idx.rgb[1][2] == 0);
    EXPECT(idx.rgb[2][0] == 0 && idx.rgb[2][1] == 0 && idx.rgb[2][2] == 255);
    pp_indexed_free(&idx);
    img.plte = NULL;
    img.trns = NULL;
    free(rgba);
    return 0;
}

/* Frequent red must survive a >512-color reduction and stay off index 0. */
static int test_popularity_keeps_red(void)
{
    enum { REDS = 100, UNIQUES = 600, N = 1 + REDS + UNIQUES };
    pp_image img;
    pp_indexed idx;
    uint8_t *rgba = rgba_alloc(N);
    int i;
    int red_index = -1;

    REQUIRE(rgba != NULL);
    memset(&img, 0, sizeof img);
    img.width = N;
    img.height = 1;
    img.rgba = rgba;
    put_px(rgba, 0, 7, 8, 9, 0);
    for (i = 0; i < REDS; i++) {
        put_px(rgba, (size_t)(1 + i), 255, 0, 0, 255);
    }
    for (i = 0; i < UNIQUES; i++) {
        int r = i % 25;
        int g = i / 25;
        put_px(rgba, (size_t)(1 + REDS + i), r, g, 0, 255);
    }
    REQUIRE(pp_quantize(&img, &idx) == 0);
    EXPECT(idx.color_count <= 16);
    EXPECT(idx.color_count >= 2);
    EXPECT(idx.indices[0] == 0);
    EXPECT(idx.rgb[0][0] == 7 && idx.rgb[0][1] == 8 && idx.rgb[0][2] == 9);
    red_index = idx.indices[1];
    EXPECT(red_index != 0);
    EXPECT(idx.rgb[red_index][0] == 255 && idx.rgb[red_index][1] == 0 && idx.rgb[red_index][2] == 0);
    for (i = 0; i < REDS; i++) {
        EXPECT(idx.indices[1 + i] == red_index);
    }
    for (i = 0; i < N; i++) {
        EXPECT(idx.indices[i] <= 15);
    }
    pp_indexed_free(&idx);
    free(rgba);
    return 0;
}

int main(void)
{
    if (test_transparent_exact() || test_opaque_first_is_index0() || test_merge_seventeen() ||
        test_merge_with_transparent() || test_indexed_identity() || test_indexed_trns_to_zero() ||
        test_popularity_keeps_red()) {
        return 1;
    }
    if (g_failures) {
        fprintf(stderr, "test_quantize: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_quantize: ok\n");
    return 0;
}
