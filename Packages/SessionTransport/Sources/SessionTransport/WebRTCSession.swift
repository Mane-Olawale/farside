import Foundation
import MediaCore
@preconcurrency import WebRTC
@preconcurrency import WebRTCAudioShim


/// How the receiver's jitter buffer is told to hold frames (spike S3).
public enum PlayoutMode: String, Sendable, Codable, CaseIterable {
    /// WebRTC's own adaptive delay.
    case standard
    /// Receiver field trial WebRTC-ForcePlayoutDelay with min 0 and max 0.
    case receiverZero
    /// Sender field trial WebRTC-ForceSendPlayoutDelay with min 0 and max 0, carried to the
    /// receiver in the negotiated playout-delay header extension.
    case senderZero
    /// Both of the above.
    case both

    var fieldTrials: [String: String] {
        let zero = "min_ms:0,max_ms:0"
        switch self {
        case .standard: return [:]
        case .receiverZero: return ["WebRTC-ForcePlayoutDelay": zero]
        case .senderZero: return ["WebRTC-ForceSendPlayoutDelay": zero]
        case .both: return ["WebRTC-ForcePlayoutDelay": zero, "WebRTC-ForceSendPlayoutDelay": zero]
        }
    }

    var negotiatesPlayoutExtension: Bool { self == .senderZero || self == .both }
}

/// Whether and how a peer handles system audio (plan section 10, audio).
public enum AudioRole: Sendable {
    case none
    /// Host: send PCM pushed into this input as stereo Opus.
    case send(InjectedAudioInput)
    /// Client: play received audio through this output.
    case receive(AudioPlayout)
}

/// One signaling message. The real product signs these (plan section 11); the spike does not.
public struct SignalMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case config, offer, answer, candidate }
    public var kind: Kind
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?
    public var playout: PlayoutMode?
    public var codecs: [VideoCodec]?
    public var audio: Bool?

    public init(kind: Kind, sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil,
                playout: PlayoutMode? = nil, codecs: [VideoCodec]? = nil, audio: Bool? = nil) {
        self.kind = kind
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.playout = playout
        self.codecs = codecs
        self.audio = audio
    }
}

/// The four pre-negotiated data channels (plan section 11).
public enum DataChannel: Int32, CaseIterable, Sendable {
    case control = 0, input = 1, pointer = 2, cursor = 3
    var reliable: Bool { self == .control || self == .input }
}

public struct TransportStats: Sendable, Codable {
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
    public var bytesReceived: Double?
    public var frameWidth: Double?
    public var frameHeight: Double?
    public var roundTripTime: Double?
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
}

/// One peer of a session. `host` captures and sends; `client` receives and renders.
/// Only this file and CodecAdapters.swift touch WebRTC types.
public final class WebRTCSession: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    public enum Role: Sendable { case host, client }

    /// Field trials are process-wide and must be set before the first factory exists.
    nonisolated(unsafe) private static var configuredPlayout: PlayoutMode?

    public let role: Role
    public let playout: PlayoutMode
    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection!
    private var injector: FrameInjector?
    private var source: RTCVideoSource?
    private var sink: FrameSink?
    private var channels: [Int32: RTCDataChannel] = [:]
    private let codecs: [VideoCodec]
    private let startBitrateKbps: Int
    private let audio: AudioRole
    private let signal: @Sendable (SignalMessage) -> Void
    private let onMessage: @Sendable (DataChannel, Data) -> Void
    private let onState: @Sendable (String) -> Void

    public init(role: Role, playout: PlayoutMode, codecs: [VideoCodec],
                startBitrateKbps: Int = 20_000,
                audio: AudioRole = .none,
                makeEncoder: @escaping @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding? = { _, _, _, _ in nil },
                makeDecoder: @escaping @Sendable (VideoCodec) -> FrameDecoding,
                onFrame: (@Sendable (PixelBufferBox, UInt32) -> Void)? = nil,
                signal: @escaping @Sendable (SignalMessage) -> Void,
                onMessage: @escaping @Sendable (DataChannel, Data) -> Void = { _, _ in },
                onState: @escaping @Sendable (String) -> Void = { _ in }) {
        if Self.configuredPlayout == nil {
            Self.configuredPlayout = playout
            let trials = playout.fieldTrials
            // The SDK's only public way to set field trials. Its replacement, a factory builder,
            // is not in the Objective-C headers of this build.
            // Deprecated, but the factory builder that replaces it is not in this build's headers.
            if !trials.isEmpty { RTCInitFieldTrialDictionary(trials) }
        }
        self.role = role
        self.playout = Self.configuredPlayout ?? playout
        self.codecs = codecs
        self.startBitrateKbps = startBitrateKbps
        self.audio = audio
        self.signal = signal
        self.onMessage = onMessage
        self.onState = onState
        let audioDevice: RTCAudioDevice? = switch audio {
        case .none: nil
        case .send(let input): input.device
        case .receive(let output): output.device
        }
        factory = RTCPeerConnectionFactory(
            encoderFactory: EncoderFactory(codecs: codecs, make: makeEncoder),
            decoderFactory: DecoderFactory(codecs: codecs, make: makeDecoder),
            audioDevice: audioDevice)
        super.init()
        if let onFrame {
            let sink = FrameSink(onFrame: onFrame)
            sink.onUnexpected = onState
            self.sink = sink
        }
        setUp()
    }

    private func setUp() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.iceServers = []
        // Spike S4 knobs for the audio jitter buffer.
        let env = ProcessInfo.processInfo.environment
        if let max = env["FARSIDE_AUDIO_JB_MAX"].flatMap(Int32.init) { config.audioJitterBufferMaxPackets = max }
        if env["FARSIDE_AUDIO_JB_FAST"] == "1" { config.audioJitterBufferFastAccelerate = true }
        connection = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)

        for channel in DataChannel.allCases {
            let c = RTCDataChannelConfiguration()
            c.isNegotiated = true
            c.channelId = channel.rawValue
            c.isOrdered = channel.reliable
            if !channel.reliable { c.maxRetransmits = 0 }
            if let dc = connection.dataChannel(forLabel: "\(channel)", configuration: c) {
                dc.delegate = self
                channels[channel.rawValue] = dc
            }
        }

        if role == .host {
            let source = factory.videoSource(forScreenCast: true)
            let injector = FrameInjector(delegate: source)
            let track = factory.videoTrack(with: source, trackId: "screen")
            let initial = RTCRtpTransceiverInit()
            initial.direction = .sendOnly
            initial.streamIds = ["farside"]
            if let transceiver = connection.addTransceiver(with: track, init: initial) {
                configure(transceiver)
                let parameters = transceiver.sender.parameters
                parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)
                for encoding in parameters.encodings {
                    encoding.maxBitrateBps = 40_000_000
                    encoding.minBitrateBps = 1_500_000
                    encoding.maxFramerate = 60
                }
                transceiver.sender.parameters = parameters
            }
            self.source = source
            self.injector = injector

            if case .send = audio {
                // Speech processing off: this is system audio, not a microphone.
                let constraints = RTCMediaConstraints(mandatoryConstraints: [
                    "googEchoCancellation": "false", "googAutoGainControl": "false",
                    "googNoiseSuppression": "false", "googHighpassFilter": "false",
                ], optionalConstraints: nil)
                let audioTrack = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "system-audio")
                let audioInit = RTCRtpTransceiverInit()
                audioInit.direction = .sendOnly
                // Separate stream id, so lip-sync never holds video back (plan section 8).
                audioInit.streamIds = ["farside-audio"]
                connection.addTransceiver(with: audioTrack, init: audioInit)
            }
        }
    }

    /// Codec order and the playout-delay header extension.
    private func configure(_ transceiver: RTCRtpTransceiver) {
        let capabilities = role == .host
            ? factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
            : factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let names = codecs.map { $0 == .hevc ? CodecNames.h265 : CodecNames.h264 }
        var ordered = names.flatMap { name in capabilities.codecs.filter { $0.name == name } }
        ordered += capabilities.codecs.filter { $0.name == "rtx" }
        // Swift imports the throwing and the deprecated setter under one name and picks the
        // deprecated one; both apply the same preferences.
        transceiver.setCodecPreferences(ordered)

        if playout.negotiatesPlayoutExtension {
            let extensions = transceiver.headerExtensionsToNegotiate
            for ext in extensions where ext.uri == "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay" {
                ext.direction = .sendRecv
            }
            try? transceiver.setHeaderExtensionsToNegotiate(extensions)
        }
    }

    // MARK: Signaling

    /// Host only: creates and sends the offer.
    public func start() {
        connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [self] sdp, error in
            guard let sdp else { return onState("offer failed: \(String(describing: error))") }
            let text = Self.withStartBitrate(sdp.sdp, kbps: startBitrateKbps)
            connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: text)) { [self] error in
                if let error { return onState("setLocal failed: \(error)") }
                signal(SignalMessage(kind: .offer, sdp: text))
            }
        }
    }

    public func handle(_ message: SignalMessage) {
        switch message.kind {
        case .config:
            break
        case .offer:
            guard let sdp = message.sdp else { return }
            connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [self] error in
                if let error { return onState("setRemote offer failed: \(error)") }
                for transceiver in connection.transceivers where transceiver.mediaType == .video {
                    configure(transceiver)
                    attachSink(transceiver.receiver)
                }
                connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [self] sdp, error in
                    guard let sdp else { return onState("answer failed: \(String(describing: error))") }
                    let text = Self.withStartBitrate(sdp.sdp, kbps: startBitrateKbps)
                    connection.setLocalDescription(RTCSessionDescription(type: .answer, sdp: text)) { [self] error in
                        if let error { return onState("setLocal answer failed: \(error)") }
                        signal(SignalMessage(kind: .answer, sdp: text))
                    }
                }
            }
        case .answer:
            guard let sdp = message.sdp else { return }
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [self] error in
                if let error { onState("setRemote answer failed: \(error)") }
            }
        case .candidate:
            guard let c = message.candidate else { return }
            connection.add(RTCIceCandidate(sdp: c, sdpMLineIndex: message.sdpMLineIndex ?? 0, sdpMid: message.sdpMid)) { _ in }
        }
    }

    /// Adds x-google start, min and max bitrates to every H.265 and H.264 format, so the
    /// bandwidth estimate starts near the LAN rate instead of 300 kbps.
    static func withStartBitrate(_ sdp: String, kbps: Int) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        let payloads = lines.compactMap { line -> String? in
            guard line.hasPrefix("a=rtpmap:"), line.contains(" H265/") || line.contains(" H264/") else { return nil }
            return String(line.dropFirst("a=rtpmap:".count).prefix { $0 != " " })
        }
        let extra = "x-google-start-bitrate=\(kbps);x-google-min-bitrate=1500;x-google-max-bitrate=40000"
        // Stereo Opus at up to 128 kbit/s, no silence suppression (plan section 10).
        for line in lines where line.hasPrefix("a=rtpmap:") && line.lowercased().contains(" opus/") {
            let pt = String(line.dropFirst("a=rtpmap:".count).prefix { $0 != " " })
            if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
                lines[i] += ";stereo=1;sprop-stereo=1;maxaveragebitrate=128000;usedtx=0"
            }
        }
        for pt in payloads {
            if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
                lines[i] += ";" + extra
            } else if let i = lines.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(pt) ") }) {
                lines.insert("a=fmtp:\(pt) " + extra, at: i + 1)
            }
        }
        return lines.joined(separator: "\r\n")
    }

    // MARK: Media and data

    /// Host only. Call from the capture queue.
    public func push(_ pixels: PixelBufferBox, timestampNs: Int64) {
        injector?.push(pixels, timestampNs: timestampNs)
    }

    public func send(_ data: Data, on channel: DataChannel) {
        channels[channel.rawValue]?.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    public func close() {
        connection.close()
    }

    public func stats(completion: @escaping @Sendable (TransportStats) -> Void) {
        let negotiated = connection.transceivers.first { $0.mediaType == .video }.map { t in
            t.negotiatedHeaderExtensions.contains { $0.uri.hasSuffix("playout-delay") && $0.direction != .stopped }
        }
        let uri = "rtp-hdrext/playout-delay"
        let local = connection.localDescription?.sdp.contains(uri)
        let remote = connection.remoteDescription?.sdp.contains(uri)
        connection.statistics { report in
            var s = TransportStats()
            s.playoutExtensionNegotiated = negotiated
            s.playoutExtensionInLocalSDP = local
            s.playoutExtensionInRemoteSDP = remote
            var codecIds: [String: String] = [:]
            var candidates: [String: String] = [:]
            for (id, stat) in report.statistics {
                if stat.type == "codec" { codecIds[id] = stat.values["mimeType"] as? String }
                if stat.type == "local-candidate" || stat.type == "remote-candidate" { candidates[id] = stat.values["candidateType"] as? String }
            }
            for stat in report.statistics.values {
                let v = stat.values
                func d(_ k: String) -> Double? { (v[k] as? NSNumber)?.doubleValue }
                switch stat.type {
                case "media-source" where (v["kind"] as? String) == "audio":
                    s.audioSourceSamplesDuration = d("totalSamplesDuration")
                    s.audioSourceLevel = d("audioLevel")
                case "outbound-rtp" where (v["kind"] as? String) == "audio":
                    s.audioOutboundRaw = v.mapValues { "\($0)" }
                    s.audioTargetBitrate = d("targetBitrate")
                    s.audioCodec = (v["codecId"] as? String).flatMap { codecIds[$0] }
                    s.audioPacketsSent = d("packetsSent")
                    s.audioBytesSent = d("bytesSent")
                case "inbound-rtp" where (v["kind"] as? String) == "audio":
                    s.audioCodec = (v["codecId"] as? String).flatMap { codecIds[$0] }
                    s.audioPacketsReceived = d("packetsReceived")
                    s.audioPacketsLost = d("packetsLost")
                    s.audioJitterBufferDelay = d("jitterBufferDelay")
                    s.audioJitterBufferEmittedCount = d("jitterBufferEmittedCount")
                    s.audioTotalSamplesReceived = d("totalSamplesReceived")
                    s.audioConcealedSamples = d("concealedSamples")
                case "outbound-rtp" where (v["kind"] as? String) == "video":
                    s.codec = (v["codecId"] as? String).flatMap { codecIds[$0] }
                    s.encoderImplementation = v["encoderImplementation"] as? String
                    s.framesEncoded = d("framesEncoded")
                    s.totalEncodeTime = d("totalEncodeTime")
                    s.targetBitrate = d("targetBitrate")
                    s.qualityLimitationReason = v["qualityLimitationReason"] as? String
                    s.nackCount = d("nackCount")
                    s.pliCount = d("pliCount")
                case "inbound-rtp" where (v["kind"] as? String) == "video":
                    s.codec = (v["codecId"] as? String).flatMap { codecIds[$0] }
                    s.decoderImplementation = v["decoderImplementation"] as? String
                    s.framesReceived = d("framesReceived")
                    s.framesDecoded = d("framesDecoded")
                    s.framesDropped = d("framesDropped")
                    s.totalDecodeTime = d("totalDecodeTime")
                    s.jitterBufferDelay = d("jitterBufferDelay")
                    s.jitterBufferTargetDelay = d("jitterBufferTargetDelay")
                    s.jitterBufferMinimumDelay = d("jitterBufferMinimumDelay")
                    s.jitterBufferEmittedCount = d("jitterBufferEmittedCount")
                    s.freezeCount = d("freezeCount")
                    s.packetsLost = d("packetsLost")
                    s.nackCount = d("nackCount")
                    s.pliCount = d("pliCount")
                    s.keyFramesDecoded = d("keyFramesDecoded")
                    s.bytesReceived = d("bytesReceived")
                    s.frameWidth = d("frameWidth")
                    s.frameHeight = d("frameHeight")
                case "candidate-pair" where (v["state"] as? String) == "succeeded" && (v["nominated"] as? NSNumber)?.boolValue == true:
                    s.roundTripTime = d("currentRoundTripTime")
                    s.localCandidateType = (v["localCandidateId"] as? String).flatMap { candidates[$0] }
                    s.remoteCandidateType = (v["remoteCandidateId"] as? String).flatMap { candidates[$0] }
                default:
                    break
                }
            }
            completion(s)
        }
    }

    // MARK: RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onState("ice \(newState.rawValue)")
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signal(SignalMessage(kind: .candidate, candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        attachSink(rtpReceiver)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        attachSink(transceiver.receiver)
    }

    private var sinkAttached = false
    /// Held for the session's life: RTCVideoTrack removes its renderers when the wrapper deallocates.
    private var receivedTrack: RTCVideoTrack?
    private func attachSink(_ receiver: RTCRtpReceiver) {
        guard let sink, !sinkAttached else { return }
        guard let track = receiver.track as? RTCVideoTrack else {
            onState("receiver track is \(String(describing: receiver.track.map { type(of: $0) }))")
            return
        }
        track.add(sink)
        receivedTrack = track
        sinkAttached = true
        onState("sink attached")
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onState("connection \(newState.rawValue)")
    }

    // MARK: RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        onState("channel \(dataChannel.label) \(dataChannel.readyState.rawValue)")
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let channel = DataChannel(rawValue: dataChannel.channelId) else { return }
        onMessage(channel, buffer.data)
    }
}
