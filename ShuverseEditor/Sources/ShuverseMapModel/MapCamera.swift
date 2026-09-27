import Foundation

/// Pan/zoom over a metatile grid. World origin is the top-left of the map.
/// `viewYFromTop` is pixels from the top of the viewport, matching the map's y-down axis.
public struct MapCamera: Equatable {
    public var originX: Float
    public var originY: Float
    public var pointsPerMetatile: Float

    public static let minimumZoom: Float = 4
    public static let maximumZoom: Float = 160

    public init(originX: Float, originY: Float, pointsPerMetatile: Float) {
        self.originX = originX
        self.originY = originY
        self.pointsPerMetatile = pointsPerMetatile
    }

    public func worldX(viewX: Float) -> Float {
        originX + viewX / pointsPerMetatile
    }

    public func worldY(viewYFromTop: Float) -> Float {
        originY + viewYFromTop / pointsPerMetatile
    }

    public func metatile(viewX: Float, viewYFromTop: Float, map: MapDocument) -> (x: Int, y: Int)? {
        let x = Int(floor(worldX(viewX: viewX)))
        let y = Int(floor(worldY(viewYFromTop: viewYFromTop)))
        guard map.contains(x: x, y: y) else { return nil }
        return (x, y)
    }

    /// Zoom toward a viewport point. The metatile under that point stays put.
    public func zoom(by factor: Float, aroundViewX viewX: Float, viewYFromTop: Float) -> MapCamera {
        guard factor.isFinite, factor > 0, pointsPerMetatile > 0 else { return self }
        let anchorX = worldX(viewX: viewX)
        let anchorY = worldY(viewYFromTop: viewYFromTop)
        let zoom = min(max(pointsPerMetatile * factor, Self.minimumZoom), Self.maximumZoom)
        return MapCamera(
            originX: anchorX - viewX / zoom,
            originY: anchorY - viewYFromTop / zoom,
            pointsPerMetatile: zoom
        )
    }

    /// Grab-pan: the world point under the cursor at drag start stays under the cursor.
    public func moved(
        from start: MapCamera,
        startViewX: Float,
        startViewYFromTop: Float,
        viewX: Float,
        viewYFromTop: Float
    ) -> MapCamera {
        let anchorX = start.worldX(viewX: startViewX)
        let anchorY = start.worldY(viewYFromTop: startViewYFromTop)
        return MapCamera(
            originX: anchorX - viewX / start.pointsPerMetatile,
            originY: anchorY - viewYFromTop / start.pointsPerMetatile,
            pointsPerMetatile: start.pointsPerMetatile
        )
    }

    /// Frame the whole map inside the viewport. Fit may go below `minimumZoom`
    /// so a short window still shows every metatile.
    public func fitting(
        mapWidth: Int,
        mapHeight: Int,
        viewportWidth: Float,
        viewportHeight: Float,
        padding: Float = 24
    ) -> MapCamera {
        let columns = Float(max(mapWidth, 1))
        let rows = Float(max(mapHeight, 1))
        let availW = max(viewportWidth - padding * 2, 1)
        let availH = max(viewportHeight - padding * 2, 1)
        let zoom = min(max(min(availW / columns, availH / rows), 1), Self.maximumZoom)
        let padX = (viewportWidth - columns * zoom) / 2
        let padY = (viewportHeight - rows * zoom) / 2
        return MapCamera(
            originX: -padX / zoom,
            originY: -padY / zoom,
            pointsPerMetatile: zoom
        )
    }
}
