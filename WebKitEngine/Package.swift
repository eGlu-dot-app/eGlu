// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKitEngine",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WebKitMacPlugin", targets: ["WebKitMacPlugin"])
    ],
    targets: [
        .target(name: "WebKitMacPlugin"),
        .testTarget(name: "WebKitMacPluginTests", dependencies: ["WebKitMacPlugin"])
    ],
    swiftLanguageModes: [.v6]
)
