import Foundation
import Network

/// LAN signaling: the Mac advertises `_farside._tcp` over Bonjour and accepts one WebSocket;
/// the iPad browses and connects (plan section 12, on a LAN with no backend).
public final class LANSignaling: @unchecked Sendable {
    public static let serviceType = "_farside._tcp"

    private let queue = DispatchQueue(label: "farside.signaling")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let onMessage: @Sendable (SignalMessage) -> Void
    private let onState: @Sendable (String) -> Void

    private init(onMessage: @escaping @Sendable (SignalMessage) -> Void, onState: @escaping @Sendable (String) -> Void) {
        self.onMessage = onMessage
        self.onState = onState
    }

    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// Host side. Accepts the first connection.
    public static func serve(name: String, onConnect: @escaping @Sendable () -> Void,
                             onMessage: @escaping @Sendable (SignalMessage) -> Void,
                             onState: @escaping @Sendable (String) -> Void) throws -> LANSignaling {
        let s = LANSignaling(onMessage: onMessage, onState: onState)
        let listener = try NWListener(using: parameters())
        listener.service = NWListener.Service(name: name, type: serviceType)
        listener.stateUpdateHandler = { state in onState("listener \(state)") }
        listener.newConnectionHandler = { [weak s] connection in
            guard let s, s.connection == nil else { connection.cancel(); return }
            s.attach(connection, onReady: onConnect)
        }
        listener.start(queue: s.queue)
        s.listener = listener
        return s
    }

    /// Client side. Connects to the first service found.
    public static func connect(onConnect: @escaping @Sendable () -> Void,
                               onMessage: @escaping @Sendable (SignalMessage) -> Void,
                               onState: @escaping @Sendable (String) -> Void) -> LANSignaling {
        let s = LANSignaling(onMessage: onMessage, onState: onState)
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters())
        browser.stateUpdateHandler = { state in onState("browser \(state)") }
        browser.browseResultsChangedHandler = { [weak s] results, _ in
            guard let s, s.connection == nil, let first = results.first else { return }
            onState("found \(first.endpoint)")
            s.attach(NWConnection(to: first.endpoint, using: parameters()), onReady: onConnect)
        }
        browser.start(queue: s.queue)
        s.browser = browser
        return s
    }

    private func attach(_ connection: NWConnection, onReady: @escaping @Sendable () -> Void) {
        self.connection = connection
        let onState = self.onState
        connection.stateUpdateHandler = { state in
            onState("connection \(state)")
            if case .ready = state { onReady() }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = try? JSONDecoder().decode(SignalMessage.self, from: data) {
                self.onMessage(message)
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    public func send(_ message: SignalMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        queue.async { [weak self] in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "signal", metadata: [metadata])
            self?.connection?.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    public func stop() {
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
    }
}
