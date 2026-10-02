// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BriareusCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "BriareusMacCore", targets: ["BriareusMacCore"])],
    targets: [
        // The apps' core, shared by the Mac app and the iPhone and iPad one: the client API (/api/v1) and what it
        // answers, with no UI.
        .target(name: "BriareusMacCore", path: "Mac/Core"),
        .testTarget(name: "BriareusMacCoreTests", dependencies: ["BriareusMacCore"], path: "MacTests")
    ]
)
