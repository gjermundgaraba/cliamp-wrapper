import AppKit
import XCTest
@testable import CliampWrapper

final class ThemeTests: XCTestCase {
    @MainActor
    func testSystemThemeUpdatesAppAndSurfaceDespiteWindowAppearance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let light = directory.appendingPathComponent("light.conf")
        let dark = directory.appendingPathComponent("dark.conf")
        let config = directory.appendingPathComponent("ghostty.conf")
        try "background = #f0e0d0\n".write(to: light, atomically: true, encoding: .utf8)
        try "background = #102030\n".write(to: dark, atomically: true, encoding: .utf8)
        try """
        theme = light:\(light.path),dark:\(dark.path)
        shell-integration = none
        """.write(to: config, atomically: true, encoding: .utf8)

        let application = NSApplication.shared
        let previousAppearance = application.appearance
        let host = GhosttyHost.shared
        defer {
            host.shutdown()
            application.appearance = previousAppearance
        }
        application.appearance = NSAppearance(named: .darkAqua)
        try host.initialize(launch: CommandResolver.Launch(
            command: "/usr/bin/env /bin/sleep 30", environment: [:],
            statusFile: directory.appendingPathComponent("status").path),
            userConfigPath: config.path)
        assertBackground(host, red: 0x10, green: 0x20, blue: 0x30)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TerminalView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.applyTerminalBackground(try XCTUnwrap(host.backgroundColor))
        try host.createSurface(in: view, window: window)

        // The titlebar is explicitly dark; switching the app must still
        // reload the surface and tint the titlebar with its new background.
        XCTAssertTrue(view.effectiveAppearance.isDark)
        application.appearance = NSAppearance(named: .aqua)
        assertBackground(host, red: 0xf0, green: 0xe0, blue: 0xd0)
        XCTAssertFalse(view.effectiveAppearance.isDark)

        application.appearance = NSAppearance(named: .darkAqua)
        assertBackground(host, red: 0x10, green: 0x20, blue: 0x30)
        XCTAssertTrue(view.effectiveAppearance.isDark)
    }

    private func assertBackground(_ host: GhosttyHost, red: UInt8, green: UInt8, blue: UInt8,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let color = host.backgroundColor?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.redComponent, CGFloat(red) / 255, file: file, line: line)
        XCTAssertEqual(color?.greenComponent, CGFloat(green) / 255, file: file, line: line)
        XCTAssertEqual(color?.blueComponent, CGFloat(blue) / 255, file: file, line: line)
    }
}
