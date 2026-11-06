// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKitEngine",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WebKitMacPlugin", targets: ["WebKitMacPlugin"])
    ],
    dependencies: [
        .package(path: "../WebEngineKit")
    ],
    targets: [
        .target(name: "WebKitMacPlugin", dependencies: [
            .product(name: "WebEngineCore", package: "WebEngineKit")
        ]),
        .testTarget(name: "WebKitMacPluginTests", dependencies: [
            "WebKitMacPlugin", .product(name: "WebEngineCore", package: "WebEngineKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)
