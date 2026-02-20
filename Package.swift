// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hanzo",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "Hanzo",
            dependencies: [
                "HotKey",
                "KeychainAccess",
            ],
            path: "Hanzo",
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
    ]
)
