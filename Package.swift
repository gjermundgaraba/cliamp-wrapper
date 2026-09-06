// swift-tools-version: 6.2
import PackageDescription

// GhosttyKit.xcframework is produced by `scripts/build-ghosttykit.sh` from the
// Ghostty submodule in vendor/ghostty. Run `make ghosttykit` before building.
let package = Package(
    name: "CliampWrapper",
    platforms: [.macOS(.v26)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "CliampWrapper",
            dependencies: ["GhosttyKit"],
            path: "Sources/CliampWrapper",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "CliampWrapperTests",
            dependencies: ["CliampWrapper"]
        ),
    ]
)
