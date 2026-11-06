// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnginePlugins",
    platforms: [.macOS("26.0"), .iOS(.v17)],
    products: [
        .library(name: "HarperPlugin", targets: ["HarperPlugin"]),
        .library(name: "DocumentsPlugin", targets: ["DocumentsPlugin"])
    ],
    dependencies: [
        .package(path: "../WritingServiceKit"),
        .package(path: "../DocumentServiceKit"),
        .package(path: "../Engines")
    ],
    targets: [
        .target(name: "HarperPlugin", dependencies: ["WritingServiceKit", "Engines"]),
        .target(name: "DocumentsPlugin", dependencies: ["DocumentServiceKit", "Engines"]),
        .testTarget(name: "HarperPluginTests", dependencies: ["HarperPlugin", "WritingServiceKit", "Engines"]),
        .testTarget(name: "DocumentsPluginTests", dependencies: ["DocumentsPlugin", "DocumentServiceKit", "Engines"])
    ],
    swiftLanguageModes: [.v6]
)
