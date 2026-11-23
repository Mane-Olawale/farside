import Testing
@testable import SessionTransport

/// A fake clock around the machine. `advance` moves time forward and delivers `.tick` exactly at
/// each deadline it passes, the way the real driver does.
struct Harness {
    var machine: SessionMachine
    var now: Duration = .zero
    var log: [SessionEffect] = []

    init(_ role: SessionMachine.Role, timeouts: SessionTimeouts = .standard) {
        machine = SessionMachine(role: role, timeouts: timeouts)
    }

    @discardableResult
    mutating func send(_ event: SessionEvent) -> [SessionEffect] {
        let effects = machine.handle(event, at: now)
        log += effects
        return effects
    }

    @discardableResult
    mutating func advance(_ amount: Duration) -> [SessionEffect] {
        let end = now + amount
        var effects: [SessionEffect] = []
        while let deadline = machine.deadline, deadline <= end {
            now = deadline
            effects += send(.tick)
        }
        now = end
        return effects
    }

    var state: SessionState { machine.state }
}

@Suite struct SessionMachineTests {
    // MARK: Normal connect

    @Test func clientConnectsAndStreams() {
        var h = Harness(.client)
        #expect(h.send(.connect) == [])
        #expect(h.state == .ringing)
        h.send(.accepted)
        #expect(h.state == .negotiating)
        h.send(.pathUp)
        #expect(h.state == .securing)
        #expect(h.send(.handshakeDone) == [.startMedia, .enableInput, .startPings])
        #expect(h.state == .streaming)
        #expect(h.machine.deadline == nil)
    }

    @Test func hostConnectsAndStreams() {
        var h = Harness(.host)
        h.send(.connect)
        h.send(.accepted)
        h.send(.pathUp)
        #expect(h.log.isEmpty, "nothing starts before the handshake")
        #expect(h.send(.handshakeDone) == [.startMedia, .enableInput, .startPings])
    }

    // MARK: Timeouts, on the fake clock

    @Test(arguments: [
        (SessionState.ringing, Duration.seconds(10), SessionEndReason.ringTimeout),
        (.negotiating, .seconds(15), .pathTimeout),
        (.securing, .seconds(3), .pathTimeout),
    ])
    func connectStepsTimeOut(state: SessionState, limit: Duration, reason: SessionEndReason) {
        var h = Harness(.client)
        reach(state, &h)
        h.advance(limit - .milliseconds(1))
        #expect(h.state == state, "not before the deadline")
        h.advance(.milliseconds(1))
        #expect(h.state == .ended(reason))
    }

    @Test func pausedEndsAfterSixtySeconds() {
        var h = Harness(.host)
        reach(.streaming, &h)
        h.send(.pause)
        h.advance(.seconds(59))
        #expect(h.state == .paused)
        let effects = h.advance(.seconds(1))
        #expect(h.state == .ended(.networkLost))
        #expect(effects == [.stopPings, .sendBye(.networkLost), .closeTransport])
    }

    @Test func recoveringEndsAfterFifteenSeconds() {
        var h = Harness(.client)
        reach(.streaming, &h)
        h.send(.pathDown)
        h.advance(.seconds(15))
        #expect(h.state == .ended(.networkLost))
    }

    @Test func streamingHasNoDeadline() {
        var h = Harness(.client)
        reach(.streaming, &h)
        h.advance(.seconds(8 * 3600))
        #expect(h.state == .streaming)
    }

    @Test func tickBeforeDeadlineDoesNothing() {
        var h = Harness(.client)
        h.send(.connect)
        h.now = .seconds(5)
        #expect(h.send(.tick) == [])
        #expect(h.state == .ringing)
    }

    @Test func deadlineRestartsInEachState() {
        var h = Harness(.client)
        h.send(.connect)
        h.advance(.seconds(9))
        h.send(.accepted)
        // Negotiating gets its own full 15 s, counted from the accept.
        h.advance(.seconds(14))
        #expect(h.state == .negotiating)
        h.advance(.seconds(1))
        #expect(h.state == .ended(.pathTimeout))
    }

    // MARK: Ending

    @Test func noByeBeforeTheControlChannelExists() {
        var h = Harness(.client)
        h.send(.connect)
        #expect(h.send(.end(.userEnded)) == [.closeTransport])
        var n = Harness(.client)
        reach(.negotiating, &n)
        #expect(n.send(.end(.userEnded)) == [.closeTransport])
    }

    @Test func localEndWhileStreamingReleasesInputFirstThenSendsBye() {
        var h = Harness(.host)
        reach(.streaming, &h)
        #expect(h.send(.end(.hostEnded)) == [.disableInput, .stopMedia, .stopPings, .sendBye(.hostEnded), .closeTransport])
        #expect(h.state == .ended(.hostEnded))
    }

    @Test func peerByeIsNotAnswered() {
        var h = Harness(.client)
        reach(.streaming, &h)
        #expect(h.send(.peerEnded(.hostEnded)) == [.disableInput, .stopMedia, .stopPings, .closeTransport])
        #expect(h.state == .ended(.hostEnded))
    }

    @Test func transportClosingIsNetworkLost() {
        var h = Harness(.client)
        reach(.securing, &h)
        #expect(h.send(.transportClosed) == [.closeTransport])
        #expect(h.state == .ended(.networkLost))
    }

    @Test func endWhenIdleOrEndedIsIgnored() {
        var h = Harness(.client)
        #expect(h.send(.end(.userEnded)) == [])
        reach(.streaming, &h)
        h.send(.end(.userEnded))
        #expect(h.send(.end(.internalError)) == [])
        #expect(h.send(.transportClosed) == [])
        #expect(h.state == .ended(.userEnded))
    }

    @Test func hostReturnsToIdleOnItsOwn() {
        var h = Harness(.host)
        reach(.streaming, &h)
        h.send(.peerEnded(.userEnded))
        h.advance(.milliseconds(999))
        #expect(h.state == .ended(.userEnded))
        h.advance(.milliseconds(1))
        #expect(h.state == .idle)
        #expect(h.machine.deadline == nil)
    }

    @Test func clientKeepsTheEndedMessageUntilDismissed() {
        var h = Harness(.client)
        reach(.streaming, &h)
        h.send(.peerEnded(.hostEnded))
        h.advance(.seconds(3600))
        #expect(h.state == .ended(.hostEnded))
        h.send(.dismiss)
        #expect(h.state == .idle)
    }

    @Test func clientCanConnectAgainFromEnded() {
        var h = Harness(.client)
        reach(.streaming, &h)
        h.send(.transportClosed)
        h.send(.connect)
        #expect(h.state == .ringing)
    }

    @Test func hostIgnoresConnectWhileEndedLingers() {
        var h = Harness(.host)
        reach(.streaming, &h)
        h.send(.end(.hostEnded))
        h.send(.connect)
        #expect(h.state == .ended(.hostEnded))
    }

    // MARK: Pause and recovery

    @Test func pauseStopsMediaAndInputAndResumeRestoresThem() {
        var h = Harness(.host)
        reach(.streaming, &h)
        #expect(h.send(.pause) == [.disableInput, .stopMedia])
        #expect(h.send(.resume) == [.startMedia, .enableInput])
        #expect(h.state == .streaming)
    }

    @Test func recoveryKeepsMediaButStopsInput() {
        var h = Harness(.host)
        reach(.streaming, &h)
        #expect(h.send(.pathDown) == [.disableInput])
        #expect(h.state == .recovering)
        #expect(h.send(.pathUp) == [.enableInput])
        #expect(h.state == .streaming)
    }

    @Test func pauseDuringRecovery() {
        var h = Harness(.client)
        reach(.streaming, &h)
        h.send(.pathDown)
        #expect(h.send(.pause) == [.stopMedia])
        #expect(h.state == .paused)
    }

    @Test func outOfOrderEventsAreIgnored() {
        var h = Harness(.client)
        for event: SessionEvent in [.accepted, .pathUp, .handshakeDone, .pathDown, .pause, .resume, .dismiss, .tick] {
            #expect(h.send(event) == [])
            #expect(h.state == .idle)
        }
        h.send(.connect)
        #expect(h.send(.handshakeDone) == [])
        #expect(h.state == .ringing)
    }

    // MARK: Invariants under random event sequences

    /// Plan section 15 invariants 1, 2, 4 and 5, checked after every step of many seeded runs.
    @Test(arguments: SessionMachine.Role.allCases)
    func invariantsHoldForRandomSequences(role: SessionMachine.Role) {
        let events: [SessionEvent] = [
            .connect, .accepted, .pathUp, .handshakeDone, .pathDown, .pause, .resume,
            .end(.userEnded), .peerEnded(.hostEnded), .transportClosed, .tick, .dismiss,
        ]
        var rng = SplitMix64(seed: 0xFA25_1DE)
        var visited: [String: Int] = [:]
        defer {
            // The runs must actually reach the states the invariants are about.
            for name in ["streaming", "paused", "recovering", "ended"] {
                #expect(visited[name, default: 0] > 50, "only \(visited[name, default: 0]) steps in \(name)")
            }
        }
        for _ in 0..<500 {
            var h = Harness(role)
            var handshakePassed = false
            var mediaRunning = false
            var inputRunning = false
            for _ in 0..<60 {
                let before = h.state
                // 60 % the next step forward, 30 % any event, 10 % let time run so timeouts fire.
                let roll = rng.next() % 10
                let effects: [SessionEffect]
                if roll < 6 {
                    effects = h.send(Self.forward(from: h.state, &rng))
                } else if roll < 9 {
                    effects = h.send(events[Int(rng.next() % UInt64(events.count))])
                } else {
                    effects = h.advance(.seconds(Int64(rng.next() % 20)))
                }
                if before == .securing && h.state == .streaming { handshakePassed = true }
                if case .idle = h.state { handshakePassed = false }
                if case .ringing = h.state { handshakePassed = false }

                for effect in effects {
                    switch effect {
                    case .startMedia:
                        #expect(handshakePassed, "invariant 5: media before the handshake")
                        #expect(!mediaRunning); mediaRunning = true
                    case .stopMedia:
                        #expect(mediaRunning); mediaRunning = false
                    case .enableInput:
                        #expect(mediaRunning, "input without a picture")
                        #expect(!inputRunning); inputRunning = true
                    case .disableInput:
                        #expect(inputRunning); inputRunning = false
                    default:
                        break
                    }
                }

                let s = h.state
                visited[s.name, default: 0] += 1
                #expect(h.machine.mediaOn == mediaRunning)
                #expect(h.machine.inputOn == inputRunning)
                #expect(mediaRunning == (s == .streaming || s == .recovering), "invariant 1 in \(s)")
                #expect(inputRunning == (s == .streaming), "invariant 2 in \(s)")
                switch s {
                case .ringing, .negotiating, .securing, .paused, .recovering:
                    #expect(h.machine.deadline != nil, "invariant 4 in \(s)")
                case .ended where role == .host:
                    #expect(h.machine.deadline != nil, "invariant 4: host Ended returns to Idle")
                default:
                    break
                }
            }
        }
    }

    @Test func endReasonsRoundTripThroughTheWire() {
        // Not paired travels only in signaling; on the wire it is auth failed.
        for reason in SessionEndReason.allCases where reason != .notPaired && reason != .declined {
            #expect(SessionEndReason(wire: reason.wire) == reason)
        }
        #expect(SessionEndReason.notPaired.wire == .authFailed)
        #expect(SessionEndReason(wire: .unspecified) == .internalError)
        #expect(SessionEndReason(wire: .UNRECOGNIZED(99)) == .internalError)
    }

    // MARK: Helpers

    /// The event that moves a session onward from `state`, so random runs spend time in the later states.
    static func forward(from state: SessionState, _ rng: inout SplitMix64) -> SessionEvent {
        switch state {
        case .idle, .ended: .connect
        case .ringing: .accepted
        case .negotiating: .pathUp
        case .securing: .handshakeDone
        case .streaming: rng.next() % 2 == 0 ? .pathDown : .pause
        case .paused: .resume
        case .recovering: rng.next() % 2 == 0 ? .pathUp : .pause
        }
    }

    private func reach(_ target: SessionState, _ h: inout Harness) {
        let path: [(SessionEvent, SessionState)] = [
            (.connect, .ringing), (.accepted, .negotiating), (.pathUp, .securing), (.handshakeDone, .streaming),
        ]
        for (event, state) in path where h.state != target {
            h.send(event)
            if state == target { break }
        }
        #expect(h.state == target)
    }
}

extension SessionState {
    var name: String {
        switch self {
        case .idle: "idle"
        case .ringing: "ringing"
        case .negotiating: "negotiating"
        case .securing: "securing"
        case .streaming: "streaming"
        case .paused: "paused"
        case .recovering: "recovering"
        case .ended: "ended"
        }
    }
}

extension SessionMachine.Role: CaseIterable {
    public static let allCases: [SessionMachine.Role] = [.client, .host]
}

/// Small deterministic generator, so a failure reproduces.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
