import Foundation
import Testing
@testable import WireProtocol

/// Golden files (plan section 11, versioning). `Golden/v1` holds one encoded envelope per message
/// type, written when protocol 1.0 was defined. Every later version adds a folder and keeps the
/// old ones, and every file in every folder must still decode.
///
/// To write the files for the current version, run once with FARSIDE_WRITE_GOLDEN=1:
///
///     FARSIDE_WRITE_GOLDEN=1 swift test --package-path Packages/WireProtocol
///
/// Never rewrite a folder for a version that has shipped.
@Suite struct GoldenTests {
    static let version = "v1"

    static let fixtures: [(name: String, envelope: Envelope)] = [
        ("hello", Envelope(seq: 1, sentAtMicroseconds: 1_000_001, body: .hello(.with {
            $0.protocolMajor = 1
            $0.protocolMinor = 0
            $0.appVersion = "0.1.0"
            $0.deviceModel = "iPad16,5"
            $0.osVersion = "27.2.1"
            $0.deviceName = "Test iPad"
            $0.capabilities = .with {
                $0.codecs = [.hevc, .h264]
                $0.maxWidth = 2752
                $0.maxHeight = 2064
                $0.maxFrameRate = 120
                $0.audio = true
            }
            $0.sessionNonce = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
            $0.resumeToken = Data([0xAA, 0xBB])
        }))),
        ("hello_ack", Envelope(seq: 1, sentAtMicroseconds: 2_000_002, body: .helloAck(.with {
            $0.protocolMajor = 1
            $0.protocolMinor = 0
            $0.appVersion = "0.1.0"
            $0.deviceModel = "Mac15,6"
            $0.osVersion = "26.0.1"
            $0.deviceName = "Test Mac"
            $0.capabilities = .with {
                $0.codecs = [.hevc, .h264]
                $0.maxWidth = 3456
                $0.maxHeight = 2234
                $0.maxFrameRate = 60
            }
            $0.sessionNonce = Data([0x11, 0x12, 0x13, 0x14])
            $0.resumeToken = Data([0xCC, 0xDD, 0xEE])
        }))),
        ("stream_config", Envelope(seq: 2, sentAtMicroseconds: 3_000_003, body: .streamConfig(.with {
            $0.displayID = 1
            $0.width = 2752
            $0.height = 2064
            $0.frameRate = 60
            $0.codecPreference = [.hevc, .h264]
            $0.quality = .balanced
            $0.audio = false
        }))),
        ("stream_config_applied", Envelope(seq: 3, sentAtMicroseconds: 4_000_004, body: .streamConfigApplied(.with {
            $0.displayID = 1
            $0.width = 2752
            $0.height = 1152
            $0.frameRate = 60
            $0.codec = .hevc
            $0.quality = .balanced
            $0.contentRect = .with { $0.x = 0; $0.y = 0; $0.width = 2752; $0.height = 1152 }
            $0.scale = 0.8
        }))),
        ("display_list", Envelope(seq: 4, sentAtMicroseconds: 5_000_005, body: .displayList(.with {
            $0.displays = [
                .with {
                    $0.id = 1
                    $0.name = "Built-in Retina Display"
                    $0.pixelWidth = 3456
                    $0.pixelHeight = 2234
                    $0.pointWidth = 1728
                    $0.pointHeight = 1117
                    $0.scale = 2
                    $0.main = true
                    $0.builtIn = true
                    $0.refreshRate = 120
                },
                .with {
                    $0.id = 3
                    $0.name = "External"
                    $0.pixelWidth = 3440
                    $0.pixelHeight = 1440
                    $0.pointWidth = 3440
                    $0.pointHeight = 1440
                    $0.scale = 1
                    $0.originX = 1728
                    $0.originY = -200
                    $0.refreshRate = 60
                },
            ]
        }))),
        ("ping", Envelope(seq: 5, sentAtMicroseconds: 6_000_006, body: .ping(.with { $0.senderTimeUs = 6_000_006 }))),
        ("pong", Envelope(seq: 6, sentAtMicroseconds: 7_000_007, body: .pong(.with {
            $0.pingSenderTimeUs = 6_000_006
            $0.receiverTimeUs = 9_123_456
        }))),
        ("bye", Envelope(seq: 7, sentAtMicroseconds: 8_000_008, body: .bye(.with {
            $0.reason = .userEnded
            $0.detail = "quit"
        }))),
    ]

    static var goldenSourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Golden").appendingPathComponent(version)
    }

    static func bundledGolden() throws -> URL {
        try #require(Bundle.module.url(forResource: "Golden", withExtension: nil))
    }

    @Test func writeGoldenFilesWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_WRITE_GOLDEN"] == "1" else { return }
        let directory = Self.goldenSourceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in Self.fixtures {
            try fixture.envelope.encoded().write(to: directory.appendingPathComponent("\(fixture.name).bin"))
        }
    }

    /// Encoding today's fixtures gives exactly the bytes on disk, and the bytes decode back to them.
    @Test(arguments: fixtures.map(\.name))
    func currentVersionMatchesGolden(name: String) throws {
        let envelope = try #require(Self.fixtures.first { $0.name == name }?.envelope)
        let url = try Self.bundledGolden().appendingPathComponent(Self.version).appendingPathComponent("\(name).bin")
        let golden = try Data(contentsOf: url)
        #expect(try envelope.encoded() == golden)
        #expect(try Envelope.decoded(golden, on: .control) == envelope)
    }

    /// Every golden file from every version decodes.
    @Test func everyGoldenFileDecodes() throws {
        let root = try Self.bundledGolden()
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "bin" }
        #expect(files.count >= Self.fixtures.count)
        for file in files {
            let data = try Data(contentsOf: file)
            let envelope = try Envelope.decoded(data, on: .control)
            #expect(envelope.body != nil, "\(file.lastPathComponent)")
        }
    }
}
