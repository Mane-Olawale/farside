import CoreVideo
import Foundation
import MediaCore
import Testing
@preconcurrency import WebRTC
@testable import SessionTransportWebRTC

/// Holds each submitted frame until the test releases it, like a busy hardware encoder.
final class HeldEncoder: FrameEncoding, @unchecked Sendable {
    let codec = VideoCodec.hevc
    private let lock = NSLock()
    private(set) var submitted: [(number: UInt64, key: Bool)] = []
    private var held: [@Sendable (EncodedFrame?) -> Void] = []

    func encodeFrame(_ pixels: PixelBufferBox, number: UInt64, displayTicks: UInt64, forceKeyFrame: Bool,
                     completion: @escaping @Sendable (EncodedFrame?) -> Void) {
        lock.withLock {
            submitted.append((number, forceKeyFrame))
            held.append(completion)
        }
    }

    func updateBitrate(_ bitsPerSecond: Int) {}

    /// Completes the oldest held frame.
    func completeOne(drop: Bool = false) {
        let next = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        next?(drop ? nil : EncodedFrame(codec: .hevc, data: Data([0, 0, 0, 1, 0x02, 0x01]), isKeyFrame: false, number: 0, displayTicks: 0))
    }

    var numbers: [UInt64] { lock.withLock { submitted.map(\.number) } }
    var keys: [Bool] { lock.withLock { submitted.map(\.key) } }
}

@Suite struct EncoderGateTests {
    static func frame(_ rtp: Int32, width: Int = 64, height: Int = 36) -> RTCVideoFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer!), rotation: ._0, timeStampNs: Int64(rtp) * 1_000_000)
        f.timeStamp = rtp
        return f
    }

    static let key = [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
    static let delta = [NSNumber(value: RTCFrameType.videoFrameDelta.rawValue)]

    func makeAdapter() -> (EncoderAdapter, HeldEncoder) {
        let held = HeldEncoder()
        let adapter = EncoderAdapter(codec: .hevc, make: { _, _, _, _ in held })
        adapter.setCallback { _, _ in true }
        let settings = RTCVideoEncoderSettings()
        settings.width = 64
        settings.height = 36
        settings.startBitrate = 20_000
        _ = adapter.startEncode(with: settings, numberOfCores: 1)
        return (adapter, held)
    }

    @Test func newestWaitingFrameWins() {
        let (adapter, held) = makeAdapter()
        _ = adapter.encode(Self.frame(1), codecSpecificInfo: nil, frameTypes: Self.delta)
        _ = adapter.encode(Self.frame(2), codecSpecificInfo: nil, frameTypes: Self.delta)
        _ = adapter.encode(Self.frame(3), codecSpecificInfo: nil, frameTypes: Self.delta)
        #expect(held.numbers == [1], "one frame in the encoder at a time")
        held.completeOne()
        #expect(held.numbers == [1, 3], "frame 2 was replaced by 3")
        #expect(adapter.takeReplacedCount() == 1)
        held.completeOne()
        _ = adapter.encode(Self.frame(4), codecSpecificInfo: nil, frameTypes: Self.delta)
        #expect(held.numbers == [1, 3, 4], "an idle encoder takes the next frame at once")
    }

    @Test func keyFrameRequestSurvivesReplacement() {
        let (adapter, held) = makeAdapter()
        _ = adapter.encode(Self.frame(1), codecSpecificInfo: nil, frameTypes: Self.delta)
        _ = adapter.encode(Self.frame(2), codecSpecificInfo: nil, frameTypes: Self.key)
        _ = adapter.encode(Self.frame(3), codecSpecificInfo: nil, frameTypes: Self.delta)
        held.completeOne()
        #expect(held.numbers == [1, 3])
        #expect(held.keys == [false, true])
    }

    @Test func droppedKeyFrameIsRequestedAgain() {
        let (adapter, held) = makeAdapter()
        _ = adapter.encode(Self.frame(1), codecSpecificInfo: nil, frameTypes: Self.key)
        held.completeOne(drop: true)
        _ = adapter.encode(Self.frame(2), codecSpecificInfo: nil, frameTypes: Self.delta)
        #expect(held.keys == [true, true])
    }

    @Test func sizeChangeRecreatesTheEncoderWithAKeyFrame() {
        let (adapter, held) = makeAdapter()
        _ = adapter.encode(Self.frame(1), codecSpecificInfo: nil, frameTypes: Self.delta)
        held.completeOne()
        _ = adapter.encode(Self.frame(2, width: 128, height: 72), codecSpecificInfo: nil, frameTypes: Self.delta)
        #expect(held.keys == [false, true])
    }
}
