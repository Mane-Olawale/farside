import Foundation
import Pairing
import SessionTransport

/// Signaling through the backend (plan section 12, over the internet): envelopes go up over
/// HTTPS and come down on this device's channel. Every envelope is signed and checked exactly as
/// on a LAN; the backend only routes them.
///
/// The iPad's side reports ready when the Mac's signed `accept` arrives. The Mac's side is ready
/// at once: it has already decided to accept.
public final class BackendSignaling: SignalingChannel, @unchecked Sendable {
    public enum Role: Sendable {
        case client
        case host
    }

    public let session: String?
    public let peer: DeviceID?
    public var identity: LocalIdentity { credentials.identity }
    public var pinnedPeerKey: PublicKey? { peer.flatMap(credentials.pinnedKey(for:)) }

    private let api: BackendAPI
    private let credentials: SessionCredentials
    private let role: Role
    private let router: SignalRouter
    private let lock = NSLock()
    private var verifier: EnvelopeVerifier
    private var onState: (@Sendable (SignalingConnection.State) -> Void)?
    private var onMessage: (@Sendable (SignalMessage) -> Void)?
    private var nextSeq: UInt64 = 1
    private var ready = false
    private var closed = false
    private let outbox: AsyncStream<Data>.Continuation
    private let log: @Sendable (String) -> Void

    public init(api: BackendAPI, credentials: SessionCredentials, session: String, peer: DeviceID, role: Role,
                router: SignalRouter, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.api = api
        self.credentials = credentials
        self.session = session
        self.peer = peer
        self.role = role
        self.router = router
        self.log = log
        verifier = EnvelopeVerifier(credentials: credentials)
        // Envelopes go up one at a time, in order: candidates must not overtake their offer.
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        outbox = continuation
        Task {
            for await envelope in stream {
                do {
                    try await api.signal(envelope)
                } catch {
                    log("signal not sent: \(error)")
                }
            }
        }
    }

    public func start(onState: @escaping @Sendable (SignalingConnection.State) -> Void,
                      onMessage: @escaping @Sendable (SignalMessage) -> Void) {
        let readyNow = lock.withLock { () -> Bool in
            self.onState = onState
            self.onMessage = onMessage
            if role == .host { ready = true }
            return ready
        }
        router.register(self)
        if readyNow { onState(.ready) } else { onState(.connecting) }
    }

    public func send(_ message: SignalMessage) {
        let envelope: Data? = lock.withLock {
            guard !closed, let session, let peer else { return nil }
            var envelope = SignalEnvelope(message: message, session: session, from: credentials.identity.id.rawValue,
                                          to: peer.rawValue, seq: nextSeq, ts: Int64(Date().timeIntervalSince1970))
            nextSeq += 1
            guard (try? envelope.sign(with: credentials.identity)) != nil else { return nil }
            return try? envelope.encoded()
        }
        if let envelope { outbox.yield(envelope) }
    }

    public func close() {
        let handler = lock.withLock { () -> (@Sendable (SignalingConnection.State) -> Void)? in
            guard !closed else { return nil }
            closed = true
            return onState
        }
        router.unregister(self)
        outbox.finish()
        handler?(.closed(nil))
    }

    /// An envelope for this session, from the router. Dropped unless it is from the peer, signed
    /// with its pinned key and fresh.
    func deliver(_ envelope: SignalEnvelope) {
        enum Outcome {
            case drop
            case becameReady(@Sendable (SignalingConnection.State) -> Void)
            case message(@Sendable (SignalMessage) -> Void)
        }
        let outcome: Outcome = lock.withLock {
            guard !closed else { return .drop }
            do {
                _ = try verifier.check(envelope, expected: peer, now: Int64(Date().timeIntervalSince1970))
            } catch {
                log("dropped a \(envelope.type) envelope: \(error)")
                return .drop
            }
            if envelope.type == .accept {
                guard role == .client, !ready, let onState else { return .drop }
                ready = true
                return .becameReady(onState)
            }
            guard let onMessage else { return .drop }
            return .message(onMessage)
        }
        switch outcome {
        case .drop: break
        case .becameReady(let onState): onState(.ready)
        case .message(let onMessage): onMessage(envelope.message)
        }
    }
}

/// Hands envelopes from this device's channel to the session they belong to. Rings, which come
/// from the backend unsigned, go to the Mac's ring handler; pairing envelopes to the pairing
/// handler.
public final class SignalRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: Weak] = [:]
    private var onRing: (@Sendable (SignalEnvelope) -> Void)?

    private struct Weak {
        weak var signaling: BackendSignaling?
    }

    public init() {}

    /// The Mac's handler for an iPad calling. The ring is only a hint: the handler checks the
    /// caller against its pins before it accepts.
    public func setRingHandler(_ handler: @escaping @Sendable (SignalEnvelope) -> Void) {
        lock.withLock { onRing = handler }
    }

    /// Raw bytes from the socket's `signal` event.
    public func receive(_ data: Data) {
        guard let envelope = try? SignalEnvelope.decoded(data) else { return }
        if envelope.type == .ring {
            lock.withLock { onRing }?(envelope)
            return
        }
        let target = lock.withLock { sessions[envelope.session]?.signaling }
        target?.deliver(envelope)
    }

    func register(_ signaling: BackendSignaling) {
        guard let session = signaling.session else { return }
        lock.withLock {
            sessions = sessions.filter { $0.value.signaling != nil }
            sessions[session] = Weak(signaling: signaling)
        }
    }

    func unregister(_ signaling: BackendSignaling) {
        guard let session = signaling.session else { return }
        lock.withLock {
            if sessions[session]?.signaling === signaling { sessions[session] = nil }
        }
    }
}
