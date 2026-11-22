// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WireProtocol",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "WireProtocol", targets: ["WireProtocol"]),
    ],
    dependencies: [
        // Pinned exactly. `make proto` builds protoc-gen-swift from this same package, so the
        // generated code always matches the runtime library.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.41.0"),
    ],
    targets: [
        .target(name: "WireProtocol", dependencies: [
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ]),
        .testTarget(
            name: "WireProtocolTests",
            dependencies: ["WireProtocol"],
            resources: [.copy("Golden")]
        ),
    ]
)
