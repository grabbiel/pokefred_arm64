import Foundation

/// One GBA background screen entry, as stored in pret `metatiles.bin`.
public struct GBAScreenEntry: Equatable {
    public var tileId: UInt16
    public var flipX: Bool
    public var flipY: Bool
    public var palette: UInt8

    public init(tileId: UInt16, flipX: Bool, flipY: Bool, palette: UInt8) {
        self.tileId = tileId & 0x03FF
        self.flipX = flipX
        self.flipY = flipY
        self.palette = palette & 0x0F
    }

    public init(raw: UInt16) {
        tileId = raw & 0x03FF
        flipX = (raw & 0x0400) != 0
        flipY = (raw & 0x0800) != 0
        palette = UInt8((raw >> 12) & 0x0F)
    }

    public var raw: UInt16 {
        var value = tileId & 0x03FF
        if flipX { value |= 0x0400 }
        if flipY { value |= 0x0800 }
        value |= UInt16(palette & 0x0F) << 12
        return value
    }
}

/// Host view of a GBA RGB555 color (`0bbbbbgggggrrrrr`).
public enum RGB555 {
    /// Same reduction as `tools/pixel_pipeline`: `c5 = (c8 * 32) >> 8`.
    public static func pack(r8: UInt8, g8: UInt8, b8: UInt8) -> UInt16 {
        let r5 = (UInt16(r8) * 32) >> 8
        let g5 = (UInt16(g8) * 32) >> 8
        let b5 = (UInt16(b8) * 32) >> 8
        return (r5 & 31) | ((g5 & 31) << 5) | ((b5 & 31) << 10)
    }

    public static func components(of packed: UInt16) -> (r: Float, g: Float, b: Float) {
        (
            Float(packed & 31) / 31,
            Float((packed >> 5) & 31) / 31,
            Float((packed >> 10) & 31) / 31
        )
    }
}

public struct GBAColor: Equatable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public static let clear = GBAColor(r: 0, g: 0, b: 0, a: 0)
}

/// Nibble order shared with `tools/pixel_pipeline` and gbagfx.
public enum GBA4bpp {
    public static let bytesPerTile = 32

    public static func index(byte: UInt8, x: Int) -> UInt8 {
        if x & 1 == 0 {
            return byte & 0x0F
        }
        return byte >> 4
    }
}

public enum TilesetGraphicsError: LocalizedError, Equatable {
    case unreadable(String)
    case badSize(String, expected: Int, actual: Int)
    case badPaletteBanks(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            return "Could not read \(name)."
        case let .badSize(name, expected, actual):
            return "\(name) is \(actual) bytes; expected \(expected)."
        case let .badPaletteBanks(name):
            return "\(name) needs 16 palette banks of 16 RGB555 colors."
        }
    }
}

/// Pallet Town primary + secondary tiles, expanded to an index atlas the GPU samples.
///
/// `indices` is one byte per texel (values 0…15), row-major, 16 tiles across.
/// Primary hardware tiles occupy ids 0…639. Secondary tiles occupy ids 640+.
/// `paletteRGB555` is 16 banks × 16 colors. Banks 0…6 are the primary tileset
/// with bank 0 color 0 forced black. Banks 7…12 are secondary palettes 7…12.
/// `metatileEntries` is 1024 metatiles × 8 screen entries (bottom 2×2, then top 2×2).
public struct GBATileset {
    public static let palletTownPrimary = "gTileset_General"
    public static let palletTownSecondary = "gTileset_PalletTown"
    public static let primaryTileCount = 640
    public static let primaryMetatileCount = 640
    public static let metatileCount = 1024
    public static let tilesPerMetatile = 8
    public static let colorsPerPalette = 16
    public static let paletteBanks = 16
    public static let primaryPaletteCount = 7
    public static let totalPaletteCount = 13
    public static let atlasTilesPerRow = 16
    public static let atlasWidth = atlasTilesPerRow * 8
    public static let atlasHeight = (metatileCount / atlasTilesPerRow) * 8
    public static let markerFile = "primary.4bpp"

    public var atlasWidth: Int
    public var atlasHeight: Int
    public var indices: [UInt8]
    public var paletteRGB555: [UInt16]
    public var metatileEntries: [UInt16]

    public init(
        atlasWidth: Int,
        atlasHeight: Int,
        indices: [UInt8],
        paletteRGB555: [UInt16],
        metatileEntries: [UInt16]
    ) {
        self.atlasWidth = atlasWidth
        self.atlasHeight = atlasHeight
        self.indices = indices
        self.paletteRGB555 = paletteRGB555
        self.metatileEntries = metatileEntries
    }

    public static func supports(_ tilesets: TilesetRef) -> Bool {
        tilesets.primary == palletTownPrimary && tilesets.secondary == palletTownSecondary
    }

    public static func combinedPalette(primary: [[UInt16]], secondary: [[UInt16]]) throws -> [UInt16] {
        guard primary.count == paletteBanks, secondary.count == paletteBanks else {
            throw TilesetGraphicsError.badPaletteBanks("tileset palettes")
        }
        guard primary.allSatisfy({ $0.count == colorsPerPalette }),
              secondary.allSatisfy({ $0.count == colorsPerPalette }) else {
            throw TilesetGraphicsError.badPaletteBanks("tileset palettes")
        }
        var colors = [UInt16](repeating: 0, count: paletteBanks * colorsPerPalette)
        for bank in 0..<primaryPaletteCount {
            for color in 0..<colorsPerPalette {
                colors[bank * colorsPerPalette + color] = primary[bank][color]
            }
        }
        colors[0] = 0
        for bank in primaryPaletteCount..<totalPaletteCount {
            for color in 0..<colorsPerPalette {
                colors[bank * colorsPerPalette + color] = secondary[bank][color]
            }
        }
        return colors
    }

    /// Bottom layer, then top layer. Index 0 stays transparent on both.
    /// Quadrant and flip rules match `map_tile_fragment`.
    public func sample(metatileId: Int, x: Int, y: Int) -> GBAColor {
        guard (0..<Self.metatileCount).contains(metatileId),
              (0..<16).contains(x),
              (0..<16).contains(y),
              indices.count == atlasWidth * atlasHeight,
              paletteRGB555.count == Self.paletteBanks * Self.colorsPerPalette,
              metatileEntries.count == Self.metatileCount * Self.tilesPerMetatile else {
            return .clear
        }
        let tx = x / 8
        let ty = y / 8
        var color = GBAColor.clear
        for layer in 0..<2 {
            let slot = layer * 4 + ty * 2 + tx
            let entry = GBAScreenEntry(raw: metatileEntries[metatileId * Self.tilesPerMetatile + slot])
            var px = x & 7
            var py = y & 7
            if entry.flipX { px = 7 - px }
            if entry.flipY { py = 7 - py }
            let column = Int(entry.tileId) % Self.atlasTilesPerRow
            let row = Int(entry.tileId) / Self.atlasTilesPerRow
            let ax = column * 8 + px
            let ay = row * 8 + py
            guard ax >= 0, ay >= 0, ax < atlasWidth, ay < atlasHeight else { continue }
            let index = Int(indices[ay * atlasWidth + ax])
            if index == 0 { continue }
            let packed = paletteRGB555[Int(entry.palette) * Self.colorsPerPalette + index]
            let rgb = RGB555.components(of: packed)
            color = GBAColor(r: rgb.r, g: rgb.g, b: rgb.b, a: 1)
        }
        return color
    }

    public static func loadPalletTown(from directory: URL) throws -> GBATileset {
        let primaryTiles = try read(directory.appendingPathComponent("primary.4bpp"), name: "primary.4bpp")
        let secondaryTiles = try read(directory.appendingPathComponent("secondary.4bpp"), name: "secondary.4bpp")
        let primaryMeta = try read(directory.appendingPathComponent("primary.metatiles.bin"), name: "primary.metatiles.bin")
        let secondaryMeta = try read(directory.appendingPathComponent("secondary.metatiles.bin"), name: "secondary.metatiles.bin")
        guard primaryTiles.count == primaryTileCount * GBA4bpp.bytesPerTile else {
            throw TilesetGraphicsError.badSize(
                "primary.4bpp",
                expected: primaryTileCount * GBA4bpp.bytesPerTile,
                actual: primaryTiles.count
            )
        }
        guard secondaryTiles.count % GBA4bpp.bytesPerTile == 0 else {
            throw TilesetGraphicsError.badSize("secondary.4bpp", expected: GBA4bpp.bytesPerTile, actual: secondaryTiles.count)
        }
        let secondaryTileCount = secondaryTiles.count / GBA4bpp.bytesPerTile
        guard secondaryTileCount <= metatileCount - primaryTileCount else {
            throw TilesetGraphicsError.badSize(
                "secondary.4bpp",
                expected: (metatileCount - primaryTileCount) * GBA4bpp.bytesPerTile,
                actual: secondaryTiles.count
            )
        }
        guard primaryMeta.count == primaryMetatileCount * tilesPerMetatile * 2 else {
            throw TilesetGraphicsError.badSize(
                "primary.metatiles.bin",
                expected: primaryMetatileCount * tilesPerMetatile * 2,
                actual: primaryMeta.count
            )
        }
        guard secondaryMeta.count % (tilesPerMetatile * 2) == 0 else {
            throw TilesetGraphicsError.badSize(
                "secondary.metatiles.bin",
                expected: tilesPerMetatile * 2,
                actual: secondaryMeta.count
            )
        }

        var indices = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        blit(primaryTiles, tileCount: primaryTileCount, firstTileId: 0, into: &indices)
        blit(secondaryTiles, tileCount: secondaryTileCount, firstTileId: primaryTileCount, into: &indices)

        let primaryBanks = try loadBanks(directory.appendingPathComponent("palettes/primary"), name: "primary palettes")
        let secondaryBanks = try loadBanks(directory.appendingPathComponent("palettes/secondary"), name: "secondary palettes")
        let palette = try combinedPalette(primary: primaryBanks, secondary: secondaryBanks)

        var entries = [UInt16](repeating: 0, count: metatileCount * tilesPerMetatile)
        writeEntries(primaryMeta, into: &entries, at: 0)
        writeEntries(secondaryMeta, into: &entries, at: primaryMetatileCount * tilesPerMetatile)

        return GBATileset(
            atlasWidth: atlasWidth,
            atlasHeight: atlasHeight,
            indices: indices,
            paletteRGB555: palette,
            metatileEntries: entries
        )
    }

    private static func read(_ url: URL, name: String) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TilesetGraphicsError.unreadable(name)
        }
    }

    private static func loadBanks(_ directory: URL, name: String) throws -> [[UInt16]] {
        var banks: [[UInt16]] = []
        banks.reserveCapacity(paletteBanks)
        for index in 0..<paletteBanks {
            let url = directory.appendingPathComponent(String(format: "%02d.pal", index))
            let data = try read(url, name: "\(name)/\(String(format: "%02d.pal", index))")
            guard data.count == colorsPerPalette * 2 else {
                throw TilesetGraphicsError.badSize(
                    url.lastPathComponent,
                    expected: colorsPerPalette * 2,
                    actual: data.count
                )
            }
            var colors = [UInt16](repeating: 0, count: colorsPerPalette)
            for color in 0..<colorsPerPalette {
                let offset = color * 2
                colors[color] = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            }
            banks.append(colors)
        }
        return banks
    }

    private static func blit(_ tiles: Data, tileCount: Int, firstTileId: Int, into indices: inout [UInt8]) {
        for tile in 0..<tileCount {
            let tileId = firstTileId + tile
            let column = tileId % atlasTilesPerRow
            let row = tileId / atlasTilesPerRow
            let origin = tile * GBA4bpp.bytesPerTile
            for y in 0..<8 {
                for x in 0..<8 {
                    let byte = tiles[origin + y * 4 + x / 2]
                    let index = GBA4bpp.index(byte: byte, x: x)
                    indices[(row * 8 + y) * atlasWidth + column * 8 + x] = index
                }
            }
        }
    }

    private static func writeEntries(_ data: Data, into entries: inout [UInt16], at start: Int) {
        let count = data.count / 2
        for index in 0..<count {
            let offset = index * 2
            entries[start + index] = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
    }
}

/// RGBA8 sheet of metatile previews for the ImGui tileset dock.
///
/// Each cell is 16×16 and matches `GBATileset.sample` (bottom layer, then top,
/// index 0 transparent). The map canvas does not upload this sheet.
public struct MetatileSwatchSheet {
    public static let columns = 16
    public static let tileSize = 16

    public var generation: UInt64
    public var columns: Int
    public var count: Int
    public var tileSize: Int
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public static func channel(_ component: Float) -> UInt8 {
        let scaled = component * 255
        if scaled <= 0 { return 0 }
        if scaled >= 255 { return 255 }
        return UInt8(scaled.rounded())
    }

    public static func make(
        from tileset: GBATileset,
        generation: UInt64 = 1,
        count: Int = GBATileset.metatileCount
    ) -> MetatileSwatchSheet {
        let columns = Self.columns
        let tileSize = Self.tileSize
        let clamped = max(0, min(count, GBATileset.metatileCount))
        let rows = clamped == 0 ? 0 : (clamped + columns - 1) / columns
        let width = columns * tileSize
        let height = rows * tileSize
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for id in 0..<clamped {
            let column = id % columns
            let row = id / columns
            for y in 0..<tileSize {
                for x in 0..<tileSize {
                    let color = tileset.sample(metatileId: id, x: x, y: y)
                    let offset = ((row * tileSize + y) * width + column * tileSize + x) * 4
                    rgba[offset] = channel(color.r)
                    rgba[offset + 1] = channel(color.g)
                    rgba[offset + 2] = channel(color.b)
                    rgba[offset + 3] = color.a <= 0 ? 0 : 255
                }
            }
        }
        return MetatileSwatchSheet(
            generation: generation,
            columns: columns,
            count: clamped,
            tileSize: tileSize,
            width: width,
            height: height,
            rgba: rgba
        )
    }

    public func pixel(metatileId: Int, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard (0..<count).contains(metatileId),
              (0..<tileSize).contains(x),
              (0..<tileSize).contains(y),
              width > 0 else {
            return nil
        }
        let column = metatileId % columns
        let row = metatileId / columns
        let offset = ((row * tileSize + y) * width + column * tileSize + x) * 4
        guard offset + 3 < rgba.count else { return nil }
        return (rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
    }

    /// Half-texel inset so a nearest sampler stays inside this metatile.
    public func uv(for metatileId: Int) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        guard width > 0, height > 0, (0..<count).contains(metatileId) else {
            return (0, 0, 0, 0)
        }
        let column = metatileId % columns
        let row = metatileId / columns
        let u0 = (Float(column * tileSize) + 0.5) / Float(width)
        let v0 = (Float(row * tileSize) + 0.5) / Float(height)
        let u1 = (Float((column + 1) * tileSize) - 0.5) / Float(width)
        let v1 = (Float((row + 1) * tileSize) - 0.5) / Float(height)
        return (u0, v0, u1, v1)
    }
}

/// Finds the baked Pallet Town directory by walking up from a set of roots.
public enum TilesetLocator {
    public static let relativePaths = [
        "Samples/tilesets/pallet_town",
        "ShuverseEditor/Samples/tilesets/pallet_town",
        "App/Resources/tilesets/pallet_town",
        "ShuverseEditor/App/Resources/tilesets/pallet_town",
    ]

    public static func find(startingAt roots: [URL], fileManager: FileManager = .default) -> URL? {
        for root in roots {
            var directory = root.standardizedFileURL
            for _ in 0..<10 {
                for relative in relativePaths {
                    let candidate = directory.appendingPathComponent(relative)
                    let marker = candidate.appendingPathComponent(GBATileset.markerFile)
                    if fileManager.isReadableFile(atPath: marker.path) {
                        return candidate
                    }
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }
        return nil
    }
}
