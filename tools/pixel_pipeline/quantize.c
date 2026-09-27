#include "quantize.h"

#include "aligned_alloc.h"

#include <stdlib.h>
#include <string.h>

#define PP_QUANT_PRECAP 512

typedef struct color_entry {
    uint8_t r, g, b;
    uint8_t alive;
    uint32_t count;
    int32_t parent;
} color_entry;

typedef struct hash_ent {
    uint32_t key;
    int32_t idx;
    int used;
} hash_ent;

typedef struct quant_state {
    color_entry *colors;
    size_t count;
    size_t color_cap;
    hash_ent *ents;
    size_t cap;
    size_t used;
} quant_state;

void pp_indexed_free(pp_indexed *idx)
{
    if (!idx) {
        return;
    }
    pp_aligned_free(idx->indices);
    idx->indices = NULL;
}

static uint32_t pack_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16);
}

static size_t mix_key(uint32_t x)
{
    x *= 0x9E3779B1u;
    x ^= x >> 16;
    return (size_t)x;
}

static void qstate_free(quant_state *st)
{
    free(st->colors);
    free(st->ents);
    memset(st, 0, sizeof *st);
}

static int hmap_init(quant_state *st)
{
    size_t i;

    st->cap = 16;
    st->used = 0;
    st->ents = (hash_ent *)malloc(st->cap * sizeof(hash_ent));
    if (!st->ents) {
        return -1;
    }
    for (i = 0; i < st->cap; i++) {
        st->ents[i].used = 0;
    }
    return 0;
}

static int hmap_grow(quant_state *st)
{
    size_t ncap = st->cap << 1;
    size_t mask;
    size_t i;
    hash_ent *next;

    if (ncap < st->cap) {
        return -1;
    }
    next = (hash_ent *)malloc(ncap * sizeof(hash_ent));
    if (!next) {
        return -1;
    }
    for (i = 0; i < ncap; i++) {
        next[i].used = 0;
    }
    mask = ncap - 1u;
    for (i = 0; i < st->cap; i++) {
        size_t j;
        if (!st->ents[i].used) {
            continue;
        }
        j = mix_key(st->ents[i].key) & mask;
        while (next[j].used) {
            j = (j + 1u) & mask;
        }
        next[j] = st->ents[i];
    }
    free(st->ents);
    st->ents = next;
    st->cap = ncap;
    return 0;
}

static int ensure_color_cap(quant_state *st)
{
    size_t ncap;
    color_entry *next;

    if (st->count < st->color_cap) {
        return 0;
    }
    ncap = st->color_cap ? st->color_cap * 2u : 64u;
    next = (color_entry *)realloc(st->colors, ncap * sizeof(color_entry));
    if (!next) {
        return -1;
    }
    st->colors = next;
    st->color_cap = ncap;
    return 0;
}

/* Returns the color index, creating it when missing. -1 on OOM. */
static int hmap_touch(quant_state *st, uint8_t r, uint8_t g, uint8_t b)
{
    uint32_t key = pack_rgb(r, g, b);
    size_t mask;
    size_t i;

    if ((st->used + 1u) * 10u >= st->cap * 7u) {
        if (hmap_grow(st) != 0) {
            return -1;
        }
    }
    mask = st->cap - 1u;
    i = mix_key(key) & mask;
    for (;;) {
        if (!st->ents[i].used) {
            color_entry *c;
            if (ensure_color_cap(st) != 0) {
                return -1;
            }
            c = &st->colors[st->count];
            memset(c, 0, sizeof *c);
            c->r = r;
            c->g = g;
            c->b = b;
            c->alive = 1;
            c->count = 1;
            c->parent = (int32_t)st->count;
            st->ents[i].used = 1;
            st->ents[i].key = key;
            st->ents[i].idx = (int32_t)st->count;
            st->count++;
            st->used++;
            return st->ents[i].idx;
        }
        if (st->ents[i].key == key) {
            st->colors[st->ents[i].idx].count++;
            return st->ents[i].idx;
        }
        i = (i + 1u) & mask;
    }
}

static int hmap_find(const quant_state *st, uint8_t r, uint8_t g, uint8_t b)
{
    uint32_t key = pack_rgb(r, g, b);
    size_t mask = st->cap - 1u;
    size_t i = mix_key(key) & mask;

    for (;;) {
        if (!st->ents[i].used) {
            return -1;
        }
        if (st->ents[i].key == key) {
            return st->ents[i].idx;
        }
        i = (i + 1u) & mask;
    }
}

static int find_root(color_entry *colors, int idx)
{
    int root = idx;

    while (colors[root].parent != root) {
        root = colors[root].parent;
    }
    while (colors[idx].parent != root) {
        int next = colors[idx].parent;
        colors[idx].parent = root;
        idx = next;
    }
    return root;
}

static uint32_t dist2(const color_entry *a, const color_entry *b)
{
    int dr = (int)a->r - (int)b->r;
    int dg = (int)a->g - (int)b->g;
    int db = (int)a->b - (int)b->b;
    return (uint32_t)(dr * dr + dg * dg + db * db);
}

static int rgb_less_or_eq(const color_entry *a, const color_entry *b)
{
    if (a->r != b->r) {
        return a->r < b->r;
    }
    if (a->g != b->g) {
        return a->g < b->g;
    }
    return a->b <= b->b;
}

static void merge_colors(color_entry *colors, int keep, int drop)
{
    colors[keep].count += colors[drop].count;
    colors[drop].alive = 0;
    colors[drop].parent = keep;
}

typedef struct pop_item {
    uint32_t count;
    int index;
} pop_item;

static int cmp_pop(const void *va, const void *vb)
{
    const pop_item *a = (const pop_item *)va;
    const pop_item *b = (const pop_item *)vb;

    if (a->count > b->count) {
        return -1;
    }
    if (a->count < b->count) {
        return 1;
    }
    if (a->index < b->index) {
        return -1;
    }
    if (a->index > b->index) {
        return 1;
    }
    return 0;
}

static int reduce_popularity(quant_state *st)
{
    pop_item *order;
    size_t i;
    int keepers;

    if (st->count <= PP_QUANT_PRECAP) {
        return (int)st->count;
    }
    order = (pop_item *)malloc(st->count * sizeof(pop_item));
    if (!order) {
        return -1;
    }
    for (i = 0; i < st->count; i++) {
        order[i].count = st->colors[i].count;
        order[i].index = (int)i;
    }
    qsort(order, st->count, sizeof(pop_item), cmp_pop);
    keepers = PP_QUANT_PRECAP;
    for (i = (size_t)keepers; i < st->count; i++) {
        int drop = order[i].index;
        int best = -1;
        uint32_t best_d = UINT32_MAX;
        int k;

        for (k = 0; k < keepers; k++) {
            int ki = order[k].index;
            uint32_t d = dist2(&st->colors[drop], &st->colors[ki]);
            if (best < 0 || d < best_d || (d == best_d && ki < best)) {
                best_d = d;
                best = ki;
            }
        }
        merge_colors(st->colors, best, drop);
    }
    free(order);
    return keepers;
}

static int pair_merge(quant_state *st, int alive, int target)
{
    while (alive > target) {
        int best_i = -1;
        int best_j = -1;
        uint32_t best_d = UINT32_MAX;
        size_t i;

        for (i = 0; i < st->count; i++) {
            size_t j;
            if (!st->colors[i].alive) {
                continue;
            }
            for (j = i + 1u; j < st->count; j++) {
                uint32_t d;
                if (!st->colors[j].alive) {
                    continue;
                }
                d = dist2(&st->colors[i], &st->colors[j]);
                if (d < best_d) {
                    best_d = d;
                    best_i = (int)i;
                    best_j = (int)j;
                }
            }
        }
        if (best_i < 0) {
            break;
        }
        if (st->colors[best_i].count > st->colors[best_j].count) {
            merge_colors(st->colors, best_i, best_j);
        } else if (st->colors[best_j].count > st->colors[best_i].count) {
            merge_colors(st->colors, best_j, best_i);
        } else if (rgb_less_or_eq(&st->colors[best_i], &st->colors[best_j])) {
            merge_colors(st->colors, best_i, best_j);
        } else {
            merge_colors(st->colors, best_j, best_i);
        }
        alive--;
    }
    return alive;
}

static int quantize_general(const pp_image *img, pp_indexed *out)
{
    quant_state st;
    size_t npix;
    size_t p;
    int has_transparent = 0;
    uint8_t tr = 0;
    uint8_t tg = 0;
    uint8_t tb = 0;
    int alive;
    int target;
    int slot;
    int *slot_of = NULL;
    int rc = -1;

    memset(&st, 0, sizeof st);
    if (hmap_init(&st) != 0) {
        return -1;
    }
    npix = (size_t)img->width * (size_t)img->height;
    for (p = 0; p < npix; p++) {
        const uint8_t *px = img->rgba + p * 4u;
        if (px[3] == 0) {
            if (!has_transparent) {
                tr = px[0];
                tg = px[1];
                tb = px[2];
                has_transparent = 1;
            }
            continue;
        }
        if (hmap_touch(&st, px[0], px[1], px[2]) < 0) {
            qstate_free(&st);
            return -1;
        }
    }
    alive = reduce_popularity(&st);
    if (alive < 0) {
        qstate_free(&st);
        return -1;
    }
    target = has_transparent ? 15 : 16;
    pair_merge(&st, alive, target);

    slot_of = (int *)malloc((st.count ? st.count : 1u) * sizeof(int));
    if (!slot_of) {
        qstate_free(&st);
        return -1;
    }
    for (p = 0; p < st.count; p++) {
        slot_of[p] = -1;
    }
    slot = 0;
    if (has_transparent) {
        out->rgb[0][0] = tr;
        out->rgb[0][1] = tg;
        out->rgb[0][2] = tb;
        slot = 1;
    }
    for (p = 0; p < st.count; p++) {
        if (!st.colors[p].alive) {
            continue;
        }
        if (slot >= 16) {
            goto done;
        }
        slot_of[p] = slot;
        out->rgb[slot][0] = st.colors[p].r;
        out->rgb[slot][1] = st.colors[p].g;
        out->rgb[slot][2] = st.colors[p].b;
        slot++;
    }
    out->color_count = slot;

    for (p = 0; p < npix; p++) {
        const uint8_t *px = img->rgba + p * 4u;
        int ci;
        int root;
        int pal;

        if (px[3] == 0) {
            out->indices[p] = 0;
            continue;
        }
        ci = hmap_find(&st, px[0], px[1], px[2]);
        if (ci < 0) {
            goto done;
        }
        root = find_root(st.colors, ci);
        pal = slot_of[root];
        if (pal < 0 || pal > 15) {
            goto done;
        }
        out->indices[p] = (uint8_t)pal;
    }
    rc = 0;
done:
    free(slot_of);
    qstate_free(&st);
    return rc;
}

static uint32_t plte_key(const pp_image *img, int i)
{
    uint8_t a = 255;
    const uint8_t *c = img->plte + (size_t)i * 3u;

    if (img->has_trns) {
        a = img->trns[i];
    }
    return (uint32_t)c[0] | ((uint32_t)c[1] << 8) | ((uint32_t)c[2] << 16) | ((uint32_t)a << 24);
}

/* 1 = applied, 0 = not applicable, -1 = hard failure (none today). */
static int try_exact_indexed(const pp_image *img, pp_indexed *out)
{
    uint32_t keys[16];
    uint8_t remap[16];
    int i;
    int trans = 0;
    int slot;
    int wrote0;
    size_t npix;
    size_t p;

    if (!img->indexed || img->plte_count < 1 || img->plte_count > 16 || !img->plte) {
        return 0;
    }
    if (img->has_trns && !img->trns) {
        return 0;
    }
    for (i = 0; i < img->plte_count; i++) {
        int j;
        keys[i] = plte_key(img, i);
        for (j = 0; j < i; j++) {
            if (keys[j] == keys[i]) {
                return 0;
            }
        }
    }
    for (i = 0; i < img->plte_count; i++) {
        uint8_t a = img->has_trns ? img->trns[i] : 255;
        if (a == 0) {
            trans++;
        }
    }
    if (trans == 0) {
        for (i = 0; i < img->plte_count; i++) {
            remap[i] = (uint8_t)i;
        }
        out->color_count = img->plte_count;
    } else {
        slot = 1;
        for (i = 0; i < img->plte_count; i++) {
            uint8_t a = img->has_trns ? img->trns[i] : 255;
            if (a == 0) {
                remap[i] = 0;
            } else {
                remap[i] = (uint8_t)slot++;
            }
        }
        out->color_count = slot;
    }

    npix = (size_t)img->width * (size_t)img->height;
    for (p = 0; p < npix; p++) {
        const uint8_t *px = img->rgba + p * 4u;
        uint32_t key = (uint32_t)px[0] | ((uint32_t)px[1] << 8) | ((uint32_t)px[2] << 16) | ((uint32_t)px[3] << 24);
        int found = -1;

        for (i = 0; i < img->plte_count; i++) {
            if (keys[i] == key) {
                found = i;
                break;
            }
        }
        if (found < 0) {
            return 0;
        }
        out->indices[p] = remap[found];
    }

    wrote0 = 0;
    for (i = 0; i < img->plte_count; i++) {
        int dst = remap[i];
        const uint8_t *c = img->plte + (size_t)i * 3u;
        if (dst == 0) {
            if (wrote0) {
                continue;
            }
            wrote0 = 1;
        }
        out->rgb[dst][0] = c[0];
        out->rgb[dst][1] = c[1];
        out->rgb[dst][2] = c[2];
    }
    return 1;
}

int pp_quantize(const pp_image *img, pp_indexed *out)
{
    size_t npix;
    uint8_t *indices;
    int exact;

    if (!img || !out || !img->rgba || img->width <= 0 || img->height <= 0) {
        return -1;
    }
    if ((size_t)img->width > SIZE_MAX / (size_t)img->height) {
        return -1;
    }
    npix = (size_t)img->width * (size_t)img->height;
    indices = (uint8_t *)pp_aligned_alloc(npix);
    if (!indices) {
        return -1;
    }
    memset(out, 0, sizeof *out);
    out->width = img->width;
    out->height = img->height;
    out->indices = indices;

    exact = try_exact_indexed(img, out);
    if (exact == 1) {
        return 0;
    }
    memset(out->rgb, 0, sizeof out->rgb);
    out->color_count = 0;
    if (quantize_general(img, out) != 0) {
        pp_aligned_free(out->indices);
        memset(out, 0, sizeof *out);
        return -1;
    }
    return 0;
}
