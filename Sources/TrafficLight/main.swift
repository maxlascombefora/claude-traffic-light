import AppKit

// Accessory policy = no Dock icon, no menu bar (the LSUIElement equivalent, set in code so
// this works as a plain SwiftPM executable with no Info.plist).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
