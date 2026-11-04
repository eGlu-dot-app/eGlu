// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKitEngine",
    platforms: [.macOS("26.0"), .iOS("17.0")],
    products: [
        .library(name: "WebKitMacPlugin", targets: ["WebKitMacPlugin"]),
        .library(name: "WebKitSupport", targets: ["WebKitSupport"]),
        .library(name: "WebKitExtensions", targets: ["WebKitExtensions"])
    ],
    dependencies: [
        .package(path: "../WebEngineKit"),
        .package(path: "../PadCore")
    ],
    targets: [
        .target(name: "WebKitSupport", dependencies: [
            .product(name: "WebEngineCore", package: "WebEngineKit")
        ], resources: [.copy("Scripts")]),
        .target(name: "WebKitMacPlugin", dependencies: [
            "WebKitSupport",
            .product(name: "WebEngineCore", package: "WebEngineKit"),
            .product(name: "WebEngineAppKit", package: "WebEngineKit")
        ]),
        // The extension runtime, moved from the Mac app, keeps the Mac app's
        // own Swift: version 5, with none of the newer concurrency defaults
        // (an async function with no actor of its own still runs off its
        // caller's), until it is written for Swift 6.
        .target(name: "WebKitExtensions", dependencies: [
            .product(name: "PadCore", package: "PadCore")
        ], swiftSettings: [
            .swiftLanguageMode(.v5)
        ]),
        .testTarget(name: "WebKitExtensionsTests", dependencies: [
            "WebKitExtensions", .product(name: "PadCore", package: "PadCore")
        ]),
        .testTarget(name: "WebKitSupportTests", dependencies: [
            "WebKitSupport",
            .product(name: "WebEngineCore", package: "WebEngineKit")
        ]),
        .testTarget(name: "WebKitMacPluginTests", dependencies: [
            "WebKitMacPlugin", "WebKitSupport",
            .product(name: "WebEngineCore", package: "WebEngineKit"),
            .product(name: "WebEngineAppKit", package: "WebEngineKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)
