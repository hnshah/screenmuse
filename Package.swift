// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenMuse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ScreenMuseApp", targets: ["ScreenMuseApp"]),
        .executable(name: "screenmuse", targets: ["ScreenMuseCLI"]),
        .executable(name: "ScreenMuseMCP", targets: ["ScreenMuseMCP"]),
        .library(name: "ScreenMuseCore", targets: ["ScreenMuseCore"]),
        .library(name: "ScreenMuseFoundation", targets: ["ScreenMuseFoundation"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenMuseApp",
            dependencies: ["ScreenMuseCore"],
            swiftSettings: [
                // Swift 5 concurrency mode: SCShareableContent Sendable + MainActor issues
                // need a dedicated refactor pass — tracked post-2.0.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Leaf target — pure-Foundation, fully Sendable, Swift 6 strict mode.
        // Contains types that don't touch platform frameworks (ScreenCaptureKit,
        // AVFoundation, AppKit) or actor-bound state. Step 1 of the Swift 6
        // migration: prove the two-target layout works with the smallest,
        // lowest-risk slice before tackling Recording / Export / AgentAPI.
        //
        // Moved here from ScreenMuseCore:
        //   Config/ScreenMuseConfig.swift  — user config file (Codable)
        //   System/DiskSpaceGuard.swift    — pre-flight disk check
        //   Publish/*.swift                — Publisher protocol + 3 impls
        //
        // Everything else (Narration, Browser, Capture, Recording, Export,
        // AgentAPI) stays in ScreenMuseCore for now — see BACKLOG.md
        // "Swift 6 migration plan" for the staged migration.
        .target(
            name: "ScreenMuseFoundation",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ScreenMuseCore",
            dependencies: ["ScreenMuseFoundation"],
            swiftSettings: [
                // Swift 5 concurrency mode: Recording/Export strict concurrency
                // needs refactoring — tracked post-2.0.
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "ScreenMuseCLI",
            dependencies: ["ScreenMuseCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "ScreenMuseMCP",
            swiftSettings: [
                // New target — Swift 6 strict mode, kept as-is.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ScreenMuseCoreTests",
            dependencies: ["ScreenMuseCore", "ScreenMuseFoundation"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
