import Foundation
import MediaCore
import SessionTransport
@preconcurrency import WebRTC
@preconcurrency import WebRTCAudioShim
import WireProtocol

// The WebRTC implementation of `SessionTransport` (ADR 0003). This target is the only code that
// imports WebRTC (plan section 5, rule 1), and nothing public here mentions a WebRTC type.

extension PlayoutMode {
    /// Field trials are the only way to reach playout delay from the Objective-C SDK (spike S3).
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

/// Whether and how a peer handles system audio (plan section 10, audio). Off in Phase 1.
public enum AudioRole: Sendable {
    case none
    /// Host: send PCM pushed into this input as mono Opus (spike S4).
    case send(InjectedAudioInput)
    /// Client: play received audio through this output.
    case receive(AudioPlayout)
}

public final class WebRTCTransport: SessionTransport, @unchecked Sendable {
    /// Field trials are process-wide and must be set before the first factory exists, so the
    /// first transport in a process fixes the playout mode for all later ones.
    nonisolated(unsafe) private static var configuredPlayout: PlayoutMode?
    private static let trialsLock = NSLock()

    public let role: TransportRole
    /// The playout mode in force, which is the first one this process asked for.
    public let playout: PlayoutMode
    public let configuration: TransportConfiguration
    private let handlers: TransportHandlers
    private let audio: AudioRole

    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection!
    private let observer = Observer()
    private var injector: FrameInjector?
    private var source: RTCVideoSource?
    private var sink: FrameSink?
    private var channels: [Int32: RTCDataChannel] = [:]
    /// Held for the session's life: RTCVideoTrack removes its renderers when the wrapper deallocates (spike S3).
    private var receivedTrack: RTCVideoTrack?
    private let lock = NSLock()
    private var closed = false
    /// start, handle and close run here, never on the caller's thread. A WebRTC call can block on
    /// the peer connection's own threads, so calling one synchronously from another peer's
    /// callback, as two transports in one process do, deadlocks.
    private let queue = DispatchQueue(label: "farside.webrtc.signaling")

    /// - Parameters:
    ///   - makeEncoder: host only. Called with codec, width, height and start bitrate in bits per second.
    ///   - makeDecoder: client only.
    public init(role: TransportRole,
                configuration: TransportConfiguration = .lan,
                audio: AudioRole = .none,
                makeEncoder: @escaping @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding? = { _, _, _, _ in nil },
                makeDecoder: @escaping @Sendable (VideoCodec) -> FrameDecoding? = { _ in nil },
                handlers: TransportHandlers) {
        let playout: PlayoutMode = Self.trialsLock.withLock {
            if let configured = Self.configuredPlayout { return configured }
            Self.configuredPlayout = configuration.playout
            let trials = configuration.playout.fieldTrials
            // Deprecated, but its replacement, a factory builder, is not in this build's headers.
            if !trials.isEmpty { RTCInitFieldTrialDictionary(trials) }
            return configuration.playout
        }
        self.role = role
        self.playout = playout
        self.configuration = configuration
        self.handlers = handlers
        self.audio = audio
        let audioDevice: RTCAudioDevice? = switch audio {
        case .none: nil
        case .send(let input): input.device
        case .receive(let output): output.device
        }
        factory = RTCPeerConnectionFactory(
            encoderFactory: EncoderFactory(codecs: configuration.codecs, make: makeEncoder),
            decoderFactory: DecoderFactory(codecs: configuration.codecs, make: makeDecoder),
            audioDevice: audioDevice)
        if let frame = handlers.frame {
            let sink = FrameSink(onFrame: frame)
            let event = handlers.event
            sink.onUnexpected = { event(.log($0)) }
            self.sink = sink
        }
        observer.owner = self
        setUp()
        if playout != configuration.playout {
            handlers.event(.log("playout \(configuration.playout.rawValue) requested, \(playout.rawValue) in force for this process"))
        }
    }

    private func setUp() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        // LAN only until Phase 3 adds STUN and TURN from the backend.
        config.iceServers = []
        // Spike S4 knobs for the audio jitter buffer.
        let env = ProcessInfo.processInfo.environment
        if let max = env["FARSIDE_AUDIO_JB_MAX"].flatMap(Int32.init) { config.audioJitterBufferMaxPackets = max }
        if env["FARSIDE_AUDIO_JB_FAST"] == "1" { config.audioJitterBufferFastAccelerate = true }
        connection = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: observer)

        // Pre-negotiated with fixed ids, so neither side waits for an in-band open (plan section 11).
        for channel in Wire.Channel.allCases {
            let c = RTCDataChannelConfiguration()
            c.isNegotiated = true
            c.channelId = channel.rawValue
            c.isOrdered = channel.isReliable
            if !channel.isReliable { c.maxRetransmits = 0 }
            if let dc = connection.dataChannel(forLabel: channel.description, configuration: c) {
                dc.delegate = observer
                channels[channel.rawValue] = dc
            }
        }

        guard role == .host else { return }
        let source = factory.videoSource(forScreenCast: true)
        let injector = FrameInjector(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "screen")
        let initial = RTCRtpTransceiverInit()
        initial.direction = .sendOnly
        initial.streamIds = ["farside"]
        if let transceiver = connection.addTransceiver(with: track, init: initial) {
            configure(transceiver)
            let parameters = transceiver.sender.parameters
            // The adaptation ladder decides resolution and frame rate, not the stack (plan section 8).
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: configuration.maxBitrateKbps * 1000)
                encoding.minBitrateBps = NSNumber(value: configuration.minBitrateKbps * 1000)
                encoding.maxFramerate = NSNumber(value: configuration.maxFrameRate)
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

    /// Codec order and the playout-delay header extension.
    private func configure(_ transceiver: RTCRtpTransceiver) {
        let capabilities = role == .host
            ? factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
            : factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let names = configuration.codecs.map { $0 == .hevc ? CodecNames.h265 : CodecNames.h264 }
        var ordered = names.flatMap { name in capabilities.codecs.filter { $0.name == name } }
        ordered += capabilities.codecs.filter { $0.name == "rtx" }
        // Swift imports the throwing and the deprecated setter under one name and picks the
        // deprecated one (spike S3). Both apply the same preferences.
        transceiver.setCodecPreferences(ordered)

        if playout.negotiatesPlayoutExtension {
            let extensions = transceiver.headerExtensionsToNegotiate
            for ext in extensions where ext.uri == "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay" {
                ext.direction = .sendRecv
            }
            try? transceiver.setHeaderExtensionsToNegotiate(extensions)
        }
    }

    private func log(_ text: String) { handlers.event(.log(text)) }

    private var isClosed: Bool { lock.withLock { closed } }

    // MARK: SessionTransport

    public func start() {
        queue.async { [self] in createOffer() }
    }

    private func createOffer() {
        guard role == .host, !isClosed else { return }
        connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [self] sdp, error in
            guard let sdp else { return log("offer failed: \(String(describing: error))") }
            let text = Self.munged(sdp.sdp, configuration: configuration)
            connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: text)) { [self] error in
                if let error { return log("set local offer failed: \(error)") }
                handlers.signal(.offer(text))
            }
        }
    }

    public func handle(_ message: SignalMessage) {
        queue.async { [self] in apply(message) }
    }

    private func apply(_ message: SignalMessage) {
        guard !isClosed else { return }
        switch message.kind {
        case .offer:
            guard role == .client, let sdp = message.body.sdp else { return }
            connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [self] error in
                if let error { return log("set remote offer failed: \(error)") }
                for transceiver in connection.transceivers where transceiver.mediaType == .video {
                    configure(transceiver)
                    attachSink(transceiver.receiver)
                }
                connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [self] sdp, error in
                    guard let sdp else { return log("answer failed: \(String(describing: error))") }
                    let text = Self.munged(sdp.sdp, configuration: configuration)
                    connection.setLocalDescription(RTCSessionDescription(type: .answer, sdp: text)) { [self] error in
                        if let error { return log("set local answer failed: \(error)") }
                        handlers.signal(.answer(text))
                    }
                }
            }
        case .answer:
            guard role == .host, let sdp = message.body.sdp else { return }
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [self] error in
                if let error { log("set remote answer failed: \(error)") }
            }
        case .candidate:
            guard let candidate = message.body.candidate else { return }
            connection.add(RTCIceCandidate(sdp: candidate, sdpMLineIndex: message.body.sdpMLineIndex ?? 0, sdpMid: message.body.sdpMid)) { _ in }
        case .join, .reject, .bye, .pair, .paired:
            // Session-level messages. The session layer acts on them.
            break
        }
    }

    public func send(_ data: Data, on channel: Wire.Channel) {
        guard let dc = lock.withLock({ closed ? nil : channels[channel.rawValue] }), dc.readyState == .open else { return }
        dc.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    public func push(_ pixels: PixelBufferBox, timestampNs: Int64) {
        injector?.push(pixels, timestampNs: timestampNs)
    }

    public func close() {
        let shouldClose = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard shouldClose else { return }
        // Anything already sent on a data channel goes out before the close.
        queue.async { [self] in
            for dc in channels.values { dc.close() }
            connection.close()
            handlers.event(.state(.closed))
        }
    }

    /// Adds x-google start, min and max bitrates to every H.265 and H.264 format, so the
    /// bandwidth estimate starts near the LAN rate instead of 300 kbps (spike S3), and sets Opus
    /// to mono at up to 96 kbit/s with no silence suppression (spike S4, plan section 10).
    static func munged(_ sdp: String, configuration: TransportConfiguration) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        let video = lines.compactMap { line -> String? in
            guard line.hasPrefix("a=rtpmap:"), line.contains(" H265/") || line.contains(" H264/") else { return nil }
            return String(line.dropFirst("a=rtpmap:".count).prefix { $0 != " " })
        }
        let bitrates = "x-google-start-bitrate=\(configuration.startBitrateKbps);x-google-min-bitrate=\(configuration.minBitrateKbps);x-google-max-bitrate=\(configuration.maxBitrateKbps)"
        for pt in video {
            if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
                lines[i] += ";" + bitrates
            } else if let i = lines.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(pt) ") }) {
                lines.insert("a=fmtp:\(pt) " + bitrates, at: i + 1)
            }
        }
        for line in lines where line.hasPrefix("a=rtpmap:") && line.lowercased().contains(" opus/") {
            let pt = String(line.dropFirst("a=rtpmap:".count).prefix { $0 != " " })
            if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
                lines[i] += ";stereo=0;sprop-stereo=0;maxaveragebitrate=96000;usedtx=0"
            }
        }
        return lines.joined(separator: "\r\n")
    }

    public func stats(completion: @escaping @Sendable (TransportStats) -> Void) {
        guard !isClosed else { return completion(TransportStats()) }
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
                    s.bytesSent = d("bytesSent")
                    s.frameWidth = d("frameWidth")
                    s.frameHeight = d("frameHeight")
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
                    s.availableOutgoingBitrate = d("availableOutgoingBitrate")
                    s.localCandidateType = (v["localCandidateId"] as? String).flatMap { candidates[$0] }
                    s.remoteCandidateType = (v["remoteCandidateId"] as? String).flatMap { candidates[$0] }
                default:
                    break
                }
            }
            completion(s)
        }
    }

    // MARK: Callbacks from the observer

    fileprivate func attachSink(_ receiver: RTCRtpReceiver) {
        let track: RTCVideoTrack? = lock.withLock {
            guard sink != nil, receivedTrack == nil else { return nil }
            return receiver.track as? RTCVideoTrack
        }
        guard let track, let sink else { return }
        track.add(sink)
        lock.withLock { receivedTrack = track }
        log("video sink attached")
    }

    fileprivate func connectionChanged(_ state: RTCPeerConnectionState) {
        let mapped: TransportState? = switch state {
        case .new, .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        // close() reports .closed itself, exactly once.
        case .closed: nil
        @unknown default: nil
        }
        if let mapped, !isClosed { handlers.event(.state(mapped)) }
    }

    fileprivate func candidate(_ candidate: RTCIceCandidate) {
        handlers.signal(.candidate(candidate.sdp, mid: candidate.sdpMid, lineIndex: candidate.sdpMLineIndex))
    }

    fileprivate func channelChanged(_ dc: RTCDataChannel) {
        guard let channel = Wire.Channel(rawValue: dc.channelId) else { return }
        switch dc.readyState {
        case .open: handlers.event(.channelOpen(channel))
        case .closed: handlers.event(.channelClosed(channel))
        default: break
        }
    }

    fileprivate func received(_ buffer: RTCDataBuffer, on dc: RTCDataChannel) {
        guard let channel = Wire.Channel(rawValue: dc.channelId) else { return }
        handlers.event(.message(channel, buffer.data))
    }
}

/// Receives WebRTC's delegate calls, so `WebRTCTransport` exposes no WebRTC conformances.
private final class Observer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    weak var owner: WebRTCTransport?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        owner?.candidate(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        owner?.attachSink(rtpReceiver)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        owner?.attachSink(transceiver.receiver)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        owner?.connectionChanged(newState)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        owner?.channelChanged(dataChannel)
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        owner?.received(buffer, on: dataChannel)
    }
}
