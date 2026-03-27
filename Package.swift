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
        .library(name: "ScreenMuseCore", targets: ["ScreenMuseCore"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenMuseApp",
            dependencies: ["ScreenMuseCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "ScreenMuseCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "ScreenMuseCLI",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v5)
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
