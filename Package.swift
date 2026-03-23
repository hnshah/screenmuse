// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenMuse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ScreenMuseApp", targets: ["ScreenMuseApp"]),
        .library(name: "ScreenMuseCore", targets: ["ScreenMuseCore"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenMuseApp",
            dependencies: ["ScreenMuseCore"],
            resources: [
                .process("Resources/Info.plist")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "ScreenMuseCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
