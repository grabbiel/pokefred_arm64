import Foundation

/// Byte layout shared by Swift uploads and `MapShaders.metal` source.
public enum MapGPULayout {
    public static let ringSlots = FrameRing.slotCount
    public static let gridWordBytes = 4
    public static let quadInstanceBytes = 48
    public static let uniformBytes = 64
    public static let instanceCenterOffset = 0
    public static let instanceHalfOffset = 8
    public static let instanceColorOffset = 16
    public static let instanceDepthOffset = 32
    /// `MapCanopyInstance`: cell index, then depth.
    public static let canopyInstanceBytes = 8
    public static let canopyCellOffset = 0
    public static let canopyDepthOffset = 4
    /// Enough for maps well past Pallet Town (24×20) without a realloc.
    public static let initialGridCells = 4096
    public static let initialMarkerInstances = 256
    public static let initialCanopyInstances = 256
    public static let initialSpriteInstances = 16
    public static let selectionInstances = 4
}

/// Per-frame constants. 16 scalar fields, 64 bytes, matching `Uniforms` in the shader.
public struct MapGPUUniforms: Equatable {
    public var originX: Float
    public var originY: Float
    public var viewportWidth: Float
    public var viewportHeight: Float
    public var pointsPerMetatile: Float
    public var groundDepth: Float
    public var pixelScale: Float
    public var selectionThickness: Float
    public var gridWidth: UInt32
    public var gridHeight: UInt32
    public var selectedX: Int32
    public var selectedY: Int32
    public var overlayFlags: UInt32
    public var tileWidth: UInt32
    public var tileHeight: UInt32
    public var collisionTintScale: Float

    public init(
        originX: Float,
        originY: Float,
        viewportWidth: Float,
        viewportHeight: Float,
        pointsPerMetatile: Float,
        groundDepth: Float = MapDepth.ground,
        pixelScale: Float,
        selectionThickness: Float = MapGeometry.selectionThickness,
        gridWidth: UInt32,
        gridHeight: UInt32,
        selectedX: Int32,
        selectedY: Int32,
        overlayFlags: UInt32,
        tileWidth: UInt32 = 0,
        tileHeight: UInt32 = 0,
        collisionTintScale: Float = MapTileOverlay.collisionTintScale
    ) {
        self.originX = originX
        self.originY = originY
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.pointsPerMetatile = pointsPerMetatile
        self.groundDepth = groundDepth
        self.pixelScale = pixelScale
        self.selectionThickness = selectionThickness
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.selectedX = selectedX
        self.selectedY = selectedY
        self.overlayFlags = overlayFlags
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.collisionTintScale = collisionTintScale
    }
}

/// Imageblock overlay bits. Both default off: selection is a depth-tested quad,
/// and cells are not recolored. See `docs/metal_gpu.md`.
public enum MapOverlayFlags {
    public static let selectionOutline: UInt32 = 1 << 0
    public static let collisionTint: UInt32 = 1 << 1
}

public enum MapTileOverlay {
    public static let collisionTintScale: Float = 0.82

    /// Framebuffer pixel → metatile space. `pixelScale` is drawable pixels per point.
    /// Matches `map_tile_overlay` in the shader.
    public static func world(pixelX: Float, pixelY: Float, uniforms: MapGPUUniforms) -> (x: Float, y: Float) {
        let scale = max(uniforms.pixelScale, 1)
        let points = max(uniforms.pointsPerMetatile, 0.0001)
        return (
            uniforms.originX + ((pixelX / scale) + 0.5) / points,
            uniforms.originY + ((pixelY / scale) + 0.5) / points
        )
    }

    public static func hitsSelectionBorder(worldX: Float, worldY: Float, uniforms: MapGPUUniforms) -> Bool {
        guard uniforms.selectedX >= 0, uniforms.selectedY >= 0 else { return false }
        let localX = worldX - Float(uniforms.selectedX)
        let localY = worldY - Float(uniforms.selectedY)
        guard localX >= 0, localY >= 0, localX < 1, localY < 1 else { return false }
        let thickness = uniforms.selectionThickness
        return localX < thickness || localY < thickness || localX > 1 - thickness || localY > 1 - thickness
    }

    public static func collisionTintActive(word: UInt32, flags: UInt32) -> Bool {
        (flags & MapOverlayFlags.collisionTint) != 0 && MapGridPack.mapAttribute(in: word) != 0
    }
}

/// Triple-buffered frame index. The CPU writes `nextSlot()` while the GPU
/// may still be reading the previous slots.
public struct FrameRing: Equatable {
    public static let slotCount = 3
    public private(set) var index: Int

    public init() {
        index = 0
    }

    public mutating func nextSlot() -> Int {
        let slot = index
        index = (index + 1) % Self.slotCount
        return slot
    }
}

/// Which ring slots still need a CPU copy. A selection change marks every
/// slot; the draw that owns a slot clears only that bit.
public struct RingSlotDirty: Equatable {
    public static let slotCount = FrameRing.slotCount
    private var mask: UInt8

    public init(allDirty: Bool = true) {
        mask = allDirty ? Self.allBits : 0
    }

    public mutating func markAllDirty() {
        mask = Self.allBits
    }

    public mutating func markClean(_ slot: Int) {
        guard Self.contains(slot) else { return }
        mask &= ~UInt8(1 << slot)
    }

    public func isDirty(_ slot: Int) -> Bool {
        guard Self.contains(slot) else { return false }
        return (mask & UInt8(1 << slot)) != 0
    }

    public var isAnyDirty: Bool {
        mask != 0
    }

    private static var allBits: UInt8 {
        UInt8((1 << slotCount) - 1)
    }

    private static func contains(_ slot: Int) -> Bool {
        slot >= 0 && slot < slotCount
    }
}

/// Byte capacity for a shared ring. `prepare` reports whether a new Metal
/// buffer is required. Updates that fit, including selection, return false.
public struct RingCapacity: Equatable {
    public private(set) var bytes: Int

    public init(bytes: Int) {
        self.bytes = max(bytes, 0)
    }

    @discardableResult
    public mutating func prepare(byteCount: Int) -> Bool {
        guard byteCount > bytes else { return false }
        var grown = max(bytes, 256)
        while grown < byteCount {
            grown *= 2
        }
        bytes = grown
        return true
    }
}
