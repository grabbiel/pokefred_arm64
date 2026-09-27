import Foundation
import ShuverseMapModel

enum InspectorText {
    static func make(document: EditorDocument, selection: CellInspection?) -> String {
        guard let map = document.activeMap else {
            return """
            No map loaded.

            File → Open Map JSON…
            or drop a Map Parser JSON file on the window.

            The bundled sample is Pallet Town (24×20).
            """
        }

        var lines: [String] = []
        lines.append(map.name)
        lines.append(map.mapId)
        lines.append(map.layoutId)
        lines.append("")
        lines.append("\(map.size.width) × \(map.size.height) metatiles")
        lines.append("\(map.size.widthPx) × \(map.size.heightPx) px")
        if let unique = map.uniqueMetatileCount {
            lines.append("\(unique) unique metatiles")
        }
        if let encoding = map.blockEncoding {
            lines.append(encoding)
        }
        lines.append("")
        lines.append("Tilesets")
        lines.append("  primary    \(map.tilesets.primary)")
        lines.append("  secondary  \(map.tilesets.secondary)")
        lines.append("")
        lines.append("Music    \(map.music)")
        lines.append("Weather  \(map.weather)")
        lines.append("Type     \(map.mapType)")
        lines.append("")
        lines.append("Connections")
        if map.connections.isEmpty {
            lines.append("  (none)")
        } else {
            for connection in map.connections {
                lines.append("  \(connection.direction)  \(connection.map)  offset \(connection.offset)")
            }
        }
        lines.append("")
        lines.append("Events")
        lines.append("  objects \(map.objectEvents.count)   warps \(map.warpEvents.count)")
        lines.append("  triggers \(map.coordEvents.count)   bg \(map.bgEvents.count)")
        lines.append("")

        if let selection {
            let cell = selection.cell
            lines.append("Cell \(selection.x), \(selection.y)")
            lines.append("  metatile   \(cell.metatileId)")
            lines.append("  attribute  \(cell.mapAttribute)")
            lines.append(String(format: "  raw        0x%04X", cell.raw))
            lines.append("  index      \(selection.y * map.size.width + selection.x)")
            let eventLines = eventLines(selection)
            if eventLines.isEmpty {
                lines.append("  (no events on this cell)")
            } else {
                lines.append(contentsOf: eventLines)
            }
        } else {
            lines.append("Click a metatile to inspect it.")
        }

        lines.append("")
        lines.append("Markers")
        lines.append("  white   object")
        lines.append("  gold    warp")
        lines.append("  cyan    coord trigger")
        lines.append("  orange  bg / sign")
        lines.append("")
        if document.decompRoot.isEmpty {
            lines.append("decomp   (not set)")
        } else {
            lines.append("decomp   \(document.decompRoot)")
        }
        if document.maps.count > 1 {
            lines.append("open     \(document.maps.count) maps")
        }
        return lines.joined(separator: "\n")
    }

    private static func eventLines(_ selection: CellInspection) -> [String] {
        var lines: [String] = []
        for event in selection.objectEvents {
            lines.append("  object \(event.localId)")
            lines.append("    \(event.graphicsId)")
            lines.append("    \(event.movementType)  elev \(event.elevation)")
            lines.append("    script \(event.script)")
            lines.append("    flag \(event.flag)")
        }
        for event in selection.warpEvents {
            lines.append("  warp → \(event.destMap) #\(event.destWarpId)")
            lines.append("    elevation \(event.elevation)")
        }
        for event in selection.coordEvents {
            lines.append("  \(event.type) \(event.variable) == \(event.varValue)")
            lines.append("    script \(event.script)")
        }
        for event in selection.bgEvents {
            lines.append("  \(event.type) \(event.script)")
            lines.append("    \(event.playerFacingDir)")
        }
        return lines
    }
}
