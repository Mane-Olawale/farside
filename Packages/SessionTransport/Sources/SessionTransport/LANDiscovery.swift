import Foundation
import Network
import WireProtocol

// LAN discovery and signaling (plan section 12, on a LAN with no backend). The Mac advertises
// `_farside._tcp` with its id, name and protocol version in the TXT record and accepts WebSocket
// connections. The iPad browses, lists what it finds, and opens a WebSocket to the one picked.

public enum LAN {
    public static let serviceType = "_farside._tcp"

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

/// Host side: advertises this Mac and hands each incoming signaling connection to the owner,
/// which decides whether to accept it.
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
    private let onConnection: @Sendable (SignalingConnection) -> Void
    private let onState: @Sendable (State) -> Void

    public init(id: String, name: String,
                onConnection: @escaping @Sendable (SignalingConnection) -> Void,
                onState: @escaping @Sendable (State) -> Void) {
        self.id = id
        self.name = name
        self.onConnection = onConnection
        self.onState = onState
    }

    public func start() throws {
        let listener = try NWListener(using: LAN.parameters())
        var txt = NWTXTRecord()
        txt[LAN.TXTKey.id] = id
        txt[LAN.TXTKey.name] = name
        txt[LAN.TXTKey.protocolMajor] = String(Wire.major)
        listener.service = NWListener.Service(name: name, type: LAN.serviceType, txtRecord: txt)
        let onState = self.onState
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .setup: onState(.starting)
            case .ready: onState(.ready(port: listener?.port?.rawValue ?? 0))
            case .waiting(let error): onState(.waiting("\(error)"))
            case .failed(let error): onState(.failed("\(error)"))
            case .cancelled: onState(.stopped)
            @unknown default: break
            }
        }
        let onConnection = self.onConnection
        listener.newConnectionHandler = { connection in
            onConnection(SignalingConnection(connection: connection, session: nil))
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
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

/// One signaling WebSocket. It stamps outgoing messages with the session id, a sequence number
/// and a timestamp, and drops incoming ones that are oversized, malformed, for another session,
/// or replayed.
public final class SignalingConnection: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting
        case ready
        case closed(String?)
    }

    private let queue = DispatchQueue(label: "farside.lan.signaling")
    private let connection: NWConnection
    /// Set by the client when it connects; the host adopts the first one it sees.
    private var session: String?
    private var nextSeq: UInt64 = 1
    private var lastReceivedSeq: UInt64 = 0
    private var onState: (@Sendable (State) -> Void)?
    private var onMessage: (@Sendable (SignalMessage) -> Void)?
    private var closed = false

    init(connection: NWConnection, session: String?) {
        self.connection = connection
        self.session = session
    }

    /// Client side: a new session to a Mac found by `LANBrowser`.
    public static func connect(to endpoint: NWEndpoint) -> SignalingConnection {
        SignalingConnection(connection: NWConnection(to: endpoint, using: LAN.parameters()), session: UUID().uuidString)
    }

    /// Client side: a new session to a typed address (Connect by address, Phase 2). The WebSocket
    /// handshake needs a `ws://` URL endpoint here; a bare host-and-port endpoint is aborted by
    /// the WebSocket protocol before it is ready. Bonjour service endpoints work as they are.
    public static func connect(host: String, port: UInt16) -> SignalingConnection {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        let endpoint: NWEndpoint = components.url.map { .url($0) }
            ?? .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        return connect(to: endpoint)
    }

    /// For logs. Marked private by callers.
    public var remoteDescription: String { "\(connection.endpoint)" }

    public func start(onState: @escaping @Sendable (State) -> Void, onMessage: @escaping @Sendable (SignalMessage) -> Void) {
        queue.async { [self] in
            self.onState = onState
            self.onMessage = onMessage
            connection.stateUpdateHandler = { [weak self] state in
                // Nothing is reported after closed, not even a late waiting.
                guard let self, !self.closed else { return }
                switch state {
                case .ready: onState(.ready)
                case .failed(let error): self.finish("\(error)")
                case .cancelled: self.finish(nil)
                case .waiting: onState(.connecting)
                default: break
                }
            }
            connection.start(queue: queue)
            receive()
        }
    }

    public func send(_ message: SignalMessage) {
        queue.async { [self] in
            guard !closed, let session else { return }
            let envelope = SignalEnvelope(message: message, session: session, seq: nextSeq, ts: Int64(Date().timeIntervalSince1970))
            nextSeq += 1
            guard let data = try? envelope.encoded() else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "signal", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    /// Closes the socket after anything already queued has been handed to the network.
    public func close() {
        queue.async { [self] in
            connection.cancel()
        }
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
        guard let envelope = try? SignalEnvelope.decoded(data) else { return }
        if session == nil { session = envelope.session }
        guard envelope.session == session, envelope.seq > lastReceivedSeq else { return }
        lastReceivedSeq = envelope.seq
        onMessage?(envelope.message)
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onState?(.closed(reason))
    }
}
