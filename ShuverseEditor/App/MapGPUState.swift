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
    private(set) var tileOverlayReady = false
    private var tileOverlayFault: String?

    private var tilePipeline: MTLRenderPipelineState?
    private var spritePipeline: MTLRenderPipelineState?
    private var tileOverlayPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var tileCorners: MTLBuffer?
    private var spriteCorners: MTLBuffer?
    private var palette: MTLBuffer?
    private var uniformRing: SharedRingBuffer?
    private var gridRing: SharedRingBuffer?
    private var markerRing: SharedRingBuffer?
    private var selectionRing: SharedRingBuffer?
    private var uploadFailed = false

    var note: String? {
        metalError ?? tileOverlayFault
    }

    var tileSize: (width: Int, height: Int) {
        guard let pipeline = tileOverlayPipeline, pipeline.tileWidth > 0, pipeline.tileHeight > 0 else {
            return (0, 0)
        }
        return (pipeline.tileWidth, pipeline.tileHeight)
    }

    func prepare(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        tileOverlayReady = false
        tileOverlayFault = nil
        do {
            let library = try device.makeLibrary(source: MapShaders.source, options: MapShaders.compileOptions())
            tilePipeline = try makePipeline(
                device: device,
                library: library,
                vertexName: MapShaders.vertexFunction,
                fragmentName: MapShaders.fragmentFunction,
                vertexDescriptor: MapShaders.tileVertexDescriptor(),
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                tileFunction: nil,
                label: "map-tiles"
            )
            spritePipeline = try makePipeline(
                device: device,
                library: library,
                vertexName: MapShaders.spriteVertexFunction,
                fragmentName: MapShaders.fragmentFunction,
                vertexDescriptor: MapShaders.spriteVertexDescriptor(),
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                tileFunction: nil,
                label: "map-sprites"
            )
            guard let depthState = device.makeDepthStencilState(descriptor: MapShaders.depthStencilDescriptor()) else {
                throw MapGPUError.depthState
            }
            self.depthState = depthState
            guard let tileCorners = makeStaticBuffer(device: device, floats: Self.tileCornerFloats, label: "tile-corners"),
                  let spriteCorners = makeStaticBuffer(device: device, floats: Self.spriteCornerFloats, label: "sprite-corners"),
                  let palette = makeStaticBuffer(device: device, floats: MetatileColor.paletteComponents(), label: "metatile-palette"),
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
                  let selectionRing = SharedRingBuffer(
                    device: device,
                    bytes: MapGPULayout.selectionInstances * MapGPULayout.quadInstanceBytes,
                    label: "selection"
                  ) else {
                throw MapGPUError.bufferAllocation
            }
            self.tileCorners = tileCorners
            self.spriteCorners = spriteCorners
            self.palette = palette
            self.uniformRing = uniformRing
            self.gridRing = gridRing
            self.markerRing = markerRing
            self.selectionRing = selectionRing
            metalError = nil
            attachTileOverlay(device: device, library: library, colorFormat: colorFormat, depthFormat: depthFormat)
        } catch {
            metalError = error.localizedDescription
        }
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        slot: Int,
        grid: MapMetatileGrid?,
        markers: [MapQuadInstance],
        selection: [MapQuadInstance],
        uniforms: MapGPUUniforms,
        gridDirty: inout RingSlotDirty,
        markerDirty: inout RingSlotDirty,
        selectionDirty: inout RingSlotDirty
    ) {
        guard metalError == nil,
              let tilePipeline,
              let spritePipeline,
              let depthState,
              let tileCorners,
              let spriteCorners,
              let palette,
              let uniformRing,
              let gridRing,
              let markerRing,
              let selectionRing else {
            return
        }

        uploadFailed = false
        upload(
            slot: slot,
            grid: grid,
            markers: markers,
            selection: selection,
            uniforms: uniforms,
            gridRing: gridRing,
            markerRing: markerRing,
            selectionRing: selectionRing,
            uniformRing: uniformRing,
            gridDirty: &gridDirty,
            markerDirty: &markerDirty,
            selectionDirty: &selectionDirty
        )
        guard !uploadFailed else { return }

        let cells = grid?.cellCount ?? 0
        let canDraw = cells > 0 && uniforms.viewportWidth > 1 && uniforms.viewportHeight > 1 && uniforms.pointsPerMetatile > 0
        if canDraw {
            encoder.setRenderPipelineState(tilePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(tileCorners, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformRing.buffers[slot], offset: 0, index: 1)
            encoder.setVertexBuffer(gridRing.buffers[slot], offset: 0, index: 2)
            encoder.setVertexBuffer(palette, offset: 0, index: 3)
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

        // One pass. Depth is `.dontCare` on store, so the overlay kernel only
        // has to write the color imageblock. Dispatch is opt-in: the draw
        // pipelines have no tile function, and a skipped dispatch still stores color.
        if uniforms.overlayFlags != 0, tileOverlayReady, canDraw,
           let overlay = tileOverlayPipeline, overlay.tileWidth > 0, overlay.tileHeight > 0 {
            encoder.setRenderPipelineState(overlay)
            encoder.setTileBuffer(uniformRing.buffers[slot], offset: 0, index: 0)
            encoder.setTileBuffer(gridRing.buffers[slot], offset: 0, index: 1)
            encoder.dispatchThreadsPerTile(MTLSize(width: overlay.tileWidth, height: overlay.tileHeight, depth: 1))
        }
    }

    private func upload(
        slot: Int,
        grid: MapMetatileGrid?,
        markers: [MapQuadInstance],
        selection: [MapQuadInstance],
        uniforms: MapGPUUniforms,
        gridRing: SharedRingBuffer,
        markerRing: SharedRingBuffer,
        selectionRing: SharedRingBuffer,
        uniformRing: SharedRingBuffer,
        gridDirty: inout RingSlotDirty,
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
            uploadFailed = true
            return
        case .fit:
            break
        }
        guard byteCount <= ring.byteCapacity else {
            uploadFailed = true
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

    private func attachTileOverlay(
        device: MTLDevice,
        library: MTLLibrary,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat
    ) {
        guard supportsTileShaders(device),
              let tileFunction = library.makeFunction(name: MapShaders.tileFunction) else {
            return
        }
        do {
            tileOverlayPipeline = try makePipeline(
                device: device,
                library: library,
                vertexName: MapShaders.vertexFunction,
                fragmentName: MapShaders.fragmentFunction,
                vertexDescriptor: MapShaders.tileVertexDescriptor(),
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                tileFunction: tileFunction,
                label: "map-tile-overlay"
            )
            tileOverlayReady = true
            tileOverlayFault = nil
        } catch {
            tileOverlayReady = false
            tileOverlayFault = "Tile overlay pipeline unavailable (\(error.localizedDescription)). Grid draw is active."
        }
    }

    private func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String,
        vertexDescriptor: MTLVertexDescriptor,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        tileFunction: MTLFunction?,
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
        if let tileFunction {
            descriptor.tileFunction = tileFunction
            descriptor.threadgroupSizeMatchesTileSize = true
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

    private func supportsTileShaders(_ device: MTLDevice) -> Bool {
        device.supportsFamily(.apple7)
    }

    private static let tileCornerFloats: [Float] = {
        let inset = MapGeometry.tileInset
        let outer = 1 - inset
        return [
            inset, inset, outer, inset, outer, outer,
            inset, inset, outer, outer, inset, outer,
        ]
    }()

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
