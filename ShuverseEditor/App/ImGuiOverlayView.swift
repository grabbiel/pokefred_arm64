import AppKit
import CImGuiHost
import MetalKit
import QuartzCore

/// Transparent MTKView over the map. `hitTest` returns nil on the dockspace
/// hole, so pan, zoom, and click-inspect stay on `MapCanvasView`. Docks, tabs,
/// and splitters receive the mouse.
final class ImGuiOverlayView: MTKView, MTKViewDelegate {
    var modelProvider: (() -> ImGuiDockModel)?
    var onFocusMap: ((String) -> Void)?
    var onOpenSample: (() -> Void)?
    var onOpenJSON: (() -> Void)?
    var onDropURL: ((URL) -> Void)?
    var keepCanvasFirstResponder: (() -> Void)?

    private let renderer: ImGuiMetalRenderer?
    private var lastFrameTime: CFTimeInterval = 0
    private var ownsMouse = false
    private var wasOverUI = false
    private var mouseX: Float = -Float.greatestFiniteMagnitude
    private var mouseY: Float = -Float.greatestFiniteMagnitude

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        renderer = ImGuiMetalRenderer(device: device ?? MTLCreateSystemDefaultDevice())
        super.init(frame: frameRect, device: renderer?.device ?? device)
        configure()
    }

    required init(coder: NSCoder) {
        let device = MTLCreateSystemDefaultDevice()
        renderer = ImGuiMetalRenderer(device: device)
        super.init(coder: coder)
        self.device = renderer?.device ?? device
        configure()
    }

    deinit {
        ig_host_shutdown()
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let (x, y) = imguiPoint(local)
        return ig_host_hit(x, y) != 0 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        ownsMouse = true
        ig_host_mouse_button(0, 1)
        keepCanvasFirstResponder?()
    }

    override func mouseUp(with event: NSEvent) {
        ownsMouse = false
        ig_host_mouse_button(0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        ownsMouse = true
        ig_host_mouse_button(1, 1)
        keepCanvasFirstResponder?()
    }

    override func rightMouseUp(with event: NSEvent) {
        ownsMouse = false
        ig_host_mouse_button(1, 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        ownsMouse = true
        ig_host_mouse_button(2, 1)
    }

    override func otherMouseUp(with event: NSEvent) {
        ownsMouse = false
        ig_host_mouse_button(2, 0)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .cancelled { return }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            dx *= 0.01
            dy *= 0.01
        }
        if dx != 0 || dy != 0 {
            ig_host_add_wheel(Float(dx), Float(dy))
        }
    }

    override func magnify(with event: NSEvent) {}

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        JSONDrop.fileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = JSONDrop.fileURL(from: sender) else { return false }
        onDropURL?(url)
        return true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let renderer,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        let (scaleX, scaleY) = framebufferScale()
        // A map pan keeps the mouse button down on the canvas. Don't feed that
        // position into ImGui or docks highlight underneath the drag.
        let (mx, my): (Float, Float)
        if NSEvent.pressedMouseButtons != 0 && !ownsMouse {
            (mx, my) = (-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        } else {
            (mx, my) = currentMouse()
        }
        mouseX = mx
        mouseY = my
        let now = CACurrentMediaTime()
        var dt = Float(now - lastFrameTime)
        if lastFrameTime == 0 || dt <= 0 {
            dt = 1.0 / 60.0
        } else if dt > 0.1 {
            dt = 0.1
        }
        lastFrameTime = now

        renderer.uploadFontIfNeeded()
        ig_host_new_frame(Float(bounds.width), Float(bounds.height), scaleX, scaleY, dt, mx, my)
        let action = ImGuiDockShell.build(modelProvider?() ?? .empty)
        ig_host_render()

        commandBuffer.label = "imgui-frame"
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.label = "imgui"
            renderer.encode(encoder, colorPixelFormat: colorPixelFormat)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        applyCursor()
        dispatch(action)
    }

    private func configure() {
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false
        layer?.isOpaque = false
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.isOpaque = false
        }
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        ig_host_init()
        registerForDraggedTypes([.fileURL])
    }

    private func framebufferScale() -> (Float, Float) {
        guard bounds.width > 0, bounds.height > 0 else { return (1, 1) }
        let scaleX = drawableSize.width / bounds.width
        let scaleY = drawableSize.height / bounds.height
        if scaleX <= 0 || scaleY <= 0 { return (1, 1) }
        return (Float(scaleX), Float(scaleY))
    }

    private func currentMouse() -> (Float, Float) {
        guard let window else {
            return (-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(local) && !ownsMouse {
            return (-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        }
        return imguiPoint(local)
    }

    private func imguiPoint(_ local: NSPoint) -> (Float, Float) {
        (Float(local.x), Float(bounds.height - local.y))
    }

    private func applyCursor() {
        if NSEvent.pressedMouseButtons != 0 && !ownsMouse {
            return
        }
        let overUI = ig_host_hit(mouseX, mouseY) != 0
        guard overUI || wasOverUI else { return }
        if !overUI {
            NSCursor.arrow.set()
            wasOverUI = false
            return
        }
        wasOverUI = true
        switch ig_host_mouse_cursor() {
        case 1:
            NSCursor.iBeam.set()
        case 3:
            NSCursor.resizeUpDown.set()
        case 4:
            NSCursor.resizeLeftRight.set()
        case 5, 6:
            NSCursor.crosshair.set()
        case 7:
            NSCursor.pointingHand.set()
        default:
            NSCursor.arrow.set()
        }
    }

    private func dispatch(_ action: ImGuiShellAction) {
        let focus = action.focusMapId
        let openSample = action.openSample
        let openJSON = action.openJSON
        guard focus != nil || openSample || openJSON else { return }
        DispatchQueue.main.async { [weak self] in
            if let focus {
                self?.onFocusMap?(focus)
            }
            if openSample {
                self?.onOpenSample?()
            }
            if openJSON {
                self?.onOpenJSON?()
            }
        }
    }
}
