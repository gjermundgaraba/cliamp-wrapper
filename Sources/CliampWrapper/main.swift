import AppKit

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
