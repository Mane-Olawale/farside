import Foundation
import Network
import Pairing
import Synchronization
import WireProtocol

// LAN discovery and signaling (plan section 12, on a LAN with no backend). The Mac advertises
// `_farside._tcp` with its id, name and protocol version in the TXT record and accepts WebSocket
// connections. The iPad browses, lists what it finds, and opens a WebSocket to the one picked.

public enum LAN {
    public static let serviceType = "_farside._tcp"

    /// The port the host listens on when it can, so Connect by address needs only the host.
    public static let defaultPort: UInt16 = 47870

    /// A WebSocket endpoint for a typed host. The handshake needs a `ws://` URL endpoint; a bare
    /// host-and-port endpoint is aborted by the WebSocket protocol before it is ready.
    static func endpoint(host: String, port: UInt16) -> NWEndpoint? {
        var components = URLComponents()
        components.scheme = "ws"
        if host.contains(":") {
            // An IPv6 address goes in brackets, with any zone (fe80::1%en0) escaped.
            components.percentEncodedHost = "[" + host.replacingOccurrences(of: "%", with: "%25") + "]"
        } else {
            components.host = host
        }
        components.port = Int(port)
        components.path = "/"
        return components.url.map { .url($0) }
    }

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = SignalEnvelope.maxBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.includePeerToPeer = false
        return parameters
    }

    enum TXTKey {
        static let id = "id"
        static let name = "name"
        static let protocolMajor = "v"
    }
}

/// A Mac found on this network.
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    /// The host's device id from its TXT record, or the service name if it has none.
    public let id: String
    public let name: String
    /// The host's wire protocol major version, if it advertised one.
    public let protocolMajor: UInt32?
    public let endpoint: NWEndpoint

    public var isCompatible: Bool { protocolMajor.map(Wire.isCompatible(major:)) ?? false }

    public init(id: String, name: String, protocolMajor: UInt32?, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.protocolMajor = protocolMajor
        self.endpoint = endpoint
    }

    /// A Mac reached by a typed address (plan section 12: Connect by address, for VPNs such as
    /// Tailscale before the backend exists). Accepts `host`, `host:port`, an IPv4 or IPv6 address,
    /// and `[v6]:port`. The port defaults to `LAN.defaultPort`. Nil if the text is not an address.
    public static func address(_ text: String) -> DiscoveredHost? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("/") else { return nil }
        var host = trimmed
        var port = LAN.defaultPort
        if trimmed.hasPrefix("[") {
            // [v6] or [v6]:port
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let p = UInt16(rest.dropFirst()), p > 0 else { return nil }
                port = p
            } else if !rest.isEmpty {
                return nil
            }
        } else if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.lastIndex(of: ":") {
            host = String(trimmed[..<colon])
            guard let p = UInt16(trimmed[trimmed.index(after: colon)...]), p > 0 else { return nil }
            port = p
        }
        guard !host.isEmpty, let endpoint = LAN.endpoint(host: host, port: port) else { return nil }
        return DiscoveredHost(id: "address:\(host):\(port)", name: host, protocolMajor: Wire.major, endpoint: endpoint)
    }

    init?(_ result: NWBrowser.Result) {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        id = txt[LAN.TXTKey.id] ?? serviceName
        name = txt[LAN.TXTKey.name] ?? serviceName
        protocolMajor = txt[LAN.TXTKey.protocolMajor].flatMap(UInt32.init)
        endpoint = result.endpoint
    }
}

/// Host side: advertises this Mac. Each incoming connection is checked before the owner sees it:
/// a signed join from a paired device reaches `onConnection`, a pairing request reaches
/// `onPairing`, and anything else is refused or dropped (plan section 14).
public final class LANAdvertiser: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        /// Usually a missing Local Network grant, or no network.
        case waiting(String)
        case failed(String)
        case stopped
    }

    private let queue = DispatchQueue(label: "farside.lan.advertiser")
    private var listener: NWListener?
    private let id: String
    private let name: String
    private let credentials: SessionCredentials
    private let onConnection: @Sendable (SignalingConnection) -> Void
    private let onPairing: @Sendable (PairingRequest, SignalingConnection) -> Void
    private let onState: @Sendable (State) -> Void
    private let limiter = LockedLimiter()

    public init(credentials: SessionCredentials, name: String,
                onConnection: @escaping @Sendable (SignalingConnection) -> Void,
                onPairing: @escaping @Sendable (PairingRequest, SignalingConnection) -> Void = { _, c in c.close() },
                onState: @escaping @Sendable (State) -> Void) {
        id = credentials.identity.id.rawValue
        self.name = name
        self.credentials = credentials
        self.onConnection = onConnection
        self.onPairing = onPairing
        self.onState = onState
    }

    /// Listens on `LAN.defaultPort`, so a typed address needs no port, or on any free port if
    /// that one is taken. Bonjour advertises whichever it got.
    public func start() throws {
        try start(port: NWEndpoint.Port(rawValue: LAN.defaultPort))
    }

    private func start(port: NWEndpoint.Port?) throws {
        let listener = try port.map { try NWListener(using: LAN.parameters(), on: $0) } ?? NWListener(using: LAN.parameters())
        var txt = NWTXTRecord()
        txt[LAN.TXTKey.id] = id
        txt[LAN.TXTKey.name] = name
        txt[LAN.TXTKey.protocolMajor] = String(Wire.major)
        listener.service = NWListener.Service(name: name, type: LAN.serviceType, txtRecord: txt)
        let onState = self.onState
        let fixed = port != nil
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .setup: onState(.starting)
            case .ready: onState(.ready(port: listener?.port?.rawValue ?? 0))
            case .waiting(let error): onState(.waiting("\(error)"))
            case .failed(.posix(.EADDRINUSE)) where fixed:
                // Something else has the default port: take any free one instead.
                listener?.cancel()
                if let advertiser = self {
                    advertiser.queue.async { try? advertiser.start(port: nil) }
                }
            case .failed(let error): onState(.failed("\(error)"))
            case .cancelled: onState(.stopped)
            @unknown default: break
            }
        }
        let (onConnection, onPairing, credentials, limiter) = (self.onConnection, self.onPairing, self.credentials, self.limiter)
        listener.newConnectionHandler = { connection in
            let source = Self.source(of: connection.endpoint)
            guard !limiter.isBlocked(source) else {
                connection.cancel()
                return
            }
            SignalingConnection(connection: connection, credentials: credentials).admit(
                onAdmitted: onConnection, onPairing: onPairing, onFailure: { limiter.failed(source) })
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The remote address without its port: one device opening many sockets is one source.
    static func source(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }
}

final class LockedLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var limiter = FailureLimiter()

    func isBlocked(_ source: String) -> Bool {
        lock.withLock { limiter.isBlocked(source, now: Clock.unixNow) }
    }

    func failed(_ source: String) {
        lock.withLock { limiter.failed(source, now: Clock.unixNow) }
    }
}

enum Clock {
    static var unixNow: Int64 { Int64(Date().timeIntervalSince1970) }
}

/// Client side: keeps an up-to-date list of the Macs on this network.
public final class LANBrowser: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case browsing
        /// Usually a missing Local Network grant.
        case waiting(String)
        case failed(String)
        case stopped
    }

    private let queue = DispatchQueue(label: "farside.lan.browser")
    private var browser: NWBrowser?
    private let onHosts: @Sendable ([DiscoveredHost]) -> Void
    private let onState: @Sendable (State) -> Void

    public init(onHosts: @escaping @Sendable ([DiscoveredHost]) -> Void, onState: @escaping @Sendable (State) -> Void) {
        self.onHosts = onHosts
        self.onState = onState
    }

    public func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LAN.serviceType, domain: nil), using: LAN.parameters())
        let onState = self.onState
        browser.stateUpdateHandler = { state in
            switch state {
            case .setup: onState(.starting)
            case .ready: onState(.browsing)
            case .waiting(let error): onState(.waiting("\(error)"))
            case .failed(let error): onState(.failed("\(error)"))
            case .cancelled: onState(.stopped)
            @unknown default: break
            }
        }
        let onHosts = self.onHosts
        browser.browseResultsChangedHandler = { results, _ in
            let hosts = results.compactMap(DiscoveredHost.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            onHosts(hosts)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}


/// One signaling WebSocket (plan sections 11 and 14). Outgoing envelopes carry the session id, a
/// sequence number, a timestamp, sender and receiver, and this device's signature. Incoming ones
/// are dropped unless they are addressed here, signed by the expected peer's pinned key, fresh,
/// and for this session.
///
/// The host side checks the first envelope before anyone else sees the connection: see
/// `LANAdvertiser`.
public final class SignalingConnection: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting
        case ready
        case closed(String?)
    }

    public enum PairingResult: Sendable, Equatable {
        case paired
        case refused
        case failed(String)
    }

    private enum Role {
        case client(takeOver: Bool)
        case host
        case pairing(PairingInvite, PairingRequest, @Sendable (PairingResult) -> Void)
    }

    private let queue = DispatchQueue(label: "farside.lan.signaling")
    private let connection: NWConnection
    private let credentials: SessionCredentials
    private let role: Role
    private var verifier: EnvelopeVerifier
    private let ids = Mutex<(session: String?, peer: DeviceID?)>((nil, nil))
    private var nextSeq: UInt64 = 1
    private var onState: (@Sendable (State) -> Void)?
    private var onMessage: (@Sendable (SignalMessage) -> Void)?
    private var closed = false
    /// Host side: set once the first envelope passed. Messages wait here until `start`.
    private var admitted = false
    private var pending: [SignalMessage] = []
    private var pairingDone = false
    /// Keeps this connection alive while nobody else holds it: the host side until admission,
    /// the iPad's pairing connection until the answer.
    private var keepAlive: SignalingConnection?
    private var admission: (onAdmitted: @Sendable (SignalingConnection) -> Void,
                            onPairing: @Sendable (PairingRequest, SignalingConnection) -> Void,
                            onFailure: @Sendable () -> Void)?

    private init(connection: NWConnection, credentials: SessionCredentials, role: Role, session: String?, peer: DeviceID?) {
        self.connection = connection
        self.credentials = credentials
        self.role = role
        verifier = EnvelopeVerifier(credentials: credentials)
        ids.withLock { $0 = (session, peer) }
    }

    /// Host side, before admission.
    convenience init(connection: NWConnection, credentials: SessionCredentials) {
        self.init(connection: connection, credentials: credentials, role: .host, session: nil, peer: nil)
    }

    /// Client side: a new session to the paired Mac `peer`, found by `LANBrowser`.
    /// `takeOver` asks the Mac to end its current session for this one.
    public static func connect(to endpoint: NWEndpoint, credentials: SessionCredentials, peer: DeviceID,
                               takeOver: Bool = false) -> SignalingConnection {
        SignalingConnection(connection: NWConnection(to: endpoint, using: LAN.parameters()), credentials: credentials,
                            role: .client(takeOver: takeOver), session: UUID().uuidString, peer: peer)
    }

    /// Client side: a new session to a typed address (Connect by address, Phase 2). The WebSocket
    /// handshake needs a `ws://` URL endpoint here; a bare host-and-port endpoint is aborted by
    /// the WebSocket protocol before it is ready. Bonjour service endpoints work as they are.
    public static func connect(host: String, port: UInt16, credentials: SessionCredentials, peer: DeviceID,
                               takeOver: Bool = false) -> SignalingConnection {
        connect(to: endpoint(host: host, port: port), credentials: credentials, peer: peer, takeOver: takeOver)
    }

    static func endpoint(host: String, port: UInt16) -> NWEndpoint {
        LAN.endpoint(host: host, port: port)
            ?? .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// iPad side of pairing (plan section 14): sends the request to the Mac from the QR code and
    /// reports whether the person at the Mac allowed it. The caller times out and closes.
    @discardableResult
    public static func pair(to endpoint: NWEndpoint, credentials: SessionCredentials, invite: PairingInvite,
                            request: PairingRequest, completion: @escaping @Sendable (PairingResult) -> Void) -> SignalingConnection {
        let connection = SignalingConnection(connection: NWConnection(to: endpoint, using: LAN.parameters()),
                                             credentials: credentials, role: .pairing(invite, request, completion),
                                             session: UUID().uuidString, peer: invite.id)
        connection.queue.async {
            connection.keepAlive = connection
            connection.open()
        }
        return connection
    }

    /// The device at the other end: the Mac for the iPad, the admitted iPad for the Mac.
    public var peer: DeviceID? { ids.withLock { $0.peer } }
    public var session: String? { ids.withLock { $0.session } }
    public var identity: LocalIdentity { credentials.identity }
    public var pinnedPeerKey: PublicKey? { peer.flatMap(credentials.pinnedKey(for:)) }
    /// Host side: the admitted device asked to take over a session in progress.
    public private(set) var requestsTakeOver = false

    /// For logs. Marked private by callers.
    public var remoteDescription: String { "\(connection.endpoint)" }

    // MARK: Host admission

    func admit(onAdmitted: @escaping @Sendable (SignalingConnection) -> Void,
               onPairing: @escaping @Sendable (PairingRequest, SignalingConnection) -> Void,
               onFailure: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            admission = (onAdmitted, onPairing, onFailure)
            keepAlive = self
            open()
        }
    }

    /// Host side: the answer to a pairing request. Closes the connection once it is sent.
    public func replyToPairing(allowed: Bool) {
        send(allowed ? SignalMessage(kind: .paired) : .reject(.notPaired), thenClose: true)
    }

    // MARK: Session use

    public func start(onState: @escaping @Sendable (State) -> Void, onMessage: @escaping @Sendable (SignalMessage) -> Void) {
        queue.async { [self] in
            self.onState = onState
            self.onMessage = onMessage
            switch role {
            case .host:
                if closed {
                    onState(.closed(nil))
                } else if admitted {
                    onState(.ready)
                    let queued = pending
                    pending = []
                    queued.forEach(onMessage)
                }
            case .client:
                open()
            case .pairing:
                break
            }
        }
    }

    public func send(_ message: SignalMessage) {
        send(message, thenClose: false)
    }

    /// Sends one last message and closes once the network has taken it.
    public func sendAndClose(_ message: SignalMessage) {
        send(message, thenClose: true)
    }

    private func send(_ message: SignalMessage, thenClose: Bool) {
        queue.async { [self] in
            let (session, peer) = ids.withLock { ($0.session, $0.peer) }
            guard !closed, let session, let peer else {
                if thenClose { connection.cancel() }
                return
            }
            var envelope = SignalEnvelope(message: message, session: session, from: credentials.identity.id.rawValue,
                                          to: peer.rawValue, seq: nextSeq, ts: Clock.unixNow)
            nextSeq += 1
            guard (try? envelope.sign(with: credentials.identity)) != nil, let data = try? envelope.encoded() else {
                if thenClose { connection.cancel() }
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "signal", metadata: [metadata])
            let connection = connection
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                if thenClose { connection.cancel() }
            })
        }
    }

    /// Closes the socket after anything already queued has been handed to the network.
    public func close() {
        queue.async { [self] in
            connection.cancel()
        }
    }

    // MARK: Internals, on the queue

    private func open() {
        connection.stateUpdateHandler = { [weak self] state in
            // Nothing is reported after closed, not even a late waiting.
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                switch self.role {
                case .client(let takeOver):
                    self.send(SignalMessage(kind: .join, body: SignalBody(takeOver: takeOver ? true : nil)))
                    self.onState?(.ready)
                case .pairing(_, let request, _):
                    self.send(.pair(request))
                case .host:
                    break
                }
            case .failed(let error): self.finish("\(error)")
            case .cancelled: self.finish(nil)
            case .waiting: self.onState?(.connecting)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.accept(data) }
            if let error {
                self.finish("\(error)")
            } else if !self.closed {
                self.receive()
            }
        }
    }

    private func accept(_ data: Data) {
        guard !closed, let envelope = try? SignalEnvelope.decoded(data) else { return }
        let now = Clock.unixNow
        switch role {
        case .host where !admitted:
            firstEnvelope(envelope, now: now)

        case .pairing(let invite, _, let completion):
            guard envelope.session == session, (try? verifier.checkPairingReply(envelope, invite: invite, now: now)) != nil else { return }
            pairingDone = true
            completion(envelope.type == .paired ? .paired : .refused)
            finish(nil)

        case .host, .client:
            guard envelope.session == session else { return }
            do {
                _ = try verifier.check(envelope, expected: peer, now: now)
            } catch {
                return  // Not from the peer, or replayed: dropped (plan section 11).
            }
            if envelope.type == .join { return }
            // The host's handlers arrive with `start`, after admission.
            if let onMessage { onMessage(envelope.message) } else { pending.append(envelope.message) }
        }
    }

    /// Host side: the first envelope decides what this connection is.
    private func firstEnvelope(_ envelope: SignalEnvelope, now: Int64) {
        guard let admission else { return }
        switch envelope.type {
        case .join:
            do {
                let sender = try verifier.check(envelope, expected: nil, now: now)
                ids.withLock { $0 = (envelope.session, sender) }
                requestsTakeOver = envelope.body.takeOver == true
                admitted = true
                self.admission = nil
                keepAlive = nil
                admission.onAdmitted(self)
            } catch .notPaired {
                // Signed by a device this Mac does not know: tell it to pair, then hang up.
                ids.withLock { $0 = (envelope.session, DeviceID(rawValue: envelope.from)) }
                admission.onFailure()
                send(.reject(.notPaired), thenClose: true)
            } catch {
                admission.onFailure()
                finish("refused: \(error)")
            }
        case .pair:
            do {
                let request = try verifier.checkPairing(envelope, now: now)
                ids.withLock { $0 = (envelope.session, request.id) }
                self.admission = nil
                keepAlive = nil
                admission.onPairing(request, self)
            } catch {
                admission.onFailure()
                finish("refused pairing: \(error)")
            }
        default:
            admission.onFailure()
            finish("refused: \(envelope.type)")
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        keepAlive = nil
        connection.cancel()
        if case .pairing(_, _, let completion) = role, !pairingDone {
            pairingDone = true
            completion(.failed(reason ?? "closed"))
        }
        onState?(.closed(reason))
    }
}
