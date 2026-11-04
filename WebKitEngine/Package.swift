// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKitEngine",
    platforms: [.macOS("26.0"), .iOS("17.0")],
    products: [
        .library(name: "WebKitMacPlugin", targets: ["WebKitMacPlugin"]),
        .library(name: "WebKitSupport", targets: ["WebKitSupport"])
    ],
    dependencies: [
        .package(path: "../WebEngineKit")
    ],
    targets: [
        .target(name: "WebKitSupport", resources: [.copy("Scripts")]),
        .target(name: "WebKitMacPlugin", dependencies: [
            "WebKitSupport",
            .product(name: "WebEngineCore", package: "WebEngineKit"),
            .product(name: "WebEngineAppKit", package: "WebEngineKit")
        ]),
        .testTarget(name: "WebKitMacPluginTests", dependencies: [
            "WebKitMacPlugin", "WebKitSupport", .product(name: "WebEngineCore", package: "WebEngineKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)
