// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HostCapture",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HostCapture", targets: ["HostCapture"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
    ],
    targets: [
        .target(name: "HostCapture", dependencies: ["MediaCore"]),
        .testTarget(name: "HostCaptureTests", dependencies: ["HostCapture"]),
    ]
)
