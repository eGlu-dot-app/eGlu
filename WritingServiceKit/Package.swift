// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WritingServiceKit",
    platforms: [.macOS("26.0"), .iOS(.v17)],
    products: [.library(name: "WritingServiceKit", targets: ["WritingServiceKit"])],
    targets: [
        .target(name: "WritingServiceKit"),
        .testTarget(name: "WritingServiceKitTests", dependencies: ["WritingServiceKit"])
    ],
    swiftLanguageModes: [.v6]
)
