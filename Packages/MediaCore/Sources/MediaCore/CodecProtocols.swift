/// What a transport needs from a hardware encoder. `HostCapture.VideoEncoder` conforms. The
/// transport package sees only this, never a capture type (plan section 5, package rule 1).
public protocol FrameEncoding: AnyObject, Sendable {
    var codec: VideoCodec { get }
    /// Encodes one frame. `completion` runs on an encoder thread with Annex B output, or nil if
    /// the frame was dropped.
    func encodeFrame(_ pixels: PixelBufferBox, number: UInt64, displayTicks: UInt64, forceKeyFrame: Bool,
                     completion: @escaping @Sendable (EncodedFrame?) -> Void)
    func updateBitrate(_ bitsPerSecond: Int)
}

/// What a transport needs from a hardware decoder. `ClientVideo.VideoDecoder` conforms.
public protocol FrameDecoding: AnyObject, Sendable {
    /// Submits one Annex B frame. Returns false if it cannot be decoded, for example a delta frame
    /// before any key frame, so the transport can ask the sender for a key frame.
    func decodeFrame(_ frame: EncodedFrame, completion: @escaping @Sendable (PixelBufferBox) -> Void) -> Bool
}
