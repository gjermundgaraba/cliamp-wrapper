import Foundation
import XCTest
@testable import CliampWrapper

final class CommandResolverTests: XCTestCase {
    func testLookupAndChildPATHShareNormalizedDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = try executable(in: root.appendingPathComponent("extra tools"))
        _ = try executable(in: root.appendingPathComponent("inherited"))

        let launch = try XCTUnwrap(CommandResolver.resolveLaunch(
            environment: ["PATH": "inherited:./extra tools::.:/usr/bin"],
            workingDirectory: root.path,
            extraPathEntries: ["./extra tools", "extra tools/../extra tools"]))

        XCTAssertEqual(launch.environment[CommandResolver.execEnv], extra.path)
        XCTAssertEqual(launch.environment["PATH"], [
            root.appendingPathComponent("extra tools").path,
            root.appendingPathComponent("inherited").path,
            root.path,
            "/usr/bin",
        ].joined(separator: ":"))
    }

    func testLookupSkipsDirectoryAndFindsExecutableSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("first/cliamp"), withIntermediateDirectories: true)
        let binary = try executable(in: root.appendingPathComponent("target"))
        let later = root.appendingPathComponent("later")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let link = later.appendingPathComponent("cliamp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        let launch = try XCTUnwrap(CommandResolver.resolveLaunch(
            environment: ["PATH": "first:later"], workingDirectory: root.path,
            extraPathEntries: []))

        XCTAssertEqual(launch.environment[CommandResolver.execEnv], link.path)
    }

    func testRelativeInheritedPATHFindsExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = try executable(in: root.appendingPathComponent("player's tools"))

        let launch = try XCTUnwrap(CommandResolver.resolveLaunch(
            environment: ["PATH": "./player's tools"], workingDirectory: root.path,
            extraPathEntries: []))

        XCTAssertEqual(launch.environment[CommandResolver.execEnv], binary.path)
        XCTAssertEqual(launch.environment["PATH"], binary.deletingLastPathComponent().path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launch.command]
        process.environment = launch.environment
        process.currentDirectoryURL = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(atPath: launch.statusFile) }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOfFile: launch.statusFile, encoding: .utf8), "0")
    }

    func testExplicitMissingPathIsAbsoluteAndStillLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let relative = "missing tools/player's binary"

        let launch = try XCTUnwrap(CommandResolver.resolveLaunch(
            environment: [CommandResolver.execEnv: relative, "PATH": ""],
            workingDirectory: root.path, extraPathEntries: []))

        XCTAssertEqual(launch.environment[CommandResolver.execEnv],
                       root.appendingPathComponent(relative).path)
        XCTAssertEqual(launch.environment["PATH"], root.path)
        XCTAssertFalse(launch.command.contains(relative))
    }

    func testTildeExpansionAndMissingPATHDefaults() throws {
        let launch = try XCTUnwrap(CommandResolver.resolveLaunch(
            environment: [CommandResolver.execEnv: "~/wrapper-missing-player"],
            workingDirectory: "/tmp", extraPathEntries: ["~/.local/bin"]))
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(launch.environment[CommandResolver.execEnv],
                       home.appendingPathComponent("wrapper-missing-player").path)
        XCTAssertEqual(launch.environment["PATH"],
                       home.appendingPathComponent(".local/bin").path
                       + ":/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testMissingSearchResultReturnsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(CommandResolver.resolveLaunch(
            environment: ["PATH": "missing"], workingDirectory: root.path,
            extraPathEntries: []))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandResolverTests-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func executable(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("cliamp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }
}
