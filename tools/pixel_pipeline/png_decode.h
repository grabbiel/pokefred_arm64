#ifndef PP_PNG_DECODE_H
#define PP_PNG_DECODE_H

#include <stddef.h>
#include <stdint.h>

/* Decoded image. rgba is 128-byte aligned, tightly packed RGBA8, row-major.
 * When indexed is non-zero, plte holds plte_count RGB triples (up to 256) and
 * trns holds one alpha byte per palette entry (255 if the file has no tRNS). */
typedef struct pp_image {
    int width;
    int height;
    uint8_t *rgba;
    int indexed;
    int plte_count;
    int has_trns;
    uint8_t *plte;
    uint8_t *trns;
} pp_image;

int pp_png_decode_file(const char *path, pp_image *out);
void pp_image_free(pp_image *img);
const char *pp_png_last_error(void);

#endif
