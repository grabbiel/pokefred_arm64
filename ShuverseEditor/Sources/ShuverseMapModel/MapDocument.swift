import Foundation

public struct CellInspection: Equatable {
    public var x: Int
    public var y: Int
    public var cell: MapCell
    public var objectEvents: [ObjectEvent]
    public var warpEvents: [WarpEvent]
    public var coordEvents: [CoordEvent]
    public var bgEvents: [BgEvent]

    public init(
        x: Int,
        y: Int,
        cell: MapCell,
        objectEvents: [ObjectEvent],
        warpEvents: [WarpEvent],
        coordEvents: [CoordEvent],
        bgEvents: [BgEvent]
    ) {
        self.x = x
        self.y = y
        self.cell = cell
        self.objectEvents = objectEvents
        self.warpEvents = warpEvents
        self.coordEvents = coordEvents
        self.bgEvents = bgEvents
    }
}

/// One loaded map. `Codable` speaks Map Parser JSON (`metatile_ids`, `map_attributes`),
/// while `cells` is the in-memory row-major grid.
public struct MapDocument: Equatable {
    public var mapId: String
    public var name: String
    public var layoutId: String
    public var music: String
    public var weather: String
    public var mapType: String
    public var tilesets: TilesetRef
    public var size: MapSize
    public var cells: [MapCell]
    public var border: [MapCell]?
    public var objectEvents: [ObjectEvent]
    public var warpEvents: [WarpEvent]
    public var coordEvents: [CoordEvent]
    public var bgEvents: [BgEvent]
    public var connections: [Connection]
    public var blockEncoding: String?
    public var uniqueMetatileCount: Int?
    public var dirty: MapDirtyFlags

    public init(
        mapId: String,
        name: String,
        layoutId: String,
        music: String,
        weather: String,
        mapType: String,
        tilesets: TilesetRef,
        size: MapSize,
        cells: [MapCell],
        border: [MapCell]? = nil,
        objectEvents: [ObjectEvent] = [],
        warpEvents: [WarpEvent] = [],
        coordEvents: [CoordEvent] = [],
        bgEvents: [BgEvent] = [],
        connections: [Connection] = [],
        blockEncoding: String? = nil,
        uniqueMetatileCount: Int? = nil,
        dirty: MapDirtyFlags = MapDirtyFlags()
    ) {
        self.mapId = mapId
        self.name = name
        self.layoutId = layoutId
        self.music = music
        self.weather = weather
        self.mapType = mapType
        self.tilesets = tilesets
        self.size = size
        self.cells = cells
        self.border = border
        self.objectEvents = objectEvents
        self.warpEvents = warpEvents
        self.coordEvents = coordEvents
        self.bgEvents = bgEvents
        self.connections = connections
        self.blockEncoding = blockEncoding
        self.uniqueMetatileCount = uniqueMetatileCount
        self.dirty = dirty
    }

    public init(parserJSON data: Data) throws {
        self = try JSONDecoder().decode(MapDocument.self, from: data)
    }

    public func parserJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func contains(x: Int, y: Int) -> Bool {
        cellIndex(x: x, y: y) != nil
    }

    public func cellIndex(x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < size.width, y < size.height else { return nil }
        return y * size.width + x
    }

    public func cell(x: Int, y: Int) -> MapCell? {
        guard let index = cellIndex(x: x, y: y), cells.indices.contains(index) else { return nil }
        return cells[index]
    }

    public func inspection(x: Int, y: Int) -> CellInspection? {
        guard let cell = cell(x: x, y: y) else { return nil }
        return CellInspection(
            x: x,
            y: y,
            cell: cell,
            objectEvents: objectEvents.filter { $0.x == x && $0.y == y },
            warpEvents: warpEvents.filter { $0.x == x && $0.y == y },
            coordEvents: coordEvents.filter { $0.x == x && $0.y == y },
            bgEvents: bgEvents.filter { $0.x == x && $0.y == y }
        )
    }

    public static func cells(metatileIds: [Int], mapAttributes: [Int], expectedCount: Int) throws -> [MapCell] {
        guard metatileIds.count == expectedCount, mapAttributes.count == expectedCount else {
            throw MapModelError.blockdataCount(
                expected: expectedCount,
                metatileIds: metatileIds.count,
                mapAttributes: mapAttributes.count
            )
        }
        var cells: [MapCell] = []
        cells.reserveCapacity(expectedCount)
        for index in 0..<expectedCount {
            let metatile = metatileIds[index]
            let attribute = mapAttributes[index]
            guard (0...1023).contains(metatile) else {
                throw MapModelError.metatileOutOfRange(index: index, value: metatile)
            }
            guard (0...63).contains(attribute) else {
                throw MapModelError.attributeOutOfRange(index: index, value: attribute)
            }
            cells.append(MapCell(metatileId: UInt16(metatile), mapAttribute: UInt8(attribute)))
        }
        return cells
    }
}

extension MapDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case mapId = "map_id"
        case name
        case layoutId = "layout_id"
        case dimensions
        case tilesets
        case music
        case weather
        case mapType = "map_type"
        case connections
        case objectEvents = "object_events"
        case warpEvents = "warp_events"
        case coordEvents = "coord_events"
        case bgEvents = "bg_events"
        case blockdata
    }

    enum DimensionKeys: String, CodingKey {
        case widthMetatiles = "width_metatiles"
        case heightMetatiles = "height_metatiles"
        case widthPx = "width_px"
        case heightPx = "height_px"
    }

    enum BlockKeys: String, CodingKey {
        case encoding
        case metatileIds = "metatile_ids"
        case mapAttributes = "map_attributes"
        case uniqueMetatileCount = "unique_metatile_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dims = try container.nestedContainer(keyedBy: DimensionKeys.self, forKey: .dimensions)
        let width = try dims.decode(Int.self, forKey: .widthMetatiles)
        let height = try dims.decode(Int.self, forKey: .heightMetatiles)
        guard width > 0, height > 0, width <= Int.max / height else {
            throw MapModelError.invalidDimensions(width: width, height: height)
        }
        let widthPx = try dims.decodeIfPresent(Int.self, forKey: .widthPx)
        let heightPx = try dims.decodeIfPresent(Int.self, forKey: .heightPx)

        let block = try container.nestedContainer(keyedBy: BlockKeys.self, forKey: .blockdata)
        let metatileIds = try block.decode([Int].self, forKey: .metatileIds)
        let mapAttributes = try block.decode([Int].self, forKey: .mapAttributes)
        let cells = try Self.cells(
            metatileIds: metatileIds,
            mapAttributes: mapAttributes,
            expectedCount: width * height
        )

        mapId = try container.decode(String.self, forKey: .mapId)
        name = try container.decode(String.self, forKey: .name)
        layoutId = try container.decode(String.self, forKey: .layoutId)
        music = try container.decode(String.self, forKey: .music)
        weather = try container.decode(String.self, forKey: .weather)
        mapType = try container.decode(String.self, forKey: .mapType)
        tilesets = try container.decode(TilesetRef.self, forKey: .tilesets)
        size = MapSize(width: width, height: height, widthPx: widthPx, heightPx: heightPx)
        self.cells = cells
        border = nil
        objectEvents = try container.decodeIfPresent([ObjectEvent].self, forKey: .objectEvents) ?? []
        warpEvents = try container.decodeIfPresent([WarpEvent].self, forKey: .warpEvents) ?? []
        coordEvents = try container.decodeIfPresent([CoordEvent].self, forKey: .coordEvents) ?? []
        bgEvents = try container.decodeIfPresent([BgEvent].self, forKey: .bgEvents) ?? []
        connections = try container.decodeIfPresent([Connection].self, forKey: .connections) ?? []
        blockEncoding = try block.decodeIfPresent(String.self, forKey: .encoding)
        uniqueMetatileCount = try block.decodeIfPresent(Int.self, forKey: .uniqueMetatileCount)
        dirty = MapDirtyFlags()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mapId, forKey: .mapId)
        try container.encode(name, forKey: .name)
        try container.encode(layoutId, forKey: .layoutId)
        try container.encode(music, forKey: .music)
        try container.encode(weather, forKey: .weather)
        try container.encode(mapType, forKey: .mapType)
        try container.encode(tilesets, forKey: .tilesets)
        try container.encode(connections, forKey: .connections)
        try container.encode(objectEvents, forKey: .objectEvents)
        try container.encode(warpEvents, forKey: .warpEvents)
        try container.encode(coordEvents, forKey: .coordEvents)
        try container.encode(bgEvents, forKey: .bgEvents)

        var dims = container.nestedContainer(keyedBy: DimensionKeys.self, forKey: .dimensions)
        try dims.encode(size.width, forKey: .widthMetatiles)
        try dims.encode(size.height, forKey: .heightMetatiles)
        try dims.encode(size.widthPx, forKey: .widthPx)
        try dims.encode(size.heightPx, forKey: .heightPx)

        var block = container.nestedContainer(keyedBy: BlockKeys.self, forKey: .blockdata)
        try block.encodeIfPresent(blockEncoding, forKey: .encoding)
        try block.encode(cells.map { Int($0.metatileId) }, forKey: .metatileIds)
        try block.encode(cells.map { Int($0.mapAttribute) }, forKey: .mapAttributes)
        try block.encodeIfPresent(uniqueMetatileCount, forKey: .uniqueMetatileCount)
    }
}
