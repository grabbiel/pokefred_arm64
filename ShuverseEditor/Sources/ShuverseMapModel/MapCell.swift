import Foundation

/// One metatile on a map. Packed the same way as `map.bin`:
/// `(mapAttribute << 10) | metatileId`, with the id in bits 0–9.
public struct MapCell: Codable, Equatable, Hashable {
    public var metatileId: UInt16
    public var mapAttribute: UInt8

    public init(metatileId: UInt16, mapAttribute: UInt8) {
        self.metatileId = metatileId & 0x3FF
        self.mapAttribute = mapAttribute & 0x3F
    }

    public init(raw: UInt16) {
        metatileId = raw & 0x3FF
        mapAttribute = UInt8((raw >> 10) & 0x3F)
    }

    public var raw: UInt16 {
        (UInt16(mapAttribute) << 10) | (metatileId & 0x3FF)
    }
}

public struct MapSize: Equatable, Hashable {
    public var width: Int
    public var height: Int
    public var widthPx: Int
    public var heightPx: Int

    public init(width: Int, height: Int, widthPx: Int? = nil, heightPx: Int? = nil) {
        self.width = width
        self.height = height
        self.widthPx = widthPx ?? width * MapSize.pixelsPerMetatile
        self.heightPx = heightPx ?? height * MapSize.pixelsPerMetatile
    }

    public static let pixelsPerMetatile = 16

    public var cellCount: Int {
        width * height
    }
}

public struct MapDirtyFlags: Codable, Equatable, Hashable {
    public var cells: Bool
    public var events: Bool
    public var header: Bool

    public init(cells: Bool = false, events: Bool = false, header: Bool = false) {
        self.cells = cells
        self.events = events
        self.header = header
    }

    public var isDirty: Bool {
        cells || events || header
    }
}

public enum MapModelError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidDimensions(width: Int, height: Int)
    case blockdataCount(expected: Int, metatileIds: Int, mapAttributes: Int)
    case metatileOutOfRange(index: Int, value: Int)
    case attributeOutOfRange(index: Int, value: Int)

    public var description: String {
        switch self {
        case let .invalidDimensions(width, height):
            return "Map dimensions must be positive (got \(width)×\(height))."
        case let .blockdataCount(expected, metatileIds, mapAttributes):
            return "Blockdata length \(metatileIds) metatile ids / \(mapAttributes) attributes does not match \(expected) cells."
        case let .metatileOutOfRange(index, value):
            return "Metatile id \(value) at index \(index) is outside 0…1023."
        case let .attributeOutOfRange(index, value):
            return "Map attribute \(value) at index \(index) is outside 0…63."
        }
    }

    public var errorDescription: String? { description }
}
