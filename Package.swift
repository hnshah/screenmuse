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
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ScreenMuseCore",
            swiftSettings: [
                // Swift 5 concurrency mode: strict concurrency requires larger
                // refactoring of Recording/Export classes — tracked for a future release.
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "ScreenMuseCLI",
            dependencies: ["ScreenMuseCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "ScreenMuseMCP",
            swiftSettings: [
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
