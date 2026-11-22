// swift-tools-version: 6.2
import PackageDescription

// Two libraries (ADR 0003, plan section 5 rule 1):
// - SessionTransport: the transport protocol, the session state machine, LAN discovery and
//   signaling, and an in-memory transport for tests. No WebRTC.
// - SessionTransportWebRTC: the WebRTC implementation. The only code in the repository that
//   imports WebRTC, and nothing public in it mentions a WebRTC type.
let package = Package(
    name: "SessionTransport",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SessionTransport", targets: ["SessionTransport"]),
        .library(name: "SessionTransportWebRTC", targets: ["SessionTransportWebRTC"]),
    ],
    dependencies: [
        .package(path: "../WireProtocol"),
        .package(path: "../MediaCore"),
        // Pinned exactly; the binary target's SHA-256 is fixed in that release's manifest
        // (dd26ba28fb9c8dbc82f4be3085e8d112a4e2a4e654e1786a9977a748c24c4912). ADR 0003.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "158.0.0"),
    ],
    targets: [
        .target(name: "SessionTransport", dependencies: ["WireProtocol", "MediaCore"]),
        .target(name: "SessionTransportWebRTC", dependencies: [
            "SessionTransport",
            "WireProtocol",
            "MediaCore",
            "WebRTCAudioShim",
            .product(name: "WebRTC", package: "WebRTC"),
        ]),
        .target(name: "WebRTCAudioShim", dependencies: [
            .product(name: "WebRTC", package: "WebRTC"),
        ]),
        .testTarget(name: "SessionTransportTests", dependencies: ["SessionTransport"]),
        .testTarget(name: "SessionTransportWebRTCTests", dependencies: ["SessionTransportWebRTC", "SessionTransport"]),
    ]
)
