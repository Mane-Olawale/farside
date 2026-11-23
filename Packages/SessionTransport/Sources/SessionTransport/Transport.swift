import Foundation
import MediaCore
import WireProtocol

// The transport seen by the rest of the product (ADR 0003, plan section 5 rule 1). Nothing in
// this target imports WebRTC. The WebRTC implementation is `WebRTCTransport` in the
// `SessionTransportWebRTC` target; apps import that target only to construct one.
//
// A transport moves opaque bytes on the four data channels, carries video from the host to the
// client, and produces and consumes signaling messages. It knows nothing about envelopes,
// sessions or state: the session layer above it decides what the bytes mean.

public protocol SessionTransport: AnyObject, Sendable {
    /// Host only: creates the offer and sends it through the signal handler.
    func start()
    /// Applies a signaling message from the other side.
    func handle(_ message: SignalMessage)
    /// Sends one message. Unreliable channels may drop it.
    func send(_ data: Data, on channel: Wire.Channel)
    /// Host only. Hands a captured frame to the encoder. Call from the capture queue.
    func push(_ pixels: PixelBufferBox, timestampNs: Int64)
    /// Current statistics. Calls back on an arbitrary queue.
    func stats(completion: @escaping @Sendable (TransportStats) -> Void)
    /// Closes everything. Safe to call more than once.
    func close()
}

extension SessionTransport {
    public func stats() async -> TransportStats {
        await withCheckedContinuation { continuation in
            stats { continuation.resume(returning: $0) }
        }
    }
}

public enum TransportRole: Sendable, Equatable {
    /// Captures, encodes and sends video. Creates the offer.
    case host
    /// Receives, decodes and renders. Answers.
    case client
}

/// The path's health, as the session layer needs it.
public enum TransportState: Sendable, Equatable {
    case connecting
    case connected
    /// The path is gone for now; the transport keeps trying.
    case disconnected
    /// The transport gave up.
    case failed
    case closed
}

public enum TransportEvent: Sendable, Equatable {
    case state(TransportState)
    case channelOpen(Wire.Channel)
    case channelClosed(Wire.Channel)
    case message(Wire.Channel, Data)
    /// Diagnostics for the log. Never contains content.
    case log(String)
}

/// Callbacks a transport delivers on. They may arrive on any queue. `frame` is the video hot
/// path and must return quickly (plan section 5, rule 4).
public struct TransportHandlers: Sendable {
    public var signal: @Sendable (SignalMessage) -> Void
    public var event: @Sendable (TransportEvent) -> Void
    /// Client only: a decoded frame and its RTP timestamp.
    public var frame: (@Sendable (PixelBufferBox, UInt32) -> Void)?

    public init(signal: @escaping @Sendable (SignalMessage) -> Void,
                event: @escaping @Sendable (TransportEvent) -> Void,
                frame: (@Sendable (PixelBufferBox, UInt32) -> Void)? = nil) {
        self.signal = signal
        self.event = event
        self.frame = frame
    }
}

/// How the receiver's jitter buffer holds frames (spike S3).
public enum PlayoutMode: String, Sendable, Codable, CaseIterable {
    /// The transport's own adaptive delay.
    case standard
    /// Zero playout delay forced on the receiver.
    case receiverZero
    /// Zero playout delay requested by the sender in a header extension.
    case senderZero
    /// Both. The product default (plan section 8, transport settings).
    case both
}

/// One STUN or TURN server from the backend (plan section 12, transport configuration).
public struct TransportIceServer: Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct TransportConfiguration: Sendable, Equatable {
    public var playout: PlayoutMode
    /// None on a LAN; STUN and TURN with short-lived credentials over the internet.
    public var iceServers: [TransportIceServer] = []
    /// Relay only: the debug switch that forces TURN (plan section 12).
    public var relayOnly = false
    /// In order of preference.
    public var codecs: [VideoCodec]
    /// Where the bandwidth estimate starts. 20 Mbps on a LAN (plan section 12).
    public var startBitrateKbps: Int
    public var minBitrateKbps: Int
    public var maxBitrateKbps: Int
    public var maxFrameRate: Int

    public init(playout: PlayoutMode = .both, codecs: [VideoCodec] = [.hevc, .h264],
                startBitrateKbps: Int = 20_000, minBitrateKbps: Int = 1_500, maxBitrateKbps: Int = 40_000,
                maxFrameRate: Int = 60) {
        self.playout = playout
        self.codecs = codecs
        self.startBitrateKbps = startBitrateKbps
        self.minBitrateKbps = minBitrateKbps
        self.maxBitrateKbps = maxBitrateKbps
        self.maxFrameRate = maxFrameRate
    }

    /// Plan section 8 and 12 defaults for a LAN session.
    public static let lan = TransportConfiguration()

    /// An internet session: the backend's ICE servers, optionally relay only.
    public static func internet(iceServers: [TransportIceServer], relayOnly: Bool = false) -> TransportConfiguration {
        var configuration = TransportConfiguration()
        configuration.iceServers = iceServers
        configuration.relayOnly = relayOnly
        return configuration
    }
}

/// What the stats overlay and the spike reports read (plan section 16).
public struct TransportStats: Sendable, Codable, Equatable {
    public var codec: String?
    public var encoderImplementation: String?
    public var decoderImplementation: String?
    public var framesEncoded: Double?
    public var totalEncodeTime: Double?
    public var targetBitrate: Double?
    public var qualityLimitationReason: String?
    public var framesReceived: Double?
    public var framesDecoded: Double?
    public var framesDropped: Double?
    public var totalDecodeTime: Double?
    public var jitterBufferDelay: Double?
    public var jitterBufferTargetDelay: Double?
    public var jitterBufferMinimumDelay: Double?
    public var jitterBufferEmittedCount: Double?
    public var freezeCount: Double?
    public var packetsLost: Double?
    public var nackCount: Double?
    public var pliCount: Double?
    public var keyFramesDecoded: Double?
    public var bytesSent: Double?
    public var bytesReceived: Double?
    public var frameWidth: Double?
    public var frameHeight: Double?
    public var roundTripTime: Double?
    public var availableOutgoingBitrate: Double?
    public var localCandidateType: String?
    public var remoteCandidateType: String?
    public var playoutExtensionNegotiated: Bool?
    public var playoutExtensionInLocalSDP: Bool?
    public var playoutExtensionInRemoteSDP: Bool?
    public var audioCodec: String?
    public var audioPacketsSent: Double?
    public var audioBytesSent: Double?
    public var audioPacketsReceived: Double?
    public var audioPacketsLost: Double?
    public var audioJitterBufferDelay: Double?
    public var audioJitterBufferEmittedCount: Double?
    public var audioTotalSamplesReceived: Double?
    public var audioConcealedSamples: Double?
    public var audioBitrateKbps: Double?
    public var audioSourceSamplesDuration: Double?
    public var audioSourceLevel: Double?
    public var audioTargetBitrate: Double?
    public var audioOutboundRaw: [String: String]?

    public init() {}
}
