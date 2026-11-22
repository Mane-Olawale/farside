// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BackendClient",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "BackendClient", targets: ["BackendClient"]),
    ],
    dependencies: [
        .package(path: "../WireProtocol"),
        .package(path: "../Pairing"),
    ],
    targets: [
        .target(name: "BackendClient", dependencies: ["WireProtocol", "Pairing"]),
    ]
)
