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
        // `swift run GenerateDrills` dumps the drill library to JSON so the web
        // client can read the SAME content the iOS app compiles — one source of
        // truth for the 76 drills. See web/scripts/generate-drills.sh.
        .executableTarget(name: "GenerateDrills", dependencies: ["VFRCore"]),
        .testTarget(name: "VFRCoreTests", dependencies: ["VFRCore"])
    ]
)
