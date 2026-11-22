// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClientVideo",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "ClientVideo", targets: ["ClientVideo"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
    ],
    targets: [
        .target(name: "ClientVideo", dependencies: ["MediaCore"]),
        .testTarget(name: "ClientVideoTests", dependencies: ["ClientVideo"]),
    ]
)
