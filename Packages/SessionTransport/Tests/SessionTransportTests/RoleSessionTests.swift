import Foundation
import Testing
import WireProtocol
@testable import SessionTransport

/// Two signaling ends in memory. Both report ready once started.
final class InMemorySignaling: SignalingChannel, @unchecked Sendable {
    private let lock = NSLock()
    weak var peer: InMemorySignaling?
    private var onState: (@Sendable (SignalingConnection.State) -> Void)?
    private var onMessage: (@Sendable (SignalMessage) -> Void)?
    private var closed = false
    private(set) var sent: [SignalMessage] = []
    /// Delays this end's ready, to force orderings real sockets only sometimes produce.
    var readyDelay: Double = 0

    static func pair() -> (InMemorySignaling, InMemorySignaling) {
        let a = InMemorySignaling(), b = InMemorySignaling()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func start(onState: @escaping @Sendable (SignalingConnection.State) -> Void, onMessage: @escaping @Sendable (SignalMessage) -> Void) {
        lock.withLock {
            self.onState = onState
            self.onMessage = onMessage
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + readyDelay) { onState(.ready) }
    }

    func send(_ message: SignalMessage) {
        lock.withLock { sent.append(message) }
        guard !lock.withLock({ closed }), let peer else { return }
        let handler = peer.lock.withLock { peer.closed ? nil : peer.onMessage }
        DispatchQueue.global().async { handler?(message) }
    }

    func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first, let peer else { return }
        let handler = peer.lock.withLock { peer.onState }
        DispatchQueue.global().async { handler?(.closed(nil)) }
    }

    var sentMessages: [SignalMessage] { lock.withLock { sent } }
}

/// Records what the host session asks for.
final class HostRecorder: HostSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    var log: [String] = []
    var states: [SessionState] = []
    var started: [Farside_V1_StreamConfigApplied] = []

    func hostSessionDisplays() -> [Farside_V1_Display] {
        [.with { $0.id = 7; $0.name = "Test"; $0.pixelWidth = 3440; $0.pixelHeight = 1440; $0.main = true }]
    }
    func hostSessionApply(_ request: Farside_V1_StreamConfig, client: DeviceInfo) -> Farside_V1_StreamConfigApplied? {
        lock.withLock { log.append("apply") }
        return .with {
            $0.displayID = request.displayID
            $0.width = 2752
            $0.height = 1152
            $0.frameRate = 60
            $0.codec = .hevc
        }
    }
    func hostSessionStartMedia(_ applied: Farside_V1_StreamConfigApplied) {
        lock.withLock { log.append("start"); started.append(applied) }
    }
    func hostSessionStopMedia() { lock.withLock { log.append("stop") } }
    func hostSessionStateChanged(_ state: SessionState, client: DeviceInfo?) { lock.withLock { states.append(state) } }
    private(set) var input: [(Envelope.OneOf_Body, UInt32)] = []
    func hostSessionInput(_ body: Envelope.OneOf_Body, seq: UInt32) { lock.withLock { input.append((body, seq)) } }
    var inputBodies: [Envelope.OneOf_Body] { lock.withLock { input.map(\.0) } }

    var snapshot: (log: [String], states: [SessionState]) { lock.withLock { (log, states) } }
}

final class ClientRecorder: ClientSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    var states: [SessionState] = []
    var applied: Farside_V1_StreamConfigApplied?
    var host: DeviceInfo?
    var roundTrips: [Double] = []

    func clientSessionChooseStream(displays: [Farside_V1_Display], host: DeviceInfo) -> Farside_V1_StreamConfig {
        lock.withLock { self.host = host }
        return .with { $0.displayID = displays.first?.id ?? 0; $0.width = 2752; $0.height = 2064; $0.frameRate = 60; $0.codecPreference = [.hevc] }
    }
    func clientSessionApplied(_ applied: Farside_V1_StreamConfigApplied) { lock.withLock { self.applied = applied } }
    func clientSessionDisplaysChanged(_ displays: [Farside_V1_Display]) {}
    func clientSessionStateChanged(_ state: SessionState, host: DeviceInfo?) { lock.withLock { states.append(state) } }
    func clientSessionRoundTrip(_ seconds: Double) { lock.withLock { roundTrips.append(seconds) } }
    private(set) var cursor: [Envelope.OneOf_Body] = []
    func clientSessionCursor(_ body: Envelope.OneOf_Body) { lock.withLock { cursor.append(body) } }
    var cursorBodies: [Envelope.OneOf_Body] { lock.withLock { cursor } }

    var snapshot: (states: [SessionState], applied: Farside_V1_StreamConfigApplied?, host: DeviceInfo?, rtts: [Double]) {
        lock.withLock { (states, applied, host, roundTrips) }
    }
}

let macInfo = DeviceInfo(name: "Test Mac", model: "Mac15,6", osVersion: "26.0.1", appVersion: "0.1.0",
                         capabilities: .with { $0.codecs = [.hevc, .h264] })
let iPadInfo = DeviceInfo(name: "Test iPad", model: "iPad16,5", osVersion: "27.2.1", appVersion: "0.1.0",
                          capabilities: .with { $0.codecs = [.hevc, .h264]; $0.maxWidth = 2752; $0.maxHeight = 2064 })

/// Polls until `condition` holds or the time runs out.
func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct RoleSessionTests {
    struct Pair {
        let host: HostSession
        let client: ClientSession
        let hostRecorder: HostRecorder
        let clientRecorder: ClientRecorder
        let transports: (host: InMemoryTransport, client: InMemoryTransport)
        let signaling: (host: InMemorySignaling, client: InMemorySignaling)
    }

    func connect(timeouts: SessionTimeouts = .standard, clientReadyDelay: Double = 0) -> Pair {
        let (hostSignal, clientSignal) = InMemorySignaling.pair()
        clientSignal.readyDelay = clientReadyDelay
        let hostRecorder = HostRecorder(), clientRecorder = ClientRecorder()
        let host = HostSession(signaling: hostSignal, local: macInfo, delegate: hostRecorder, timeouts: timeouts)
        let client = ClientSession(signaling: clientSignal, local: iPadInfo, delegate: clientRecorder, timeouts: timeouts)
        let transports = InMemoryTransport.pair(host: host.transportHandlers(), client: client.transportHandlers())
        client.start(transport: transports.client)
        host.start(transport: transports.host)
        return Pair(host: host, client: client, hostRecorder: hostRecorder, clientRecorder: clientRecorder,
                    transports: transports, signaling: (hostSignal, clientSignal))
    }

    @Test func handshakeReachesStreamingOnBothSides() async {
        let p = connect()
        #expect(await eventually { p.host.state == .streaming && p.client.state == .streaming })
        let host = p.hostRecorder.snapshot
        #expect(host.log == ["apply", "start"], "capture starts once, after the config is applied")
        #expect(host.states.contains(.securing))
        let client = p.clientRecorder.snapshot
        #expect(client.applied?.width == 2752)
        #expect(client.host?.name == "Test Mac")
        #expect(client.states.suffix(1) == [.streaming])
    }

    /// The transport connects before the client's own signaling reports ready. The client must
    /// still notice the path once it starts negotiating.
    /// Input goes from the iPad to the host's delegate in order, with increasing sequence numbers,
    /// and cursor messages come back.
    @Test func inputAndCursorFlowWhileStreaming() async {
        let p = connect()
        #expect(await eventually { p.host.state == .streaming && p.client.state == .streaming })
        p.client.sendInput(.key(.with { $0.hidUsage = 0x0E; $0.down = true }))
        p.client.sendInput(.pointerMove(.with { $0.displayID = 1; $0.x = 0.5; $0.y = 0.5 }))
        p.client.sendInput(.key(.with { $0.hidUsage = 0x0E; $0.down = false }))
        #expect(await eventually { p.hostRecorder.inputBodies.count == 3 })
        let input = p.hostRecorder.input
        #expect(input.map(\.0.channel) == [.input, .pointer, .input])
        #expect(input[0].1 < input[1].1 && input[1].1 < input[2].1)
        p.host.sendCursor(.cursorPosition(.with { $0.x = 0.25; $0.lastInputSeq = input[1].1 }))
        #expect(await eventually { p.clientRecorder.cursorBodies.count == 1 })
    }

    /// Before streaming there is nothing to control: input is not even sent.
    @Test func inputBeforeStreamingIsDropped() async {
        let (hostSignal, clientSignal) = InMemorySignaling.pair()
        let hostRecorder = HostRecorder(), clientRecorder = ClientRecorder()
        let host = HostSession(signaling: hostSignal, local: macInfo, delegate: hostRecorder)
        let client = ClientSession(signaling: clientSignal, local: iPadInfo, delegate: clientRecorder)
        let transports = InMemoryTransport.pair(host: host.transportHandlers(), client: client.transportHandlers())
        client.sendInput(.releaseAll(.init()))
        client.start(transport: transports.client)
        host.start(transport: transports.host)
        #expect(await eventually { host.state == .streaming })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hostRecorder.inputBodies.isEmpty)
    }

    @Test func pathUpBeforeClientSignalingIsReady() async {
        let p = connect(clientReadyDelay: 0.2)
        #expect(await eventually { p.host.state == .streaming && p.client.state == .streaming })
    }

    @Test func clientEndingSendsByeAndHostStopsCapture() async {
        let p = connect()
        #expect(await eventually { p.host.state == .streaming })
        p.client.end(.userEnded)
        #expect(await eventually { p.host.state == .ended(.userEnded) || p.host.state == .idle })
        #expect(p.hostRecorder.snapshot.log.last == "stop")
        #expect(p.client.state == .ended(.userEnded))
    }

    @Test func hostEndingReachesTheClient() async {
        let p = connect()
        #expect(await eventually { p.client.state == .streaming })
        p.host.end(.hostEnded)
        #expect(await eventually { p.client.state == .ended(.hostEnded) })
    }

    /// The iPad app is killed: no Bye, its sockets just close. The Mac must end promptly.
    @Test func peerVanishingEndsTheSession() async {
        let p = connect()
        #expect(await eventually { p.host.state == .streaming })
        p.signaling.client.close()
        p.transports.client.close()
        #expect(await eventually { p.host.state == .ended(.networkLost) || p.host.state == .idle })
        #expect(p.hostRecorder.snapshot.log.last == "stop")
    }

    @Test func hostReturnsToIdleAfterEnding() async {
        let p = connect(timeouts: SessionTimeouts(hostEnded: .milliseconds(50)))
        #expect(await eventually { p.host.state == .streaming })
        p.client.end(.userEnded)
        #expect(await eventually { p.host.state == .idle })
    }

    /// No Hello within the securing timeout: the host gives up and never captures.
    @Test func silentClientTimesOut() async throws {
        let (hostSignal, clientSignal) = InMemorySignaling.pair()
        let recorder = HostRecorder()
        let host = HostSession(signaling: hostSignal, local: macInfo, delegate: recorder,
                               timeouts: SessionTimeouts(securing: .milliseconds(200)))
        let transports = InMemoryTransport.pair(host: host.transportHandlers(),
                                                client: TransportHandlers(signal: { _ in }, event: { _ in }))
        clientSignal.start(onState: { _ in }, onMessage: { _ in })
        host.start(transport: transports.host)
        #expect(await eventually { host.state == .ended(.pathTimeout) || host.state == .idle })
        #expect(recorder.snapshot.log.isEmpty)
        withExtendedLifetime(transports.client) {}
    }

    /// A client on another major version gets Bye(version_mismatch) and no capture starts.
    @Test func versionMismatchEndsBeforeCapture() async throws {
        let (hostSignal, clientSignal) = InMemorySignaling.pair()
        let recorder = HostRecorder()
        let host = HostSession(signaling: hostSignal, local: macInfo, delegate: recorder)
        let received = Locked<[Envelope]>([])
        let transports = InMemoryTransport.pair(
            host: host.transportHandlers(),
            client: TransportHandlers(signal: { _ in }, event: { event in
                if case .message(let channel, let data) = event, let e = try? Envelope.decoded(data, on: channel) {
                    received.mutate { $0.append(e) }
                }
            }))
        clientSignal.start(onState: { _ in }, onMessage: { _ in })
        host.start(transport: transports.host)
        #expect(await eventually { host.state == .securing })
        let hello = try Envelope(seq: 1, sentAtMicroseconds: 1, body: .hello(.with { $0.protocolMajor = Wire.major + 1 })).encoded()
        transports.client.send(hello, on: .control)
        #expect(await eventually { received.get().contains { $0.bye.reason == .versionMismatch } })
        #expect(host.state == .ended(.versionMismatch) || host.state == .idle)
        #expect(recorder.snapshot.log.isEmpty)
        #expect(clientSignal.peer?.sentMessages.contains(.bye(.versionMismatch)) == true)
    }

    @Test func pingsMeasureRoundTrip() async {
        let p = connect()
        #expect(await eventually(4) { !p.clientRecorder.snapshot.rtts.isEmpty })
        #expect(p.clientRecorder.snapshot.rtts.allSatisfy { $0 >= 0 && $0 < 1 })
    }
}
