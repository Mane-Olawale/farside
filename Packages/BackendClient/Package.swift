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
        .package(path: "../Pairing"),
        .package(path: "../SecureStore"),
        .package(path: "../SessionTransport"),
    ],
    targets: [
        .target(name: "BackendClient", dependencies: [
            "Pairing",
            "SecureStore",
            .product(name: "SessionTransport", package: "SessionTransport"),
        ]),
        .testTarget(name: "BackendClientTests", dependencies: [
            "BackendClient", "Pairing", "SecureStore",
            .product(name: "SessionTransport", package: "SessionTransport"),
        ]),
    ]
)
