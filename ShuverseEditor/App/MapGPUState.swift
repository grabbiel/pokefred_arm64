import Foundation
import Metal
import ShuverseMapModel

/// Triple-buffered `MTLStorageModeShared` storage. Apple Silicon is UMA, so
/// the CPU writes a slot the GPU is not reading. `makeBuffer` runs when the
/// ring is created or when a map outgrows it, not when the selection changes.
final class SharedRingBuffer {
    let label: String
    private let device: MTLDevice
    private var capacity: RingCapacity
    private(set) var buffers: [MTLBuffer]

    init?(device: MTLDevice, bytes: Int, label: String) {
        self.device = device
        self.label = label
        self.capacity = RingCapacity(bytes: max(bytes, 16))
        guard let buffers = Self.allocate(device: device, bytes: self.capacity.bytes, label: label) else {
            return nil
        }
        self.buffers = buffers
    }

    var byteCapacity: Int { capacity.bytes }

    /// Grows storage when `byteCount` does not fit. `.grew` means every slot
    /// must be rewritten. `.failed` leaves the previous buffers in place.
    func ensure(byteCount: Int) -> RingEnsure {
        var next = capacity
        guard next.prepare(byteCount: byteCount) else { return .fit }
        guard let buffers = Self.allocate(device: device, bytes: next.bytes, label: label) else {
            return .failed
        }
        capacity = next
        self.buffers = buffers
        return .grew
    }

    func write(bytes: UnsafeRawPointer, length: Int, slot: Int) {
        buffers[slot].contents().copyMemory(from: bytes, byteCount: length)
    }

    private static func allocate(device: MTLDevice, bytes: Int, label: String) -> [MTLBuffer]? {
        let length = max(bytes, 16)
        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(FrameRing.slotCount)
        for index in 0..<FrameRing.slotCount {
            guard let buffer = device.makeBuffer(length: length, options: [.storageModeShared]) else {
                return nil
            }
            buffer.label = "\(label)[\(index)]"
            buffers.append(buffer)
        }
        return buffers
    }
}

enum RingEnsure {
    case fit
    case grew
    case failed
}

final class MapGPUState {
    private(set) var metalError: String?

    private var tilePipeline: MTLRenderPipelineState?
    private var canopyPipeline: MTLRenderPipelineState?
    private var spritePipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var tileCorners: MTLBuffer?
    private var spriteCorners: MTLBuffer?
    private var uniformRing: SharedRingBuffer?
    private var gridRing: SharedRingBuffer?
    private var markerRing: SharedRingBuffer?
    private var canopyRing: SharedRingBuffer?
    private var spriteRing: SharedRingBuffer?
    private var selectionRing: SharedRingBuffer?
    private var indexRing: SharedRingBuffer?
    private var indexTextures: [MTLTexture] = []
    private var cpuIndices: [UInt8] = []
    private var animSpans: [AtlasRowSpan] = []
    private var animDirty = RingSlotDirty(allDirty: false)
    private var atlasWidth = 0
    private var atlasHeight = 0
    private var atlasRowBytes = 0
    private var paletteRGB555: MTLBuffer?
    private var metatileTable: MTLBuffer?
    private var uploadFailed = false
    private var statusNote: String?
    private(set) var tilesetReady = false
    private var texturedGround = false

    var note: String? { metalError ?? statusNote }

    func prepare(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        do {
            let library = try device.makeLibrary(source: MapShaders.source, options: MapShaders.compileOptions())
            tilePipeline = try makePipeline(
                device: device,
                library: library,
                vertexName: MapShaders.vertexFunction,
                fragmentName: MapShaders.tileFragmentFunction,
                vertexDescriptor: MapShaders.tileVertexDescriptor(),
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                label: "map-tiles"
            )
            canopyPipeline = try makePipeline(
                device: device,
                library: library,
                vertexName: MapShaders.canopyVertexFunction,
                fragmentName: MapShaders.canopyFragmentFunction,
                vertexDescriptor: MapShaders.canopyVertexDescriptor(),
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                label: "map-canopy"
            )
            spritePipeline = try makePipeline(
                device: device,
                library: library,
                vertexName: MapShaders.spriteVertexFunction,
                fragmentName: MapShaders.fragmentFunction,
                vertexDescriptor: MapShaders.spriteVertexDescriptor(),
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                label: "map-sprites"
            )
            guard let depthState = device.makeDepthStencilState(descriptor: MapShaders.depthStencilDescriptor()) else {
                throw MapGPUError.depthState
            }
            self.depthState = depthState
            guard let tileCorners = makeStaticBuffer(device: device, floats: Self.tileCornerFloats, label: "tile-corners"),
                  let spriteCorners = makeStaticBuffer(device: device, floats: Self.spriteCornerFloats, label: "sprite-corners"),
                  let uniformRing = SharedRingBuffer(device: device, bytes: 256, label: "uniforms"),
                  let gridRing = SharedRingBuffer(
                    device: device,
                    bytes: MapGPULayout.initialGridCells * MapGPULayout.gridWordBytes,
                    label: "metatile-grid"
                  ),
                  let markerRing = SharedRingBuffer(
                    device: device,
                    bytes: MapGPULayout.initialMarkerInstances * MapGPULayout.quadInstanceBytes,
                    label: "markers"
                  ),
                  let canopyRing = SharedRingBuffer(
                    device: device,
                    bytes: MapGPULayout.initialCanopyInstances * MapGPULayout.canopyInstanceBytes,
                    label: "canopy"
                  ),
                  let spriteRing = SharedRingBuffer(
                    device: device,
                    bytes: MapGPULayout.initialSpriteInstances * MapGPULayout.quadInstanceBytes,
                    label: "sprites"
                  ),
                  let selectionRing = SharedRingBuffer(
                    device: device,
                    bytes: MapGPULayout.selectionInstances * MapGPULayout.quadInstanceBytes,
                    label: "selection"
                  ) else {
                throw MapGPUError.bufferAllocation
            }
            self.tileCorners = tileCorners
            self.spriteCorners = spriteCorners
            self.uniformRing = uniformRing
            self.gridRing = gridRing
            self.markerRing = markerRing
            self.canopyRing = canopyRing
            self.spriteRing = spriteRing
            self.selectionRing = selectionRing
            metalError = nil
        } catch {
            metalError = error.localizedDescription
        }
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        slot: Int,
        grid: MapMetatileGrid?,
        canopy: [MapCanopyInstance],
        sprites: [MapQuadInstance],
        markers: [MapQuadInstance],
        selection: [MapQuadInstance],
        uniforms: MapGPUUniforms,
        gridDirty: inout RingSlotDirty,
        canopyDirty: inout RingSlotDirty,
        spriteDirty: inout RingSlotDirty,
        markerDirty: inout RingSlotDirty,
        selectionDirty: inout RingSlotDirty
    ) -> Bool {
        guard metalError == nil,
              let tilePipeline,
              let canopyPipeline,
              let spritePipeline,
              let depthState,
              let tileCorners,
              let spriteCorners,
              let uniformRing,
              let gridRing,
              let canopyRing,
              let spriteRing,
              let markerRing,
              let selectionRing else {
            return true
        }

        uploadFailed = false
        upload(
            slot: slot,
            grid: grid,
            canopy: canopy,
            sprites: sprites,
            markers: markers,
            selection: selection,
            uniforms: uniforms,
            gridRing: gridRing,
            canopyRing: canopyRing,
            spriteRing: spriteRing,
            markerRing: markerRing,
            selectionRing: selectionRing,
            uniformRing: uniformRing,
            gridDirty: &gridDirty,
            canopyDirty: &canopyDirty,
            spriteDirty: &spriteDirty,
            markerDirty: &markerDirty,
            selectionDirty: &selectionDirty
        )
        guard !uploadFailed else { return false }
        guard flushTilesetAnimation(slot: slot) else { return false }

        let cells = grid?.cellCount ?? 0
        let canDraw = cells > 0 && uniforms.viewportWidth > 1 && uniforms.viewportHeight > 1 && uniforms.pointsPerMetatile > 0
        let textured = canDraw && texturedGround && indexTextures.indices.contains(slot)
        // Sprites, then canopy, then ground. Ground is later and opaque.
        // Less-than depth keeps sprites (0.20) in front of the leaves (0.40)
        // and both in front of ground (0.70). One encoder, so color stays on-chip.
        if textured, !sprites.isEmpty {
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(spriteCorners, offset: 0, index: 0)
            encoder.setVertexBuffer(spriteRing.buffers[slot], offset: 0, index: 1)
            encoder.setVertexBuffer(uniformRing.buffers[slot], offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sprites.count)
        }

        if textured, !canopy.isEmpty, let paletteRGB555, let metatileTable {
            encoder.setRenderPipelineState(canopyPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(tileCorners, offset: 0, index: 0)
            encoder.setVertexBuffer(canopyRing.buffers[slot], offset: 0, index: 1)
            encoder.setVertexBuffer(uniformRing.buffers[slot], offset: 0, index: 2)
            encoder.setVertexBuffer(gridRing.buffers[slot], offset: 0, index: 3)
            encoder.setFragmentTexture(indexTextures[slot], index: 0)
            encoder.setFragmentBuffer(paletteRGB555, offset: 0, index: 0)
            encoder.setFragmentBuffer(metatileTable, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: canopy.count)
        }

        if textured, let paletteRGB555, let metatileTable {
            encoder.setRenderPipelineState(tilePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(tileCorners, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformRing.buffers[slot], offset: 0, index: 1)
            encoder.setVertexBuffer(gridRing.buffers[slot], offset: 0, index: 2)
            encoder.setFragmentTexture(indexTextures[slot], index: 0)
            encoder.setFragmentBuffer(paletteRGB555, offset: 0, index: 0)
            encoder.setFragmentBuffer(metatileTable, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cells)
        }

        if !markers.isEmpty || !selection.isEmpty {
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(spriteCorners, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformRing.buffers[slot], offset: 0, index: 2)
            if !markers.isEmpty {
                encoder.setVertexBuffer(markerRing.buffers[slot], offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: markers.count)
            }
            if !selection.isEmpty {
                encoder.setVertexBuffer(selectionRing.buffers[slot], offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: selection.count)
            }
        }

        return true
    }

    private func upload(
        slot: Int,
        grid: MapMetatileGrid?,
        canopy: [MapCanopyInstance],
        sprites: [MapQuadInstance],
        markers: [MapQuadInstance],
        selection: [MapQuadInstance],
        uniforms: MapGPUUniforms,
        gridRing: SharedRingBuffer,
        canopyRing: SharedRingBuffer,
        spriteRing: SharedRingBuffer,
        markerRing: SharedRingBuffer,
        selectionRing: SharedRingBuffer,
        uniformRing: SharedRingBuffer,
        gridDirty: inout RingSlotDirty,
        canopyDirty: inout RingSlotDirty,
        spriteDirty: inout RingSlotDirty,
        markerDirty: inout RingSlotDirty,
        selectionDirty: inout RingSlotDirty
    ) {
        let words = grid?.words ?? []
        writeIfDirty(
            words,
            slot: slot,
            ring: gridRing,
            dirty: &gridDirty,
            minimumBytes: MapGPULayout.gridWordBytes
        )
        writeIfDirty(
            canopy,
            slot: slot,
            ring: canopyRing,
            dirty: &canopyDirty,
            minimumBytes: MapGPULayout.canopyInstanceBytes
        )
        writeIfDirty(
            sprites,
            slot: slot,
            ring: spriteRing,
            dirty: &spriteDirty,
            minimumBytes: MapGPULayout.quadInstanceBytes
        )
        writeIfDirty(
            markers,
            slot: slot,
            ring: markerRing,
            dirty: &markerDirty,
            minimumBytes: MapGPULayout.quadInstanceBytes
        )
        writeIfDirty(
            selection,
            slot: slot,
            ring: selectionRing,
            dirty: &selectionDirty,
            minimumBytes: MapGPULayout.quadInstanceBytes
        )

        var uniforms = uniforms
        withUnsafeBytes(of: &uniforms) { raw in
            guard let base = raw.baseAddress else { return }
            uniformRing.write(bytes: base, length: MemoryLayout<MapGPUUniforms>.size, slot: slot)
        }
    }

    private func writeIfDirty<T>(
        _ values: [T],
        slot: Int,
        ring: SharedRingBuffer,
        dirty: inout RingSlotDirty,
        minimumBytes: Int
    ) {
        let byteCount = values.count * MemoryLayout<T>.stride
        switch ring.ensure(byteCount: max(byteCount, minimumBytes)) {
        case .grew:
            dirty.markAllDirty()
        case .failed:
            failUpload("Could not allocate a \(max(byteCount, minimumBytes))-byte shared ring (\(ring.label)).")
            return
        case .fit:
            break
        }
        guard byteCount <= ring.byteCapacity else {
            failUpload("Need \(byteCount) bytes in \(ring.label); capacity is \(ring.byteCapacity).")
            return
        }
        guard dirty.isDirty(slot) else { return }
        if byteCount > 0 {
            values.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                ring.write(bytes: base, length: raw.count, slot: slot)
            }
        }
        dirty.markClean(slot)
    }

    func setTexturedGround(_ enabled: Bool) {
        texturedGround = enabled && tilesetReady
    }

    func setStatusNote(_ note: String?) {
        statusNote = note
    }

    func failTileset(_ detail: String) {
        tilesetReady = false
        texturedGround = false
        statusNote = "Shared tileset upload failed. \(detail)"
    }

    /// Copies the index atlas into a triple `MTLStorageModeShared` ring and views
    /// each slot as an r8Uint texture. Palette and metatile entries stay single
    /// shared buffers. Row stride follows `minimumLinearTextureAlignment`.
    /// There is no managed blit. Animation later rewrites affected rows in the
    /// free slot via `rewriteIndexRows`.
    func uploadTileset(_ graphics: GBATileset, device: MTLDevice) -> Bool {
        guard graphics.atlasWidth == GBATileset.atlasWidth,
              graphics.atlasHeight == GBATileset.atlasHeight,
              graphics.indices.count == graphics.atlasWidth * graphics.atlasHeight else {
            failTileset(
                "Index atlas is \(graphics.indices.count) bytes for \(graphics.atlasWidth)×\(graphics.atlasHeight); expected \(GBATileset.atlasWidth)×\(GBATileset.atlasHeight)."
            )
            return false
        }
        guard graphics.paletteRGB555.count == GBATileset.paletteBanks * GBATileset.colorsPerPalette else {
            failTileset("RGB555 palette has \(graphics.paletteRGB555.count) colors.")
            return false
        }
        guard graphics.metatileEntries.count == GBATileset.metatileCount * GBATileset.tilesPerMetatile else {
            failTileset("Metatile table has \(graphics.metatileEntries.count) entries.")
            return false
        }

        let alignment = max(device.minimumLinearTextureAlignment(for: .r8Uint), 1)
        let rowBytes = ((graphics.atlasWidth + alignment - 1) / alignment) * alignment
        let length = rowBytes * graphics.atlasHeight
        // One shared atlas per in-flight frame. Animation rewrites rows only on
        // the slot the GPU has finished reading.
        guard let ring = SharedRingBuffer(device: device, bytes: length, label: "tileset-indices") else {
            failTileset("Could not allocate a \(length)-byte shared index buffer.")
            return false
        }
        let fullSpan = AtlasRowSpan(firstRow: 0, rowCount: graphics.atlasHeight)
        for buffer in ring.buffers {
            buffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: length)
            let copied = graphics.indices.withUnsafeBytes { raw in
                IndexAtlasRows.copy(
                    indices: raw,
                    atlasWidth: graphics.atlasWidth,
                    atlasHeight: graphics.atlasHeight,
                    spans: [fullSpan],
                    destination: buffer.contents(),
                    rowBytes: rowBytes
                )
            }
            guard copied else {
                failTileset("Could not read the index atlas bytes.")
                return false
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: graphics.atlasWidth,
            height: graphics.atlasHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        var textures: [MTLTexture] = []
        textures.reserveCapacity(ring.buffers.count)
        for buffer in ring.buffers {
            guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: rowBytes) else {
                failTileset(
                    "Could not create a shared r8Uint texture view (\(graphics.atlasWidth)×\(graphics.atlasHeight), row \(rowBytes), alignment \(alignment))."
                )
                return false
            }
            texture.label = "tileset-indices"
            textures.append(texture)
        }

        let paletteBytes = graphics.paletteRGB555.count * MemoryLayout<UInt16>.stride
        guard let palette = graphics.paletteRGB555.withUnsafeBytes({ raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: paletteBytes, options: [.storageModeShared])
        }) else {
            failTileset("Could not allocate the shared RGB555 palette buffer.")
            return false
        }
        palette.label = "tileset-rgb555"

        let tableBytes = graphics.metatileEntries.count * MemoryLayout<UInt16>.stride
        guard let table = graphics.metatileEntries.withUnsafeBytes({ raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: tableBytes, options: [.storageModeShared])
        }) else {
            failTileset("Could not allocate the shared metatile table.")
            return false
        }
        table.label = "metatile-entries"

        indexRing = ring
        indexTextures = textures
        cpuIndices = Array(graphics.indices)
        animSpans = []
        animDirty = RingSlotDirty(allDirty: false)
        atlasWidth = graphics.atlasWidth
        atlasHeight = graphics.atlasHeight
        atlasRowBytes = rowBytes
        paletteRGB555 = palette
        metatileTable = table
        tilesetReady = true
        texturedGround = true
        statusNote = nil
        return true
    }

    /// Keeps a CPU copy of the index atlas and marks every ring slot dirty.
    /// `encode` memcpy's `spans` into the slot the GPU is not reading. A slot
    /// that has not flushed yet keeps its earlier row ranges, so a later clip
    /// does not drop the previous clip's rows.
    func rewriteIndexRows(_ indices: [UInt8], spans: [AtlasRowSpan]) -> Bool {
        guard tilesetReady, atlasWidth > 0, atlasHeight > 0, indexRing != nil else {
            failTileset("Index atlas is not ready for animation.")
            return false
        }
        guard indices.count == atlasWidth * atlasHeight else {
            failTileset("Index atlas is \(indices.count) bytes; expected \(atlasWidth * atlasHeight).")
            return false
        }
        guard !spans.isEmpty else { return true }
        for span in spans {
            guard span.firstRow >= 0, span.rowCount > 0, span.firstRow + span.rowCount <= atlasHeight else {
                failTileset("Animation rows \(span.firstRow)..<\(span.firstRow + span.rowCount) do not fit the index atlas.")
                return false
            }
        }
        cpuIndices = Array(indices)
        if animDirty.isAnyDirty {
            animSpans = AtlasRowSpan.union(animSpans + spans)
        } else {
            animSpans = AtlasRowSpan.union(spans)
        }
        animDirty.markAllDirty()
        return true
    }

    /// Copies the staged animation rows into one shared atlas slot.
    private func flushTilesetAnimation(slot: Int) -> Bool {
        guard tilesetReady, animDirty.isDirty(slot) else { return true }
        guard let ring = indexRing, ring.buffers.indices.contains(slot), atlasRowBytes >= atlasWidth else {
            failTileset("Shared index atlas ring is missing a slot.")
            uploadFailed = true
            return false
        }
        let buffer = ring.buffers[slot]
        let copied = cpuIndices.withUnsafeBytes { raw in
            IndexAtlasRows.copy(
                indices: raw,
                atlasWidth: atlasWidth,
                atlasHeight: atlasHeight,
                spans: animSpans,
                destination: buffer.contents(),
                rowBytes: atlasRowBytes
            )
        }
        guard copied else {
            failTileset("Could not copy tileset animation rows into the shared index atlas.")
            uploadFailed = true
            return false
        }
        animDirty.markClean(slot)
        return true
    }

    private func failUpload(_ detail: String) {
        uploadFailed = true
        metalError = "Shared ring upload failed. \(detail)"
    }

    private func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String,
        vertexDescriptor: MTLVertexDescriptor,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw MapGPUError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        if let color = descriptor.colorAttachments[0] {
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .sourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makeStaticBuffer(device: MTLDevice, floats: [Float], label: String) -> MTLBuffer? {
        let byteCount = floats.count * MemoryLayout<Float>.stride
        let buffer = floats.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: byteCount, options: [.storageModeShared])
        }
        buffer?.label = label
        return buffer
    }

    private static let tileCornerFloats: [Float] = [
        0, 0, 1, 0, 1, 1,
        0, 0, 1, 1, 0, 1,
    ]

    private static let spriteCornerFloats: [Float] = [
        -1, -1, 1, -1, 1, 1,
        -1, -1, 1, 1, -1, 1,
    ]
}

private enum MapGPUError: LocalizedError {
    case missingFunction
    case bufferAllocation
    case depthState

    var errorDescription: String? {
        switch self {
        case .missingFunction:
            return "Metal shader is missing a map entry point."
        case .bufferAllocation:
            return "Could not allocate shared Metal buffers."
        case .depthState:
            return "Could not create the map depth-stencil state."
        }
    }
}
