import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let controller = EditorWindowController()
        windowController = controller
        controller.show()
        if let url = MapFileLocator.initialMapURL() {
            controller.openMap(at: url)
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openMapJSON(_ sender: Any?) {
        windowController?.openMapPanel()
    }

    @objc func openPalletTown(_ sender: Any?) {
        guard let url = MapFileLocator.palletTownURL() else {
            windowController?.present(message: "Pallet Town sample was not found.")
            return
        }
        windowController?.openMap(at: url)
    }

    @objc func zoomIn(_ sender: Any?) {
        windowController?.canvas.zoomIn(sender)
    }

    @objc func zoomOut(_ sender: Any?) {
        windowController?.canvas.zoomOut(sender)
    }

    @objc func fitMap(_ sender: Any?) {
        windowController?.canvas.fitMap(sender)
    }

    private func installMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Shuverse Editor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open Map JSON…", action: #selector(openMapJSON(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Open Pallet Town Sample", action: #selector(openPalletTown(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Fit Map", action: #selector(fitMap(_:)), keyEquivalent: "0")

        NSApp.mainMenu = main
    }
}
