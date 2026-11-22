// Hardware decoder, Metal renderer, frame pacing. Built for iPadOS and macOS: VideoToolbox and
// Metal are the same on both, and the macOS build drives the loopback rig.
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import VideoToolbox

public struct DecodedOutput: Sendable {
    public let pixels: PixelBufferBox
    public let frame: EncodedFrame
    public let submitTicks: UInt64
    public let outputTicks: UInt64
}

public enum DecoderEvent: Sendable {
    /// No format yet, or the frame could not be parsed. Ask the host for a key frame.
    case needsKeyFrame
    case decodeFailed(OSStatus)
}

/// A hardware `VTDecompressionSession` fed with Annex B frames (plan section 8, decoder settings).
/// The session is rebuilt whenever the parameter sets change. Call `decode` from one queue.
public final class VideoDecoder: @unchecked Sendable {
    public private(set) var hardwareAccelerated: Bool?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private let onEvent: @Sendable (DecoderEvent) -> Void

    public init(onEvent: @escaping @Sendable (DecoderEvent) -> Void = { _ in }) {
        self.onEvent = onEvent
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Returns false, and reports `needsKeyFrame`, if the frame cannot be submitted.
    @discardableResult
    public func decode(_ frame: EncodedFrame, completion: @escaping @Sendable (DecodedOutput) -> Void) -> Bool {
        let submit = HostClock.now()
        var sets: [Data] = []
        var slices: [Data] = []
        for unit in AnnexB.split(frame.data) {
            if frame.codec.isParameterSet(unit) { sets.append(unit) } else { slices.append(unit) }
        }
        if !sets.isEmpty, sets != parameterSets {
            rebuild(codec: frame.codec, sets: sets)
        }
        guard let session, let format, !slices.isEmpty,
              let sample = Self.makeSample(LengthPrefixed.join(slices), format: format)
        else {
            onEvent(.needsKeyFrame)
            return false
        }
        let onEvent = self.onEvent
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                onEvent(.decodeFailed(status))
                return
            }
            completion(DecodedOutput(pixels: PixelBufferBox(imageBuffer), frame: frame, submitTicks: submit, outputTicks: HostClock.now()))
        }
        if status != noErr {
            if status == kVTInvalidSessionErr { self.session = nil; parameterSets = [] }
            onEvent(.decodeFailed(status))
            return false
        }
        return true
    }

    private func rebuild(codec: VideoCodec, sets: [Data]) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = Self.makeFormat(codec: codec, sets: sets)
        parameterSets = sets
        guard let format else { return }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            onEvent(.decodeFailed(status))
            return
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hardware: Unmanaged<CFTypeRef>?
        let copied = withUnsafeMutablePointer(to: &hardware) {
            VTSessionCopyProperty(created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        if copied == noErr { hardwareAccelerated = hardware?.takeRetainedValue() as? Bool }
        session = created
    }

    static func makeFormat(codec: VideoCodec, sets: [Data]) -> CMVideoFormatDescription? {
        let buffers = sets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = buffers.map(\.count)
        var format: CMFormatDescription?
        let status: OSStatus = switch codec {
        case .hevc:
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        case .h264:
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
            let block
        else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}

extension VideoDecoder: FrameDecoding {
    public func decodeFrame(_ frame: EncodedFrame, completion: @escaping @Sendable (PixelBufferBox) -> Void) -> Bool {
        decode(frame) { completion($0.pixels) }
    }
}
