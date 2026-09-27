import AppKit

#if !arch(arm64)
#error("Shuverse Editor is Apple Silicon only (arm64). Build with: swift build --arch arm64")
#endif

let applicationDelegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = applicationDelegate
application.run()
