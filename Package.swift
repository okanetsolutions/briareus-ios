// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BriareusCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "BriareusCore", targets: ["BriareusCore"])],
    targets: [
        .target(name: "BriareusCore", path: "Core"),
        .testTarget(name: "BriareusCoreTests", dependencies: ["BriareusCore"], path: "Tests")
    ]
)
