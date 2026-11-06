// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocumentServiceKit",
    platforms: [.macOS("26.0"), .iOS(.v17)],
    products: [.library(name: "DocumentServiceKit", targets: ["DocumentServiceKit"])],
    targets: [
        .target(name: "DocumentServiceKit"),
        .testTarget(name: "DocumentServiceKitTests", dependencies: ["DocumentServiceKit"])
    ],
    swiftLanguageModes: [.v6]
)
