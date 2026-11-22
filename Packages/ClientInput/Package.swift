// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClientInput",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "ClientInput", targets: ["ClientInput"]),
    ],
    dependencies: [
        .package(path: "../InputModel"),
        .package(path: "../WireProtocol"),
    ],
    targets: [
        .target(name: "ClientInput", dependencies: ["InputModel", "WireProtocol"]),
    ]
)
