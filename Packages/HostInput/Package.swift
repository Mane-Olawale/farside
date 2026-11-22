// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HostInput",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HostInput", targets: ["HostInput"]),
    ],
    dependencies: [
        .package(path: "../InputModel"),
    ],
    targets: [
        .target(name: "HostInput", dependencies: ["InputModel"]),
        .testTarget(name: "HostInputTests", dependencies: ["HostInput"]),
    ]
)
