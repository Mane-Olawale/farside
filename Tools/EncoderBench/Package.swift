// swift-tools-version: 6.2
import PackageDescription

// Times HostCapture's VideoEncoder on complete synthetic frames, with no capture in the way.
//
//     swift run -c release --package-path Tools/EncoderBench EncoderBench 3440 1440 hevc [60] [ll|normal]
let package = Package(
    name: "EncoderBench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/HostCapture"),
        .package(path: "../../Packages/MediaCore"),
    ],
    targets: [
        .executableTarget(name: "EncoderBench", dependencies: ["HostCapture", "MediaCore"]),
    ]
)
