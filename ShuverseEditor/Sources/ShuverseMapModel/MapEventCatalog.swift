import Foundation

/// One row in the Events dock. `key` is stable for a map's current event arrays.
public struct MapEventRow: Equatable {
    public var key: String
    public var kind: String
    public var title: String
    public var detail: String
    public var x: Int
    public var y: Int

    public init(key: String, kind: String, title: String, detail: String, x: Int, y: Int) {
        self.key = key
        self.kind = kind
        self.title = title
        self.detail = detail
        self.x = x
        self.y = y
    }
}

/// Read-only list of objects, warps, triggers, and signs on one map.
public enum MapEventCatalog {
    public static func rows(for map: MapDocument) -> [MapEventRow] {
        var rows: [MapEventRow] = []
        rows.reserveCapacity(
            map.objectEvents.count + map.warpEvents.count + map.coordEvents.count + map.bgEvents.count
        )
        for (index, event) in map.objectEvents.enumerated() {
            rows.append(objectRow(index: index, event: event))
        }
        for (index, event) in map.warpEvents.enumerated() {
            rows.append(warpRow(index: index, event: event))
        }
        for (index, event) in map.coordEvents.enumerated() {
            rows.append(triggerRow(index: index, event: event))
        }
        for (index, event) in map.bgEvents.enumerated() {
            rows.append(bgRow(index: index, event: event))
        }
        return rows
    }

    public static func row(key: String, in map: MapDocument) -> MapEventRow? {
        rows(for: map).first { $0.key == key }
    }

    private static func objectRow(index: Int, event: ObjectEvent) -> MapEventRow {
        MapEventRow(
            key: "object:\(index)",
            kind: "object",
            title: "object \(event.localId)  (\(event.x), \(event.y))",
            detail: """
            object \(event.localId)
              (\(event.x), \(event.y))  elev \(event.elevation)
              \(event.graphicsId)
              \(event.movementType)
              script \(event.script)
              flag \(event.flag)
            """,
            x: event.x,
            y: event.y
        )
    }

    private static func warpRow(index: Int, event: WarpEvent) -> MapEventRow {
        MapEventRow(
            key: "warp:\(index)",
            kind: "warp",
            title: "warp → \(event.destMap) #\(event.destWarpId)  (\(event.x), \(event.y))",
            detail: """
            warp → \(event.destMap) #\(event.destWarpId)
              (\(event.x), \(event.y))  elevation \(event.elevation)
            """,
            x: event.x,
            y: event.y
        )
    }

    private static func triggerRow(index: Int, event: CoordEvent) -> MapEventRow {
        let kind = event.type.isEmpty ? "trigger" : event.type
        return MapEventRow(
            key: "trigger:\(index)",
            kind: kind,
            title: "\(kind) \(event.variable) == \(event.varValue)  (\(event.x), \(event.y))",
            detail: """
            \(kind) \(event.variable) == \(event.varValue)
              (\(event.x), \(event.y))  elev \(event.elevation)
              script \(event.script)
            """,
            x: event.x,
            y: event.y
        )
    }

    private static func bgRow(index: Int, event: BgEvent) -> MapEventRow {
        let kind = event.type.isEmpty ? "sign" : event.type
        return MapEventRow(
            key: "bg:\(index)",
            kind: kind,
            title: "\(kind) \(event.script)  (\(event.x), \(event.y))",
            detail: """
            \(kind) \(event.script)
              (\(event.x), \(event.y))  elev \(event.elevation)
              \(event.playerFacingDir)
            """,
            x: event.x,
            y: event.y
        )
    }
}
