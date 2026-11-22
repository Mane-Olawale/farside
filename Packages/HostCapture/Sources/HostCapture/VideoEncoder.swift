#if os(macOS)
import CoreMedia
import Foundation
import MediaCore
import VideoToolbox

public struct EncoderSettings: Sendable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var framesPerSecond: Int
    public var maxFrameQP: Int?
    public var useConferencingPreset: Bool
    /// Low-latency rate control (plan section 8). Off only for comparison runs.
    public var lowLatencyRateControl: Bool

    public init(codec: VideoCodec, width: Int, height: Int, bitrate: Int, framesPerSecond: Int = 60,
                maxFrameQP: Int? = 40, useConferencingPreset: Bool = true, lowLatencyRateControl: Bool = true) {
        self.codec = codec
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.framesPerSecond = framesPerSecond
        self.maxFrameQP = maxFrameQP
        self.useConferencingPreset = useConferencingPreset
        self.lowLatencyRateControl = lowLatencyRateControl
    }
}

/// What the encoder accepted, for the spike report.
public struct EncoderReport: Sendable, Codable {
    public var hardwareAccelerated: Bool?
    public var conferencingPresetApplied: Bool
    /// What the conferencing preset contains on this encoder, whether or not it was applied.
    public var presetSettings: [String: String]
    public var rejectedProperties: [String]
}

public struct EncodedOutput: Sendable {
    public let frame: EncodedFrame
    public let source: CapturedFrame
    public let submitTicks: UInt64
    /// When VideoToolbox returned the compressed sample.
    public let outputTicks: UInt64
    /// When the Annex B frame was ready to send.
    public let packagedTicks: UInt64
}

public enum EncoderError: Error {
    case createFailed(OSStatus)
}

/// A hardware `VTCompressionSession` in low-latency rate control mode (plan section 8).
/// Encoded output is Annex B with parameter sets in front of each key frame.
public final class VideoEncoder: @unchecked Sendable {
    public let settings: EncoderSettings
    public private(set) var report: EncoderReport
    private let session: VTCompressionSession

    public init(settings: EncoderSettings) throws {
        self.settings = settings
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: settings.lowLatencyRateControl ? kCFBooleanTrue : kCFBooleanFalse,
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(settings.width),
            height: Int32(settings.height),
            codecType: settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw EncoderError.createFailed(status) }
        session = created
        report = EncoderReport(hardwareAccelerated: nil, conferencingPresetApplied: false, presetSettings: [:], rejectedProperties: [])
        configure()
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    private func configure() {
        // Start from the encoder's own conferencing preset, then override (plan section 8).
        if let all = copyProperty(kVTCompressionPropertyKey_SupportedPresetDictionaries) as? [String: Any],
           let conferencing = all[kVTCompressionPreset_VideoConferencing as String] as? [String: Any] {
            report.presetSettings = conferencing.mapValues { String(describing: $0) }
            if settings.useConferencingPreset {
                report.conferencingPresetApplied = VTSessionSetProperties(session, propertyDictionary: conferencing as CFDictionary) == noErr
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.framesPerSecond as CFNumber, "ExpectedFrameRate")
        set(kVTCompressionPropertyKey_ProfileLevel,
            settings.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            "ProfileLevel")
        set(kVTCompressionPropertyKey_AverageBitRate, settings.bitrate as CFNumber, "AverageBitRate")
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max as CFNumber, "MaxKeyFrameInterval")
        if let qp = settings.maxFrameQP {
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber, "MaxAllowedFrameQP")
        }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2, "ColorPrimaries")
        set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2, "TransferFunction")
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, "YCbCrMatrix")

        report.hardwareAccelerated = copyProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool
    }

    private func copyProperty(_ key: CFString) -> CFTypeRef? {
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    /// A rejected property is a warning, not a failure (plan section 8).
    private func set(_ key: CFString, _ value: CFTypeRef, _ name: String) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr { report.rejectedProperties.append("\(name) (\(status))") }
    }

    public func updateBitrate(_ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    }

    /// Encodes one frame. `completion` runs on a VideoToolbox thread with the output, or nil if
    /// the encoder failed or dropped the frame.
    public func encode(_ frame: CapturedFrame, forceKeyFrame: Bool, completion: @escaping @Sendable (EncodedOutput?) -> Void) {
        let properties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let codec = settings.codec
        let submit = HostClock.now()
        let pts = CMClockMakeHostTimeFromSystemUnits(frame.displayTicks)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixels.buffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            let output = HostClock.now()
            guard status == noErr, let sampleBuffer,
                  let encoded = Self.package(sampleBuffer, codec: codec, number: frame.number, displayTicks: frame.displayTicks)
            else {
                completion(nil)
                return
            }
            completion(EncodedOutput(frame: encoded, source: frame, submitTicks: submit, outputTicks: output, packagedTicks: HostClock.now()))
        }
        if status != noErr { completion(nil) }
    }

    /// Length-prefixed sample to Annex B, with parameter sets in front of key frames.
    static func package(_ sample: CMSampleBuffer, codec: VideoCodec, number: UInt64, displayTicks: UInt64) -> EncodedFrame? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription,
              let bytes = try? block.dataBytes()
        else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let isKey = !notSync

        let (parameterSets, headerLength) = Self.parameterSets(format, codec: codec)
        guard let units = LengthPrefixed.split(bytes, prefixLength: headerLength) else { return nil }
        let data = AnnexB.join(isKey ? parameterSets + units : units)
        return EncodedFrame(codec: codec, data: data, isKeyFrame: isKey, number: number, displayTicks: displayTicks)
    }

    static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> ([Data], Int) {
        var count = 0
        var headerLength: Int32 = 4
        var sets: [Data] = []
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = switch codec {
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            }
            guard status == noErr, let pointer else { break }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return (sets, Int(headerLength))
    }
}
#endif

#if os(macOS)
extension VideoEncoder: FrameEncoding {
    public var codec: VideoCodec { settings.codec }

    public func encodeFrame(_ pixels: PixelBufferBox, number: UInt64, displayTicks: UInt64, forceKeyFrame: Bool,
                            completion: @escaping @Sendable (EncodedFrame?) -> Void) {
        let frame = CapturedFrame(pixels: pixels, number: number, displayTicks: displayTicks, arrivalTicks: HostClock.now())
        encode(frame, forceKeyFrame: forceKeyFrame) { completion($0?.frame) }
    }
}
#endif
