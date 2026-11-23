import WireProtocol

// The session state machine (plan section 15). Both apps run it. It is a pure value: give it an
// event and the current time, and it returns the resources to switch on or off. Time is a
// `Duration` since any fixed origin the caller chooses, so tests drive it with plain numbers.
//
// The machine never schedules anything itself. After each call, the caller wakes it with `.tick`
// at `deadline`, if there is one.

/// Why a session ended (plan section 15, end reasons). The raw values are the plan's codes.
public enum SessionEndReason: String, Sendable, Equatable, CaseIterable {
    case userEnded = "user_ended"
    case hostEnded = "host_ended"
    case takenOver = "taken_over"
    case ringTimeout = "ring_timeout"
    case pathTimeout = "path_timeout"
    case authFailed = "auth_failed"
    case versionMismatch = "version_mismatch"
    case permissionMissing = "permission_missing"
    case hostSleeping = "host_sleeping"
    case networkLost = "network_lost"
    case internalError = "internal_error"
    /// Another device is in a session with this Mac.
    case busy = "busy"
    /// The Mac has not paired with this device (plan section 14). Signaling only; on the wire it
    /// travels as auth failed.
    case notPaired = "not_paired"
}

public enum SessionState: Sendable, Equatable {
    /// No session.
    case idle
    /// Waiting for the other side to accept. On a LAN, the signaling socket opening is the accept.
    case ringing
    /// Exchanging descriptions and probing paths.
    case negotiating
    /// Encrypted channel up; Hello, HelloAck, StreamConfig and StreamConfigApplied in flight.
    case securing
    /// Video and input flowing.
    case streaming
    /// The iPad app left the foreground.
    case paused
    /// Path restart in progress.
    case recovering
    /// Finished.
    case ended(SessionEndReason)

    public var isActive: Bool {
        switch self {
        case .idle, .ended: false
        default: true
        }
    }
}

public enum SessionEvent: Sendable, Equatable {
    /// Client: the user tapped Connect. Host: a peer reached the listener.
    case connect
    /// The other side accepted. Host: this Mac accepted the incoming peer.
    case accepted
    /// The transport connected and the control channel is open. In Recovering, the path is back.
    case pathUp
    /// Hello and stream config are settled on both sides.
    case handshakeDone
    /// The transport lost its path but has not given up.
    case pathDown
    case pause
    case resume
    /// This side decided to end. A Bye goes out if the control channel may still be open.
    case end(SessionEndReason)
    /// The other side sent Bye.
    case peerEnded(SessionEndReason)
    /// The transport closed or failed with no Bye.
    case transportClosed
    /// Time passed. Fires the current deadline if it is due.
    case tick
    /// Client: the user dismissed the ended message.
    case dismiss
}

/// What the owner must do after an event. Effects come in the order to apply them.
public enum SessionEffect: Sendable, Equatable {
    /// Host: start capture and encoding. Client: start decoding and rendering.
    case startMedia
    case stopMedia
    /// Host: start injecting input. Client: start sending it.
    case enableInput
    /// Host: release every held key and button, then stop injecting.
    case disableInput
    case startPings
    case stopPings
    case sendBye(SessionEndReason)
    case closeTransport
}

/// How long each state may last (plan sections 12 and 15).
public struct SessionTimeouts: Sendable, Equatable {
    public var ringing: Duration
    public var negotiating: Duration
    public var securing: Duration
    public var paused: Duration
    public var recovering: Duration
    /// Host only: how long Ended lingers, so a Bye can flush, before the Mac is Idle again.
    public var hostEnded: Duration

    public init(ringing: Duration = .seconds(10), negotiating: Duration = .seconds(15),
                securing: Duration = .seconds(3), paused: Duration = .seconds(60),
                recovering: Duration = .seconds(15), hostEnded: Duration = .seconds(1)) {
        self.ringing = ringing
        self.negotiating = negotiating
        self.securing = securing
        self.paused = paused
        self.recovering = recovering
        self.hostEnded = hostEnded
    }

    public static let standard = SessionTimeouts()
}

public struct SessionMachine: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case client, host }

    public let role: Role
    public let timeouts: SessionTimeouts
    public private(set) var state: SessionState = .idle
    /// When the current state times out, on the caller's clock. Nil when it cannot.
    public private(set) var deadline: Duration?
    /// Invariant 1: on only in Streaming and Recovering.
    public private(set) var mediaOn = false
    /// Invariant 2: on only in Streaming.
    public private(set) var inputOn = false
    public private(set) var pingsOn = false

    public init(role: Role, timeouts: SessionTimeouts = .standard) {
        self.role = role
        self.timeouts = timeouts
    }

    /// Applies one event at time `now`. Events that make no sense in the current state are ignored
    /// and return no effects.
    public mutating func handle(_ event: SessionEvent, at now: Duration) -> [SessionEffect] {
        switch (state, event) {
        case (.idle, .connect):
            return enter(.ringing, at: now)
        case (.ended, .connect) where role == .client:
            // Connecting again straight from the ended message. The host instead waits out its
            // short Ended linger, then takes the next peer from Idle.
            return enter(.ringing, at: now)
        case (.ringing, .accepted):
            return enter(.negotiating, at: now)
        case (.negotiating, .pathUp):
            return enter(.securing, at: now)
        case (.securing, .handshakeDone), (.recovering, .pathUp), (.paused, .resume):
            return enter(.streaming, at: now)
        case (.streaming, .pathDown):
            return enter(.recovering, at: now)
        case (.streaming, .pause), (.recovering, .pause):
            return enter(.paused, at: now)

        case (_, .end(let reason)) where state.isActive:
            // A Bye can only travel once the control channel exists.
            let channelMayBeOpen = state != .ringing && state != .negotiating
            return finish(reason, at: now, sendBye: channelMayBeOpen)
        case (_, .peerEnded(let reason)) where state.isActive:
            return finish(reason, at: now, sendBye: false)
        case (_, .transportClosed) where state.isActive:
            return finish(.networkLost, at: now, sendBye: false)

        case (_, .tick):
            guard let deadline, now >= deadline else { return [] }
            return timedOut(at: now)

        case (.ended, .dismiss) where role == .client:
            return enter(.idle, at: now)

        default:
            return []
        }
    }

    private mutating func timedOut(at now: Duration) -> [SessionEffect] {
        switch state {
        case .ringing: finish(.ringTimeout, at: now, sendBye: false)
        case .negotiating: finish(.pathTimeout, at: now, sendBye: false)
        case .securing: finish(.pathTimeout, at: now, sendBye: true)
        case .paused, .recovering: finish(.networkLost, at: now, sendBye: true)
        case .ended: enter(.idle, at: now)
        case .idle, .streaming: []
        }
    }

    private mutating func finish(_ reason: SessionEndReason, at now: Duration, sendBye: Bool) -> [SessionEffect] {
        var effects = resources(media: false, input: false, pings: false)
        if sendBye { effects.append(.sendBye(reason)) }
        effects.append(.closeTransport)
        state = .ended(reason)
        deadline = role == .host ? now + timeouts.hostEnded : nil
        return effects
    }

    private mutating func enter(_ next: SessionState, at now: Duration) -> [SessionEffect] {
        state = next
        let effects: [SessionEffect]
        switch next {
        case .idle, .ringing, .negotiating, .securing, .ended:
            effects = resources(media: false, input: false, pings: false)
        case .streaming:
            effects = resources(media: true, input: true, pings: true)
        case .recovering:
            // Capture keeps running so the first frame after recovery is fresh; input stops.
            effects = resources(media: true, input: false, pings: true)
        case .paused:
            effects = resources(media: false, input: false, pings: true)
        }
        deadline = switch next {
        case .ringing: now + timeouts.ringing
        case .negotiating: now + timeouts.negotiating
        case .securing: now + timeouts.securing
        case .paused: now + timeouts.paused
        case .recovering: now + timeouts.recovering
        case .ended: role == .host ? now + timeouts.hostEnded : nil
        case .idle, .streaming: nil
        }
        return effects
    }

    /// Switches media, input and pings to the wanted values. Input goes off before media and on
    /// after it, so no input is ever injected without a picture.
    private mutating func resources(media: Bool, input: Bool, pings: Bool) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        if inputOn && !input { effects.append(.disableInput); inputOn = false }
        if mediaOn && !media { effects.append(.stopMedia); mediaOn = false }
        if !mediaOn && media { effects.append(.startMedia); mediaOn = true }
        if !inputOn && input { effects.append(.enableInput); inputOn = true }
        if pingsOn && !pings { effects.append(.stopPings); pingsOn = false }
        if !pingsOn && pings { effects.append(.startPings); pingsOn = true }
        return effects
    }
}

// MARK: Wire mapping

extension SessionEndReason {
    public init(wire: Farside_V1_EndReason) {
        self = switch wire {
        case .userEnded: .userEnded
        case .hostEnded: .hostEnded
        case .takenOver: .takenOver
        case .ringTimeout: .ringTimeout
        case .pathTimeout: .pathTimeout
        case .authFailed: .authFailed
        case .versionMismatch: .versionMismatch
        case .permissionMissing: .permissionMissing
        case .hostSleeping: .hostSleeping
        case .networkLost: .networkLost
        case .busy: .busy
        case .internalError, .unspecified, .UNRECOGNIZED: .internalError
        }
    }

    public var wire: Farside_V1_EndReason {
        switch self {
        case .userEnded: .userEnded
        case .hostEnded: .hostEnded
        case .takenOver: .takenOver
        case .ringTimeout: .ringTimeout
        case .pathTimeout: .pathTimeout
        case .authFailed: .authFailed
        case .versionMismatch: .versionMismatch
        case .permissionMissing: .permissionMissing
        case .hostSleeping: .hostSleeping
        case .networkLost: .networkLost
        case .internalError: .internalError
        case .busy: .busy
        case .notPaired: .authFailed
        }
    }
}
