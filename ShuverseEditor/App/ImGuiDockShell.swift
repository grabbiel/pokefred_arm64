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
    var tilesetPrimary: String
    var tilesetSecondary: String

    static let empty = ImGuiDockModel(
        maps: [],
        inspector: "",
        status: "No map",
        rendererNote: "",
        tilesetPrimary: "",
        tilesetSecondary: ""
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
            text("Tileset palette")
            if model.tilesetPrimary.isEmpty && model.tilesetSecondary.isEmpty {
                text("No tileset on the active map.")
            } else {
                text("primary    \(model.tilesetPrimary)")
                text("secondary  \(model.tilesetSecondary)")
            }
            ig_host_separator()
            text("Placeholder grid")
            let columns = 8
            let count = 16
            for index in 0..<count {
                ig_host_swatch(Int32(index), 18, 18)
                if index % columns != columns - 1 {
                    ig_host_same_line()
                }
            }
            text("Pixel paint is not in this slice.")
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
}
