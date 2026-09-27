# Standalone GBA 4bpp pipeline. Does not build the Metal editor.
#   make
#   make test
#   make EXTRA_CFLAGS=-DPP_FORCE_SCALAR=1 test

CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2
ALL_CFLAGS := $(CFLAGS) $(EXTRA_CFLAGS)
CPPFLAGS := -I. -Ithird_party
LDFLAGS ?=
LDLIBS := -lm

BUILD := build

LIB_SRCS := \
	aligned_alloc.c \
	convert.c \
	png_decode.c \
	quantize.c \
	rgb555_scalar.c \
	rgb555_neon.c \
	tile_pack.c \
	writer.c

LIB_OBJS := $(patsubst %.c,$(BUILD)/%.o,$(LIB_SRCS))
STB_OBJ := $(BUILD)/stb_image_impl.o
COMMON_OBJS := $(LIB_OBJS) $(STB_OBJ)

TESTS := test_align test_rgb555 test_tile_pack test_quantize test_golden
TEST_BINS := $(patsubst %,$(BUILD)/%,$(TESTS))

AR ?= ar

.PHONY: all test clean

# Pattern-rule objects are intermediate; keep them for incremental rebuilds.
.SECONDARY:

all: $(BUILD)/pixel_pipeline $(BUILD)/libpixel_pipeline.a $(TEST_BINS)

test: all
	./$(BUILD)/test_align
	./$(BUILD)/test_rgb555
	./$(BUILD)/test_tile_pack
	./$(BUILD)/test_quantize
	./$(BUILD)/test_golden
	./$(BUILD)/pixel_pipeline >$(BUILD)/cli_usage.txt 2>&1; test $$? -eq 2
	grep -q "usage: pixel_pipeline <input.png> <output.4bpp> <output.pal>" $(BUILD)/cli_usage.txt
	./$(BUILD)/pixel_pipeline testdata/missing.png $(BUILD)/cli_bad.4bpp $(BUILD)/cli_bad.pal >$(BUILD)/cli_bad.txt 2>&1; test $$? -eq 1
	grep -q "pixel_pipeline:" $(BUILD)/cli_bad.txt
	./$(BUILD)/pixel_pipeline testdata/tanoby_ruins_tiles.png $(BUILD)/cli_tanoby.4bpp $(BUILD)/cli_tanoby.pal
	cmp $(BUILD)/cli_tanoby.4bpp tests/golden/tanoby_ruins_tiles.4bpp
	cmp $(BUILD)/cli_tanoby.pal tests/golden/tanoby_ruins_tiles.pal
	./$(BUILD)/pixel_pipeline testdata/game_corner_tiles.png $(BUILD)/cli_game_corner.4bpp $(BUILD)/cli_game_corner.pal
	cmp $(BUILD)/cli_game_corner.4bpp tests/golden/game_corner_tiles.4bpp
	cmp $(BUILD)/cli_game_corner.pal tests/golden/game_corner_tiles.pal
	./$(BUILD)/pixel_pipeline testdata/pallet_town_tiles.png $(BUILD)/cli_pallet_town.4bpp $(BUILD)/cli_pallet_town.pal
	cmp $(BUILD)/cli_pallet_town.4bpp tests/golden/pallet_town_tiles.4bpp
	cmp $(BUILD)/cli_pallet_town.pal tests/golden/pallet_town_tiles.pal
	./$(BUILD)/pixel_pipeline testdata/mart_tiles.png $(BUILD)/cli_mart.4bpp $(BUILD)/cli_mart.pal
	cmp $(BUILD)/cli_mart.4bpp tests/golden/mart_tiles.4bpp
	cmp $(BUILD)/cli_mart.pal tests/golden/mart_tiles.pal
	./$(BUILD)/pixel_pipeline testdata/school_tiles.png $(BUILD)/cli_school.4bpp $(BUILD)/cli_school.pal
	cmp $(BUILD)/cli_school.4bpp tests/golden/school_tiles.4bpp
	cmp $(BUILD)/cli_school.pal tests/golden/school_tiles.pal
	./$(BUILD)/pixel_pipeline testdata/underground_path_tiles.png $(BUILD)/cli_underground_path.4bpp $(BUILD)/cli_underground_path.pal
	cmp $(BUILD)/cli_underground_path.4bpp tests/golden/underground_path_tiles.4bpp
	cmp $(BUILD)/cli_underground_path.pal tests/golden/underground_path_tiles.pal
	./$(BUILD)/pixel_pipeline testdata/generic_building_1_tiles.png $(BUILD)/cli_generic_building_1.4bpp $(BUILD)/cli_generic_building_1.pal
	cmp $(BUILD)/cli_generic_building_1.4bpp tests/golden/generic_building_1_tiles.4bpp
	cmp $(BUILD)/cli_generic_building_1.pal tests/golden/generic_building_1_tiles.pal

$(BUILD) $(BUILD)/tests:
	mkdir -p $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(ALL_CFLAGS) $(CPPFLAGS) -MMD -MP -c -o $@ $<

$(BUILD)/tests/%.o: tests/%.c | $(BUILD)/tests
	$(CC) $(ALL_CFLAGS) $(CPPFLAGS) -MMD -MP -c -o $@ $<

$(STB_OBJ): third_party/stb_image_impl.c third_party/stb_image.h png_stb.h | $(BUILD)
	$(CC) -std=c11 -O2 -I. -Ithird_party -w -MMD -MP -c -o $@ $<

$(BUILD)/libpixel_pipeline.a: $(COMMON_OBJS)
	rm -f $@
	$(AR) rcs $@ $(COMMON_OBJS)

$(BUILD)/pixel_pipeline: $(BUILD)/cli.o $(BUILD)/libpixel_pipeline.a
	$(CC) $(ALL_CFLAGS) -o $@ $(BUILD)/cli.o $(BUILD)/libpixel_pipeline.a $(LDFLAGS) $(LDLIBS)

$(BUILD)/test_%: $(BUILD)/tests/test_%.o $(BUILD)/libpixel_pipeline.a
	$(CC) $(ALL_CFLAGS) -o $@ $(BUILD)/tests/test_$*.o $(BUILD)/libpixel_pipeline.a $(LDFLAGS) $(LDLIBS)

clean:
	rm -rf $(BUILD)

-include $(wildcard $(BUILD)/*.d) $(wildcard $(BUILD)/tests/*.d)
