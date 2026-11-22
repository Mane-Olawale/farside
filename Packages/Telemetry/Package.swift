// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Telemetry",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Telemetry", targets: ["Telemetry"]),
    ],
    targets: [
        .target(name: "Telemetry"),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry"]),
    ]
)
