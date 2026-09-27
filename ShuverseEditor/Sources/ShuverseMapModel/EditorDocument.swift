import Foundation

/// Workspace root. Opening another map inserts or replaces a `MapDocument`
/// without closing the rest. Undo stays per map; v1 only tracks dirty flags.
public struct EditorDocument: Codable, Equatable {
    public var decompRoot: String
    public var maps: [MapDocument]
    public var activeMapId: String?
    public var sharedTilesets: [String: Tileset]
    public var dirtyMaps: Set<String>

    public init(
        decompRoot: String = "",
        maps: [MapDocument] = [],
        activeMapId: String? = nil,
        sharedTilesets: [String: Tileset] = [:],
        dirtyMaps: Set<String> = []
    ) {
        self.decompRoot = decompRoot
        self.maps = maps
        self.activeMapId = activeMapId
        self.sharedTilesets = sharedTilesets
        self.dirtyMaps = dirtyMaps
    }

    public var activeMap: MapDocument? {
        guard let activeMapId else { return nil }
        return maps.first { $0.mapId == activeMapId }
    }

    public mutating func importParserMap(_ data: Data) throws {
        try importMap(MapDocument(parserJSON: data))
    }

    public mutating func importMap(_ map: MapDocument) {
        if let index = maps.firstIndex(where: { $0.mapId == map.mapId }) {
            maps[index] = map
        } else {
            maps.append(map)
        }
        activeMapId = map.mapId
        dirtyMaps.remove(map.mapId)
        registerTileset(map.tilesets.primary)
        registerTileset(map.tilesets.secondary)
    }

    @discardableResult
    public mutating func focus(mapId: String) -> Bool {
        guard maps.contains(where: { $0.mapId == mapId }) else { return false }
        activeMapId = mapId
        return true
    }

    private mutating func registerTileset(_ id: String) {
        guard sharedTilesets[id] == nil else { return }
        sharedTilesets[id] = Tileset(id: id)
    }
}
