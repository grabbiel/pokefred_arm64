import AppKit
import UniformTypeIdentifiers
import ShuverseMapModel

final class EditorWindowController: NSWindowController {
    let canvas = MapCanvasView(frame: .zero, device: nil)
    private let inspector = NSView()
    private let mapPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let textView: NSTextView
    private let textScroll: NSScrollView

    private var document = EditorDocument()
    private var selection: CellInspection?
    private var rendererNote: String?

    init() {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as? NSTextView ?? NSTextView()
        textScroll = scroll
        textView = editor
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

    func openMap(at url: URL) {
        do {
            try document.importParserMap(Data(contentsOf: url))
            selection = nil
            refreshChrome()
            canvas.setMap(document.activeMap, fit: true)
        } catch {
            present(message: error.localizedDescription)
        }
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
            self?.refreshChrome()
        }
        canvas.onCameraChange = { [weak self] line in
            self?.statusLabel.stringValue = self?.statusText(line) ?? line
        }
        canvas.onRendererNote = { [weak self] note in
            self?.rendererNote = note
            self?.refreshChrome()
        }

        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.wantsLayer = true
        inspector.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.125, blue: 0.15, alpha: 1).cgColor

        mapPopup.translatesAutoresizingMaskIntoConstraints = false
        mapPopup.target = self
        mapPopup.action = #selector(activeMapChanged(_:))
        mapPopup.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        configureTextView()

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor(srgbRed: 0.75, green: 0.78, blue: 0.82, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail

        host.addSubview(canvas)
        host.addSubview(inspector)
        host.addSubview(statusBar)
        inspector.addSubview(mapPopup)
        inspector.addSubview(textScroll)
        statusBar.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: host.topAnchor),
            canvas.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            canvas.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            inspector.topAnchor.constraint(equalTo: host.topAnchor),
            inspector.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            inspector.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 320),

            mapPopup.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 10),
            mapPopup.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -10),
            mapPopup.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 10),

            textScroll.leadingAnchor.constraint(equalTo: inspector.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: inspector.trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: mapPopup.bottomAnchor, constant: 8),
            textScroll.bottomAnchor.constraint(equalTo: inspector.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        self.window = window
        refreshChrome()
        canvas.reportRendererStatus()
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainer?.widthTracksTextView = true
    }

    @objc private func activeMapChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard document.maps.indices.contains(index) else { return }
        let mapId = document.maps[index].mapId
        guard document.focus(mapId: mapId) else { return }
        selection = nil
        canvas.setMap(document.activeMap, fit: true)
        refreshChrome()
    }

    private func refreshChrome() {
        rebuildMapPopup()
        var body = InspectorText.make(document: document, selection: selection)
        if let rendererNote, !rendererNote.isEmpty {
            body = "Metal\n  \(rendererNote)\n\n" + body
        }
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1),
        ]
        textView.string = body
        window?.title = "Shuverse Editor — \(document.activeMap?.name ?? "No Map")"
        statusLabel.stringValue = statusText(canvas.statusLine())
    }

    private func rebuildMapPopup() {
        mapPopup.removeAllItems()
        if document.maps.isEmpty {
            mapPopup.addItem(withTitle: "No map")
            mapPopup.isEnabled = false
            return
        }
        mapPopup.isEnabled = true
        for map in document.maps {
            mapPopup.addItem(withTitle: "\(map.name) — \(map.mapId)")
        }
        if let index = document.maps.firstIndex(where: { $0.mapId == document.activeMapId }) {
            mapPopup.selectItem(at: index)
        }
    }

    private func statusText(_ line: String) -> String {
        if let rendererNote, !rendererNote.isEmpty {
            return "\(line)   \(rendererNote)"
        }
        return line
    }
}

extension EditorWindowController: NSWindowDelegate {}

enum JSONDrop {
    static func fileURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first { $0.pathExtension.lowercased() == "json" }
    }
}

final class JSONDropView: NSView, NSDraggingDestination {
    var onDropURL: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        JSONDrop.fileURL(from: sender) == nil ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = JSONDrop.fileURL(from: sender) else { return false }
        onDropURL?(url)
        return true
    }
}
