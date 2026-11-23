import Foundation
import Testing
@testable import WireProtocol

/// Golden files (plan section 11, versioning). Each folder holds one encoded envelope per message
/// type added in that version: `Golden/v1` for 1.0, `Golden/v1_1` for the input and cursor
/// messages of 1.1. Every later version adds a folder and keeps the old ones, and every file in
/// every folder must still decode, on the channel its message belongs to.
///
/// To write the files for the current version only, run once with FARSIDE_WRITE_GOLDEN=1:
///
///     FARSIDE_WRITE_GOLDEN=1 swift test --package-path Packages/WireProtocol
///
/// Never rewrite a folder for a version that has shipped.
@Suite struct GoldenTests {
    /// The folder `FARSIDE_WRITE_GOLDEN` writes.
    static let currentVersion = "v1_2"

    static let fixtures: [(version: String, name: String, envelope: Envelope)] =
        v1.map { ("v1", $0.name, $0.envelope) } + v1_1.map { ("v1_1", $0.name, $0.envelope) }
        + v1_2.map { ("v1_2", $0.name, $0.envelope) }

    /// 1.2: pause, resume and notices (Phase 4).
    static let v1_2: [(name: String, envelope: Envelope)] = [
        ("pause", Envelope(seq: 20, sentAtMicroseconds: 20_000_020, body: .pause(.init()))),
        ("resume", Envelope(seq: 21, sentAtMicroseconds: 21_000_021, body: .resume(.with {
            $0.resumeToken = Data((0..<16).map { UInt8($0) })
        }))),
        ("notice", Envelope(seq: 22, sentAtMicroseconds: 22_000_022, body: .notice(.with {
            $0.code = .screenRecordingLost
            $0.detail = "stream stopped by the system"
        }))),
    ]

    static let v1_1: [(name: String, envelope: Envelope)] = [
        ("pointer_move", Envelope(seq: 10, sentAtMicroseconds: 10_000_010, body: .pointerMove(.with {
            $0.displayID = 3
            $0.x = 0.25
            $0.y = 0.75
            $0.buttons = 1
        }))),
        ("pointer_delta", Envelope(seq: 11, sentAtMicroseconds: 11_000_011, body: .pointerDelta(.with {
            $0.dx = 7
            $0.dy = -4
        }))),
        ("button", Envelope(seq: 12, sentAtMicroseconds: 12_000_012, body: .button(.with {
            $0.button = .left
            $0.down = true
            $0.clickCount = 2
            $0.displayID = 3
            $0.x = 0.5
            $0.y = 0.5
        }))),
        ("scroll", Envelope(seq: 13, sentAtMicroseconds: 13_000_013, body: .scroll(.with {
            $0.dx = 0
            $0.dy = -12.5
            $0.phase = .changed
            $0.momentumPhase = .none
            $0.continuous = true
        }))),
        ("key", Envelope(seq: 14, sentAtMicroseconds: 14_000_014, body: .key(.with {
            $0.hidUsage = 0x0E  // K
            $0.down = true
            $0.modifiers = UInt32(Farside_V1_Modifier.leftCommand.rawValue | Farside_V1_Modifier.leftShift.rawValue)
        }))),
        ("text", Envelope(seq: 15, sentAtMicroseconds: 15_000_015, body: .text(.with { $0.text = "héllo 👋🏽" }))),
        ("release_all", Envelope(seq: 16, sentAtMicroseconds: 16_000_016, body: .releaseAll(.init()))),
        ("input_heartbeat", Envelope(seq: 17, sentAtMicroseconds: 17_000_017, body: .inputHeartbeat(.init()))),
        ("cursor_shape", Envelope(seq: 18, sentAtMicroseconds: 18_000_018, body: .cursorShape(.with {
            $0.id = 7
            $0.png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            $0.width = 16
            $0.height = 24
            $0.hotX = 4
            $0.hotY = 3
            $0.scale = 2
        }))),
        ("cursor_state", Envelope(seq: 19, sentAtMicroseconds: 19_000_019, body: .cursorState(.with {
            $0.shapeID = 7
            $0.visible = true
        }))),
        ("cursor_position", Envelope(seq: 20, sentAtMicroseconds: 20_000_020, body: .cursorPosition(.with {
            $0.displayID = 3
            $0.x = 0.125
            $0.y = 0.875
            $0.lastInputSeq = 10
        }))),
    ]

    static let v1: [(name: String, envelope: Envelope)] = [
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
            .appendingPathComponent("Golden").appendingPathComponent(currentVersion)
    }

    static func bundledGolden() throws -> URL {
        try #require(Bundle.module.url(forResource: "Golden", withExtension: nil))
    }

    @Test func writeGoldenFilesWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_WRITE_GOLDEN"] == "1" else { return }
        let directory = Self.goldenSourceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in Self.fixtures where fixture.version == Self.currentVersion {
            try fixture.envelope.encoded().write(to: directory.appendingPathComponent("\(fixture.name).bin"))
        }
    }

    /// Encoding today's fixtures gives exactly the bytes on disk, and the bytes decode back to them.
    @Test(arguments: fixtures.map { "\($0.version)/\($0.name)" })
    func encodingMatchesGolden(path: String) throws {
        let envelope = try #require(Self.fixtures.first { "\($0.version)/\($0.name)" == path }?.envelope)
        let golden = try Data(contentsOf: Self.bundledGolden().appendingPathComponent("\(path).bin"))
        let channel = try #require(envelope.body?.channel)
        #expect(try envelope.encoded() == golden)
        #expect(try Envelope.decoded(golden, on: channel) == envelope)
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
            // Exactly one channel accepts each message.
            let accepted = Wire.Channel.allCases.compactMap { try? Envelope.decoded(data, on: $0) }
            #expect(accepted.count == 1, "\(file.lastPathComponent)")
        }
    }
}
