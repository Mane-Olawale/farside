// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SecureStore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SecureStore", targets: ["SecureStore"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "SecureStore", dependencies: []),
    ]
)
