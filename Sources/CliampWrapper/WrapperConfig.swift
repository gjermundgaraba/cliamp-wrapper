import Foundation
import os

enum WrapperConfig {
    static let appName = "Cliamp"
    static let command = "cliamp"

    /// Optional per-user Ghostty config loaded after the bundled one.
    static let userConfigPath = "~/.config/cliamp-wrapper/ghostty.conf"

    /// Searched for the cliamp binary and prepended to the child's PATH.
    static let extraPathEntries = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Window size on first launch; later launches restore the saved frame.
    static let defaultWindowSize = NSSize(width: 960, height: 640)

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cliamp-wrapper", category: "wrapper")
}
