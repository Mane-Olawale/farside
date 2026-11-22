// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SessionTransport",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SessionTransport", targets: ["SessionTransport"]),
    ],
    dependencies: [
        .package(path: "../WireProtocol"),
        .package(path: "../MediaCore"),
        // Pinned exactly; the binary target's SHA-256 is fixed in that release's manifest
        // (dd26ba28fb9c8dbc82f4be3085e8d112a4e2a4e654e1786a9977a748c24c4912). ADR 0003.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "158.0.0"),
    ],
    targets: [
        .target(name: "SessionTransport", dependencies: [
            "WireProtocol",
            "MediaCore",
            "WebRTCAudioShim",
            .product(name: "WebRTC", package: "WebRTC"),
        ]),
        .target(name: "WebRTCAudioShim", dependencies: [
            .product(name: "WebRTC", package: "WebRTC"),
        ]),
    ]
)
