#include "png_decode.h"

#include "aligned_alloc.h"

#include "stb_image.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char g_err[256];

const char *pp_png_last_error(void)
{
    return g_err;
}

static void set_err(const char *msg)
{
    snprintf(g_err, sizeof g_err, "%s", msg ? msg : "unknown error");
}

static uint32_t read_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int read_file(const char *path, uint8_t **out, size_t *out_len)
{
    FILE *f;
    long sz;
    uint8_t *buf;

    f = fopen(path, "rb");
    if (!f) {
        set_err("could not open PNG");
        return -1;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        set_err("could not read PNG");
        return -1;
    }
    sz = ftell(f);
    if (sz < 0 || (unsigned long)sz > 64ul * 1024ul * 1024ul) {
        fclose(f);
        set_err("PNG is empty or larger than 64MB");
        return -1;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        set_err("could not read PNG");
        return -1;
    }
    buf = (uint8_t *)malloc((size_t)sz + 1u);
    if (!buf) {
        fclose(f);
        set_err("out of memory");
        return -1;
    }
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        set_err("could not read PNG");
        return -1;
    }
    fclose(f);
    *out = buf;
    *out_len = (size_t)sz;
    return 0;
}

/* Recover PLTE/tRNS so an indexed tileset can keep palette index order.
 * Color type other than indexed is not an error. */
static int scan_palette(const uint8_t *data, size_t len, pp_image *img)
{
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    size_t off;
    int saw_ihdr = 0;
    int color_type = -1;
    int plte_count = 0;
    uint8_t *plte = NULL;
    uint8_t trns_tmp[256];
    int saw_trns = 0;
    size_t trns_len = 0;

    memset(trns_tmp, 255, sizeof trns_tmp);
    if (len < 8 || memcmp(data, sig, 8) != 0) {
        set_err("not a PNG");
        return -1;
    }
    off = 8;
    while (off + 8 <= len) {
        uint32_t clen;
        const uint8_t *type;
        const uint8_t *cdata;

        clen = read_be32(data + off);
        if (off + 12u + (size_t)clen > len) {
            free(plte);
            set_err("truncated PNG chunk");
            return -1;
        }
        type = data + off + 4;
        cdata = data + off + 8;
        if (memcmp(type, "IHDR", 4) == 0) {
            if (clen < 13) {
                free(plte);
                set_err("bad IHDR");
                return -1;
            }
            color_type = cdata[9];
            saw_ihdr = 1;
        } else if (memcmp(type, "PLTE", 4) == 0) {
            if ((clen % 3u) != 0 || clen / 3u > 256u) {
                free(plte);
                set_err("bad PLTE");
                return -1;
            }
            free(plte);
            plte_count = (int)(clen / 3u);
            plte = (uint8_t *)malloc((size_t)plte_count * 3u);
            if (!plte) {
                set_err("out of memory");
                return -1;
            }
            memcpy(plte, cdata, (size_t)plte_count * 3u);
        } else if (memcmp(type, "tRNS", 4) == 0) {
            if (clen > 256u) {
                free(plte);
                set_err("bad tRNS");
                return -1;
            }
            memcpy(trns_tmp, cdata, clen);
            trns_len = clen;
            saw_trns = 1;
        } else if (memcmp(type, "IEND", 4) == 0) {
            break;
        }
        off += 12u + (size_t)clen;
    }
    if (!saw_ihdr) {
        free(plte);
        set_err("PNG missing IHDR");
        return -1;
    }
    if (color_type != 3) {
        free(plte);
        img->indexed = 0;
        return 0;
    }
    if (!plte || plte_count <= 0) {
        free(plte);
        set_err("indexed PNG missing PLTE");
        return -1;
    }
    if (saw_trns && trns_len > (size_t)plte_count) {
        free(plte);
        set_err("tRNS longer than PLTE");
        return -1;
    }
    img->trns = (uint8_t *)malloc((size_t)plte_count);
    if (!img->trns) {
        free(plte);
        set_err("out of memory");
        return -1;
    }
    memcpy(img->trns, trns_tmp, (size_t)plte_count);
    img->plte = plte;
    img->plte_count = plte_count;
    img->indexed = 1;
    img->has_trns = saw_trns;
    return 0;
}

int pp_png_decode_file(const char *path, pp_image *out)
{
    uint8_t *file = NULL;
    size_t file_len = 0;
    int w = 0;
    int h = 0;
    int n = 0;
    unsigned char *px;
    size_t nbytes;
    uint8_t *aligned;

    if (!out) {
        set_err("missing output");
        return -1;
    }
    memset(out, 0, sizeof *out);
    g_err[0] = '\0';
    if (!path) {
        set_err("missing path");
        return -1;
    }
    if (read_file(path, &file, &file_len) != 0) {
        return -1;
    }
    if (scan_palette(file, file_len, out) != 0) {
        free(file);
        pp_image_free(out);
        return -1;
    }
    if (file_len > 0x7FFFFFFFu) {
        free(file);
        pp_image_free(out);
        set_err("PNG is too large");
        return -1;
    }
    px = stbi_load_from_memory(file, (int)file_len, &w, &h, &n, 4);
    free(file);
    if (!px) {
        pp_image_free(out);
        set_err(stbi_failure_reason() ? stbi_failure_reason() : "PNG decode failed");
        return -1;
    }
    if (w <= 0 || h <= 0 || (size_t)w > (SIZE_MAX / 4u) / (size_t)h) {
        stbi_image_free(px);
        pp_image_free(out);
        set_err("PNG dimensions are invalid");
        return -1;
    }
    nbytes = (size_t)w * (size_t)h * 4u;
    aligned = (uint8_t *)pp_aligned_alloc(nbytes);
    if (!aligned) {
        stbi_image_free(px);
        pp_image_free(out);
        set_err("out of memory");
        return -1;
    }
    memcpy(aligned, px, nbytes);
    stbi_image_free(px);
    out->width = w;
    out->height = h;
    out->rgba = aligned;
    return 0;
}

void pp_image_free(pp_image *img)
{
    if (!img) {
        return;
    }
    pp_aligned_free(img->rgba);
    free(img->plte);
    free(img->trns);
    memset(img, 0, sizeof *img);
}
