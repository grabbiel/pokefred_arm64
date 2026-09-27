import CImGuiHost
import Foundation
import ShuverseMapModel

struct ImGuiDockModel {
    struct MapEntry {
        var id: String
        var title: String
        var active: Bool
    }

    var maps: [MapEntry]
    var inspector: String
    var status: String
    var rendererNote: String
    var mapKey: String
    var tilesetPrimary: String
    var tilesetSecondary: String
    var swatches: MetatileSwatchSheet?
    var swatchTexID: UInt64
    var swatchNote: String

    static let empty = ImGuiDockModel(
        maps: [],
        inspector: "",
        status: "No map",
        rendererNote: "",
        mapKey: "",
        tilesetPrimary: "",
        tilesetSecondary: "",
        swatches: nil,
        swatchTexID: 0,
        swatchNote: ""
    )
}

struct ImGuiShellAction {
    var focusMapId: String?
    var openSample = false
    var openJSON = false
}

/// Builds the four dock windows. The central node stays empty so the map
/// canvas shows through; `ig_host_hit` uses that hole for event routing.
enum ImGuiDockShell {
    private static var selectedMetatile = -1
    private static var selectedMapKey = ""

    static func build(_ model: ImGuiDockModel) -> ImGuiShellAction {
        var action = ImGuiShellAction()
        ig_host_dockspace()

        if ig_host_begin("Map List") != 0 {
            text("Workspace")
            if model.maps.isEmpty {
                text("No map loaded.")
            } else {
                for entry in model.maps {
                    if selectable(entry.title, selected: entry.active), !entry.active {
                        action.focusMapId = entry.id
                    }
                }
            }
            ig_host_separator()
            if button("Open Pallet Town Sample") {
                action.openSample = true
            }
            if button("Open Map JSON…") {
                action.openJSON = true
            }
        }
        ig_host_end()

        if ig_host_begin("Inspector") != 0 {
            if ig_host_begin_child("inspector-body") != 0 {
                text(model.inspector)
            }
            ig_host_end_child()
        }
        ig_host_end()

        if ig_host_begin("Status") != 0 {
            text(model.status.isEmpty ? "No map" : model.status)
            if model.rendererNote.isEmpty {
                text("Metal canvas ready")
            } else {
                text(model.rendererNote)
            }
            if let version = ig_host_version() {
                text("Dear ImGui \(String(cString: version)) docks")
            }
        }
        ig_host_end()

        if ig_host_begin("Tileset") != 0 {
            if model.mapKey != selectedMapKey {
                selectedMapKey = model.mapKey
                selectedMetatile = -1
            }
            text("Tileset")
            if model.tilesetPrimary.isEmpty && model.tilesetSecondary.isEmpty {
                text("No tileset on the active map.")
            } else {
                text("primary    \(model.tilesetPrimary)")
                text("secondary  \(model.tilesetSecondary)")
            }
            if let sheet = model.swatches, model.swatchTexID != 0 {
                text("\(sheet.count) metatiles from the 4bpp atlas")
                if selectedMetatile >= 0 {
                    text("metatile \(selectedMetatile)")
                }
                ig_host_separator()
                if ig_host_begin_child("tileset-swatches") != 0 {
                    drawSwatches(sheet, texID: model.swatchTexID)
                }
                ig_host_end_child()
            } else if !model.swatchNote.isEmpty {
                ig_host_separator()
                text(model.swatchNote)
            }
        }
        ig_host_end()

        return action
    }

    private static func text(_ value: String) {
        value.withCString { ig_host_text($0) }
    }

    private static func button(_ label: String) -> Bool {
        label.withCString { ig_host_button($0) != 0 }
    }

    private static func selectable(_ label: String, selected: Bool) -> Bool {
        label.withCString { ig_host_selectable($0, selected ? 1 : 0) != 0 }
    }

    private static func drawSwatches(_ sheet: MetatileSwatchSheet, texID: UInt64) {
        ig_host_push_swatch_style()
        let button: Float = 32
        let gap: Float = 2
        let columns = max(1, Int((ig_host_content_width() + gap) / (button + gap + 2)))
        for id in 0..<sheet.count {
            let uv = sheet.uv(for: id)
            let clicked = ig_host_image_button(
                Int32(id),
                texID,
                uv.u0,
                uv.v0,
                uv.u1,
                uv.v1,
                button,
                button,
                selectedMetatile == id ? 1 : 0
            ) != 0
            if clicked {
                selectedMetatile = id
            }
            if (id + 1) % columns != 0 {
                ig_host_same_line()
            }
        }
        ig_host_pop_swatch_style()
    }
}
