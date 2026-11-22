// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InputModel",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "InputModel", targets: ["InputModel"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "InputModel", dependencies: []),
        .testTarget(name: "InputModelTests", dependencies: ["InputModel"]),
    ]
)
