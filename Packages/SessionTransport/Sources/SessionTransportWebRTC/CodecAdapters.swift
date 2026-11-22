// Adapters between our VideoToolbox codecs and WebRTC's encoder, decoder, capturer and renderer
// interfaces (plan section 5, rule 1; ADR 0003).
import CoreVideo
import Foundation
import MediaCore
@preconcurrency import WebRTC

enum CodecNames {
    static let h265 = "H265"
    static let h264 = kRTCVideoCodecH264Name

    static func codec(_ name: String) -> VideoCodec? {
        switch name {
        case h265: .hevc
        case h264: .h264
        default: nil
        }
    }

    /// Advertised formats. HEVC Main, level 6.0 so any panel-size stream fits; H.264 High 5.2.
    static func info(_ codec: VideoCodec) -> RTCVideoCodecInfo {
        switch codec {
        case .hevc:
            RTCVideoCodecInfo(name: h265, parameters: ["profile-id": "1", "tier-flag": "0", "level-id": "180", "tx-mode": "SRST"])
        case .h264:
            RTCVideoCodecInfo(name: h264, parameters: ["profile-level-id": "640c34", "packetization-mode": "1", "level-asymmetry-allowed": "1"])
        }
    }
}

/// The SDK has no H.265 codec-specific info class. The callback needs some object, and the
/// packetizer is chosen from the negotiated payload, not from this.
final class GenericCodecInfo: NSObject, RTCCodecSpecificInfo {}

/// Wraps our VideoToolbox encoder as a WebRTC encoder (plan section 5, package rule 1).
///
/// This is also the frame gate (plan section 8): one frame in the encoder, at most one waiting,
/// newest wins. WebRTC sits between capture and encode, so the gate has to sit here. Spike S1
/// measured about 16 ms per frame at panel size, so without it frames would queue in VideoToolbox.
final class EncoderAdapter: NSObject, RTCVideoEncoder, @unchecked Sendable {
    private struct Pending: Sendable {
        let pixels: PixelBufferBox
        let width: Int
        let height: Int
        let rtpTimestamp: Int32
        let timeStampNs: Int64
    }

    private let codec: VideoCodec
    private let make: @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding?
    private let gate = LatestSlot<Pending>()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var encoder: FrameEncoding?
    private var callback: RTCVideoEncoderCallback?
    private var width = 0
    private var height = 0
    private var bitrate = 0
    /// A key frame was asked for and not yet submitted. Survives the asking frame being replaced.
    private var keyFrameWanted = false

    init(codec: VideoCodec, make: @escaping @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding?) {
        self.codec = codec
        self.make = make
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        lock.withLock { self.callback = callback }
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.withLock {
            width = Int(settings.width)
            height = Int(settings.height)
            bitrate = Int(settings.startBitrate) * 1000
            encoder = make(codec, width, height, max(bitrate, 1_000_000))
            return encoder == nil ? -1 : 0
        }
    }

    func release() -> Int {
        lock.withLock { encoder = nil }
        return 0
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return -1 }
        let pixels = buffer.pixelBuffer
        if frameTypes.contains(where: { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }) {
            lock.withLock { keyFrameWanted = true }
        }
        let pending = Pending(pixels: PixelBufferBox(pixels), width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                              rtpTimestamp: frame.timeStamp, timeStampNs: frame.timeStampNs)
        if let start = gate.offer(pending) { submit(start) }
        return 0
    }

    /// Frames replaced in the gate before they reached the encoder, since the last call.
    func takeReplacedCount() -> Int { gate.takeReplacedCount() }

    private func submit(_ first: Pending) {
        let codec = self.codec
        var next: Pending? = first
        while let item = next {
            let prepared: (FrameEncoding, Bool)? = lock.withLock {
                if encoder == nil || item.width != width || item.height != height {
                    width = item.width
                    height = item.height
                    encoder = make(codec, item.width, item.height, max(bitrate, 1_000_000))
                    keyFrameWanted = true
                }
                guard let encoder else { return nil }
                defer { keyFrameWanted = false }
                return (encoder, keyFrameWanted)
            }
            guard let (encoder, key) = prepared else {
                next = gate.finish()
                continue
            }
            encoder.encodeFrame(item.pixels, number: UInt64(UInt32(bitPattern: item.rtpTimestamp)),
                                displayTicks: UInt64(max(item.timeStampNs, 0)), forceKeyFrame: key) { [weak self] encoded in
                guard let self else { return }
                if let encoded, let callback = self.lock.withLock({ self.callback }) {
                    let image = RTCEncodedImage()
                    image.buffer = encoded.data
                    image.encodedWidth = Int32(item.width)
                    image.encodedHeight = Int32(item.height)
                    image.timeStamp = UInt32(bitPattern: item.rtpTimestamp)
                    image.captureTimeMs = item.timeStampNs / 1_000_000
                    image.frameType = encoded.isKeyFrame ? .videoFrameKey : .videoFrameDelta
                    image.rotation = ._0
                    image.contentType = .screenshare
                    let info: RTCCodecSpecificInfo
                    if codec == .h264 {
                        let h264 = RTCCodecSpecificInfoH264()
                        h264.packetizationMode = .nonInterleaved
                        info = h264
                    } else {
                        info = GenericCodecInfo()
                    }
                    FrameTimeline.shared.mark(.encoded)
                    _ = callback(image, info)
                } else if encoded == nil, key {
                    // A dropped key frame must not be forgotten.
                    self.lock.withLock { self.keyFrameWanted = true }
                }
                if let waiting = self.gate.finish() { self.submit(waiting) }
            }
            return
        }
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        let encoder: FrameEncoding? = lock.withLock {
            bitrate = Int(bitrateKbit) * 1000
            return bitrate > 0 ? self.encoder : nil
        }
        encoder?.updateBitrate(Int(bitrateKbit) * 1000)
        return 0
    }

    func implementationName() -> String { "Farside VideoToolbox \(codec.rawValue)" }

    /// No QP scaler: the adaptation ladder decides resolution (plan section 8).
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }

    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
}

final class EncoderFactory: NSObject, RTCVideoEncoderFactory, @unchecked Sendable {
    private let codecs: [VideoCodec]
    private let make: @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding?

    init(codecs: [VideoCodec], make: @escaping @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding?) {
        self.codecs = codecs
        self.make = make
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        guard let codec = CodecNames.codec(info.name), codecs.contains(codec) else { return nil }
        return EncoderAdapter(codec: codec, make: make)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] { codecs.map(CodecNames.info) }
}

/// Wraps our VideoToolbox decoder as a WebRTC decoder.
final class DecoderAdapter: NSObject, RTCVideoDecoder, @unchecked Sendable {
    private let codec: VideoCodec
    private let decoder: FrameDecoding
    private var callback: RTCVideoDecoderCallback?
    private let lock = NSLock()

    init(codec: VideoCodec, decoder: FrameDecoding) {
        self.codec = codec
        self.decoder = decoder
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        lock.withLock { self.callback = callback }
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { 0 }
    func release() -> Int { 0 }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        let rtpTimestamp = encodedImage.timeStamp
        FrameTimeline.shared.arrived(rtpTimestamp: rtpTimestamp)
        let captureMs = encodedImage.captureTimeMs
        let frame = EncodedFrame(codec: codec, data: encodedImage.buffer, isKeyFrame: encodedImage.frameType == .videoFrameKey,
                                 number: UInt64(rtpTimestamp), displayTicks: 0)
        let accepted = decoder.decodeFrame(frame) { [weak self] pixels in
            FrameTimeline.shared.mark(.decoded)
            guard let self, let callback = self.lock.withLock({ self.callback }) else { return }
            let out = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels.buffer), rotation: ._0, timeStampNs: captureMs * 1_000_000)
            out.timeStamp = Int32(bitPattern: rtpTimestamp)
            callback(out)
        }
        // An error makes WebRTC ask the sender for a key frame.
        return accepted ? 0 : -1
    }

    func implementationName() -> String { "Farside VideoToolbox \(codec.rawValue)" }
}

final class DecoderFactory: NSObject, RTCVideoDecoderFactory, @unchecked Sendable {
    private let codecs: [VideoCodec]
    private let make: @Sendable (VideoCodec) -> FrameDecoding?

    init(codecs: [VideoCodec], make: @escaping @Sendable (VideoCodec) -> FrameDecoding?) {
        self.codecs = codecs
        self.make = make
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        guard let codec = CodecNames.codec(info.name), codecs.contains(codec), let decoder = make(codec) else { return nil }
        return DecoderAdapter(codec: codec, decoder: decoder)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] { codecs.map(CodecNames.info) }
}

/// Pushes our captured frames into a WebRTC video source.
final class FrameInjector: RTCVideoCapturer, @unchecked Sendable {
    func push(_ pixels: PixelBufferBox, timestampNs: Int64) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels.buffer), rotation: ._0, timeStampNs: timestampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}

/// Hands decoded frames back to our renderer.
final class FrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let onFrame: @Sendable (PixelBufferBox, UInt32) -> Void
    var onUnexpected: (@Sendable (String) -> Void)?
    private var reported = false

    init(onFrame: @escaping @Sendable (PixelBufferBox, UInt32) -> Void) {
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else {
            if !reported {
                reported = true
                onUnexpected?("renderer got \(type(of: frame.buffer as AnyObject))")
            }
            return
        }
        onFrame(PixelBufferBox(buffer.pixelBuffer), UInt32(bitPattern: frame.timeStamp))
    }
}
