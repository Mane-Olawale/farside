// EncodedFrame, codec identifiers, parameter set parsing, length-prefixed to Annex B conversion,
// clock offset estimation.
import CoreVideo
import Foundation

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case hevc
    case h264

    /// NAL unit type from the first header byte.
    public func nalType(_ firstByte: UInt8) -> UInt8 {
        switch self {
        case .hevc: (firstByte >> 1) & 0x3F
        case .h264: firstByte & 0x1F
        }
    }

    /// VPS, SPS or PPS for HEVC; SPS or PPS for H.264.
    public func isParameterSet(_ nal: Data) -> Bool {
        guard let first = nal.first else { return false }
        let type = nalType(first)
        switch self {
        case .hevc: return (32...34).contains(type)
        case .h264: return type == 7 || type == 8
        }
    }

    /// An intra random access point: IDR, CRA or BLA for HEVC; IDR for H.264.
    public func isKeyFrameSlice(_ nal: Data) -> Bool {
        guard let first = nal.first else { return false }
        let type = nalType(first)
        switch self {
        case .hevc: return (16...21).contains(type)
        case .h264: return type == 5
        }
    }
}

/// One compressed video frame as it travels on the wire: Annex B, with parameter sets in front
/// of every key frame.
public struct EncodedFrame: Sendable {
    public var codec: VideoCodec
    public var data: Data
    public var isKeyFrame: Bool
    /// Capture sequence number from the host.
    public var number: UInt64
    /// Host clock ticks (`mach_absolute_time`) when the captured content was on the Mac's display.
    public var displayTicks: UInt64

    public init(codec: VideoCodec, data: Data, isKeyFrame: Bool, number: UInt64, displayTicks: UInt64) {
        self.codec = codec
        self.data = data
        self.isKeyFrame = isKeyFrame
        self.number = number
        self.displayTicks = displayTicks
    }
}

/// Carries a pixel buffer across queues without copying (plan section 5, package rule 5).
/// The owner must not mutate the pixels after handing the box on.
public struct PixelBufferBox: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
