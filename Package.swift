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
        .library(name: "ScreenMuseCore", targets: ["ScreenMuseCore"])
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
        .target(
            name: "ScreenMuseCore",
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
            dependencies: ["ScreenMuseCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
