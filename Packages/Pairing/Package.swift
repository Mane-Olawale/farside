// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pairing",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Pairing", targets: ["Pairing"]),
    ],
    dependencies: [
        .package(path: "../SecureStore"),
    ],
    targets: [
        .target(name: "Pairing", dependencies: ["SecureStore"]),
    ]
)
