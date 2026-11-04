// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebEngineKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WebEngineCore", targets: ["WebEngineCore"]),
        .library(name: "WebEngineAppKit", targets: ["WebEngineAppKit"])
    ],
    targets: [
        .target(name: "WebEngineCore"),
        .target(name: "WebEngineAppKit"),
        .testTarget(name: "WebEngineCoreTests", dependencies: ["WebEngineCore"]),
        .testTarget(name: "WebEngineAppKitTests", dependencies: ["WebEngineAppKit"])
    ],
    swiftLanguageModes: [.v6]
)
