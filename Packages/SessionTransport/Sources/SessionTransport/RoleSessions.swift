import Foundation
import WireProtocol

/// What one side says about itself in Hello and HelloAck.
public struct DeviceInfo: Sendable, Equatable {
    public var name: String
    public var model: String
    public var osVersion: String
    public var appVersion: String
    public var capabilities: Farside_V1_Capabilities

    public init(name: String, model: String, osVersion: String, appVersion: String, capabilities: Farside_V1_Capabilities) {
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.capabilities = capabilities
    }

    init(hello: Farside_V1_Hello) {
        self.init(name: hello.deviceName, model: hello.deviceModel, osVersion: hello.osVersion,
                  appVersion: hello.appVersion, capabilities: hello.capabilities)
    }

    init(ack: Farside_V1_HelloAck) {
        self.init(name: ack.deviceName, model: ack.deviceModel, osVersion: ack.osVersion,
                  appVersion: ack.appVersion, capabilities: ack.capabilities)
    }
}

// MARK: Host

/// Called on the session's queue. Implementations hop to their own queues for slow work.
public protocol HostSessionDelegate: AnyObject, Sendable {
    /// The displays to offer, in wire form.
    func hostSessionDisplays() -> [Farside_V1_Display]
    /// Decides the stream for a request. Nil ends the session with `internal_error`.
    func hostSessionApply(_ request: Farside_V1_StreamConfig, client: DeviceInfo) -> Farside_V1_StreamConfigApplied?
    /// Start capture with this configuration. Capture never starts before the handshake.
    func hostSessionStartMedia(_ applied: Farside_V1_StreamConfigApplied)
    func hostSessionStopMedia()
    func hostSessionStateChanged(_ state: SessionState, client: DeviceInfo?)
    /// Input from the iPad (plan section 9), only while streaming. `seq` is the envelope's, which
    /// orders pointer moves on the unreliable channel.
    func hostSessionInput(_ body: Envelope.OneOf_Body, seq: UInt32)
}

extension HostSessionDelegate {
    public func hostSessionInput(_ body: Envelope.OneOf_Body, seq: UInt32) {}
}

/// The Mac's side of one session (plan section 11, handshake): waits for Hello, answers with
/// HelloAck and DisplayList, applies StreamConfig, and starts capture once both agree.
public final class HostSession: SessionBase, @unchecked Sendable {
    private let local: DeviceInfo
    private weak var delegate: HostSessionDelegate?
    private var client: DeviceInfo?
    private var applied: Farside_V1_StreamConfigApplied?
    private let resumeToken = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    public init(signaling: SignalingChannel, local: DeviceInfo, delegate: HostSessionDelegate,
                timeouts: SessionTimeouts = .standard, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.local = local
        self.delegate = delegate
        super.init(role: .host, signaling: signaling, timeouts: timeouts, log: log)
    }

    /// Takes the incoming connection. The offer goes out once signaling is ready.
    public func start(transport: SessionTransport) {
        queue.async { [self] in
            attach(transport)
            apply(.connect)
            startSignaling()
        }
    }

    /// Resends the display list, for example after a display was added.
    public func sendDisplays() {
        queue.async { [self] in
            guard machine.state == .streaming || machine.state == .securing, client != nil, let delegate else { return }
            send(.displayList(.with { $0.displays = delegate.hostSessionDisplays() }))
        }
    }

    override func signalingReadied() {
        // Unattended mode, the only one in Phase 1: accept at once (plan section 6).
        apply(.accepted)
        if machine.state == .negotiating { transport?.start() }
    }

    /// Sends a cursor message to the iPad (plan section 10). Dropped unless streaming.
    public func sendCursor(_ body: Envelope.OneOf_Body) {
        queue.async { [self] in sendWhileStreaming(body) }
    }

    override func received(_ body: Envelope.OneOf_Body, seq: UInt32) {
        switch body {
        case .pointerMove, .pointerDelta, .button, .scroll, .key, .text, .releaseAll, .inputHeartbeat:
            guard machine.state == .streaming else { return }
            delegate?.hostSessionInput(body, seq: seq)

        case .hello(let hello):
            guard machine.state == .securing, client == nil else { return }
            guard Wire.isCompatible(major: hello.protocolMajor) else {
                log("client speaks protocol \(hello.protocolMajor).\(hello.protocolMinor)")
                return apply(.end(.versionMismatch))
            }
            let client = DeviceInfo(hello: hello)
            self.client = client
            send(.helloAck(.with {
                $0.protocolMajor = Wire.major
                $0.protocolMinor = Wire.minor
                $0.appVersion = local.appVersion
                $0.deviceModel = local.model
                $0.osVersion = local.osVersion
                $0.deviceName = local.name
                $0.capabilities = local.capabilities
                $0.sessionNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
                $0.resumeToken = resumeToken
            }))
            send(.displayList(.with { $0.displays = delegate?.hostSessionDisplays() ?? [] }))
            delegate?.hostSessionStateChanged(machine.state, client: client)

        case .streamConfig(let request):
            guard let client, machine.state == .securing || machine.state == .streaming else { return }
            guard let applied = delegate?.hostSessionApply(request, client: client) else {
                return apply(.end(.internalError))
            }
            let restart = machine.state == .streaming && self.applied != applied
            self.applied = applied
            send(.streamConfigApplied(applied))
            if machine.state == .securing {
                apply(.handshakeDone)
            } else if restart {
                // A new display or size while streaming.
                delegate?.hostSessionStopMedia()
                delegate?.hostSessionStartMedia(applied)
            }

        default:
            break
        }
    }

    override func effect(_ effect: SessionEffect) {
        switch effect {
        case .startMedia:
            if let applied { delegate?.hostSessionStartMedia(applied) }
        case .stopMedia:
            delegate?.hostSessionStopMedia()
        default:
            break
        }
    }

    override func stateChanged(_ state: SessionState) {
        delegate?.hostSessionStateChanged(state, client: client)
    }
}

// MARK: Client

/// Called on the session's queue.
public protocol ClientSessionDelegate: AnyObject, Sendable {
    /// Picks the stream to ask for, once the host's displays are known.
    func clientSessionChooseStream(displays: [Farside_V1_Display], host: DeviceInfo) -> Farside_V1_StreamConfig
    /// The host's decision. Authoritative.
    func clientSessionApplied(_ applied: Farside_V1_StreamConfigApplied)
    func clientSessionDisplaysChanged(_ displays: [Farside_V1_Display])
    func clientSessionStateChanged(_ state: SessionState, host: DeviceInfo?)
    func clientSessionRoundTrip(_ seconds: Double)
    /// Cursor shape, state and position from the Mac (plan section 10), only while streaming.
    func clientSessionCursor(_ body: Envelope.OneOf_Body)
}

extension ClientSessionDelegate {
    public func clientSessionCursor(_ body: Envelope.OneOf_Body) {}
}

/// The iPad's side of one session: sends Hello when the control channel opens, then asks for a
/// stream once the host's displays arrive.
public final class ClientSession: SessionBase, @unchecked Sendable {
    private let local: DeviceInfo
    private weak var delegate: ClientSessionDelegate?
    private var host: DeviceInfo?
    private var requested = false

    public init(signaling: SignalingChannel, local: DeviceInfo, delegate: ClientSessionDelegate,
                timeouts: SessionTimeouts = .standard, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.local = local
        self.delegate = delegate
        super.init(role: .client, signaling: signaling, timeouts: timeouts, log: log)
        onRoundTrip = { [weak delegate] rtt in delegate?.clientSessionRoundTrip(rtt) }
    }

    /// Connects. The transport waits for the host's offer.
    public func start(transport: SessionTransport) {
        queue.async { [self] in
            attach(transport)
            apply(.connect)
            startSignaling()
        }
    }

    override func signalingReadied() {
        apply(.accepted)
    }

    override func controlChannelOpened() {
        send(.hello(.with {
            $0.protocolMajor = Wire.major
            $0.protocolMinor = Wire.minor
            $0.appVersion = local.appVersion
            $0.deviceModel = local.model
            $0.osVersion = local.osVersion
            $0.deviceName = local.name
            $0.capabilities = local.capabilities
            $0.sessionNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        }))
    }

    /// Sends input to the Mac (plan section 9). Dropped unless streaming. Call from any thread;
    /// messages keep their order.
    public func sendInput(_ body: Envelope.OneOf_Body) {
        queue.async { [self] in sendWhileStreaming(body) }
    }

    override func received(_ body: Envelope.OneOf_Body, seq: UInt32) {
        switch body {
        case .cursorShape, .cursorState, .cursorPosition:
            guard machine.state == .streaming else { return }
            delegate?.clientSessionCursor(body)

        case .helloAck(let ack):
            guard machine.state == .securing, host == nil else { return }
            guard Wire.isCompatible(major: ack.protocolMajor) else {
                log("host speaks protocol \(ack.protocolMajor).\(ack.protocolMinor)")
                return apply(.end(.versionMismatch))
            }
            host = DeviceInfo(ack: ack)
            delegate?.clientSessionStateChanged(machine.state, host: host)

        case .displayList(let list):
            guard let host else { return }
            if !requested, machine.state == .securing, let delegate {
                requested = true
                send(.streamConfig(delegate.clientSessionChooseStream(displays: list.displays, host: host)))
            } else {
                delegate?.clientSessionDisplaysChanged(list.displays)
            }

        case .streamConfigApplied(let applied):
            guard requested else { return }
            delegate?.clientSessionApplied(applied)
            if machine.state == .securing { apply(.handshakeDone) }

        default:
            break
        }
    }

    override func stateChanged(_ state: SessionState) {
        delegate?.clientSessionStateChanged(state, host: host)
    }

    /// Leaves the ended state for idle, so the owner can drop the session.
    public func dismiss() {
        queue.async { [self] in apply(.dismiss) }
    }
}
