#ifndef SHUVERSE_IMGUI_HOST_H
#define SHUVERSE_IMGUI_HOST_H

/* C API over Dear ImGui (docking). The macOS app links this and draws the
 * resulting meshes with its own Metal pass. Keep this header C-only. */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IgHostDrawData {
    float display_x;
    float display_y;
    float display_w;
    float display_h;
    float scale_x;
    float scale_y;
    int list_count;
    int total_vtx;
    int total_idx;
    int valid;
} IgHostDrawData;

typedef struct IgHostDrawList {
    const void *vertices;
    int vertex_count;
    const void *indices;
    int index_count;
    int command_count;
} IgHostDrawList;

typedef struct IgHostDrawCmd {
    float clip_x;
    float clip_y;
    float clip_z;
    float clip_w;
    unsigned long long tex_id;
    unsigned int elem_count;
    unsigned int idx_offset;
    unsigned int vtx_offset;
    int is_callback;
} IgHostDrawCmd;

enum {
    IG_HOST_VERTEX_STRIDE = 20,
    IG_HOST_INDEX_STRIDE = 2
};

void ig_host_init(void);
void ig_host_shutdown(void);
const char *ig_host_version(void);

/* Button edges are queued and applied on the next ig_host_new_frame.
 * button: 0 left, 1 right, 2 middle. down: 0 or 1. */
void ig_host_mouse_button(int button, int down);
void ig_host_add_wheel(float dx, float dy);

void ig_host_new_frame(
    float width,
    float height,
    float scale_x,
    float scale_y,
    float dt_seconds,
    float mouse_x,
    float mouse_y
);

/* Passthrough central dockspace plus the default Map List / Inspector /
 * Status / Tileset split. Call once per frame after ig_host_new_frame. */
void ig_host_dockspace(void);

int ig_host_begin(const char *name);
void ig_host_end(void);
int ig_host_begin_child(const char *name);
void ig_host_end_child(void);
void ig_host_text(const char *text);
void ig_host_separator(void);
void ig_host_same_line(void);
int ig_host_button(const char *label);
int ig_host_selectable(const char *label, int selected);
void ig_host_swatch(int ident, float w, float h);
float ig_host_content_width(void);
void ig_host_push_swatch_style(void);
void ig_host_pop_swatch_style(void);
/* Clickable image. uv is the texture rect. selected draws a highlight. */
int ig_host_image_button(
    int ident,
    unsigned long long tex_id,
    float u0,
    float v0,
    float u1,
    float v1,
    float w,
    float h,
    int selected
);
void ig_host_render(void);

/* 1 when the point (top-left origin, points) lies on a dock, tab, or
 * splitter. The empty central node is a hole and returns 0. */
int ig_host_hit(float x, float y);
int ig_host_mouse_cursor(void);

const unsigned char *ig_host_font_pixels(int *width, int *height);
void ig_host_font_set_tex_id(unsigned long long tex_id);

void ig_host_draw_data(IgHostDrawData *out);
void ig_host_draw_list(int index, IgHostDrawList *out);
void ig_host_draw_cmd(int list_index, int command_index, IgHostDrawCmd *out);

#ifdef __cplusplus
}
#endif

#endif
