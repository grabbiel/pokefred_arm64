import AppKit
import Metal
import MetalKit
import ShuverseMapModel

final class MapCanvasView: MTKView, MTKViewDelegate {
    var onInspect: ((CellInspection?) -> Void)?
    var onCameraChange: ((String) -> Void)?
    var onRendererNote: ((String?) -> Void)?
    var onDropURL: ((URL) -> Void)?

    /// Reserved for a future imageblock overlay (`MapOverlayFlags`). macOS does
    /// not dispatch that kernel; selection stays on the depth-tested quads.
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
    private var canopy: [MapCanopyInstance] = []
    private var sprites: [MapQuadInstance] = []
    private var markers: [MapQuadInstance] = []
    private var selectionInstances: [MapQuadInstance] = []
    private var gridDirty = RingSlotDirty()
    private var canopyDirty = RingSlotDirty()
    private var spriteDirty = RingSlotDirty()
    private var markerDirty = RingSlotDirty()
    private var selectionDirty = RingSlotDirty()

    private var commandQueue: MTLCommandQueue?
    private let gpu = MapGPUState()
    private let inflightFrames = DispatchSemaphore(value: FrameRing.slotCount)
    private var frameRing = FrameRing()
    private var metalError: String?
    private var animBase: GBATileset?
    private var animGraphics: GBATileset?
    private var animPlayer: TilesetAnimPlayer?
    private var animTimer: Timer?
    private var displayedAnimFrame: Int?
    private var displayedFlowerFrame: Int?

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
            canopy = MapDrawListBuilder.canopy(on: map)
            sprites = MapDrawListBuilder.sprites(on: map)
            markers = MapDrawListBuilder.markers(on: map)
        } else {
            grid = nil
            canopy = []
            sprites = []
            markers = []
        }
        selectionInstances = []
        gridDirty.markAllDirty()
        canopyDirty.markAllDirty()
        spriteDirty.markAllDirty()
        markerDirty.markAllDirty()
        selectionDirty.markAllDirty()
        bindTileset(for: map)
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
        if !canopy.isEmpty {
            text += "   canopy \(canopy.count)"
        }
        if !sprites.isEmpty {
            text += "   sprites \(sprites.count)"
        }
        if let displayedAnimFrame {
            text += "   water frame \(displayedAnimFrame)"
        }
        if let displayedFlowerFrame {
            text += "   flower frame \(displayedFlowerFrame)"
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
        let uploaded = gpu.encode(
            encoder: encoder,
            slot: slot,
            grid: grid,
            canopy: canopy,
            sprites: sprites,
            markers: markers,
            selection: selectionInstances,
            uniforms: makeUniforms(),
            gridDirty: &gridDirty,
            canopyDirty: &canopyDirty,
            spriteDirty: &spriteDirty,
            markerDirty: &markerDirty,
            selectionDirty: &selectionDirty
        )
        publishRendererNote()
        if !uploaded {
            let message = gpu.note ?? "Shared ring upload failed."
            assertionFailure(message)
        }
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

    deinit {
        animTimer?.invalidate()
    }

    private func bindTileset(for map: MapDocument?) {
        guard let map else {
            gpu.setTexturedGround(false)
            stopTilesetAnimation()
            return
        }
        guard GBATileset.supports(map.tilesets) else {
            gpu.setTexturedGround(false)
            gpu.setStatusNote("No 4bpp tileset is loaded for this map.")
            stopTilesetAnimation()
            publishRendererNote()
            return
        }
        if !gpu.tilesetReady {
            guard let device else {
                gpu.failTileset("Metal device is missing, so the shared tileset texture was not created.")
                stopTilesetAnimation()
                publishRendererNote()
                assertionFailure(gpu.note ?? "Shared tileset upload failed.")
                return
            }
            guard let directory = MapFileLocator.palletTownTilesetDirectory() else {
                gpu.failTileset("Pallet Town 4bpp tileset files were not found.")
                stopTilesetAnimation()
                publishRendererNote()
                assertionFailure(gpu.note ?? "Shared tileset upload failed.")
                return
            }
            do {
                let graphics = try GBATileset.loadPalletTown(from: directory)
                if !gpu.uploadTileset(graphics, device: device) {
                    stopTilesetAnimation()
                    publishRendererNote()
                    assertionFailure(gpu.note ?? "Shared tileset upload failed.")
                    return
                }
                animBase = graphics
            } catch {
                gpu.failTileset(error.localizedDescription)
                stopTilesetAnimation()
                publishRendererNote()
                assertionFailure(gpu.note ?? "Shared tileset upload failed.")
                return
            }
        }
        let started = startTilesetAnimation()
        gpu.setTexturedGround(true)
        if started {
            gpu.setStatusNote(nil)
        }
        publishRendererNote()
    }

    /// 60 Hz stand-in for the pret tileset counter. The view stays paused;
    /// `needsDisplay` is set only when a frame is copied into the atlas.
    private func startTilesetAnimation() -> Bool {
        guard animPlayer == nil else { return true }
        guard let base = animBase else {
            gpu.failTileset("Pallet Town tileset animation has no CPU atlas.")
            reportTilesetFailure()
            return false
        }
        guard let table = PalletTownTilesetAnim.makeTable(from: base), !table.clips.isEmpty else {
            gpu.setStatusNote("Tileset animation stub was not applied.")
            publishRendererNote()
            return false
        }
        var graphics = base
        var spans: [AtlasRowSpan] = []
        spans.reserveCapacity(table.clips.count)
        for clip in table.clips {
            guard let span = TilesetAnimBlit.apply(
                clip,
                frame: 0,
                to: &graphics.indices,
                atlasWidth: graphics.atlasWidth,
                atlasHeight: graphics.atlasHeight
            ) else {
                gpu.failTileset("Could not copy tileset animation frame 0 onto tile \(clip.baseTileId).")
                reportTilesetFailure()
                return false
            }
            spans.append(span)
        }
        guard gpu.rewriteIndexRows(graphics.indices, spans: spans) else {
            reportTilesetFailure()
            return false
        }
        animGraphics = graphics
        animPlayer = TilesetAnimPlayer(table: table)
        displayedAnimFrame = 0
        displayedFlowerFrame = 0
        let timer = Timer(timeInterval: 1.0 / Double(PalletTownTilesetAnim.ticksPerSecond), repeats: true) { [weak self] _ in
            self?.tickTilesetAnimation()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
        onCameraChange?(statusLine())
        return true
    }

    private func stopTilesetAnimation() {
        animTimer?.invalidate()
        animTimer = nil
        animPlayer = nil
        animGraphics = nil
        let wasShowing = displayedAnimFrame != nil || displayedFlowerFrame != nil
        displayedAnimFrame = nil
        displayedFlowerFrame = nil
        if wasShowing {
            onCameraChange?(statusLine())
        }
    }

    private func tickTilesetAnimation() {
        guard var player = animPlayer, var graphics = animGraphics else { return }
        let steps = player.advance()
        animPlayer = player
        guard !steps.isEmpty else { return }
        var spans: [AtlasRowSpan] = []
        spans.reserveCapacity(steps.count)
        for step in steps {
            guard player.table.clips.indices.contains(step.clipIndex) else { continue }
            let clip = player.table.clips[step.clipIndex]
            guard let span = TilesetAnimBlit.apply(
                clip,
                frame: step.frameIndex,
                to: &graphics.indices,
                atlasWidth: graphics.atlasWidth,
                atlasHeight: graphics.atlasHeight
            ) else {
                gpu.failTileset("Could not copy tileset animation frame \(step.frameIndex) onto tile \(clip.baseTileId).")
                stopTilesetAnimation()
                reportTilesetFailure()
                return
            }
            spans.append(span)
            if clip.baseTileId == PalletTownTilesetAnim.waterBaseTileId {
                displayedAnimFrame = step.frameIndex
            } else if clip.baseTileId == PalletTownTilesetAnim.flowerBaseTileId {
                displayedFlowerFrame = step.frameIndex
            }
        }
        animGraphics = graphics
        guard gpu.rewriteIndexRows(graphics.indices, spans: spans) else {
            stopTilesetAnimation()
            reportTilesetFailure()
            return
        }
        needsDisplay = true
        onCameraChange?(statusLine())
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
    }

    private func prepareMetal() {
        guard let device else {
            metalError = "Metal is not available on this Mac."
            onRendererNote?(metalError)
            return
        }
        commandQueue = device.makeCommandQueue()
        gpu.prepare(device: device, colorFormat: colorPixelFormat, depthFormat: depthStencilPixelFormat)
        publishRendererNote()
    }

    private func reportTilesetFailure() {
        publishRendererNote()
        assertionFailure(gpu.note ?? "Shared tileset upload failed.")
    }

    private func publishRendererNote() {
        let note = gpu.note
        guard note != metalError else { return }
        metalError = note
        onRendererNote?(metalError)
    }

    private func makeUniforms() -> MapGPUUniforms {
        let scale: Float
        if bounds.width > 1, drawableSize.width > 0 {
            scale = Float(drawableSize.width / bounds.width)
        } else {
            scale = 1
        }
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
            overlayFlags: overlayFlags
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
