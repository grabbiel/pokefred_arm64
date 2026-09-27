import AppKit
import Metal
import MetalKit
import ShuverseMapModel

final class MapCanvasView: MTKView, MTKViewDelegate {
    var onInspect: ((CellInspection?) -> Void)?
    var onCameraChange: ((String) -> Void)?
    var onRendererNote: ((String?) -> Void)?
    var onDropURL: ((URL) -> Void)?

    /// Imageblock overlay bits (`MapOverlayFlags`). Default 0 keeps selection
    /// as depth-tested quads. Non-zero dispatches `map_tile_overlay`.
    var overlayFlags: UInt32 = 0 {
        didSet {
            guard overlayFlags != oldValue else { return }
            needsDisplay = true
        }
    }

    private var map: MapDocument?
    private var selection: (x: Int, y: Int)?
    private var camera = MapCamera(originX: 0, originY: 0, pointsPerMetatile: 16)
    private var needsFit = false

    private var grid: MapMetatileGrid?
    private var markers: [MapQuadInstance] = []
    private var selectionInstances: [MapQuadInstance] = []
    private var gridDirty = RingSlotDirty()
    private var markerDirty = RingSlotDirty()
    private var selectionDirty = RingSlotDirty()

    private var commandQueue: MTLCommandQueue?
    private let gpu = MapGPUState()
    private let inflightFrames = DispatchSemaphore(value: FrameRing.slotCount)
    private var frameRing = FrameRing()
    private var metalError: String?

    private var dragStart: NSPoint?
    private var dragCamera: MapCamera?
    private var dragDistance: CGFloat = 0

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = device ?? MTLCreateSystemDefaultDevice()
        configure()
    }

    func setMap(_ map: MapDocument?, fit: Bool) {
        self.map = map
        selection = nil
        if let map {
            grid = MapMetatileGrid.make(map: map)
            markers = MapDrawListBuilder.markers(on: map)
        } else {
            grid = nil
            markers = []
        }
        selectionInstances = []
        gridDirty.markAllDirty()
        markerDirty.markAllDirty()
        selectionDirty.markAllDirty()
        if fit {
            needsFit = true
            fitIfPossible()
        }
        needsDisplay = true
        onInspect?(nil)
        onCameraChange?(statusLine())
    }

    func statusLine() -> String {
        guard let map else { return "No map" }
        var text = "\(map.name)   \(map.size.width)×\(map.size.height)   "
        text += String(format: "%.1f pt/metatile", camera.pointsPerMetatile)
        if let selection {
            text += "   cell \(selection.x), \(selection.y)"
        }
        return text
    }

    @objc func zoomIn(_ sender: Any?) {
        zoom(by: 1.15, around: centerPoint)
        publishCamera()
    }

    @objc func zoomOut(_ sender: Any?) {
        zoom(by: 1 / 1.15, around: centerPoint)
        publishCamera()
    }

    @objc func fitMap(_ sender: Any?) {
        needsFit = true
        fitIfPossible()
        publishCamera()
    }

    func reportRendererStatus() {
        onRendererNote?(metalError)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        preparePass(descriptor)
        inflightFrames.wait()
        var committed = false
        defer {
            if !committed {
                inflightFrames.signal()
            }
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        let slot = frameRing.nextSlot()
        commandBuffer.label = "map-frame"
        gpu.encode(
            encoder: encoder,
            slot: slot,
            grid: grid,
            markers: markers,
            selection: selectionInstances,
            uniforms: makeUniforms(tileWidth: encoder.tileWidth, tileHeight: encoder.tileHeight),
            gridDirty: &gridDirty,
            markerDirty: &markerDirty,
            selectionDirty: &selectionDirty
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [inflightFrames] _ in
            inflightFrames.signal()
        }
        committed = true
        commandBuffer.commit()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard needsFit else { return }
        fitIfPossible()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCamera = camera
        dragDistance = 0
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let dragCamera else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragDistance = hypot(point.x - dragStart.x, point.y - dragStart.y)
        let height = Float(bounds.height)
        camera = camera.moved(
            from: dragCamera,
            startViewX: Float(dragStart.x),
            startViewYFromTop: height - Float(dragStart.y),
            viewX: Float(point.x),
            viewYFromTop: height - Float(point.y)
        )
        publishCamera()
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        let point = convert(event.locationInWindow, from: nil)
        if dragDistance < 3 {
            inspect(at: point)
        }
        dragStart = nil
        dragCamera = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let command = event.modifierFlags.contains(.command)
        if event.hasPreciseScrollingDeltas && !command {
            let height = Float(bounds.height)
            let shiftedX = point.x + event.scrollingDeltaX
            let shiftedY = point.y + event.scrollingDeltaY
            camera = camera.moved(
                from: camera,
                startViewX: Float(point.x),
                startViewYFromTop: height - Float(point.y),
                viewX: Float(shiftedX),
                viewYFromTop: height - Float(shiftedY)
            )
        } else {
            let steps = event.hasPreciseScrollingDeltas
                ? Float(event.scrollingDeltaY) / 8
                : Float(event.scrollingDeltaY)
            guard steps != 0 else { return }
            zoom(by: pow(1.12, steps), around: point)
        }
        publishCamera()
    }

    override func magnify(with event: NSEvent) {
        let factor = Float(1 + event.magnification)
        guard factor > 0 else { return }
        zoom(by: factor, around: convert(event.locationInWindow, from: nil))
        publishCamera()
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        let step: Float = 64
        switch scalar {
        case "+", "=":
            zoom(by: 1.15, around: centerPoint)
        case "-", "_":
            zoom(by: 1 / 1.15, around: centerPoint)
        case "0", "f", "F":
            needsFit = true
            fitIfPossible()
        case UnicodeScalar(NSUpArrowFunctionKey)!:
            pan(dx: 0, dyFromTop: -step)
        case UnicodeScalar(NSDownArrowFunctionKey)!:
            pan(dx: 0, dyFromTop: step)
        case UnicodeScalar(NSLeftArrowFunctionKey)!:
            pan(dx: -step, dyFromTop: 0)
        case UnicodeScalar(NSRightArrowFunctionKey)!:
            pan(dx: step, dyFromTop: 0)
        default:
            super.keyDown(with: event)
            return
        }
        publishCamera()
    }

    private func configure() {
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        clearDepth = Double(MapDepth.clear)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        registerForDraggedTypes([.fileURL])
        prepareMetal()
    }

    private func preparePass(_ descriptor: MTLRenderPassDescriptor) {
        if let color = descriptor.colorAttachments[0] {
            color.loadAction = .clear
            color.storeAction = .store
            color.clearColor = clearColor
        }
        // Depth is only used inside this pass. TBDR can drop it instead of
        // writing the attachment back to memory.
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = Double(MapDepth.clear)
        descriptor.tileWidth = MapGPUState.tileWidth
        descriptor.tileHeight = MapGPUState.tileHeight
    }

    private func prepareMetal() {
        guard let device else {
            metalError = "Metal is not available on this Mac."
            onRendererNote?(metalError)
            return
        }
        commandQueue = device.makeCommandQueue()
        gpu.prepare(device: device, colorFormat: colorPixelFormat, depthFormat: depthStencilPixelFormat)
        metalError = gpu.note
        onRendererNote?(metalError)
    }

    private func makeUniforms(tileWidth: Int, tileHeight: Int) -> MapGPUUniforms {
        let scale: Float
        if bounds.width > 1, drawableSize.width > 0 {
            scale = Float(drawableSize.width / bounds.width)
        } else {
            scale = 1
        }
        let resolvedTileWidth = tileWidth > 0 ? tileWidth : MapGPUState.tileWidth
        let resolvedTileHeight = tileHeight > 0 ? tileHeight : MapGPUState.tileHeight
        return MapGPUUniforms(
            originX: camera.originX,
            originY: camera.originY,
            viewportWidth: Float(bounds.width),
            viewportHeight: Float(bounds.height),
            pointsPerMetatile: camera.pointsPerMetatile,
            pixelScale: scale,
            gridWidth: UInt32(max(grid?.width ?? 0, 0)),
            gridHeight: UInt32(max(grid?.height ?? 0, 0)),
            selectedX: Int32(selection?.x ?? -1),
            selectedY: Int32(selection?.y ?? -1),
            overlayFlags: overlayFlags,
            tileWidth: UInt32(resolvedTileWidth),
            tileHeight: UInt32(resolvedTileHeight)
        )
    }

    private func inspect(at viewPoint: NSPoint) {
        guard let map else { return }
        let hit = camera.metatile(
            viewX: Float(viewPoint.x),
            viewYFromTop: Float(bounds.height - viewPoint.y),
            map: map
        )
        if let hit {
            selection = (hit.x, hit.y)
            selectionInstances = MapDrawListBuilder.selection(x: hit.x, y: hit.y, on: map)
            onInspect?(map.inspection(x: hit.x, y: hit.y))
        } else {
            selection = nil
            selectionInstances = []
            onInspect?(nil)
        }
        selectionDirty.markAllDirty()
        publishCamera()
    }

    private func fitIfPossible() {
        guard needsFit, let map, bounds.width > 8, bounds.height > 8 else { return }
        camera = camera.fitting(
            mapWidth: map.size.width,
            mapHeight: map.size.height,
            viewportWidth: Float(bounds.width),
            viewportHeight: Float(bounds.height)
        )
        needsFit = false
        onCameraChange?(statusLine())
    }

    private func zoom(by factor: Float, around viewPoint: NSPoint) {
        camera = camera.zoom(
            by: factor,
            aroundViewX: Float(viewPoint.x),
            viewYFromTop: Float(bounds.height - viewPoint.y)
        )
        needsDisplay = true
    }

    private func pan(dx: Float, dyFromTop: Float) {
        guard camera.pointsPerMetatile > 0 else { return }
        camera.originX += dx / camera.pointsPerMetatile
        camera.originY += dyFromTop / camera.pointsPerMetatile
    }

    private var centerPoint: NSPoint {
        NSPoint(x: bounds.midX, y: bounds.midY)
    }

    private func publishCamera() {
        needsDisplay = true
        onCameraChange?(statusLine())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        JSONDrop.fileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = JSONDrop.fileURL(from: sender) else { return false }
        onDropURL?(url)
        return true
    }
}
