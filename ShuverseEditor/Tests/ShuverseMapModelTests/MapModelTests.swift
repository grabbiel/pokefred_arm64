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

    func testMeshVertexIsPackedForMetal() {
        XCTAssertEqual(MemoryLayout<MeshVertex>.stride, 24)
        XCTAssertEqual(MemoryLayout<MeshVertex>.alignment, 4)
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

    func testDrawListCoversPalletTownGrid() throws {
        let map = try loadPalletTown()
        let list = MapDrawListBuilder.make(map: map, selectedX: nil, selectedY: nil)
        let eventCount = map.objectEvents.count + map.warpEvents.count + map.coordEvents.count + map.bgEvents.count
        XCTAssertEqual(eventCount, 14)
        XCTAssertEqual(list.vertices.count, (map.cells.count + eventCount) * 6)

        let rect = MapGeometry.tileRect(x: 0, y: 0)
        XCTAssertEqual(list.vertices[0].x, rect.x0, accuracy: 0.0001)
        XCTAssertEqual(list.vertices[0].y, rect.y0, accuracy: 0.0001)

        let second = list.vertices[6]
        let secondRect = MapGeometry.tileRect(x: 1, y: 0)
        XCTAssertEqual(second.x, secondRect.x0, accuracy: 0.0001)
        let firstColor = MetatileColor.components(for: 28)
        let nextColor = MetatileColor.components(for: 29)
        XCTAssertEqual(list.vertices[0].r, firstColor.r, accuracy: 0.0001)
        XCTAssertEqual(list.vertices[0].g, firstColor.g, accuracy: 0.0001)
        XCTAssertEqual(list.vertices[0].b, firstColor.b, accuracy: 0.0001)
        XCTAssertTrue(firstColor.r != nextColor.r || firstColor.g != nextColor.g || firstColor.b != nextColor.b)

        let below = list.vertices[24 * 6]
        XCTAssertEqual(below.y, MapGeometry.tileRect(x: 0, y: 1).y0, accuracy: 0.0001)
        XCTAssertGreaterThan(below.y, list.vertices[0].y)

        let selected = MapDrawListBuilder.make(map: map, selectedX: 6, selectedY: 7)
        XCTAssertEqual(selected.vertices.count, list.vertices.count + 24)
        XCTAssertEqual(
            MapDrawListBuilder.make(map: map, selectedX: 99, selectedY: 0).vertices.count,
            list.vertices.count
        )
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
