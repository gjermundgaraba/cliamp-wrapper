import Foundation
import os

/// Static knobs for this wrapper. Change these (or the bundled
/// Resources/ghostty.conf) to wrap a different TUI.
enum WrapperConfig {
    /// Initial window title and menu labels. The TUI may change the title
    /// with the usual escape sequence.
    static let appName = "Cliamp"

    /// Executable name of the TUI to run.
    static let tuiName = "cliamp"

    /// Optional per-user Ghostty config loaded after the bundled one.
    static let userConfigPath = "~/.config/cliamp-wrapper/ghostty.conf"

    /// Directories prepended to PATH for the child process and searched for
    /// the TUI binary.
    static let extraPathEntries = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Window content size in points on first launch; later launches restore
    /// the autosaved frame.
    static let defaultWindowSize = NSSize(width: 960, height: 640)

    static let log = Logger(subsystem: "net.garaba.cliamp", category: "wrapper")
}
