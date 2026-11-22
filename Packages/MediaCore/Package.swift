// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MediaCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
    ],
    targets: [
        .target(name: "MediaCore"),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
    ]
)
