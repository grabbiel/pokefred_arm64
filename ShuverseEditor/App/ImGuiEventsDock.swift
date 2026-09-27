import CImGuiHost
import Foundation
import ShuverseMapModel

/// Read-only Events window. Selection is reported to the host; this type does
/// not paint or store a tileset brush.
enum ImGuiEventsDock {
    struct Model {
        var mapName: String
        var rows: [MapEventRow]
        var selectedKey: String?

        static let empty = Model(mapName: "", rows: [], selectedKey: nil)
    }

    static var modelProvider: (() -> Model)?

    /// Returns the row key when the user clicks one. Call after the dockspace exists.
    static func build() -> String? {
        let model = modelProvider?() ?? .empty
        var picked: String?
        if ig_host_begin("Events") != 0 {
            text(model.mapName.isEmpty ? "No map" : model.mapName)
            if model.rows.isEmpty {
                text("No events on the active map.")
            } else {
                text(summary(model.rows))
                if let selected = model.rows.first(where: { $0.key == model.selectedKey }) {
                    ig_host_separator()
                    text(selected.detail)
                }
                ig_host_separator()
                if ig_host_begin_child("events-list") != 0 {
                    for row in model.rows {
                        let label = "\(row.title)##\(row.key)"
                        if selectable(label, selected: row.key == model.selectedKey) {
                            picked = row.key
                        }
                    }
                }
                ig_host_end_child()
            }
        }
        ig_host_end()
        return picked
    }

    private static func summary(_ rows: [MapEventRow]) -> String {
        func count(_ kind: String) -> Int {
            rows.filter { $0.kind == kind }.count
        }
        return "objects \(count("object"))   warps \(count("warp"))   triggers \(count("trigger"))   signs \(count("sign"))"
    }

    private static func text(_ value: String) {
        value.withCString { ig_host_text($0) }
    }

    private static func selectable(_ label: String, selected: Bool) -> Bool {
        label.withCString { ig_host_selectable($0, selected ? 1 : 0) != 0 }
    }
}
