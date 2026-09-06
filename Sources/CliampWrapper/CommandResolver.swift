import Foundation

/// Locates the TUI binary and describes how libghostty should launch it.
enum CommandResolver {
    /// Environment variable carrying the resolved executable path into the
    /// launcher script. Setting it before launch also overrides the search.
    static let execEnv = "CLIAMP_WRAPPER_EXEC"

    /// Environment variable carrying the path the launcher script writes the
    /// child's exit status to.
    static let statusFileEnv = "CLIAMP_WRAPPER_STATUS_FILE"

    struct Launch {
        /// Shell command for the surface. libghostty always runs a per-surface
        /// command through a shell and keeps the surface open after it exits.
        let command: String
        /// Extra environment for the child process.
        let environment: [String: String]
        /// File the real exit status is written to.
        let statusFile: String
    }

    /// Ghostty on macOS runs every command under `/usr/bin/login`, which
    /// always exits 0, so the exit code libghostty reports is useless. The
    /// launcher runs the TUI from a POSIX sh, records `$?` to a file and
    /// exits with the same status. `/usr/bin/env` in front keeps Ghostty's
    /// `exec -l` from turning sh into a login shell that reads profiles.
    ///
    /// Paths never appear in the script; they travel through environment
    /// variables so spaces and quotes in the app location are harmless.
    private static let launcherScript =
        "\"$\(execEnv)\"; s=$?; printf %s \"$s\" > \"$\(statusFileEnv)\"; exit $s"

    static func resolveLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        extraPathEntries: [String] = WrapperConfig.extraPathEntries
    ) -> Launch? {
        let launchDirectory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let directories = searchDirectories(
            environment: environment, extraPathEntries: extraPathEntries,
            relativeTo: launchDirectory)
        guard let executable = resolveBinary(
            environment: environment, directories: directories,
            relativeTo: launchDirectory) else { return nil }
        let statusFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliamp-wrapper-\(ProcessInfo.processInfo.processIdentifier).status")
            .path
        return Launch(
            command: "/usr/bin/env /bin/sh -c '\(launcherScript)'",
            environment: [
                "PATH": directories.joined(separator: ":"),
                "CLIAMP_WRAPPER": "1",
                execEnv: executable,
                statusFileEnv: statusFile,
            ],
            statusFile: statusFile)
    }

    /// Explicit paths are anchored to the wrapper's launch directory too.
    /// Do not check their existence: a bad override fails visibly in the launcher.
    private static func resolveBinary(
        environment: [String: String], directories: [String], relativeTo base: URL
    ) -> String? {
        if let explicit = environment[execEnv], !explicit.isEmpty {
            return absolutePath(explicit, relativeTo: base)
        }
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(WrapperConfig.tuiName).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolve and de-duplicate once so binary lookup and the child's PATH
    /// agree even when Ghostty starts the child in a different directory.
    private static func searchDirectories(
        environment: [String: String], extraPathEntries: [String], relativeTo base: URL
    ) -> [String] {
        let inherited = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        var seen = Set<String>()
        return (extraPathEntries + inherited)
            .map { absolutePath($0, relativeTo: base) }
            .filter { seen.insert($0).inserted }
    }

    private static func absolutePath(_ path: String, relativeTo base: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded.isEmpty ? "." : expanded, relativeTo: base)
            .standardizedFileURL.path
    }
}
