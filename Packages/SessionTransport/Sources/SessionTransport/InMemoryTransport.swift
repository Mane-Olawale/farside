import Foundation
import MediaCore
import WireProtocol

/// Two transports joined in memory, for tests of everything above the transport. Delivery is
/// asynchronous on one serial queue, in order, like the reliable channels.
public final class InMemoryTransport: SessionTransport, @unchecked Sendable {
    public let role: TransportRole
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var handlers: TransportHandlers
    private weak var peer: InMemoryTransport?
    private var closed = false
    private var dropping = false
    public private(set) var sentSignals: [SignalMessage] = []
    /// How long after `start()` the path comes up: long enough for the session descriptions to
    /// cross whatever signaling the test uses.
    public var connectDelay: Duration = .milliseconds(50)

    private init(role: TransportRole, queue: DispatchQueue, handlers: TransportHandlers) {
        self.role = role
        self.queue = queue
        self.handlers = handlers
    }

    /// A connected host and client. Nothing flows until the host calls `start()`.
    public static func pair(host: TransportHandlers, client: TransportHandlers,
                            queue: DispatchQueue = DispatchQueue(label: "farside.inmemory")) -> (host: InMemoryTransport, client: InMemoryTransport) {
        let h = InMemoryTransport(role: .host, queue: queue, handlers: host)
        let c = InMemoryTransport(role: .client, queue: queue, handlers: client)
        h.peer = c
        c.peer = h
        return (h, c)
    }

    private var isClosed: Bool { lock.withLock { closed } }

    /// Host: exchanges session descriptions carrying certificate fingerprints, then connects
    /// both ends and opens every channel, as a successful negotiation would.
    public func start() {
        guard role == .host, let peer else { return }
        handlers.signal(.offer("v=0\r\na=fingerprint:sha-256 \(Self.fingerprint("host"))\r\n"))
        peer.handlers.signal(.answer("v=0\r\na=fingerprint:sha-256 \(Self.fingerprint("client"))\r\n"))
        // Signaling is delivered asynchronously; let the descriptions land first.
        queue.asyncAfter(deadline: .now() + connectDelay.timeInterval) {
            for end in [self, peer] where !end.isClosed {
                end.handlers.event(.state(.connected))
                for channel in Wire.Channel.allCases { end.handlers.event(.channelOpen(channel)) }
            }
        }
    }

    public func handle(_ message: SignalMessage) {}

    static func fingerprint(_ seed: String) -> String {
        (0..<32).map { String(format: "%02X", (UInt8(truncatingIfNeeded: seed.hashValue >> ($0 % 8)) &+ UInt8($0))) }
            .joined(separator: ":")
    }

    public func send(_ data: Data, on channel: Wire.Channel) {
        guard !isClosed, !lock.withLock({ dropping }), let peer else { return }
        queue.async {
            guard !peer.isClosed else { return }
            peer.handlers.event(.message(channel, data))
        }
    }

    public func push(_ pixels: PixelBufferBox, timestampNs: Int64) {
        guard role == .host, !isClosed, let peer, let frame = peer.handlers.frame else { return }
        let rtp = UInt32(truncatingIfNeeded: timestampNs / 11_111)  // 90 kHz
        queue.async { frame(pixels, rtp) }
    }

    public func stats(completion: @escaping @Sendable (TransportStats) -> Void) {
        completion(TransportStats())
    }

    /// Closes this end. The other end sees the path fail, as it would when a peer vanishes.
    public func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        queue.async { [self] in
            handlers.event(.state(.closed))
            if let peer, !peer.isClosed { peer.handlers.event(.state(.failed)) }
        }
    }

    // MARK: Fault injection

    /// Both ends lose the path; messages are dropped until `simulatePathUp`.
    public func simulatePathDown() {
        guard let peer else { return }
        for end in [self, peer] { end.lock.withLock { end.dropping = true } }
        queue.async { for end in [self, peer] where !end.isClosed { end.handlers.event(.state(.disconnected)) } }
    }

    public func simulatePathUp() {
        guard let peer else { return }
        for end in [self, peer] { end.lock.withLock { end.dropping = false } }
        queue.async { for end in [self, peer] where !end.isClosed { end.handlers.event(.state(.connected)) } }
    }

    /// Waits until everything queued so far has been delivered.
    public func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
