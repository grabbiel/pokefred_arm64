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
/// Canopy and the sprite stub are submitted before ground in the same pass.
/// The depth test is what keeps them in front of the later ground quads.
public enum MapDepth {
    public static let clear: Float = 1
    /// Metatile quads. Both GBA layers, composited.
    public static let ground: Float = 0.70
    /// Pallet Town object stub, in front of the ground and behind canopy.
    public static let sprite: Float = 0.55
    /// Tree-top leaves, in front of the sprite stub.
    public static let canopy: Float = 0.40
    /// Event markers. In front of canopy so editor chrome stays visible.
    public static let marker: Float = 0.28
    /// Selection outline. Closest layer drawn in v1.
    public static let selection: Float = 0.15
}

/// pret general-tileset tree tops (`METATILE_General_ThinTreeTop_*` and
/// `METATILE_General_WideTreeTop_*`). These are metatile ids, not Pallet Town
/// cell coordinates. `canopy(on:)` matches them on any map. The top 2×2 is the
/// overhanging leaves. The bottom 2×2 stays in the ground pass.
public enum GeneralTilesetTreeTops {
    public static let treeTopMetatileIds: Set<UInt16> = [
        0x00A, // ThinTreeTop_Grass
        0x00B, // WideTreeTopLeft_Grass
        0x00C, // WideTreeTopRight_Grass
        0x00E, // WideTreeTopLeft_Mowed
        0x00F, // WideTreeTopRight_Mowed
        0x013, // ThinTreeTop_Mowed
    ]
}

/// Pallet Town sample anchors for the red depth-sprite stub.
/// Valid only when `mapId` is `MAP_PALLET_TOWN`. Not coordinates for other maps.
private enum PalletTownDepthSpriteSample {
    static let mapId = "MAP_PALLET_TOWN"
    /// South-west `METATILE_General_WideTreeTopLeft_Mowed` on the sample map.
    static let underCanopyX = 2
    static let underCanopyY = 19
    /// Town ground below Oak's lab, not a tree top.
    static let openGroundX = 8
    static let openGroundY = 15
}

/// One canopy quad. `cellIndex` selects a word in `MapMetatileGrid`.
/// 8 bytes: uint cell index, float depth. Matches the canopy vertex descriptor.
public struct MapCanopyInstance: Equatable {
    public var cellIndex: UInt32
    public var depth: Float

    public init(cellIndex: Int, depth: Float = MapDepth.canopy) {
        self.cellIndex = UInt32(cellIndex)
        self.depth = depth
    }
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

    /// Cells whose metatile id is in `GeneralTilesetTreeTops`. Matched on any
    /// map; this is not a Pallet Town layout. The GPU draws only that metatile's
    /// top layer, at `MapDepth.canopy`. Ground is not rebuilt.
    public static func canopy(on map: MapDocument) -> [MapCanopyInstance] {
        let count = min(map.cells.count, map.size.cellCount)
        var instances: [MapCanopyInstance] = []
        for index in 0..<count {
            guard GeneralTilesetTreeTops.treeTopMetatileIds.contains(map.cells[index].metatileId) else { continue }
            instances.append(MapCanopyInstance(cellIndex: index))
        }
        return instances
    }

    /// Two solid quads so the depth order is visible on the Pallet Town sample.
    /// Anchors are `PalletTownDepthSpriteSample` and apply only for that map id.
    /// One sits in the leafy corner of the south-west wide tree top.
    /// One sits on open ground and stays fully in front of that metatile.
    /// Empty for every other map.
    public static func depthSprites(on map: MapDocument) -> [MapQuadInstance] {
        guard map.mapId == PalletTownDepthSpriteSample.mapId else { return [] }
        let underX = PalletTownDepthSpriteSample.underCanopyX
        let underY = PalletTownDepthSpriteSample.underCanopyY
        let openX = PalletTownDepthSpriteSample.openGroundX
        let openY = PalletTownDepthSpriteSample.openGroundY
        var sprites: [MapQuadInstance] = []
        if isTreeTop(x: underX, y: underY, on: map) {
            sprites.append(depthSprite(x: underX, y: underY, anchorX: 0.62, anchorY: 0.68))
        }
        if map.contains(x: openX, y: openY), !isTreeTop(x: openX, y: openY, on: map) {
            sprites.append(depthSprite(x: openX, y: openY, anchorX: 0.5, anchorY: 0.5))
        }
        return sprites
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

    private static func isTreeTop(x: Int, y: Int, on map: MapDocument) -> Bool {
        guard let cell = map.cell(x: x, y: y) else { return false }
        return GeneralTilesetTreeTops.treeTopMetatileIds.contains(cell.metatileId)
    }

    private static func depthSprite(x: Int, y: Int, anchorX: Float, anchorY: Float) -> MapQuadInstance {
        MapQuadInstance(
            centerX: Float(x) + anchorX,
            centerY: Float(y) + anchorY,
            halfX: 0.30,
            halfY: 0.28,
            red: 0.90,
            green: 0.16,
            blue: 0.20,
            alpha: 1,
            depth: MapDepth.sprite
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
