import AppKit

// Headless probe: no windows. The mode comes from `open ... --args --mode <m> --run-id <id>`.
let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
