// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VFRCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14) // so we can run `swift test` on the Mac without a simulator
    ],
    products: [
        .library(name: "VFRCore", targets: ["VFRCore"])
    ],
    targets: [
        .target(name: "VFRCore"),
        .testTarget(name: "VFRCoreTests", dependencies: ["VFRCore"])
    ]
)
