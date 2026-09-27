import AppKit
import UniformTypeIdentifiers
import ShuverseMapModel

final class EditorWindowController: NSWindowController {
    let canvas = MapCanvasView(frame: .zero, device: nil)
    private let overlay: ImGuiOverlayView

    private var editorDocument = EditorDocument()
    private var selection: CellInspection?
    private var rendererNote: String?
    private var cameraLine = "No map"

    init() {
        overlay = ImGuiOverlayView(frame: .zero, device: canvas.device)
        super.init(window: nil)
        buildWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func openMapPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Open a Map Parser JSON file"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openMap(at: url)
    }

    func openPalletTown() {
        guard let url = MapFileLocator.palletTownURL() else {
            present(message: "Pallet Town sample was not found.")
            return
        }
        openMap(at: url)
    }

    func openMap(at url: URL) {
        do {
            try editorDocument.importParserMap(Data(contentsOf: url))
            selection = nil
            canvas.setMap(editorDocument.activeMap, fit: true)
            refreshChrome()
        } catch {
            present(message: error.localizedDescription)
        }
    }

    func focusMap(id: String) {
        guard editorDocument.focus(mapId: id) else { return }
        selection = nil
        canvas.setMap(editorDocument.activeMap, fit: true)
        refreshChrome()
    }

    func present(message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open map"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shuverse Editor"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 860, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let host = JSONDropView(frame: window.contentView?.bounds ?? .zero)
        host.onDropURL = { [weak self] url in
            self?.openMap(at: url)
        }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor
        window.contentView = host

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onDropURL = { [weak self] url in
            self?.openMap(at: url)
        }
        canvas.onInspect = { [weak self] inspection in
            self?.selection = inspection
        }
        canvas.onCameraChange = { [weak self] line in
            self?.cameraLine = line
        }
        canvas.onRendererNote = { [weak self] note in
            self?.rendererNote = note
        }

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.modelProvider = { [weak self] in
            self?.dockModel() ?? .empty
        }
        overlay.onFocusMap = { [weak self] id in
            self?.focusMap(id: id)
        }
        overlay.onOpenSample = { [weak self] in
            self?.openPalletTown()
        }
        overlay.onOpenJSON = { [weak self] in
            self?.openMapPanel()
        }
        overlay.onDropURL = { [weak self] url in
            self?.openMap(at: url)
        }
        overlay.keepCanvasFirstResponder = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.canvas)
        }

        host.addSubview(canvas)
        host.addSubview(overlay)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: host.topAnchor),
            canvas.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        self.window = window
        refreshChrome()
        canvas.reportRendererStatus()
    }

    private func dockModel() -> ImGuiDockModel {
        let maps = editorDocument.maps.map { map in
            ImGuiDockModel.MapEntry(
                id: map.mapId,
                title: "\(map.name) — \(map.mapId)",
                active: map.mapId == editorDocument.activeMapId
            )
        }
        return ImGuiDockModel(
            maps: maps,
            inspector: InspectorText.make(document: editorDocument, selection: selection),
            status: cameraLine,
            rendererNote: rendererNote ?? "",
            tilesetPrimary: editorDocument.activeMap?.tilesets.primary ?? "",
            tilesetSecondary: editorDocument.activeMap?.tilesets.secondary ?? ""
        )
    }

    private func refreshChrome() {
        cameraLine = canvas.statusLine()
        window?.title = "Shuverse Editor — \(editorDocument.activeMap?.name ?? "No Map")"
    }
}

extension EditorWindowController: NSWindowDelegate {}

enum JSONDrop {
    static func fileURL(from sender: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first { $0.pathExtension.lowercased() == "json" }
    }
}

final class JSONDropView: NSView {
    var onDropURL: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
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
