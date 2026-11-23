import Foundation
import MediaCore
import Pairing
import Synchronization
import WireProtocol

/// The signaling path a session uses. `SignalingConnection` is the LAN one; tests use a pair in
/// memory, and Phase 3 adds the backend.
public protocol SignalingChannel: AnyObject, Sendable {
    func start(onState: @escaping @Sendable (SignalingConnection.State) -> Void,
               onMessage: @escaping @Sendable (SignalMessage) -> Void)
    func send(_ message: SignalMessage)
    func close()
    /// The session id the envelopes carry. Known once ready.
    var session: String? { get }
    /// The device at the other end. Known once ready.
    var peer: DeviceID? { get }
    var identity: LocalIdentity { get }
    /// The peer's pinned key, or nil if it is not paired: the identity handshake then fails.
    var pinnedPeerKey: PublicKey? { get }
}

extension SignalingConnection: SignalingChannel {}

/// What both roles share: the state machine on a real clock, transport and signaling events
/// turned into machine events, envelopes on the control channel, pings, and Bye.
///
/// Everything runs on one serial queue. Subclasses add the handshake for their role. Owners
/// see only `HostSession` and `ClientSession`.
public class SessionBase: @unchecked Sendable {
    let queue: DispatchQueue
    private(set) var machine: SessionMachine
    private let origin = ContinuousClock.now
    private var deadlineTimer: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private(set) var transport: SessionTransport?
    let signaling: SignalingChannel
    /// Envelope sequence numbers, one counter for all channels. Atomic so a caller can learn the
    /// number its message will carry before the message is sent.
    private let sequence = Atomic<UInt32>(0)
    private var pathConnected = false
    private var controlOpen = false
    private var signalingReady = false
    private var stateHandler: (@Sendable (SessionState) -> Void)?
    /// Round trip from the last pong, in seconds.
    private(set) var lastRoundTrip: Double?
    /// The DTLS certificate fingerprints from this side's and the peer's session descriptions,
    /// which the identity handshake signs (plan section 14).
    private let certificates = Mutex<(local: String?, remote: String?)>((nil, nil))
    var onRoundTrip: (@Sendable (Double) -> Void)?
    let log: @Sendable (String) -> Void

    init(role: SessionMachine.Role, signaling: SignalingChannel, timeouts: SessionTimeouts,
         log: @escaping @Sendable (String) -> Void) {
        queue = DispatchQueue(label: role == .host ? "farside.session.host" : "farside.session.client", qos: .userInitiated)
        machine = SessionMachine(role: role, timeouts: timeouts)
        self.signaling = signaling
        self.log = log
    }

    // MARK: Owner API

    public var state: SessionState { queue.sync { machine.state } }

    /// Handlers to construct the transport with. `frame` is the client's video path.
    public func transportHandlers(frame: (@Sendable (PixelBufferBox, UInt32) -> Void)? = nil) -> TransportHandlers {
        TransportHandlers(
            signal: { [weak self] message in
                guard let self else { return }
                if message.kind == .offer || message.kind == .answer, let sdp = message.body.sdp {
                    certificates.withLock { $0.local = SDPFingerprint.value(in: sdp) }
                }
                signaling.send(message)
            },
            event: { [weak self] event in
                guard let self else { return }
                queue.async { self.transportEvent(event) }
            },
            frame: frame)
    }

    /// Ends the session from this side. A Bye goes out if anything can carry it.
    public func end(_ reason: SessionEndReason) {
        queue.async { self.apply(.end(reason)) }
    }

    /// Ends the session and waits, up to `timeout`, until the Bye has been handed to the network.
    /// For app termination.
    public func endAndFlush(_ reason: SessionEndReason, timeout: Duration = .milliseconds(300)) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.apply(.end(reason))
            // Sends are queued on the transport and signaling queues; give them a moment.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { done.signal() }
        }
        _ = done.wait(timeout: .now() + timeout.timeInterval)
    }

    // MARK: Subclass hooks, on the queue

    func controlChannelOpened() {}
    func received(_ body: Envelope.OneOf_Body, seq: UInt32) {}
    func effect(_ effect: SessionEffect) {}
    func stateChanged(_ state: SessionState) {}

    // MARK: Machinery

    func setStateHandler(_ handler: @escaping @Sendable (SessionState) -> Void) {
        stateHandler = handler
    }

    func attach(_ transport: SessionTransport) {
        self.transport = transport
    }

    func startSignaling() {
        signaling.start(
            onState: { [weak self] state in
                guard let self else { return }
                queue.async { self.signalingState(state) }
            },
            onMessage: { [weak self] message in
                guard let self else { return }
                queue.async { self.signalingMessage(message) }
            })
    }

    func now() -> Duration { ContinuousClock.now - origin }

    /// What both identity signatures cover, or nil if anything is missing.
    func helloTranscript(clientNonce: Data, isHost: Bool) -> HelloTranscript? {
        let (local, remote) = certificates.withLock { ($0.local, $0.remote) }
        guard let session = signaling.session, let peer = signaling.peer, let local, let remote else { return nil }
        let me = signaling.identity.id
        return HelloTranscript(session: session, client: isHost ? peer : me, host: isHost ? me : peer,
                               clientCertificate: isHost ? remote : local, hostCertificate: isHost ? local : remote,
                               clientNonce: clientNonce)
    }

    func apply(_ event: SessionEvent) {
        let before = machine.state
        let effects = machine.handle(event, at: now())
        for effect in effects { perform(effect) }
        scheduleDeadline()
        if machine.state != before {
            log("session \(before) -> \(machine.state) on \(event)")
            stateChanged(machine.state)
            stateHandler?(machine.state)
            // The path may have come up while this side was still ringing, when pathUp is
            // ignored. Look again now that it counts.
            if machine.state == .negotiating { checkPathUp() }
        }
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .startPings: startPings()
        case .stopPings: stopPings()
        case .sendBye(let reason):
            send(.bye(.with { $0.reason = reason.wire }))
            // Also over signaling, in case the data channel is not up or already gone.
            signaling.send(.bye(reason))
        case .closeTransport:
            transport?.close()
            signaling.close()
        default:
            break
        }
        self.effect(effect)
    }

    private func scheduleDeadline() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let deadline = machine.deadline else { return }
        let delay = max(.zero, deadline - now())
        let item = DispatchWorkItem { [weak self] in self?.apply(.tick) }
        deadlineTimer = item
        queue.asyncAfter(deadline: .now() + delay.timeInterval, execute: item)
    }

    /// Sends a session message, but only while streaming: input and cursor updates mean nothing
    /// before the handshake or while paused, and are dropped. Returns whether it went out.
    @discardableResult
    func sendWhileStreaming(_ body: Envelope.OneOf_Body, seq: UInt32? = nil) -> Bool {
        guard machine.state == .streaming else { return false }
        send(body, seq: seq)
        return true
    }

    /// The next envelope sequence number. Wraps.
    func nextSeq() -> UInt32 { sequence.add(1, ordering: .relaxed).newValue }

    func send(_ body: Envelope.OneOf_Body, seq: UInt32? = nil) {
        let envelope = Envelope(seq: seq ?? nextSeq(), sentAtMicroseconds: Self.microseconds(), body: body)
        do {
            transport?.send(try envelope.encoded(), on: body.channel)
        } catch {
            log("could not encode \(body.channel) message: \(error)")
        }
    }

    /// This device's monotonic clock in microseconds, for envelopes and pings.
    static func microseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000
    }

    // MARK: Events

    private func signalingState(_ state: SignalingConnection.State) {
        switch state {
        case .connecting:
            break
        case .ready:
            signalingReady = true
            signalingReadied()
        case .closed(let reason):
            signalingReady = false
            if machine.state.isActive {
                log("signaling closed: \(reason ?? "by peer")")
                // On a LAN the socket closes at once when the other app quits or crashes, long
                // before ICE gives up. Phase 4 keeps sessions alive through network changes.
                apply(.transportClosed)
            }
        }
    }

    func signalingReadied() {}

    private func signalingMessage(_ message: SignalMessage) {
        switch message.kind {
        case .join:
            break  // Consumed by the signaling connection.
        case .offer, .answer:
            certificates.withLock { $0.remote = message.body.sdp.flatMap(SDPFingerprint.value(in:)) }
            transport?.handle(message)
        case .candidate:
            transport?.handle(message)
        case .bye, .reject:
            apply(.peerEnded(message.endReason ?? .internalError))
        case .pair, .paired, .ring, .accept:
            break  // Pairing, and the internet path's ring and accept, are handled before the session.
        }
    }

    private func transportEvent(_ event: TransportEvent) {
        switch event {
        case .state(.connected):
            pathConnected = true
            checkPathUp()
        case .state(.disconnected):
            pathConnected = false
            apply(.pathDown)
        case .state(.failed), .state(.closed):
            pathConnected = false
            apply(.transportClosed)
        case .state(.connecting):
            break
        case .channelOpen(.control):
            controlOpen = true
            checkPathUp()
        case .channelClosed(.control):
            controlOpen = false
        case .channelOpen, .channelClosed:
            break
        case .message(let channel, let data):
            receive(data, on: channel)
        case .log(let text):
            log(text)
        }
    }

    private func checkPathUp() {
        guard pathConnected, controlOpen else { return }
        let wasNegotiating = machine.state == .negotiating
        apply(.pathUp)
        if wasNegotiating, machine.state == .securing { controlChannelOpened() }
    }

    private func receive(_ data: Data, on channel: Wire.Channel) {
        let envelope: Envelope
        do {
            envelope = try Envelope.decoded(data, on: channel)
        } catch .unknownBody {
            return  // From a newer peer; ignored by design.
        } catch {
            log("dropped \(channel) message: \(error)")
            return
        }
        guard let body = envelope.body else { return }
        switch body {
        case .ping(let ping):
            send(.pong(.with {
                $0.pingSenderTimeUs = ping.senderTimeUs
                $0.receiverTimeUs = Self.microseconds()
            }))
        case .pong(let pong):
            let rtt = Double(Self.microseconds() &- pong.pingSenderTimeUs) / 1_000_000
            lastRoundTrip = rtt
            onRoundTrip?(rtt)
        case .bye(let bye):
            apply(.peerEnded(SessionEndReason(wire: bye.reason)))
        default:
            received(body, seq: envelope.seq)
        }
    }

    // MARK: Pings

    private func startPings() {
        stopPings()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.send(.ping(.with { $0.senderTimeUs = Self.microseconds() }))
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPings() {
        pingTimer?.cancel()
        pingTimer = nil
    }
}

extension Duration {
    var timeInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
