import Foundation

public struct TilesetRef: Codable, Equatable, Hashable {
    public var primary: String
    public var secondary: String

    public init(primary: String, secondary: String) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// Shared tileset identity. Maps dedupe on `id`. Pallet Town's 4bpp atlas is
/// loaded beside this record by `GBATileset`; the id stays small in workspace JSON.
public struct Tileset: Codable, Equatable, Hashable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct Connection: Codable, Equatable, Hashable {
    public var map: String
    public var offset: Int
    public var direction: String

    public init(map: String, offset: Int, direction: String) {
        self.map = map
        self.offset = offset
        self.direction = direction
    }
}

public struct ObjectEvent: Codable, Equatable, Hashable {
    public var localId: String
    public var graphicsId: String
    public var x: Int
    public var y: Int
    public var elevation: Int
    public var movementType: String
    public var script: String
    public var flag: String

    public init(
        localId: String,
        graphicsId: String,
        x: Int,
        y: Int,
        elevation: Int,
        movementType: String,
        script: String,
        flag: String
    ) {
        self.localId = localId
        self.graphicsId = graphicsId
        self.x = x
        self.y = y
        self.elevation = elevation
        self.movementType = movementType
        self.script = script
        self.flag = flag
    }

    enum CodingKeys: String, CodingKey {
        case localId = "local_id"
        case graphicsId = "graphics_id"
        case x
        case y
        case elevation
        case movementType = "movement_type"
        case script
        case flag
    }
}

public struct WarpEvent: Codable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var elevation: Int
    public var destMap: String
    public var destWarpId: String

    public init(x: Int, y: Int, elevation: Int, destMap: String, destWarpId: String) {
        self.x = x
        self.y = y
        self.elevation = elevation
        self.destMap = destMap
        self.destWarpId = destWarpId
    }

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case elevation
        case destMap = "dest_map"
        case destWarpId = "dest_warp_id"
    }
}

public struct CoordEvent: Codable, Equatable, Hashable {
    public var type: String
    public var x: Int
    public var y: Int
    public var elevation: Int
    public var variable: String
    public var varValue: String
    public var script: String

    public init(
        type: String,
        x: Int,
        y: Int,
        elevation: Int,
        variable: String,
        varValue: String,
        script: String
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.elevation = elevation
        self.variable = variable
        self.varValue = varValue
        self.script = script
    }

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case elevation
        case variable = "var"
        case varValue = "var_value"
        case script
    }
}

public struct BgEvent: Codable, Equatable, Hashable {
    public var type: String
    public var x: Int
    public var y: Int
    public var elevation: Int
    public var playerFacingDir: String
    public var script: String

    public init(
        type: String,
        x: Int,
        y: Int,
        elevation: Int,
        playerFacingDir: String,
        script: String
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.elevation = elevation
        self.playerFacingDir = playerFacingDir
        self.script = script
    }

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case elevation
        case playerFacingDir = "player_facing_dir"
        case script
    }
}
