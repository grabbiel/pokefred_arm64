import Foundation

/// Tightly packed `x, y, r, g, b, a` floats. The Metal shader reads this as
/// `packed_float2` + `packed_float4` (24 bytes, no padding).
public struct MeshVertex: Equatable {
    public var x: Float
    public var y: Float
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(x: Float, y: Float, r: Float, g: Float, b: Float, a: Float) {
        self.x = x
        self.y = y
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

public struct MapDrawList: Equatable {
    public var vertices: [MeshVertex]

    public init(vertices: [MeshVertex]) {
        self.vertices = vertices
    }
}

public enum MapGeometry {
    public static let tileInset: Float = 0.06
    public static let selectionThickness: Float = 0.07

    public static func tileRect(x: Int, y: Int) -> (x0: Float, y0: Float, x1: Float, y1: Float) {
        let fx = Float(x)
        let fy = Float(y)
        return (fx + tileInset, fy + tileInset, fx + 1 - tileInset, fy + 1 - tileInset)
    }
}

public enum MapDrawListBuilder {
    /// Cell quads colored by metatile id, then event markers, then a selection outline.
    public static func make(map: MapDocument, selectedX: Int?, selectedY: Int?) -> MapDrawList {
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity((map.cells.count + 32) * 6)

        for y in 0..<map.size.height {
            for x in 0..<map.size.width {
                let cell = map.cells[y * map.size.width + x]
                let color = MetatileColor.components(for: cell.metatileId)
                let rect = MapGeometry.tileRect(x: x, y: y)
                appendQuad(rect.x0, rect.y0, rect.x1, rect.y1, color: color, to: &vertices)
            }
        }

        appendMarkers(map: map, to: &vertices)

        if let selectedX, let selectedY, map.contains(x: selectedX, y: selectedY) {
            appendSelection(x: selectedX, y: selectedY, to: &vertices)
        }

        return MapDrawList(vertices: vertices)
    }

    private static func appendMarkers(map: MapDocument, to vertices: inout [MeshVertex]) {
        var kindsByCell: [Int: [MarkerKind]] = [:]
        func add(_ kind: MarkerKind, x: Int, y: Int) {
            guard let index = map.cellIndex(x: x, y: y) else { return }
            kindsByCell[index, default: []].append(kind)
        }
        for event in map.objectEvents { add(.object, x: event.x, y: event.y) }
        for event in map.warpEvents { add(.warp, x: event.x, y: event.y) }
        for event in map.coordEvents { add(.coord, x: event.x, y: event.y) }
        for event in map.bgEvents { add(.bg, x: event.x, y: event.y) }

        for (index, kinds) in kindsByCell.sorted(by: { $0.key < $1.key }) {
            let x = index % map.size.width
            let y = index / map.size.width
            let slots = markerSlots(count: kinds.count)
            for (kind, slot) in zip(kinds, slots) {
                let cx = Float(x) + slot.0
                let cy = Float(y) + slot.1
                let half: Float = kinds.count == 1 ? 0.12 : 0.08
                appendQuad(cx - half, cy - half, cx + half, cy + half, color: kind.color, to: &vertices)
            }
        }
    }

    private static func markerSlots(count: Int) -> [(Float, Float)] {
        if count <= 1 { return [(0.5, 0.5)] }
        return [(0.30, 0.30), (0.70, 0.30), (0.30, 0.70), (0.70, 0.70)]
    }

    private static func appendSelection(x: Int, y: Int, to vertices: inout [MeshVertex]) {
        let x0 = Float(x)
        let y0 = Float(y)
        let x1 = x0 + 1
        let y1 = y0 + 1
        let t = MapGeometry.selectionThickness
        let color: (r: Float, g: Float, b: Float, a: Float) = (1, 0.86, 0.25, 1)
        appendQuad(x0, y0, x1, y0 + t, color: color, to: &vertices)
        appendQuad(x0, y1 - t, x1, y1, color: color, to: &vertices)
        appendQuad(x0, y0 + t, x0 + t, y1 - t, color: color, to: &vertices)
        appendQuad(x1 - t, y0 + t, x1, y1 - t, color: color, to: &vertices)
    }

    private static func appendQuad(
        _ x0: Float,
        _ y0: Float,
        _ x1: Float,
        _ y1: Float,
        color: (r: Float, g: Float, b: Float, a: Float),
        to vertices: inout [MeshVertex]
    ) {
        let v00 = MeshVertex(x: x0, y: y0, r: color.r, g: color.g, b: color.b, a: color.a)
        let v10 = MeshVertex(x: x1, y: y0, r: color.r, g: color.g, b: color.b, a: color.a)
        let v11 = MeshVertex(x: x1, y: y1, r: color.r, g: color.g, b: color.b, a: color.a)
        let v01 = MeshVertex(x: x0, y: y1, r: color.r, g: color.g, b: color.b, a: color.a)
        vertices.append(contentsOf: [v00, v10, v11, v00, v11, v01])
    }
}

private enum MarkerKind {
    case object
    case warp
    case coord
    case bg

    var color: (r: Float, g: Float, b: Float, a: Float) {
        switch self {
        case .object: return (0.95, 0.95, 0.97, 1)
        case .warp: return (1, 0.82, 0.22, 1)
        case .coord: return (0.30, 0.86, 1, 1)
        case .bg: return (1, 0.46, 0.24, 1)
        }
    }
}
