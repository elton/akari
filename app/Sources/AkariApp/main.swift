import AppKit

// akari.app entry point. `.accessory` keeps it out of the Dock and the
// Cmd-Tab switcher: this is a menu bar app that draws on the desktop.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
