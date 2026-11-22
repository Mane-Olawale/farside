// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WireProtocol",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "WireProtocol", targets: ["WireProtocol"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "WireProtocol", dependencies: []),
    ]
)
