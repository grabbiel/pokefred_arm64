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
        XCTAssertTrue(gpu.contains("dispatchThreadsPerTile"))
        XCTAssertFalse(gpu.contains("GLFW"))
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
