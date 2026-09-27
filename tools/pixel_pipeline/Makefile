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

.PHONY: all test clean

# Pattern-rule objects are intermediate; keep them for incremental rebuilds.
.SECONDARY:

all: $(BUILD)/pixel_pipeline $(TEST_BINS)

test: all
	./$(BUILD)/test_align
	./$(BUILD)/test_rgb555
	./$(BUILD)/test_tile_pack
	./$(BUILD)/test_quantize
	./$(BUILD)/test_golden

$(BUILD) $(BUILD)/tests:
	mkdir -p $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(ALL_CFLAGS) $(CPPFLAGS) -MMD -MP -c -o $@ $<

$(BUILD)/tests/%.o: tests/%.c | $(BUILD)/tests
	$(CC) $(ALL_CFLAGS) $(CPPFLAGS) -MMD -MP -c -o $@ $<

$(STB_OBJ): third_party/stb_image_impl.c third_party/stb_image.h | $(BUILD)
	$(CC) -std=c11 -O2 -Ithird_party -w -MMD -MP -c -o $@ $<

$(BUILD)/pixel_pipeline: $(BUILD)/cli.o $(COMMON_OBJS)
	$(CC) $(ALL_CFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

$(BUILD)/test_%: $(BUILD)/tests/test_%.o $(COMMON_OBJS)
	$(CC) $(ALL_CFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

clean:
	rm -rf $(BUILD)

-include $(wildcard $(BUILD)/*.d) $(wildcard $(BUILD)/tests/*.d)
