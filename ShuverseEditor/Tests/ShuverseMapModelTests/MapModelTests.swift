import XCTest
@testable import ShuverseMapModel

final class MapModelTests: XCTestCase {
    func testMapCellPacksAttributeInHighBits() {
        let cell = MapCell(metatileId: 678, mapAttribute: 12)
        XCTAssertEqual(cell.raw, 0x32A6)
        XCTAssertEqual(MapCell(raw: cell.raw), cell)

        let masked = MapCell(metatileId: 2048 + 5, mapAttribute: 64 + 3)
        XCTAssertEqual(masked.metatileId, 5)
        XCTAssertEqual(masked.mapAttribute, 3)
        XCTAssertEqual(MapCell(raw: masked.raw), masked)
    }

    func testGPULayoutsMatchShaderContract() {
        XCTAssertEqual(MemoryLayout<MapGPUUniforms>.size, MapGPULayout.uniformBytes)
        XCTAssertEqual(MemoryLayout<MapGPUUniforms>.stride, MapGPULayout.uniformBytes)
        XCTAssertEqual(MemoryLayout<MapQuadInstance>.size, MapGPULayout.quadInstanceBytes)
        XCTAssertEqual(MemoryLayout<MapQuadInstance>.stride, MapGPULayout.quadInstanceBytes)
        XCTAssertEqual(MemoryLayout<UInt32>.stride, MapGPULayout.gridWordBytes)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.originX), 0)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.viewportWidth), 8)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.pointsPerMetatile), 16)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.groundDepth), 20)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.pixelScale), 24)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.selectionThickness), 28)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.gridWidth), 32)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.selectedX), 40)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.overlayFlags), 48)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.tileWidth), 52)
        XCTAssertEqual(MemoryLayout.offset(of: \MapGPUUniforms.collisionTintScale), 60)
        XCTAssertEqual(MemoryLayout.offset(of: \MapQuadInstance.centerX), MapGPULayout.instanceCenterOffset)
        XCTAssertEqual(MemoryLayout.offset(of: \MapQuadInstance.halfX), MapGPULayout.instanceHalfOffset)
        XCTAssertEqual(MemoryLayout.offset(of: \MapQuadInstance.red), MapGPULayout.instanceColorOffset)
        XCTAssertEqual(MemoryLayout.offset(of: \MapQuadInstance.depth), MapGPULayout.instanceDepthOffset)

        XCTAssertGreaterThan(MapDepth.clear, MapDepth.ground)
        XCTAssertGreaterThan(MapDepth.ground, MapDepth.sprite)
        XCTAssertGreaterThan(MapDepth.sprite, MapDepth.canopy)
        XCTAssertGreaterThan(MapDepth.canopy, MapDepth.marker)
        XCTAssertGreaterThan(MapDepth.marker, MapDepth.selection)
    }

    func testPalletTownIs24By20() throws {
        let map = try loadPalletTown()
        XCTAssertEqual(map.mapId, "MAP_PALLET_TOWN")
        XCTAssertEqual(map.name, "PalletTown")
        XCTAssertEqual(map.layoutId, "LAYOUT_PALLET_TOWN")
        XCTAssertEqual(map.size.width, 24)
        XCTAssertEqual(map.size.height, 20)
        XCTAssertEqual(map.size.widthPx, 384)
        XCTAssertEqual(map.size.heightPx, 320)
        XCTAssertEqual(map.cells.count, 480)
        XCTAssertEqual(map.uniqueMetatileCount, 98)
        XCTAssertEqual(map.tilesets.primary, "gTileset_General")
        XCTAssertEqual(map.tilesets.secondary, "gTileset_PalletTown")

        let firstRow: [UInt16] = [28, 29, 28, 29, 28, 29, 28, 29, 28, 29, 28, 31, 678, 679, 30, 29, 28, 29, 28, 29, 28, 29, 28, 29]
        XCTAssertEqual(map.cells.prefix(24).map(\.metatileId), firstRow)
        XCTAssertEqual(map.cells[0].mapAttribute, 1)
        XCTAssertEqual(map.cells[12].metatileId, 678)
        XCTAssertEqual(map.cells[12].mapAttribute, 12)
        XCTAssertEqual(map.cells[12].raw, MapCell(metatileId: 678, mapAttribute: 12).raw)

        let signLady = try XCTUnwrap(map.inspection(x: 3, y: 10))
        XCTAssertEqual(signLady.objectEvents.map(\.localId), ["LOCALID_PALLET_SIGN_LADY"])

        let playersHouse = try XCTUnwrap(map.inspection(x: 6, y: 7))
        XCTAssertEqual(playersHouse.warpEvents.map(\.destMap), ["MAP_PALLET_TOWN_PLAYERS_HOUSE_1F"])

        let oakTrigger = try XCTUnwrap(map.inspection(x: 12, y: 1))
        XCTAssertEqual(oakTrigger.coordEvents.first?.variable, "VAR_MAP_SCENE_PALLET_TOWN_OAK")
        XCTAssertEqual(oakTrigger.coordEvents.first?.varValue, "0")

        XCTAssertEqual(map.connections.map(\.direction), ["up", "down"])
        XCTAssertEqual(map.connections.map(\.map), ["MAP_ROUTE1", "MAP_ROUTE21_NORTH"])
    }

    func testPalletTownRoundTripPreservesCellsAndEvents() throws {
        let map = try loadPalletTown()
        let decoded = try MapDocument(parserJSON: map.parserJSON())
        XCTAssertEqual(decoded.mapId, map.mapId)
        XCTAssertEqual(decoded.cells, map.cells)
        XCTAssertEqual(decoded.objectEvents, map.objectEvents)
        XCTAssertEqual(decoded.warpEvents, map.warpEvents)
        XCTAssertEqual(decoded.coordEvents, map.coordEvents)
        XCTAssertEqual(decoded.bgEvents, map.bgEvents)
        XCTAssertEqual(decoded.connections, map.connections)
        XCTAssertEqual(decoded.blockEncoding, map.blockEncoding)
        XCTAssertEqual(decoded.uniqueMetatileCount, 98)
        XCTAssertFalse(decoded.dirty.isDirty)
    }

    func testEditorDocumentOpensPalletTownAndDedupesTilesets() throws {
        var document = EditorDocument(decompRoot: "/tmp/pokefirered")
        let data = try Data(contentsOf: palletTownURL())
        try document.importParserMap(data)
        try document.importParserMap(data)

        XCTAssertEqual(document.maps.count, 1)
        XCTAssertEqual(document.activeMapId, "MAP_PALLET_TOWN")
        XCTAssertEqual(document.activeMap?.size.cellCount, 480)
        XCTAssertEqual(
            document.sharedTilesets.keys.sorted(),
            ["gTileset_General", "gTileset_PalletTown"]
        )
        XCTAssertTrue(document.dirtyMaps.isEmpty)
        XCTAssertFalse(document.focus(mapId: "MAP_ROUTE1"))
        XCTAssertTrue(document.focus(mapId: "MAP_PALLET_TOWN"))

        let decoded = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.decompRoot, "/tmp/pokefirered")
        XCTAssertEqual(decoded.activeMap?.cells, document.activeMap?.cells)
        XCTAssertEqual(decoded.sharedTilesets, document.sharedTilesets)
    }

    func testRejectsInconsistentBlockdata() {
        XCTAssertThrowsError(try MapDocument(parserJSON: Data(mapJSON(ids: [2000], attributes: [1]).utf8))) { error in
            XCTAssertEqual(error as? MapModelError, .metatileOutOfRange(index: 0, value: 2000))
        }
        XCTAssertThrowsError(try MapDocument(parserJSON: Data(mapJSON(ids: [1], attributes: [64]).utf8))) { error in
            XCTAssertEqual(error as? MapModelError, .attributeOutOfRange(index: 0, value: 64))
        }
        XCTAssertThrowsError(try MapDocument(parserJSON: Data(mapJSON(ids: [1, 2], attributes: [1, 1]).utf8))) { error in
            XCTAssertEqual(
                error as? MapModelError,
                .blockdataCount(expected: 1, metatileIds: 2, mapAttributes: 2)
            )
        }
    }

    func testSampleCopiesMatch() throws {
        let sample = try Data(contentsOf: palletTownURL())
        let bundled = try Data(contentsOf: packageRoot().appendingPathComponent("App/Resources/PalletTown.json"))
        XCTAssertEqual(sample, bundled)
        XCTAssertEqual(sample.count, bundled.count)
        XCTAssertGreaterThan(sample.count, 0)

        let sampleTiles = packageRoot().appendingPathComponent("Samples/tilesets/pallet_town")
        let bundledTiles = packageRoot().appendingPathComponent("App/Resources/tilesets/pallet_town")
        let relative = try relativeFiles(in: sampleTiles)
        XCTAssertEqual(try relativeFiles(in: bundledTiles), relative)
        XCTAssertTrue(relative.contains("primary.4bpp"))
        XCTAssertTrue(relative.contains("palettes/primary/00.pal"))
        XCTAssertTrue(relative.contains("palettes/secondary/11.pal"))
        for path in relative {
            let left = try Data(contentsOf: sampleTiles.appendingPathComponent(path))
            let right = try Data(contentsOf: bundledTiles.appendingPathComponent(path))
            XCTAssertEqual(left, right, path)
        }
    }

    func testSharedGridCoversPalletTownWithoutVertexRemesh() throws {
        let map = try loadPalletTown()
        let grid = MapDrawListBuilder.grid(for: map)
        XCTAssertEqual(grid.width, 24)
        XCTAssertEqual(grid.height, 20)
        XCTAssertEqual(grid.words.count, 480)
        XCTAssertEqual(MapGridPack.metatileId(in: grid.words[0]), 28)
        XCTAssertEqual(MapGridPack.mapAttribute(in: grid.words[0]), 1)
        XCTAssertEqual(MapGridPack.metatileId(in: grid.words[12]), 678)
        XCTAssertEqual(MapGridPack.mapAttribute(in: grid.words[12]), 12)
        XCTAssertEqual(grid.words[12], UInt32(map.cells[12].raw))
        XCTAssertEqual(grid.words[24], MapGridPack.word(for: map.cells[24]))

        let eventCount = map.objectEvents.count + map.warpEvents.count + map.coordEvents.count + map.bgEvents.count
        XCTAssertEqual(eventCount, 14)
        let markers = MapDrawListBuilder.markers(on: map)
        XCTAssertEqual(markers.count, eventCount)
        let signLady = try XCTUnwrap(markers.first {
            abs($0.centerX - 3.5) < 0.001 && abs($0.centerY - 10.5) < 0.001
        })
        XCTAssertEqual(signLady.halfX, 0.12, accuracy: 0.0001)
        XCTAssertEqual(signLady.halfY, 0.12, accuracy: 0.0001)
        XCTAssertEqual(signLady.red, 0.95, accuracy: 0.0001)
        XCTAssertEqual(signLady.depth, MapDepth.marker)

        let warp = try XCTUnwrap(markers.first {
            abs($0.centerX - 6.5) < 0.001 && abs($0.centerY - 7.5) < 0.001
        })
        XCTAssertEqual(warp.red, 1, accuracy: 0.0001)
        XCTAssertEqual(warp.green, 0.82, accuracy: 0.0001)

        let selected = MapDrawListBuilder.selection(x: 6, y: 7, on: map)
        XCTAssertEqual(selected.count, MapGPULayout.selectionInstances)
        XCTAssertEqual(selected[0].depth, MapDepth.selection)
        XCTAssertEqual(selected[0].centerX, 6.5, accuracy: 0.0001)
        XCTAssertEqual(selected[0].centerY, 7 + MapGeometry.selectionThickness / 2, accuracy: 0.0001)
        XCTAssertEqual(MapDrawListBuilder.grid(for: map), grid)
        XCTAssertTrue(MapDrawListBuilder.selection(x: 99, y: 0, on: map).isEmpty)

        var gridCapacity = RingCapacity(bytes: MapGPULayout.initialGridCells * MapGPULayout.gridWordBytes)
        XCTAssertFalse(gridCapacity.prepare(byteCount: grid.words.count * MapGPULayout.gridWordBytes))
        var selectionCapacity = RingCapacity(
            bytes: MapGPULayout.selectionInstances * MapGPULayout.quadInstanceBytes
        )
        XCTAssertFalse(selectionCapacity.prepare(byteCount: selected.count * MapGPULayout.quadInstanceBytes))
        XCTAssertTrue(gridCapacity.prepare(byteCount: 5000 * MapGPULayout.gridWordBytes))
    }

    func testStackedMarkersAndTileOverlayMath() {
        let map = MapDocument(
            mapId: "MAP_X",
            name: "X",
            layoutId: "LAYOUT_X",
            music: "M",
            weather: "W",
            mapType: "T",
            tilesets: TilesetRef(primary: "a", secondary: "b"),
            size: MapSize(width: 2, height: 1),
            cells: [
                MapCell(metatileId: 1, mapAttribute: 0),
                MapCell(metatileId: 2, mapAttribute: 4),
            ],
            objectEvents: [
                ObjectEvent(
                    localId: "o",
                    graphicsId: "g",
                    x: 1,
                    y: 0,
                    elevation: 0,
                    movementType: "m",
                    script: "s",
                    flag: "f"
                ),
            ],
            bgEvents: [
                BgEvent(type: "sign", x: 1, y: 0, elevation: 0, playerFacingDir: "any", script: "s"),
            ]
        )
        let markers = MapDrawListBuilder.markers(on: map)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].centerX, 1.30, accuracy: 0.0001)
        XCTAssertEqual(markers[0].centerY, 0.30, accuracy: 0.0001)
        XCTAssertEqual(markers[0].halfX, 0.08, accuracy: 0.0001)
        XCTAssertEqual(markers[0].red, 0.95, accuracy: 0.0001)
        XCTAssertEqual(markers[1].centerX, 1.70, accuracy: 0.0001)
        XCTAssertEqual(markers[1].blue, 0.24, accuracy: 0.0001)

        let uniforms = MapGPUUniforms(
            originX: 0,
            originY: 0,
            viewportWidth: 800,
            viewportHeight: 600,
            pointsPerMetatile: 16,
            pixelScale: 2,
            gridWidth: 2,
            gridHeight: 1,
            selectedX: 1,
            selectedY: 0,
            overlayFlags: MapOverlayFlags.selectionOutline | MapOverlayFlags.collisionTint,
            tileWidth: 32,
            tileHeight: 32
        )
        let edge = MapTileOverlay.world(pixelX: 32, pixelY: 0, uniforms: uniforms)
        XCTAssertEqual(edge.x, 1.03125, accuracy: 0.0001)
        XCTAssertTrue(MapTileOverlay.hitsSelectionBorder(worldX: edge.x, worldY: 0.01, uniforms: uniforms))
        XCTAssertFalse(MapTileOverlay.hitsSelectionBorder(worldX: 1.5, worldY: 0.5, uniforms: uniforms))
        XCTAssertFalse(MapTileOverlay.hitsSelectionBorder(worldX: 0.1, worldY: 0.1, uniforms: uniforms))
        let word = MapGridPack.word(for: map.cells[1])
        XCTAssertTrue(MapTileOverlay.collisionTintActive(word: word, flags: uniforms.overlayFlags))
        XCTAssertFalse(MapTileOverlay.collisionTintActive(word: word, flags: 0))
        XCTAssertFalse(
            MapTileOverlay.collisionTintActive(
                word: MapGridPack.word(for: map.cells[0]),
                flags: MapOverlayFlags.collisionTint
            )
        )
    }

    func testRingSlotsAndPalette() {
        var ring = FrameRing()
        XCTAssertEqual([ring.nextSlot(), ring.nextSlot(), ring.nextSlot(), ring.nextSlot()], [0, 1, 2, 0])

        var dirty = RingSlotDirty()
        XCTAssertTrue(dirty.isDirty(0))
        XCTAssertTrue(dirty.isDirty(2))
        dirty.markClean(1)
        XCTAssertFalse(dirty.isDirty(1))
        XCTAssertTrue(dirty.isDirty(0))
        dirty.markAllDirty()
        XCTAssertTrue(dirty.isDirty(1))

        let palette = MetatileColor.paletteComponents()
        XCTAssertEqual(palette.count, 1024 * 4)
        let first = MetatileColor.components(for: 28)
        XCTAssertEqual(palette[28 * 4], first.r, accuracy: 0.0001)
        XCTAssertEqual(palette[28 * 4 + 1], first.g, accuracy: 0.0001)
        XCTAssertEqual(palette[28 * 4 + 2], first.b, accuracy: 0.0001)
        XCTAssertEqual(palette[28 * 4 + 3], first.a, accuracy: 0.0001)
        let next = MetatileColor.components(for: 29)
        XCTAssertTrue(first.r != next.r || first.g != next.g || first.b != next.b)
    }

    func testEditorKeepsSharedGridPath() throws {
        let root = packageRoot()
        let shaders = try String(contentsOf: root.appendingPathComponent("App/MapShaders.swift"), encoding: .utf8)
        let canvas = try String(contentsOf: root.appendingPathComponent("App/MapCanvasView.swift"), encoding: .utf8)
        let gpu = try String(contentsOf: root.appendingPathComponent("App/MapGPUState.swift"), encoding: .utf8)
        let locator = try String(contentsOf: root.appendingPathComponent("App/MapFileLocator.swift"), encoding: .utf8)
        XCTAssertTrue(locator.contains("import ShuverseMapModel"))
        XCTAssertTrue(locator.contains("TilesetLocator.find"))
        XCTAssertTrue(shaders.contains("[[stage_in]]"))
        XCTAssertTrue(shaders.contains("vertex Varying map_vertex"))
        XCTAssertTrue(shaders.contains("vertex Varying map_sprite_vertex"))
        XCTAssertTrue(shaders.contains("fragment float4 map_fragment(Varying in [[stage_in]])"))
        XCTAssertTrue(shaders.contains("kernel void map_tile_overlay"))
        XCTAssertTrue(shaders.contains("imageblock<TilePixel>"))
        XCTAssertTrue(canvas.contains("depthStencilPixelFormat"))
        XCTAssertTrue(canvas.contains("storeAction = .dontCare"))
        XCTAssertTrue(canvas.contains("MapMetatileGrid.make"))
        XCTAssertFalse(canvas.contains("makeBuffer"))
        XCTAssertFalse(canvas.contains("MapDrawListBuilder.make"))
        XCTAssertFalse(canvas.contains("GLFW"))
        XCTAssertTrue(gpu.contains(".storageModeShared"))
        XCTAssertTrue(gpu.contains("FrameRing.slotCount"))
        XCTAssertFalse(gpu.contains("assertionFailure"))
        XCTAssertTrue(canvas.contains("assertionFailure"))
        XCTAssertTrue(gpu.contains("Shared ring upload failed"))
        XCTAssertTrue(gpu.contains("Shared tileset upload failed"))
        XCTAssertTrue(gpu.contains(".r8Uint"))
        XCTAssertTrue(gpu.contains("minimumLinearTextureAlignment"))
        XCTAssertTrue(gpu.contains("makeTexture"))
        XCTAssertTrue(gpu.contains("tileset-rgb555"))
        XCTAssertTrue(gpu.contains("tileset-indices"))
        XCTAssertFalse(gpu.contains("MetatileColor"))
        XCTAssertFalse(gpu.contains("storageModeManaged"))
        XCTAssertFalse(gpu.contains("didModifyRange"))
        XCTAssertTrue(shaders.contains("fragment float4 map_tile_fragment"))
        XCTAssertTrue(shaders.contains("texture2d<uint, access::read>"))
        XCTAssertTrue(shaders.contains("const device ushort *palette"))
        XCTAssertTrue(shaders.contains("constant uint AtlasTilesPerRow = 16u;"))
        XCTAssertTrue(shaders.contains("palette[pal * 16u + index]"))
        XCTAssertFalse(shaders.contains("palette[metatileId]"))
        XCTAssertEqual(GBATileset.atlasTilesPerRow, 16)
        XCTAssertFalse(gpu.contains("dispatchThreadsPerTile"))
        XCTAssertFalse(gpu.contains("MTLTileRenderPipelineDescriptor"))
        XCTAssertFalse(gpu.contains("tileFunction"))
        XCTAssertFalse(canvas.contains("dispatchThreadsPerTile"))
        XCTAssertFalse(gpu.contains("GLFW"))
    }

    func testRGB555AndNibbleOrderMatchPixelPipeline() {
        XCTAssertEqual(RGB555.pack(r8: 0, g8: 0, b8: 0), 0)
        XCTAssertEqual(RGB555.pack(r8: 255, g8: 0, b8: 0), 31)
        XCTAssertEqual(RGB555.pack(r8: 0, g8: 255, b8: 0), 31 << 5)
        XCTAssertEqual(RGB555.pack(r8: 0, g8: 0, b8: 255), 31 << 10)
        XCTAssertEqual(RGB555.pack(r8: 189, g8: 255, b8: 139), 0x47F7)
        let green = RGB555.components(of: 0x47F7)
        XCTAssertEqual(green.r, Float(23) / 31, accuracy: 0.0001)
        XCTAssertEqual(green.g, 1, accuracy: 0.0001)
        XCTAssertEqual(green.b, Float(17) / 31, accuracy: 0.0001)
        XCTAssertEqual(GBA4bpp.index(byte: 0x21, x: 0), 1)
        XCTAssertEqual(GBA4bpp.index(byte: 0x21, x: 1), 2)
        XCTAssertEqual(GBAScreenEntry(raw: 0xB681).tileId, 641)
        XCTAssertTrue(GBAScreenEntry(raw: 0xB681).flipX)
        XCTAssertFalse(GBAScreenEntry(raw: 0xB681).flipY)
        XCTAssertEqual(GBAScreenEntry(raw: 0xB681).palette, 11)
        XCTAssertEqual(GBAScreenEntry(raw: 0xB681).raw, 0xB681)
    }

    func testCombinedPaletteUsesPalletTownBanks() throws {
        var primary = Array(repeating: Array(repeating: UInt16(0xFFFF), count: 16), count: 16)
        var secondary = Array(repeating: Array(repeating: UInt16(0x1111), count: 16), count: 16)
        primary[0][0] = 0x7FFF
        secondary[11][6] = 0x6393
        let palette = try GBATileset.combinedPalette(primary: primary, secondary: secondary)
        XCTAssertEqual(palette.count, 256)
        XCTAssertEqual(palette[0], 0)
        XCTAssertEqual(palette[1], 0xFFFF)
        XCTAssertEqual(palette[6 * 16 + 4], 0xFFFF)
        XCTAssertEqual(palette[7 * 16], 0x1111)
        XCTAssertEqual(palette[11 * 16 + 6], 0x6393)
        XCTAssertEqual(palette[13 * 16], 0)
    }

    func testSampleRespectsFlipAndTransparentIndex() {
        var indices = [UInt8](repeating: 0, count: GBATileset.atlasWidth * GBATileset.atlasHeight)
        func paint(tileId: Int, x: Int, y: Int, index: UInt8) {
            let column = tileId % GBATileset.atlasTilesPerRow
            let row = tileId / GBATileset.atlasTilesPerRow
            indices[(row * 8 + y) * GBATileset.atlasWidth + column * 8 + x] = index
        }
        // Tile 0 stays empty so a zero screen entry does not cover the layer under it.
        paint(tileId: 4, x: 0, y: 0, index: 1)
        paint(tileId: 4, x: 7, y: 0, index: 2)
        paint(tileId: 1, x: 0, y: 0, index: 3)
        paint(tileId: 2, x: 0, y: 0, index: 0)
        paint(tileId: 2, x: 1, y: 0, index: 4)

        var palette = [UInt16](repeating: 0, count: 256)
        palette[1] = 31
        palette[2] = 31 << 5
        palette[3] = 31 << 10
        palette[4] = 31 | (31 << 5)

        var entries = [UInt16](repeating: 0, count: GBATileset.metatileCount * GBATileset.tilesPerMetatile)
        entries[0] = GBAScreenEntry(tileId: 4, flipX: true, flipY: false, palette: 0).raw
        entries[8] = GBAScreenEntry(tileId: 1, flipX: false, flipY: false, palette: 0).raw
        entries[12] = GBAScreenEntry(tileId: 2, flipX: false, flipY: false, palette: 0).raw

        let tileset = GBATileset(
            atlasWidth: GBATileset.atlasWidth,
            atlasHeight: GBATileset.atlasHeight,
            indices: indices,
            paletteRGB555: palette,
            metatileEntries: entries
        )
        let flippedLeft = tileset.sample(metatileId: 0, x: 0, y: 0)
        XCTAssertEqual(flippedLeft.g, 1, accuracy: 0.0001)
        XCTAssertEqual(flippedLeft.a, 1, accuracy: 0.0001)
        let flippedRight = tileset.sample(metatileId: 0, x: 7, y: 0)
        XCTAssertEqual(flippedRight.r, 1, accuracy: 0.0001)
        XCTAssertEqual(flippedRight.g, 0, accuracy: 0.0001)

        let covered = tileset.sample(metatileId: 1, x: 0, y: 0)
        XCTAssertEqual(covered.b, 1, accuracy: 0.0001)
        XCTAssertEqual(covered.r, 0, accuracy: 0.0001)
        let overlaid = tileset.sample(metatileId: 1, x: 1, y: 0)
        XCTAssertEqual(overlaid.r, 1, accuracy: 0.0001)
        XCTAssertEqual(overlaid.g, 1, accuracy: 0.0001)

        let clear = tileset.sample(metatileId: 1, x: 2, y: 0)
        XCTAssertEqual(clear.a, 0, accuracy: 0.0001)
        let sheet = MetatileSwatchSheet.make(from: tileset, count: 2)
        XCTAssertEqual(sheet.width, 256)
        XCTAssertEqual(sheet.height, 16)
        XCTAssertEqual(sheet.count, 2)
        let clearPixel = sheet.pixel(metatileId: 1, x: 2, y: 0)
        XCTAssertEqual(clearPixel?.a, 0)
        let grassPixel = sheet.pixel(metatileId: 0, x: 0, y: 0)
        XCTAssertEqual(grassPixel?.a, 255)
        XCTAssertEqual(grassPixel?.g, MetatileSwatchSheet.channel(flippedLeft.g))
        XCTAssertEqual(grassPixel?.r, MetatileSwatchSheet.channel(flippedLeft.r))
        let uv = sheet.uv(for: 1)
        XCTAssertGreaterThan(uv.u0, 0)
        XCTAssertLessThan(uv.u1, 2 / Float(sheet.columns))
    }

    func testPalletTownTilesetDecodesRealPixels() throws {
        let directory = try XCTUnwrap(TilesetLocator.find(startingAt: [packageRoot()]))
        let tileset = try GBATileset.loadPalletTown(from: directory)
        XCTAssertEqual(tileset.atlasWidth, 128)
        XCTAssertEqual(tileset.atlasHeight, 512)
        XCTAssertEqual(tileset.indices.count, 128 * 512)
        XCTAssertEqual(tileset.paletteRGB555.count, 256)
        XCTAssertEqual(tileset.metatileEntries.count, 1024 * 8)
        XCTAssertEqual(tileset.paletteRGB555[0], 0)
        XCTAssertEqual(tileset.paletteRGB555[1], 0x47F7)
        XCTAssertEqual(tileset.paletteRGB555[11 * 16], 0x7C1F)
        XCTAssertEqual(tileset.metatileEntries[28 * 8], 0x29)
        XCTAssertEqual(tileset.metatileEntries[29 * 8 + 6], 0x437)
        XCTAssertEqual(tileset.metatileEntries[678 * 8], 0xB281)

        let grass = tileset.sample(metatileId: 28, x: 5, y: 0)
        let expected = RGB555.components(of: 0x47F7)
        XCTAssertEqual(grass.r, expected.r, accuracy: 0.0001)
        XCTAssertEqual(grass.g, expected.g, accuracy: 0.0001)
        XCTAssertEqual(grass.b, expected.b, accuracy: 0.0001)
        XCTAssertEqual(grass.a, 1, accuracy: 0.0001)

        let shade = tileset.sample(metatileId: 28, x: 4, y: 4)
        let shadeExpected = RGB555.components(of: 0x3350)
        XCTAssertEqual(shade.r, shadeExpected.r, accuracy: 0.0001)
        XCTAssertEqual(shade.g, shadeExpected.g, accuracy: 0.0001)
        XCTAssertEqual(shade.b, shadeExpected.b, accuracy: 0.0001)

        let roof = tileset.sample(metatileId: 678, x: 4, y: 4)
        XCTAssertEqual(roof.a, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(roof.r, 0.5)

        let sheet = MetatileSwatchSheet.make(from: tileset)
        XCTAssertEqual(sheet.count, GBATileset.metatileCount)
        XCTAssertEqual(sheet.width, MetatileSwatchSheet.columns * MetatileSwatchSheet.tileSize)
        XCTAssertEqual(sheet.height, (GBATileset.metatileCount / MetatileSwatchSheet.columns) * MetatileSwatchSheet.tileSize)
        let grassPixel = sheet.pixel(metatileId: 28, x: 5, y: 0)
        XCTAssertEqual(grassPixel?.r, MetatileSwatchSheet.channel(expected.r))
        XCTAssertEqual(grassPixel?.g, MetatileSwatchSheet.channel(expected.g))
        XCTAssertEqual(grassPixel?.b, MetatileSwatchSheet.channel(expected.b))
        XCTAssertEqual(grassPixel?.a, 255)
        let roofPixel = sheet.pixel(metatileId: 678, x: 4, y: 4)
        XCTAssertEqual(roofPixel?.a, 255)
        XCTAssertEqual(roofPixel?.r, MetatileSwatchSheet.channel(roof.r))
        XCTAssertEqual(roofPixel?.g, MetatileSwatchSheet.channel(roof.g))
        XCTAssertEqual(roofPixel?.b, MetatileSwatchSheet.channel(roof.b))
        XCTAssertTrue(GBATileset.supports(TilesetRef(primary: "gTileset_General", secondary: "gTileset_PalletTown")))
        XCTAssertFalse(GBATileset.supports(TilesetRef(primary: "gTileset_General", secondary: "gTileset_ViridianCity")))
    }

    func testCameraHitTestPanAndZoom() throws {
        let map = try loadPalletTown()
        let camera = MapCamera(originX: 0, originY: 0, pointsPerMetatile: 16)
        XCTAssertEqual(camera.metatile(viewX: 104, viewYFromTop: 120, map: map)?.x, 6)
        XCTAssertEqual(camera.metatile(viewX: 104, viewYFromTop: 120, map: map)?.y, 7)
        XCTAssertNil(camera.metatile(viewX: -0.1, viewYFromTop: 8, map: map))
        XCTAssertNil(camera.metatile(viewX: 24 * 16, viewYFromTop: 8, map: map))

        let zoomed = camera.zoom(by: 2, aroundViewX: 100, viewYFromTop: 40)
        XCTAssertEqual(zoomed.pointsPerMetatile, 32, accuracy: 0.001)
        XCTAssertEqual(zoomed.worldX(viewX: 100), camera.worldX(viewX: 100), accuracy: 0.001)
        XCTAssertEqual(zoomed.worldY(viewYFromTop: 40), camera.worldY(viewYFromTop: 40), accuracy: 0.001)

        let panned = camera.moved(
            from: camera,
            startViewX: 10,
            startViewYFromTop: 20,
            viewX: 30,
            viewYFromTop: 5
        )
        XCTAssertEqual(panned.worldX(viewX: 30), camera.worldX(viewX: 10), accuracy: 0.001)
        XCTAssertEqual(panned.worldY(viewYFromTop: 5), camera.worldY(viewYFromTop: 20), accuracy: 0.001)

        let fitted = camera.fitting(mapWidth: 24, mapHeight: 20, viewportWidth: 800, viewportHeight: 600, padding: 0)
        XCTAssertEqual(fitted.pointsPerMetatile, 30, accuracy: 0.001)
        XCTAssertEqual(fitted.originX, -40 / 30, accuracy: 0.001)
        XCTAssertEqual(fitted.originY, 0, accuracy: 0.001)
    }

    private func relativeFiles(in directory: URL) throws -> [String] {
        let root = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            XCTAssertTrue(path.hasPrefix(root))
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            files.append(relative)
        }
        return files.sorted()
    }

    private func loadPalletTown() throws -> MapDocument {
        try MapDocument(parserJSON: Data(contentsOf: palletTownURL()))
    }

    private func palletTownURL() throws -> URL {
        let url = packageRoot().appendingPathComponent("Samples/PalletTown.json")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path), url.path)
        return url
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func mapJSON(ids: [Int], attributes: [Int]) -> String {
        let idsText = ids.map(String.init).joined(separator: ", ")
        let attributesText = attributes.map(String.init).joined(separator: ", ")
        return """
        {
          "map_id": "MAP_X",
          "name": "X",
          "layout_id": "LAYOUT_X",
          "dimensions": {"width_metatiles": 1, "height_metatiles": 1},
          "tilesets": {"primary": "a", "secondary": "b"},
          "music": "M",
          "weather": "W",
          "map_type": "T",
          "blockdata": {"metatile_ids": [\(idsText)], "map_attributes": [\(attributesText)]}
        }
        """
    }
}
