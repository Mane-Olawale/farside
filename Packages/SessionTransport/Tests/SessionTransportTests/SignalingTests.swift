import Foundation
import Network
import Pairing
import SecureStore
import Testing
import WireProtocol
@testable import SessionTransport

func envelope(_ message: SignalMessage, session: String = "s", from: String = "a", to: String = "b", seq: UInt64 = 1, ts: Int64 = 5) -> SignalEnvelope {
    SignalEnvelope(message: message, session: session, from: from, to: to, seq: seq, ts: ts)
}

/// A Mac and an iPad that have paired with each other, and a stranger.
struct Devices {
    let mac = testIdentity("Mac")
    let iPad = testIdentity("iPad")
    let stranger = testIdentity("Stranger")

    var macCredentials: SessionCredentials {
        let iPad = iPad
        return SessionCredentials(identity: mac, trust: .pinned { $0 == iPad.id ? iPad.publicKey : nil })
    }

    func credentials(_ me: LocalIdentity) -> SessionCredentials {
        let mac = mac
        return SessionCredentials(identity: me, trust: .pinned { $0 == mac.id ? mac.publicKey : nil })
    }
}

@Suite struct SignalingTests {
    @Test func envelopeRoundTrip() throws {
        let message = SignalMessage.candidate("candidate:1 1 udp 2122260223 192.168.1.2 50000 typ host", mid: "0", lineIndex: 0)
        let e = envelope(message, seq: 3, ts: 1_763_750_000)
        let decoded = try SignalEnvelope.decoded(e.encoded())
        #expect(decoded == e)
        #expect(decoded.message == message)
    }

    @Test func envelopeMatchesThePlanShape() throws {
        var e = envelope(.bye(.userEnded))
        try e.sign(with: testIdentity("x"))
        let json = try #require(JSONSerialization.jsonObject(with: e.encoded()) as? [String: Any])
        #expect(Set(json.keys) == ["v", "type", "session", "from", "to", "seq", "ts", "body", "sig"])
        #expect(json["v"] as? Int == 1)
        #expect(json["type"] as? String == "bye")
    }

    @Test func rejectsOversized() {
        let data = Data(repeating: 0x20, count: SignalEnvelope.maxBytes + 1)
        #expect(throws: SignalEnvelope.DecodeError.tooLarge) { try SignalEnvelope.decoded(data) }
    }

    @Test func rejectsOtherVersions() throws {
        var e = envelope(.offer("x"))
        e.v = 2
        let data = try e.encoded()
        #expect(throws: SignalEnvelope.DecodeError.unsupportedVersion(2)) { try SignalEnvelope.decoded(data) }
    }

    @Test func rejectsMalformed() {
        #expect(throws: SignalEnvelope.DecodeError.malformed) { try SignalEnvelope.decoded(Data("{\"v\":1}".utf8)) }
    }

    @Test func endReasonsTravelInRejectAndBye() {
        #expect(SignalMessage.reject(.takenOver).endReason == .takenOver)
        #expect(SignalMessage.bye(.hostEnded).endReason == .hostEnded)
        #expect(SignalMessage.offer("x").endReason == nil)
    }
}

/// Plan section 14: signed signaling, and exit criterion 3 of Phase 3.
@Suite struct SignedSignalingTests {
    let d = Devices()
    let now: Int64 = 1_763_750_000
    let offerSDP = "v=0\r\na=group:BUNDLE 0\r\na=fingerprint:sha-256 AA:BB:CC:DD\r\na=setup:actpass\r\n"

    func signedOffer(_ sdp: String) throws -> SignalEnvelope {
        var e = envelope(.offer(sdp), session: "s1", from: d.iPad.id.rawValue, to: d.mac.id.rawValue, ts: now)
        try e.sign(with: d.iPad)
        return e
    }

    @Test func signedOfferPasses() throws {
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(try verifier.check(signedOffer(offerSDP), expected: nil, now: now) == d.iPad.id)
    }

    /// Exit criterion 3: someone on the path swaps the offer's certificate fingerprint for their
    /// own. The signature no longer matches, so the Mac drops it.
    @Test func tamperedFingerprintIsRejected() throws {
        var e = try signedOffer(offerSDP)
        e.body.sdp = offerSDP.replacingOccurrences(of: "AA:BB:CC:DD", with: "EE:FF:00:11")
        // Through the wire format, as the Mac would receive it.
        let received = try SignalEnvelope.decoded(e.encoded())
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(throws: EnvelopeVerifier.Failure.badSignature) { try verifier.check(received, expected: nil, now: now) }
    }

    @Test func everyOtherFieldIsCovered() throws {
        let good = try signedOffer(offerSDP)
        var changes: [SignalEnvelope] = []
        var a = good; a.session = "s2"; changes.append(a)
        var b = good; b.seq = 9; changes.append(b)
        var c = good; c.ts += 1; changes.append(c)
        var t = good; t.type = .answer; changes.append(t)
        for changed in changes {
            var verifier = EnvelopeVerifier(credentials: d.macCredentials)
            #expect(throws: EnvelopeVerifier.Failure.badSignature) { try verifier.check(changed, expected: nil, now: now) }
        }
    }

    @Test func strangerIsNotPaired() throws {
        var e = envelope(.init(kind: .join), from: d.stranger.id.rawValue, to: d.mac.id.rawValue, ts: now)
        try e.sign(with: d.stranger)
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(throws: EnvelopeVerifier.Failure.notPaired) { try verifier.check(e, expected: nil, now: now) }
    }

    @Test func strangerClaimingThePairedIdFails() throws {
        var e = envelope(.init(kind: .join), from: d.iPad.id.rawValue, to: d.mac.id.rawValue, ts: now)
        try e.sign(with: d.stranger)
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(throws: EnvelopeVerifier.Failure.badSignature) { try verifier.check(e, expected: nil, now: now) }
    }

    @Test func unsignedFails() throws {
        let e = envelope(.offer(offerSDP), from: d.iPad.id.rawValue, to: d.mac.id.rawValue, ts: now)
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(throws: EnvelopeVerifier.Failure.badSignature) { try verifier.check(e, expected: nil, now: now) }
    }

    @Test func otherRecipientAndOtherSenderFail() throws {
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        var toOther = envelope(.offer("x"), from: d.iPad.id.rawValue, to: d.stranger.id.rawValue, ts: now)
        try toOther.sign(with: d.iPad)
        #expect(throws: EnvelopeVerifier.Failure.wrongRecipient) { try verifier.check(toOther, expected: nil, now: now) }
        #expect(throws: EnvelopeVerifier.Failure.badSender) {
            try verifier.check(signedOffer(offerSDP), expected: d.stranger.id, now: now)
        }
    }

    @Test func replayAndStaleFail() throws {
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        let e = try signedOffer(offerSDP)
        _ = try verifier.check(e, expected: nil, now: now)
        #expect(throws: EnvelopeVerifier.Failure.unfresh(.replayed)) { try verifier.check(e, expected: nil, now: now) }
        var fresh = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(throws: EnvelopeVerifier.Failure.unfresh(.stale)) { try fresh.check(e, expected: nil, now: now + 61) }
    }

    @Test func pairingRequestMustBeSignedByItsOwnKey() throws {
        let invite = PairingInvite(host: d.mac, now: now)
        let request = PairingRequest(client: d.stranger, platform: "iPadOS", invite: invite)
        var good = envelope(.pair(request), from: d.stranger.id.rawValue, to: d.mac.id.rawValue, ts: now)
        try good.sign(with: d.stranger)
        var verifier = EnvelopeVerifier(credentials: d.macCredentials)
        #expect(try verifier.checkPairing(good, now: now) == request)
        var forged = envelope(.pair(request), from: d.stranger.id.rawValue, to: d.mac.id.rawValue, seq: 2, ts: now)
        try forged.sign(with: d.iPad)
        #expect(throws: EnvelopeVerifier.Failure.badSignature) { try verifier.checkPairing(forged, now: now) }
    }

    @Test func limiterBlocksAfterFiveFailures() {
        var limiter = FailureLimiter()
        for t in 0..<4 { limiter.failed("10.0.0.9", now: Int64(t)) }
        #expect(!limiter.isBlocked("10.0.0.9", now: 5))
        limiter.failed("10.0.0.9", now: 5)
        #expect(limiter.isBlocked("10.0.0.9", now: 6))
        #expect(!limiter.isBlocked("10.0.0.8", now: 6))
        #expect(!limiter.isBlocked("10.0.0.9", now: 606))
    }
}

/// The real WebSocket path: an advertiser on this Mac and connections to its port on loopback.
@Suite(.serialized) struct LoopbackSignalingTests {
    let d = Devices()

    func advertise(onConnection: @escaping @Sendable (SignalingConnection) -> Void,
                   onPairing: @escaping @Sendable (PairingRequest, SignalingConnection) -> Void = { _, c in c.close() }) async throws -> (LANAdvertiser, UInt16) {
        let (portStream, portContinuation) = AsyncStream.makeStream(of: UInt16.self)
        let advertiser = LANAdvertiser(
            credentials: d.macCredentials, name: "Farside test \(UUID().uuidString.prefix(6))",
            onConnection: onConnection, onPairing: onPairing,
            onState: { state in if case .ready(let port) = state { portContinuation.yield(port) } })
        try advertiser.start()
        var ports = portStream.makeAsyncIterator()
        return (advertiser, try #require(await ports.next()))
    }

    /// As in the product, the host speaks first: it sends the offer as soon as its side reports
    /// ready, which happens only once the client's signed join has been checked.
    @Test(.timeLimit(.minutes(1)))
    func pairedDeviceRoundTrip() async throws {
        let (hostReceived, hostContinuation) = AsyncStream.makeStream(of: SignalMessage.self)
        let (clientReceived, clientContinuation) = AsyncStream.makeStream(of: SignalMessage.self)
        let accepted = Locked<SignalingConnection?>(nil)
        let (advertiser, port) = try await advertise(onConnection: { connection in
            accepted.set(connection)
            connection.start(onState: { state in
                if state == .ready {
                    connection.send(.offer("offer-sdp"))
                    connection.send(.candidate("c1", mid: "0", lineIndex: 0))
                }
            }, onMessage: { hostContinuation.yield($0) })
        })
        defer { advertiser.stop() }

        let client = SignalingConnection.connect(host: "127.0.0.1", port: port, credentials: d.credentials(d.iPad), peer: d.mac.id)
        client.start(onState: { _ in }, onMessage: { message in
            clientContinuation.yield(message)
            if message.kind == .offer { client.send(.answer("answer-sdp")) }
        })
        defer { client.close() }

        var clientIterator = clientReceived.makeAsyncIterator()
        #expect(await clientIterator.next() == .offer("offer-sdp"))
        #expect(await clientIterator.next() == .candidate("c1", mid: "0", lineIndex: 0))
        var hostIterator = hostReceived.makeAsyncIterator()
        #expect(await hostIterator.next() == .answer("answer-sdp"))
        #expect(accepted.get()?.peer == d.iPad.id)
        accepted.get()?.close()
    }

    /// Exit criterion 4 on the LAN: a device the Mac has not paired with is told so and never
    /// reaches the owner, so no session is created for it.
    @Test(.timeLimit(.minutes(1)))
    func unpairedDeviceIsRefused() async throws {
        let reached = Locked(false)
        let (advertiser, port) = try await advertise(onConnection: { _ in reached.set(true) })
        defer { advertiser.stop() }
        let (received, continuation) = AsyncStream.makeStream(of: SignalMessage.self)
        let strangerCredentials = d.credentials(d.stranger)
        let client = SignalingConnection.connect(host: "127.0.0.1", port: port, credentials: strangerCredentials, peer: d.mac.id)
        client.start(onState: { _ in }, onMessage: { continuation.yield($0) })
        defer { client.close() }
        var iterator = received.makeAsyncIterator()
        #expect(await iterator.next() == .reject(.notPaired))
        #expect(!reached.get())
    }

    /// The QR flow over the LAN: the Mac's pairing hook sees a checked request, allows it, and
    /// the iPad hears back.
    @Test(.timeLimit(.minutes(1)))
    func pairingRoundTrip() async throws {
        let seen = Locked<PairingRequest?>(nil)
        var window = PairingWindow(invite: PairingInvite(host: d.mac, now: Int64(Date().timeIntervalSince1970)))
        let invite = window.invite
        let (advertiser, port) = try await advertise(onConnection: { _ in }, onPairing: { request, connection in
            seen.set(request)
            connection.replyToPairing(allowed: true)
        })
        defer { advertiser.stop() }
        let request = PairingRequest(client: d.stranger, platform: "iPadOS", invite: invite)
        let (results, continuation) = AsyncStream.makeStream(of: SignalingConnection.PairingResult.self)
        SignalingConnection.pair(to: SignalingConnection.endpoint(host: "127.0.0.1", port: port),
                                 credentials: d.credentials(d.stranger), invite: invite, request: request,
                                 completion: { continuation.yield($0) })
        var iterator = results.makeAsyncIterator()
        #expect(await iterator.next() == .paired)
        let received = try #require(seen.get())
        #expect(try window.accept(received, now: Int64(Date().timeIntervalSince1970)).key == d.stranger.publicKey)
    }

    /// A Mac that copies the real one's id but not its key cannot answer for it: the iPad only
    /// accepts a reply signed by the key in the QR code.
    @Test(.timeLimit(.minutes(1)))
    func impostorCannotAnswerAPairing() async throws {
        let invite = PairingInvite(host: d.mac, now: Int64(Date().timeIntervalSince1970))
        let impostor = LocalIdentity(id: d.mac.id, key: SoftwareSigningKey(), name: "Mac")
        let (portStream, portContinuation) = AsyncStream.makeStream(of: UInt16.self)
        let advertiser = LANAdvertiser(
            credentials: SessionCredentials(identity: impostor, trust: .pinned { _ in nil }), name: "Farside impostor \(UUID().uuidString.prefix(6))",
            onConnection: { _ in }, onPairing: { _, connection in connection.replyToPairing(allowed: true) },
            onState: { state in if case .ready(let port) = state { portContinuation.yield(port) } })
        try advertiser.start()
        defer { advertiser.stop() }
        var ports = portStream.makeAsyncIterator()
        let port = try #require(await ports.next())
        let (results, continuation) = AsyncStream.makeStream(of: SignalingConnection.PairingResult.self)
        SignalingConnection.pair(to: SignalingConnection.endpoint(host: "127.0.0.1", port: port),
                                 credentials: d.credentials(d.stranger), invite: invite,
                                 request: PairingRequest(client: d.stranger, platform: "iPadOS", invite: invite),
                                 completion: { continuation.yield($0) })
        var iterator = results.makeAsyncIterator()
        let result = await iterator.next()
        #expect(result != .paired)
    }
}

@Suite struct InMemoryTransportTests {
    @Test func connectsAndCarriesMessagesBothWays() async throws {
        let hostEvents = Locked<[TransportEvent]>([])
        let clientEvents = Locked<[TransportEvent]>([])
        let (host, client) = InMemoryTransport.pair(
            host: TransportHandlers(signal: { _ in }, event: { e in hostEvents.mutate { $0.append(e) } }),
            client: TransportHandlers(signal: { _ in }, event: { e in clientEvents.mutate { $0.append(e) } }))
        host.start()
        #expect(await eventually { clientEvents.get().contains(.state(.connected)) })
        host.send(Data([1]), on: .control)
        client.send(Data([2]), on: .input)
        await host.drain()
        #expect(clientEvents.get().contains(.state(.connected)))
        #expect(clientEvents.get().contains(.channelOpen(.cursor)))
        #expect(clientEvents.get().contains(.message(.control, Data([1]))))
        #expect(hostEvents.get().contains(.message(.input, Data([2]))))
    }

    @Test func closingOneEndFailsTheOther() async {
        let clientEvents = Locked<[TransportEvent]>([])
        // Both ends hold each other weakly, so the test keeps the client alive.
        let (host, client) = InMemoryTransport.pair(
            host: TransportHandlers(signal: { _ in }, event: { _ in }),
            client: TransportHandlers(signal: { _ in }, event: { e in clientEvents.mutate { $0.append(e) } }))
        host.start()
        host.close()
        host.close()
        await host.drain()
        #expect(clientEvents.get().last == .state(.failed))
        #expect(clientEvents.get().filter { $0 == .state(.failed) }.count == 1)
        withExtendedLifetime(client) {}
    }
}

/// A tiny lock box for test callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

@Suite struct ConnectByAddressTests {
    func url(_ host: DiscoveredHost?) -> String? {
        guard case .url(let url) = host?.endpoint else { return nil }
        return url.absoluteString
    }

    @Test func hostAloneUsesTheDefaultPort() {
        #expect(url(.address("mac.tailnet.ts.net")) == "ws://mac.tailnet.ts.net:\(LAN.defaultPort)/")
        #expect(url(.address(" 100.64.0.7 ")) == "ws://100.64.0.7:\(LAN.defaultPort)/")
    }

    @Test func explicitPort() {
        #expect(url(.address("192.168.1.20:5000")) == "ws://192.168.1.20:5000/")
    }

    @Test func ipv6() {
        #expect(url(.address("fd7a:115c:a1e0::1")) == "ws://[fd7a:115c:a1e0::1]:\(LAN.defaultPort)/")
        #expect(url(.address("[fd7a:115c:a1e0::1]:6000")) == "ws://[fd7a:115c:a1e0::1]:6000/")
        #expect(url(.address("fe80::1%en0")) == "ws://[fe80::1%25en0]:\(LAN.defaultPort)/")
    }

    @Test(arguments: ["", "  ", "host:0", "host:99999", "host:abc", "http://host", "two words", "[::1"])
    func rejectsNonAddresses(_ text: String) {
        #expect(DiscoveredHost.address(text) == nil)
    }
}
