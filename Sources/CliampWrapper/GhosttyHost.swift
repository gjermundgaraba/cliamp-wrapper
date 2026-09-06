import AppKit
import GhosttyKit

/// Owns the libghostty app, config and the single terminal surface, and
/// implements the runtime callbacks libghostty needs from its embedder.
final class GhosttyHost {
    static let shared = GhosttyHost()

    enum InitError: LocalizedError {
        case ghosttyInit
        case configNew
        case appNew
        case surfaceNew
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .ghosttyInit: return "ghostty_init failed"
            case .configNew: return "ghostty_config_new failed"
            case .appNew: return "ghostty_app_new failed"
            case .surfaceNew: return "ghostty_surface_new failed"
            case .notInitialized: return "initialize() must be called before createSurface()"
            }
        }
    }

    private(set) var app: ghostty_app_t?
    private(set) var surface: ghostty_surface_t?

    weak var window: NSWindow?
    weak var view: TerminalView?

    /// Terminal background from the config, used for the window so the
    /// titlebar blends with the surface.
    private(set) var backgroundColor: NSColor?

    private var launch: CommandResolver.Launch?
    private var config: ghostty_config_t?
    private var appearanceObservation: NSKeyValueObservation?

    private let log = WrapperConfig.log

    private init() {}

    // MARK: - Lifecycle

    /// Initialises libghostty, loads the bundled (and optional user) config,
    /// and creates the app. The command is set on the surface, not in the config.
    func initialize(launch: CommandResolver.Launch, userConfigPath: String = WrapperConfig.userConfigPath) throws {
        self.launch = launch

        // Point libghostty at the resources we ship (terminfo, themes, shell
        // integration). It would find them by walking up from the executable,
        // but an inherited GHOSTTY_RESOURCES_DIR (e.g. when launched from a
        // Ghostty terminal) takes precedence, so set ours explicitly.
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
           FileManager.default.fileExists(atPath: resources) {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw InitError.ghosttyInit
        }

        // Keep the source config for Ghostty's soft reloads on theme changes.
        guard let config = ghostty_config_new() else { throw InitError.configNew }
        self.config = config

        if let bundled = Bundle.main.url(forResource: "ghostty", withExtension: "conf")?.path {
            log.info("loading bundled config \(bundled, privacy: .public)")
            ghostty_config_load_file(config, bundled)
        } else {
            log.warning("bundled ghostty.conf not found in app resources")
        }

        let userConfig = (userConfigPath as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: userConfig) {
            log.info("loading user config \(userConfig, privacy: .public)")
            ghostty_config_load_file(config, userConfig)
        }

        // Pull in any `config-file` directives the loaded files contain.
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        let diagnostics = ghostty_config_diagnostics_count(config)
        for i in 0..<diagnostics {
            let diag = ghostty_config_get_diagnostic(config, i)
            log.warning("config: \(String(cString: diag.message), privacy: .public)")
        }

        updateBackground(from: config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyHost.wakeup() },
            action_cb: { _, target, action in
                GhosttyHost.shared.handleAction(action, target: target)
            },
            read_clipboard_cb: { _, location, state, mimes, mimesLen, list in
                Clipboard.read(location: location, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { _, _, state, request in
                Clipboard.confirmRead(state: state, request: request)
            },
            write_clipboard_cb: { _, location, content, len, confirm in
                Clipboard.write(location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { _, processAlive in
                GhosttyHost.shared.closeSurface(processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, config) else { throw InitError.appNew }
        self.app = app

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            self?.syncAppearance()
        }
        ghostty_app_set_focus(app, NSApp.isActive)

        // libghostty caches the keyboard layout for key translation; tell it
        // when the input source changes. App-lifetime observer.
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            guard let app = GhosttyHost.shared.app else { return }
            ghostty_app_keyboard_changed(app)
        }
    }

    /// Creates the terminal surface bound to `view` and starts the command.
    func createSurface(in view: TerminalView, window: NSWindow) throws {
        guard let app, let launch else { throw InitError.notInitialized }
        self.view = view
        self.window = window

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = window.backingScaleFactor

        let keys = launch.environment.keys.sorted()
        let cKeys = keys.map { strdup($0)! }
        let cValues = keys.map { strdup(launch.environment[$0]!)! }
        defer {
            cKeys.forEach { free($0) }
            cValues.forEach { free($0) }
        }
        var envVars = zip(cKeys, cValues).map { key, value in
            ghostty_env_var_s(key: UnsafePointer(key), value: UnsafePointer(value))
        }

        // A per-surface command is run through a shell and libghostty keeps
        // the surface open after it exits, which is what the exit banner needs.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let created: ghostty_surface_t? = home.withCString { cwd in
            launch.command.withCString { command in
                cfg.working_directory = cwd
                cfg.command = command
                return envVars.withUnsafeMutableBufferPointer { buffer in
                    cfg.env_vars = buffer.baseAddress
                    cfg.env_var_count = buffer.count
                    return ghostty_surface_new(app, &cfg)
                }
            }
        }
        guard let created else { throw InitError.surfaceNew }
        surface = created
        syncAppearance()
        view.surfaceDidAttach()
    }

    /// Frees the surface and app. Freeing the surface closes the PTY, which
    /// hangs up the child process.
    func shutdown() {
        appearanceObservation = nil
        if let surface {
            self.surface = nil
            ghostty_surface_free(surface)
        }
        if let app {
            self.app = nil
            ghostty_app_free(app)
        }
        if let config {
            self.config = nil
            ghostty_config_free(config)
        }
        if let launch {
            try? FileManager.default.removeItem(atPath: launch.statusFile)
        }
    }

    // MARK: - Runtime callbacks

    private static func wakeup() {
        DispatchQueue.main.async {
            guard let app = GhosttyHost.shared.app else { return }
            ghostty_app_tick(app)
        }
    }

    private func closeSurface(processAlive: Bool) {
        log.info("surface closed (process alive: \(processAlive))")
        quit()
    }

    /// libghostty invokes its callbacks with its own frames on the stack, so
    /// teardown (which frees the surface and joins its threads) is deferred
    /// to the next run-loop turn.
    private func quit() {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Runs a keybinding action by name, e.g. `copy_to_clipboard`.
    func perform(_ action: String) {
        guard let surface else { return }
        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    private func syncAppearance() {
        // Window appearance follows the terminal background for titlebar
        // contrast; only the app's appearance represents the system theme.
        let scheme = NSApp.effectiveAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        if let app { ghostty_app_set_color_scheme(app, scheme) }
        if let surface { ghostty_surface_set_color_scheme(surface, scheme) }
    }

    private func updateBackground(from config: ghostty_config_t) {
        var color = ghostty_config_color_s()
        if ghostty_config_get(config, &color, "background", 10) {
            setBackground(red: color.r, green: color.g, blue: color.b)
        }
    }

    private func setBackground(red: UInt8, green: UInt8, blue: UInt8) {
        let color = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                            blue: CGFloat(blue) / 255, alpha: 1)
        backgroundColor = color
        window?.applyTerminalBackground(color)
    }

    // MARK: - Actions

    private func handleAction(_ action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            guard action.action.reload_config.soft, let config else { return false }
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                guard let app else { return false }
                ghostty_app_update_config(app, config)
            case GHOSTTY_TARGET_SURFACE:
                ghostty_surface_update_config(target.target.surface, config)
            default: return false
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Once attached, the surface's applied config owns the background.
            if target.tag == GHOSTTY_TARGET_SURFACE || surface == nil,
               let config = action.action.config_change.config {
                updateBackground(from: config)
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_WINDOW_TITLE:
            guard let ptr = action.action.set_title.title else { return false }
            window?.title = String(cString: ptr)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.cursor = Self.cursor(for: action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            // Only mouse-hide-while-typing uses this; the system shows the
            // cursor again on any movement, so no state to unwind.
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            // Link targets come from terminal output. Only web and mail
            // schemes go to Launch Services; anything else is dropped. Always
            // report handled so the core never uses its unrestricted opener.
            let payload = action.action.open_url
            if let ptr = payload.url,
               let url = URL(string: String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(payload.len)), as: UTF8.self)),
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            } else {
                log.info("ignored link that is not http, https or mailto")
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let status = childExitStatus()
            log.info("child exited with status \(status) after \(action.action.child_exited.timetime_ms) ms")
            if status == 0 {
                quit()
                return true
            }
            // Keep the surface (and its output) visible and tell the user.
            // libghostty waits for a keypress, which then closes the surface.
            showExitBanner(status: status)
            return true

        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            // One window: closing it and quitting are the same thing.
            quit()
            return true

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            window?.toggleFullScreen(nil)
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return true }
            setBackground(red: change.r, green: change.g, blue: change.b)
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY {
                log.error("libghostty reports an unhealthy renderer")
            }
            return true

        case GHOSTTY_ACTION_QUIT_TIMER, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_PROMPT_TITLE, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_READONLY, GHOSTTY_ACTION_SET_TAB_TITLE, GHOSTTY_ACTION_SIZE_LIMIT:
            // Nothing to do for a single fixed surface.
            return true

        default:
            // Tabs, splits, inspector, notifications, etc. are not supported.
            return false
        }
    }

    /// The real exit status from the launcher's status file. libghostty's
    /// own exit code is not consulted: Ghostty runs commands under `login`,
    /// which always exits 0. A missing or unreadable file is not a clean exit.
    private func childExitStatus() -> Int32 {
        guard let launch,
              let text = try? String(contentsOfFile: launch.statusFile, encoding: .utf8),
              let status = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return -1
        }
        return status
    }

    /// Non-modal banner above the terminal, so Cmd+Q still works and any key
    /// still closes the surface as libghostty expects. The terminal view is
    /// shrunk to keep the program's last output readable.
    private func showExitBanner(status: Int32) {
        guard let window, let content = window.contentView, let view else { return }

        let bannerHeight: CGFloat = 32
        var frame = content.bounds
        frame.size.height -= bannerHeight
        view.frame = frame

        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemRed.cgColor

        let label = NSTextField(labelWithString:
            "\(WrapperConfig.command) exited with status \(status). Press any key or \u{2318}Q to quit.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        banner.addSubview(label)

        content.addSubview(banner, positioned: .above, relativeTo: view)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: content.topAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: bannerHeight),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: banner.trailingAnchor, constant: -12),
        ])
        window.title = "\(WrapperConfig.appName): exited with status \(status)"
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return .resizeDown
        default: return .arrow
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
