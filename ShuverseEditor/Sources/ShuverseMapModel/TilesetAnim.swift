import Foundation

/// Pixel rows in the index atlas that a tileset animation just overwrote.
public struct AtlasRowSpan: Equatable {
    public var firstRow: Int
    public var rowCount: Int

    public init(firstRow: Int, rowCount: Int) {
        self.firstRow = firstRow
        self.rowCount = rowCount
    }

    /// Sorts row ranges and merges overlaps. A later animation clip can share
    /// one memcpy with rows a ring slot has not flushed yet.
    public static func union(_ spans: [AtlasRowSpan]) -> [AtlasRowSpan] {
        let ordered = spans.filter { $0.rowCount > 0 }.sorted { lhs, rhs in
            if lhs.firstRow != rhs.firstRow { return lhs.firstRow < rhs.firstRow }
            return lhs.rowCount < rhs.rowCount
        }
        var merged: [AtlasRowSpan] = []
        for span in ordered {
            guard let last = merged.last else {
                merged.append(span)
                continue
            }
            let lastEnd = last.firstRow + last.rowCount
            if span.firstRow <= lastEnd {
                let end = max(lastEnd, span.firstRow + span.rowCount)
                merged[merged.count - 1] = AtlasRowSpan(firstRow: last.firstRow, rowCount: end - last.firstRow)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

/// One 8×8 tile's palette indices, repeated `tileCount` times, row-major.
public struct TilesetAnimFrame: Equatable {
    public var indices: [UInt8]

    public init(indices: [UInt8]) {
        self.indices = indices
    }
}

/// Pret-style clip: on `counter % period == phase`, copy `frames[counter / period]`
/// over `tileCount` hardware tiles starting at `baseTileId`.
public struct TilesetAnimClip: Equatable {
    public var baseTileId: Int
    public var tileCount: Int
    public var frames: [TilesetAnimFrame]
    public var period: Int
    public var phase: Int

    public init(
        baseTileId: Int,
        tileCount: Int,
        frames: [TilesetAnimFrame],
        period: Int,
        phase: Int
    ) {
        self.baseTileId = baseTileId
        self.tileCount = tileCount
        self.frames = frames
        self.period = period
        self.phase = phase
    }
}

public struct TilesetAnimTable: Equatable {
    public var counterMax: Int
    public var clips: [TilesetAnimClip]

    public init(counterMax: Int, clips: [TilesetAnimClip]) {
        self.counterMax = counterMax
        self.clips = clips
    }
}

public struct TilesetAnimStep: Equatable {
    public var clipIndex: Int
    public var frameIndex: Int

    public init(clipIndex: Int, frameIndex: Int) {
        self.clipIndex = clipIndex
        self.frameIndex = frameIndex
    }
}

/// Pallet Town water and flower stubs.
///
/// pret `InitTilesetAnim_General` wraps a counter at 640. `TilesetAnim_General`
/// copies `water_current_landwatersedge` when `counter % 16 == 1`, frame
/// `counter / 16`, onto 4bpp tile 416 for 48 tiles, and copies `flower` when
/// `counter % 16 == 2`, frame `counter / 16`, onto tiles 508…511 (4 tiles,
/// 5 frames). Those frames live in separate graphics. This table does not
/// load them.
///
/// Pallet Town only samples water tiles 416…419 (metatiles 291, 298, 299, 300,
/// 721, 722). The water stub keeps that id, period, and phase, and builds
/// eight frames by rotating each baked tile up one pixel per frame. Frame 0
/// is the baked tile.
///
/// Flower tiles 508…511 are the top layer of metatile 4, which Pallet Town
/// places. The flower stub keeps pret's id, period, phase, and frame count,
/// and rotates each baked tile left one pixel per frame. Sand-water edge
/// (tile 464, 18 tiles, `counter % 8 == 0`) is not in this table: the Pallet
/// layout does not use those metatiles.
public enum PalletTownTilesetAnim {
    public static let counterMax = 640
    public static let ticksPerSecond = 60
    public static let waterBaseTileId = 416
    public static let waterTileCount = 4
    /// Full pret DMA length. Tiles 420…463 are not rewritten.
    public static let pretWaterDMATileCount = 48
    public static let waterFrameCount = 8
    public static let waterPeriod = 16
    public static let waterPhase = 1
    public static let flowerBaseTileId = 508
    public static let flowerTileCount = 4
    /// Top layer of this metatile is tiles 508…511.
    public static let flowerMetatileId = 4
    public static let flowerFrameCount = 5
    public static let flowerPeriod = 16
    public static let flowerPhase = 2

    public static func makeTable(from tileset: GBATileset) -> TilesetAnimTable? {
        guard tileset.atlasWidth == GBATileset.atlasWidth,
              tileset.atlasHeight == GBATileset.atlasHeight,
              tileset.indices.count == tileset.atlasWidth * tileset.atlasHeight,
              let water = waterFrames(in: tileset.indices, atlasWidth: tileset.atlasWidth),
              let flower = flowerFrames(in: tileset.indices, atlasWidth: tileset.atlasWidth) else {
            return nil
        }
        return TilesetAnimTable(
            counterMax: counterMax,
            clips: [
                TilesetAnimClip(
                    baseTileId: waterBaseTileId,
                    tileCount: waterTileCount,
                    frames: water,
                    period: waterPeriod,
                    phase: waterPhase
                ),
                TilesetAnimClip(
                    baseTileId: flowerBaseTileId,
                    tileCount: flowerTileCount,
                    frames: flower,
                    period: flowerPeriod,
                    phase: flowerPhase
                ),
            ]
        )
    }

    static func waterFrames(in indices: [UInt8], atlasWidth: Int) -> [TilesetAnimFrame]? {
        guard let base = readTiles(indices, atlasWidth: atlasWidth, tileId: waterBaseTileId, count: waterTileCount) else {
            return nil
        }
        return (0..<waterFrameCount).map { frame in
            TilesetAnimFrame(indices: scrollUp(base, tileCount: waterTileCount, rows: frame))
        }
    }

    static func flowerFrames(in indices: [UInt8], atlasWidth: Int) -> [TilesetAnimFrame]? {
        guard let base = readTiles(indices, atlasWidth: atlasWidth, tileId: flowerBaseTileId, count: flowerTileCount) else {
            return nil
        }
        return (0..<flowerFrameCount).map { frame in
            TilesetAnimFrame(indices: scrollLeft(base, tileCount: flowerTileCount, columns: frame))
        }
    }

    static func readTiles(_ indices: [UInt8], atlasWidth: Int, tileId: Int, count: Int) -> [UInt8]? {
        guard count > 0, atlasWidth == GBATileset.atlasWidth else { return nil }
        var pixels = [UInt8](repeating: 0, count: count * 64)
        for tile in 0..<count {
            guard writeTile(tileId + tile, from: indices, atlasWidth: atlasWidth, into: &pixels, at: tile * 64) else {
                return nil
            }
        }
        return pixels
    }

    /// `rows == 0` leaves the tile unchanged. Larger values move each row up.
    static func scrollUp(_ tiles: [UInt8], tileCount: Int, rows: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: tiles.count)
        let shift = ((rows % 8) + 8) % 8
        guard tiles.count >= tileCount * 64 else { return out }
        for tile in 0..<tileCount {
            let origin = tile * 64
            for y in 0..<8 {
                let sourceY = (y + shift) % 8
                for x in 0..<8 {
                    out[origin + y * 8 + x] = tiles[origin + sourceY * 8 + x]
                }
            }
        }
        return out
    }

    /// `columns == 0` leaves the tile unchanged. Larger values move each column left.
    static func scrollLeft(_ tiles: [UInt8], tileCount: Int, columns: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: tiles.count)
        let shift = ((columns % 8) + 8) % 8
        guard tiles.count >= tileCount * 64 else { return out }
        for tile in 0..<tileCount {
            let origin = tile * 64
            for y in 0..<8 {
                for x in 0..<8 {
                    let sourceX = (x + shift) % 8
                    out[origin + y * 8 + x] = tiles[origin + y * 8 + sourceX]
                }
            }
        }
        return out
    }

    private static func writeTile(
        _ tileId: Int,
        from indices: [UInt8],
        atlasWidth: Int,
        into pixels: inout [UInt8],
        at origin: Int
    ) -> Bool {
        let column = tileId % GBATileset.atlasTilesPerRow
        let row = tileId / GBATileset.atlasTilesPerRow
        let atlasHeight = indices.count / atlasWidth
        guard tileId >= 0, atlasWidth > 0, indices.count == atlasWidth * atlasHeight else { return false }
        for y in 0..<8 {
            let ay = row * 8 + y
            guard ay >= 0, ay < atlasHeight else { return false }
            for x in 0..<8 {
                let ax = column * 8 + x
                guard ax >= 0, ax < atlasWidth else { return false }
                pixels[origin + y * 8 + x] = indices[ay * atlasWidth + ax]
            }
        }
        return true
    }
}

/// Advances the pret counter, then reports clips that should be copied this tick.
public struct TilesetAnimPlayer: Equatable {
    public let table: TilesetAnimTable
    public private(set) var counter: Int

    public init(table: TilesetAnimTable) {
        self.table = table
        counter = 0
    }

    public mutating func advance() -> [TilesetAnimStep] {
        counter += 1
        if table.counterMax > 0, counter >= table.counterMax {
            counter = 0
        }
        var steps: [TilesetAnimStep] = []
        for (index, clip) in table.clips.enumerated() {
            guard clip.period > 0, !clip.frames.isEmpty, counter % clip.period == clip.phase else { continue }
            let frame = (counter / clip.period) % clip.frames.count
            steps.append(TilesetAnimStep(clipIndex: index, frameIndex: frame))
        }
        return steps
    }
}

public enum TilesetAnimBlit {
    /// Writes `clip.frames[frame]` into the index atlas. Returns the pixel rows
    /// that contain those tiles (a whole atlas row when the tiles share one).
    public static func apply(
        _ clip: TilesetAnimClip,
        frame frameIndex: Int,
        to indices: inout [UInt8],
        atlasWidth: Int,
        atlasHeight: Int
    ) -> AtlasRowSpan? {
        guard atlasWidth == GBATileset.atlasWidth,
              atlasHeight == GBATileset.atlasHeight,
              indices.count == atlasWidth * atlasHeight,
              clip.tileCount > 0,
              clip.frames.indices.contains(frameIndex) else {
            return nil
        }
        let frame = clip.frames[frameIndex]
        guard frame.indices.count == clip.tileCount * 64,
              frame.indices.allSatisfy({ $0 <= 15 }),
              clip.baseTileId >= 0,
              clip.baseTileId + clip.tileCount <= GBATileset.metatileCount else {
            return nil
        }
        let tilesPerRow = GBATileset.atlasTilesPerRow
        for tile in 0..<clip.tileCount {
            let tileId = clip.baseTileId + tile
            let column = tileId % tilesPerRow
            let row = tileId / tilesPerRow
            let source = tile * 64
            for y in 0..<8 {
                for x in 0..<8 {
                    indices[(row * 8 + y) * atlasWidth + column * 8 + x] = frame.indices[source + y * 8 + x]
                }
            }
        }
        let firstTileRow = clip.baseTileId / tilesPerRow
        let lastTileRow = (clip.baseTileId + clip.tileCount - 1) / tilesPerRow
        return AtlasRowSpan(firstRow: firstTileRow * 8, rowCount: (lastTileRow - firstTileRow + 1) * 8)
    }
}

/// Copies atlas rows into a shared r8Uint allocation. `rowBytes` may be wider
/// than the atlas (texture alignment). Bytes outside each copied row are left
/// alone. Returns false when a span does not fit.
public enum IndexAtlasRows {
    public static func copy(
        indices: UnsafeRawBufferPointer,
        atlasWidth: Int,
        atlasHeight: Int,
        spans: [AtlasRowSpan],
        destination: UnsafeMutableRawPointer,
        rowBytes: Int
    ) -> Bool {
        guard atlasWidth > 0, atlasHeight > 0, rowBytes >= atlasWidth else { return false }
        guard indices.count == atlasWidth * atlasHeight, let base = indices.baseAddress else { return false }
        for span in spans {
            guard span.firstRow >= 0, span.rowCount > 0, span.firstRow + span.rowCount <= atlasHeight else {
                return false
            }
            for row in 0..<span.rowCount {
                let sourceRow = span.firstRow + row
                destination.advanced(by: sourceRow * rowBytes).copyMemory(
                    from: base.advanced(by: sourceRow * atlasWidth),
                    byteCount: atlasWidth
                )
            }
        }
        return true
    }

    public static func copying(
        indices: [UInt8],
        atlasWidth: Int,
        atlasHeight: Int,
        spans: [AtlasRowSpan],
        rowBytes: Int
    ) -> [UInt8]? {
        let length = rowBytes * atlasHeight
        guard length > 0 else { return nil }
        var output = [UInt8](repeating: 0xFF, count: length)
        let copied = indices.withUnsafeBytes { raw in
            output.withUnsafeMutableBytes { destination -> Bool in
                guard let pointer = destination.baseAddress else { return false }
                return copy(
                    indices: raw,
                    atlasWidth: atlasWidth,
                    atlasHeight: atlasHeight,
                    spans: spans,
                    destination: pointer,
                    rowBytes: rowBytes
                )
            }
        }
        return copied ? output : nil
    }
}
