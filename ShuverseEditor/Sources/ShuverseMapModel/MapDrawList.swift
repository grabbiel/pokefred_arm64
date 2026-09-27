import Foundation

public enum MapGeometry {
    public static let tileInset: Float = 0.06
    public static let selectionThickness: Float = 0.07

    public static func tileRect(x: Int, y: Int) -> (x0: Float, y0: Float, x1: Float, y1: Float) {
        let fx = Float(x)
        let fy = Float(y)
        return (fx + tileInset, fy + tileInset, fx + 1 - tileInset, fy + 1 - tileInset)
    }
}

/// Depth values written by the canvas. Smaller is closer (`MTLCompareFunction.less`).
/// Sprite and canopy slots are reserved so later draws can sort against the
/// same depth-stencil state without a new attachment.
public enum MapDepth {
    public static let clear: Float = 1
    /// Metatile quads.
    public static let ground: Float = 0.70
    /// Reserved for NPC / player sprites, in front of the ground.
    public static let sprite: Float = 0.55
    /// Reserved for canopy (tree tops), in front of sprites.
    public static let canopy: Float = 0.40
    /// Event markers. In front of canopy so editor chrome stays visible.
    public static let marker: Float = 0.28
    /// Selection outline. Closest layer drawn in v1.
    public static let selection: Float = 0.15
}

/// One cell of the shared GPU grid. Low 16 bits are `MapCell.raw`
/// (attribute in bits 10–15, metatile id in bits 0–9).
public enum MapGridPack {
    public static func word(for cell: MapCell) -> UInt32 {
        UInt32(cell.raw)
    }

    public static func metatileId(in word: UInt32) -> UInt16 {
        UInt16(word & 0x3FF)
    }

    public static func mapAttribute(in word: UInt32) -> UInt8 {
        UInt8((word >> 10) & 0x3F)
    }
}

/// Row-major metatile id/attribute grid. The GPU instances one quad per word
/// and samples this buffer; the CPU does not expand each cell into 6 vertices.
public struct MapMetatileGrid: Equatable {
    public var width: Int
    public var height: Int
    public var words: [UInt32]

    public init(width: Int, height: Int, words: [UInt32]) {
        self.width = width
        self.height = height
        self.words = words
    }

    public var cellCount: Int { words.count }

    public static func make(map: MapDocument) -> MapMetatileGrid {
        let width = map.size.width
        let height = map.size.height
        let count = width * height
        var words = [UInt32](repeating: 0, count: count)
        let limit = min(count, map.cells.count)
        for index in 0..<limit {
            words[index] = MapGridPack.word(for: map.cells[index])
        }
        return MapMetatileGrid(width: width, height: height, words: words)
    }
}

/// One instanced quad (marker or selection edge) in metatile space.
/// 12 floats, 48 bytes: center, half-extent, RGBA, depth, then 3 pads so the
/// stride matches the sprite vertex descriptor (`float2/float2/float4/float`).
public struct MapQuadInstance: Equatable {
    public var centerX: Float
    public var centerY: Float
    public var halfX: Float
    public var halfY: Float
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
    public var depth: Float
    public var pad0: Float
    public var pad1: Float
    public var pad2: Float

    public init(
        centerX: Float,
        centerY: Float,
        halfX: Float,
        halfY: Float,
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float,
        depth: Float
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.halfX = halfX
        self.halfY = halfY
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.depth = depth
        self.pad0 = 0
        self.pad1 = 0
        self.pad2 = 0
    }
}

public enum MapDrawListBuilder {
    /// Packed id/attribute words. Selection is not baked in; it is a separate
    /// quad list (or a later tile-shader overlay) so picking a cell does not
    /// rebuild the grid.
    public static func grid(for map: MapDocument) -> MapMetatileGrid {
        MapMetatileGrid.make(map: map)
    }

    public static func markers(on map: MapDocument) -> [MapQuadInstance] {
        var kindsByCell: [Int: [MarkerKind]] = [:]
        func add(_ kind: MarkerKind, x: Int, y: Int) {
            guard let index = map.cellIndex(x: x, y: y) else { return }
            kindsByCell[index, default: []].append(kind)
        }
        for event in map.objectEvents { add(.object, x: event.x, y: event.y) }
        for event in map.warpEvents { add(.warp, x: event.x, y: event.y) }
        for event in map.coordEvents { add(.coord, x: event.x, y: event.y) }
        for event in map.bgEvents { add(.bg, x: event.x, y: event.y) }

        var instances: [MapQuadInstance] = []
        instances.reserveCapacity(kindsByCell.count)
        for (index, kinds) in kindsByCell.sorted(by: { $0.key < $1.key }) {
            let x = index % map.size.width
            let y = index / map.size.width
            let slots = markerSlots(count: kinds.count)
            let half: Float = kinds.count == 1 ? 0.12 : 0.08
            for (kind, slot) in zip(kinds, slots) {
                let color = kind.color
                instances.append(
                    MapQuadInstance(
                        centerX: Float(x) + slot.0,
                        centerY: Float(y) + slot.1,
                        halfX: half,
                        halfY: half,
                        red: color.r,
                        green: color.g,
                        blue: color.b,
                        alpha: color.a,
                        depth: MapDepth.marker
                    )
                )
            }
        }
        return instances
    }

    /// Four outline quads. Empty when the cell is outside the map.
    /// Changing this list does not touch `MapMetatileGrid`.
    public static func selection(x: Int, y: Int, on map: MapDocument) -> [MapQuadInstance] {
        guard map.contains(x: x, y: y) else { return [] }
        let x0 = Float(x)
        let y0 = Float(y)
        let x1 = x0 + 1
        let y1 = y0 + 1
        let thickness = MapGeometry.selectionThickness
        return [
            rect(x0, y0, x1, y0 + thickness),
            rect(x0, y1 - thickness, x1, y1),
            rect(x0, y0 + thickness, x0 + thickness, y1 - thickness),
            rect(x1 - thickness, y0 + thickness, x1, y1 - thickness),
        ]
    }

    private static func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> MapQuadInstance {
        MapQuadInstance(
            centerX: (x0 + x1) * 0.5,
            centerY: (y0 + y1) * 0.5,
            halfX: (x1 - x0) * 0.5,
            halfY: (y1 - y0) * 0.5,
            red: 1,
            green: 0.86,
            blue: 0.25,
            alpha: 1,
            depth: MapDepth.selection
        )
    }

    private static func markerSlots(count: Int) -> [(Float, Float)] {
        if count <= 1 { return [(0.5, 0.5)] }
        return [(0.30, 0.30), (0.70, 0.30), (0.30, 0.70), (0.70, 0.70)]
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
