// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hanzo",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.16.0")),
    ],
    targets: [
        .target(
            name: "HanzoCore",
            dependencies: [
                "HotKey",
                "WhisperKit",
            ],
            path: "HanzoCore",
            exclude: [
                "Info.plist",
                "Hanzo.entitlements",
            ],
            resources: [
                .process("Assets.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "HanzoApp",
            dependencies: [
                "HanzoCore",
            ],
            path: "HanzoApp",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "HanzoTests",
            dependencies: [
                "HanzoCore",
            ],
            path: "Tests/HanzoTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
