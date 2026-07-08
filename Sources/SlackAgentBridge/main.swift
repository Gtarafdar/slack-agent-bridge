import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = Unmanaged.passRetained(delegate)
app.run()
