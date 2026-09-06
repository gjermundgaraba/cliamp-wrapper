import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var terminalView: TerminalView?
    private let titleToolbar = TitleToolbar()
    private let host = GhosttyHost.shared
    private let log = WrapperConfig.log

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()

        guard let launch = CommandResolver.resolveLaunch() else {
            fail(
                "\(WrapperConfig.tuiName) was not found",
                detail: "Install \(WrapperConfig.tuiName) (for example with `brew install bjarneo/cliamp/cliamp`) "
                    + "or set \(CommandResolver.execEnv) to its path.")
            return
        }
        log.info("command: \(launch.command, privacy: .public)")

        do {
            try host.initialize(launch: launch)
        } catch {
            fail("libghostty failed to start", detail: error.localizedDescription)
            return
        }

        let window = makeWindow()
        let view = TerminalView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        window.makeFirstResponder(view)
        self.window = window
        self.terminalView = view

        do {
            try host.createSurface(in: view, window: window)
        } catch {
            fail("libghostty could not create a terminal surface", detail: error.localizedDescription)
            return
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        host.setAppFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        host.setAppFocus(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.shutdown()
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WrapperConfig.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = WrapperConfig.appName
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        titleToolbar.attach(to: window)
        if let background = host.backgroundColor {
            window.applyTerminalBackground(background)
        }
        window.setFrameAutosaveName("\(WrapperConfig.appName)Main")
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let view = terminalView, window?.firstResponder !== view {
            window?.makeFirstResponder(view)
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let name = WrapperConfig.appName
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(ghosttyItem("Copy", action: "copy_to_clipboard", key: "c"))
        editMenu.addItem(ghosttyItem("Paste", action: "paste_from_clipboard", key: "v"))
        editMenu.addItem(ghosttyItem("Select All", action: "select_all", key: "a"))

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(ghosttyItem("Increase Font Size", action: "increase_font_size:1", key: "="))
        viewMenu.addItem(ghosttyItem("Decrease Font Size", action: "decrease_font_size:1", key: "-"))
        viewMenu.addItem(ghosttyItem("Reset Font Size", action: "reset_font_size", key: "0"))
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func ghosttyItem(_ title: String, action: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performGhosttyAction(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func performGhosttyAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        host.perform(action)
    }

    // MARK: - Errors

    private func fail(_ message: String, detail: String) {
        log.error("\(message, privacy: .public): \(detail, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

extension NSWindow {
    /// Tints the window, titlebar included, with the terminal background and
    /// picks the matching light or dark appearance.
    func applyTerminalBackground(_ color: NSColor) {
        backgroundColor = color
        appearance = NSAppearance(named: color.isDarkColor ? .darkAqua : .aqua)
    }
}

extension NSColor {
    /// Rough perceived-luminance check used to pick the titlebar appearance.
    var isDarkColor: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }
}
