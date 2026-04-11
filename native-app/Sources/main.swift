import Cocoa

// MARK: - Application Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Run as accessory (no Dock icon)
app.setActivationPolicy(.accessory)
app.run()
