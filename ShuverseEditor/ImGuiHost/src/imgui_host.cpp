#include "imgui_host.h"

#define IMGUI_DEFINE_MATH_OPERATORS
#include "imgui.h"
#include "imgui_internal.h"

#include <cstring>

static_assert(sizeof(ImDrawVert) == IG_HOST_VERTEX_STRIDE, "ImDrawVert must stay 20 bytes");
static_assert(sizeof(ImDrawIdx) == IG_HOST_INDEX_STRIDE, "ImDrawIdx must stay 16-bit");

namespace {

struct ButtonEvent {
    int button;
    int down;
};

constexpr int kQueueCap = 64;

bool ready = false;
ButtonEvent button_queue[kQueueCap];
int button_count = 0;
float wheel_x = 0;
float wheel_y = 0;

void apply_style()
{
    ImGui::StyleColorsDark();
    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowRounding = 0.0f;
    style.ChildRounding = 0.0f;
    style.FrameRounding = 2.0f;
    style.WindowBorderSize = 1.0f;
    style.Colors[ImGuiCol_WindowBg] = ImVec4(0.12f, 0.125f, 0.15f, 1.0f);
    style.Colors[ImGuiCol_ChildBg] = ImVec4(0.12f, 0.125f, 0.15f, 1.0f);
    style.Colors[ImGuiCol_TitleBg] = ImVec4(0.10f, 0.11f, 0.13f, 1.0f);
    style.Colors[ImGuiCol_TitleBgActive] = ImVec4(0.16f, 0.18f, 0.22f, 1.0f);
    style.Colors[ImGuiCol_TitleBgCollapsed] = ImVec4(0.10f, 0.11f, 0.13f, 1.0f);
    style.Colors[ImGuiCol_Header] = ImVec4(0.22f, 0.28f, 0.36f, 1.0f);
    style.Colors[ImGuiCol_HeaderHovered] = ImVec4(0.28f, 0.36f, 0.46f, 1.0f);
    style.Colors[ImGuiCol_HeaderActive] = ImVec4(0.32f, 0.42f, 0.54f, 1.0f);
    style.Colors[ImGuiCol_DockingEmptyBg] = ImVec4(0.0f, 0.0f, 0.0f, 0.0f);
    style.Colors[ImGuiCol_FrameBg] = ImVec4(0.16f, 0.17f, 0.20f, 1.0f);
}

} // namespace

extern "C" {

void ig_host_init(void)
{
    if (ready) {
        return;
    }
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    io.IniFilename = nullptr;
    io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset | ImGuiBackendFlags_HasMouseCursors;
    io.BackendPlatformName = "Shuverse AppKit";
    io.BackendRendererName = "Shuverse Metal";
    apply_style();
    button_count = 0;
    wheel_x = 0;
    wheel_y = 0;
    ready = true;
}

void ig_host_shutdown(void)
{
    if (!ready) {
        return;
    }
    ImGui::DestroyContext();
    ready = false;
    button_count = 0;
}

const char *ig_host_version(void)
{
    return IMGUI_VERSION;
}

void ig_host_mouse_button(int button, int down)
{
    if (button < 0 || button > 2 || button_count >= kQueueCap) {
        return;
    }
    button_queue[button_count].button = button;
    button_queue[button_count].down = down ? 1 : 0;
    button_count += 1;
}

void ig_host_add_wheel(float dx, float dy)
{
    wheel_x += dx;
    wheel_y += dy;
}

void ig_host_new_frame(
    float width,
    float height,
    float scale_x,
    float scale_y,
    float dt_seconds,
    float mouse_x,
    float mouse_y)
{
    ig_host_init();
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(width > 0.0f ? width : 1.0f, height > 0.0f ? height : 1.0f);
    io.DisplayFramebufferScale = ImVec2(scale_x > 0.0f ? scale_x : 1.0f, scale_y > 0.0f ? scale_y : 1.0f);
    io.DeltaTime = dt_seconds > 0.0f ? dt_seconds : (1.0f / 60.0f);
    io.AddMousePosEvent(mouse_x, mouse_y);
    for (int i = 0; i < button_count; ++i) {
        io.AddMouseButtonEvent(button_queue[i].button, button_queue[i].down != 0);
    }
    button_count = 0;
    if (wheel_x != 0.0f || wheel_y != 0.0f) {
        io.AddMouseWheelEvent(wheel_x, wheel_y);
        wheel_x = 0.0f;
        wheel_y = 0.0f;
    }
    ImGui::NewFrame();
}

void ig_host_dockspace(void)
{
    const ImGuiID id = ImHashStr("ShuverseDockSpace");
    ImGuiViewport *viewport = ImGui::GetMainViewport();
    if (ImGui::DockBuilderGetNode(id) == nullptr) {
        ImGui::DockBuilderAddNode(id, ImGuiDockNodeFlags_DockSpace | ImGuiDockNodeFlags_PassthruCentralNode);
        ImGui::DockBuilderSetNodePos(id, viewport->WorkPos);
        ImGui::DockBuilderSetNodeSize(id, viewport->WorkSize);
        ImGuiID left = 0;
        ImGuiID center = 0;
        ImGuiID right = 0;
        ImGuiID bottom = 0;
        ImGuiID status = 0;
        ImGuiID tileset = 0;
        ImGuiID inspector = 0;
        ImGuiID events = 0;
        ImGui::DockBuilderSplitNode(id, ImGuiDir_Left, 0.22f, &left, &center);
        ImGui::DockBuilderSplitNode(center, ImGuiDir_Right, 0.34f, &right, &center);
        ImGui::DockBuilderSplitNode(center, ImGuiDir_Down, 0.28f, &bottom, &center);
        ImGui::DockBuilderSplitNode(bottom, ImGuiDir_Right, 0.46f, &tileset, &status);
        ImGui::DockBuilderSplitNode(right, ImGuiDir_Down, 0.46f, &events, &inspector);
        ImGui::DockBuilderDockWindow("Map List", left);
        ImGui::DockBuilderDockWindow("Inspector", inspector);
        ImGui::DockBuilderDockWindow("Events", events);
        ImGui::DockBuilderDockWindow("Status", status);
        ImGui::DockBuilderDockWindow("Tileset", tileset);
        ImGui::DockBuilderFinish(id);
    }
    ImGui::DockSpaceOverViewport(id, viewport, ImGuiDockNodeFlags_PassthruCentralNode);
}

int ig_host_begin(const char *name)
{
    return ImGui::Begin(name != nullptr ? name : "", nullptr, ImGuiWindowFlags_NoCollapse) ? 1 : 0;
}

void ig_host_end(void)
{
    ImGui::End();
}

int ig_host_begin_child(const char *name)
{
    return ImGui::BeginChild(name != nullptr ? name : "child", ImVec2(0, 0), ImGuiChildFlags_None, ImGuiWindowFlags_None) ? 1 : 0;
}

void ig_host_end_child(void)
{
    ImGui::EndChild();
}

void ig_host_text(const char *text)
{
    if (text == nullptr) {
        return;
    }
    ImGui::TextUnformatted(text);
}

void ig_host_separator(void)
{
    ImGui::Separator();
}

void ig_host_same_line(void)
{
    ImGui::SameLine();
}

int ig_host_button(const char *label)
{
    const float width = ImGui::GetContentRegionAvail().x;
    return ImGui::Button(label != nullptr ? label : "", ImVec2(width, 0)) ? 1 : 0;
}

int ig_host_selectable(const char *label, int selected)
{
    return ImGui::Selectable(label != nullptr ? label : "", selected != 0) ? 1 : 0;
}

void ig_host_swatch(int ident, float w, float h)
{
    ImGui::PushID(ident);
    ImGui::BeginDisabled(true);
    ImGui::ColorButton(
        "swatch",
        ImVec4(0.16f, 0.18f, 0.22f, 1.0f),
        ImGuiColorEditFlags_NoTooltip | ImGuiColorEditFlags_NoBorder,
        ImVec2(w, h));
    ImGui::EndDisabled();
    ImGui::PopID();
}

float ig_host_content_width(void)
{
    return ImGui::GetContentRegionAvail().x;
}

void ig_host_push_swatch_style(void)
{
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(1.0f, 1.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(2.0f, 2.0f));
}

void ig_host_pop_swatch_style(void)
{
    ImGui::PopStyleVar(2);
}

int ig_host_image_button(
    int ident,
    unsigned long long tex_id,
    float u0,
    float v0,
    float u1,
    float v1,
    float w,
    float h,
    int selected)
{
    if (tex_id == 0 || w <= 0.0f || h <= 0.0f) {
        return 0;
    }
    ImGui::PushID(ident);
    if (selected) {
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.36f, 0.52f, 0.78f, 1.0f));
    }
    const bool clicked = ImGui::ImageButton(
        "swatch",
        (ImTextureID)tex_id,
        ImVec2(w, h),
        ImVec2(u0, v0),
        ImVec2(u1, v1),
        ImVec4(0.08f, 0.09f, 0.11f, 1.0f));
    if (selected) {
        ImGui::PopStyleColor();
    }
    ImGui::PopID();
    return clicked ? 1 : 0;
}

void ig_host_render(void)
{
    ImGui::Render();
}

int ig_host_hit(float x, float y)
{
    if (!ready || ImGui::GetCurrentContext() == nullptr) {
        return 0;
    }
    ImGuiContext &g = *GImGui;
    if (g.Windows.Size == 0) {
        return 0;
    }
    const ImVec2 pos(x, y);
    const ImVec2 padding_regular = g.Style.TouchExtraPadding;
    const ImVec2 padding_for_resize = ImMax(
        padding_regular,
        ImVec2(g.Style.WindowBorderHoverPadding, g.Style.WindowBorderHoverPadding));
    for (int i = g.Windows.Size - 1; i >= 0; --i) {
        ImGuiWindow *window = g.Windows[i];
        if (window == nullptr || !window->Active || window->Hidden) {
            continue;
        }
        if ((window->Flags & ImGuiWindowFlags_NoMouseInputs) != 0) {
            continue;
        }
        const ImVec2 hit_padding = (window->Flags & (ImGuiWindowFlags_NoResize | ImGuiWindowFlags_AlwaysAutoResize)) != 0
            ? padding_regular
            : padding_for_resize;
        if (!window->OuterRectClipped.ContainsWithPad(pos, hit_padding)) {
            continue;
        }
        if (window->HitTestHoleSize.x != 0) {
            const ImVec2 hole_pos(
                window->Pos.x + static_cast<float>(window->HitTestHoleOffset.x),
                window->Pos.y + static_cast<float>(window->HitTestHoleOffset.y));
            const ImVec2 hole_size(
                static_cast<float>(window->HitTestHoleSize.x),
                static_cast<float>(window->HitTestHoleSize.y));
            if (ImRect(hole_pos, hole_pos + hole_size).Contains(pos)) {
                continue;
            }
        }
        return 1;
    }
    return 0;
}

int ig_host_mouse_cursor(void)
{
    if (!ready || ImGui::GetCurrentContext() == nullptr) {
        return 0;
    }
    return static_cast<int>(ImGui::GetMouseCursor());
}

const unsigned char *ig_host_font_pixels(int *width, int *height)
{
    ig_host_init();
    unsigned char *pixels = nullptr;
    int w = 0;
    int h = 0;
    ImGui::GetIO().Fonts->GetTexDataAsRGBA32(&pixels, &w, &h);
    if (width != nullptr) {
        *width = w;
    }
    if (height != nullptr) {
        *height = h;
    }
    return pixels;
}

void ig_host_font_set_tex_id(unsigned long long tex_id)
{
    ig_host_init();
    ImGui::GetIO().Fonts->SetTexID(static_cast<ImTextureID>(tex_id));
}

void ig_host_draw_data(IgHostDrawData *out)
{
    if (out == nullptr) {
        return;
    }
    std::memset(out, 0, sizeof(*out));
    ImDrawData *draw = ImGui::GetDrawData();
    if (draw == nullptr || !draw->Valid) {
        return;
    }
    out->display_x = draw->DisplayPos.x;
    out->display_y = draw->DisplayPos.y;
    out->display_w = draw->DisplaySize.x;
    out->display_h = draw->DisplaySize.y;
    out->scale_x = draw->FramebufferScale.x;
    out->scale_y = draw->FramebufferScale.y;
    out->list_count = draw->CmdListsCount;
    out->total_vtx = draw->TotalVtxCount;
    out->total_idx = draw->TotalIdxCount;
    out->valid = 1;
}

void ig_host_draw_list(int index, IgHostDrawList *out)
{
    if (out == nullptr) {
        return;
    }
    std::memset(out, 0, sizeof(*out));
    ImDrawData *draw = ImGui::GetDrawData();
    if (draw == nullptr || index < 0 || index >= draw->CmdListsCount) {
        return;
    }
    const ImDrawList *list = draw->CmdLists[index];
    out->vertices = list->VtxBuffer.Data;
    out->vertex_count = list->VtxBuffer.Size;
    out->indices = list->IdxBuffer.Data;
    out->index_count = list->IdxBuffer.Size;
    out->command_count = list->CmdBuffer.Size;
}

void ig_host_draw_cmd(int list_index, int command_index, IgHostDrawCmd *out)
{
    if (out == nullptr) {
        return;
    }
    std::memset(out, 0, sizeof(*out));
    ImDrawData *draw = ImGui::GetDrawData();
    if (draw == nullptr || list_index < 0 || list_index >= draw->CmdListsCount) {
        return;
    }
    const ImDrawList *list = draw->CmdLists[list_index];
    if (command_index < 0 || command_index >= list->CmdBuffer.Size) {
        return;
    }
    const ImDrawCmd &cmd = list->CmdBuffer[command_index];
    out->clip_x = cmd.ClipRect.x;
    out->clip_y = cmd.ClipRect.y;
    out->clip_z = cmd.ClipRect.z;
    out->clip_w = cmd.ClipRect.w;
    out->tex_id = static_cast<unsigned long long>(cmd.GetTexID());
    out->elem_count = cmd.ElemCount;
    out->idx_offset = cmd.IdxOffset;
    out->vtx_offset = cmd.VtxOffset;
    out->is_callback = cmd.UserCallback != nullptr ? 1 : 0;
}

} // extern "C"
