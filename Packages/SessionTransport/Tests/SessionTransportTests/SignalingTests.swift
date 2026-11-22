import Foundation
import Network
import Testing
import WireProtocol
@testable import SessionTransport

@Suite struct SignalingTests {
    @Test func envelopeRoundTrip() throws {
        let message = SignalMessage.candidate("candidate:1 1 udp 2122260223 192.168.1.2 50000 typ host", mid: "0", lineIndex: 0)
        let envelope = SignalEnvelope(message: message, session: "s1", seq: 3, ts: 1_763_750_000)
        let decoded = try SignalEnvelope.decoded(envelope.encoded())
        #expect(decoded == envelope)
        #expect(decoded.message == message)
    }

    @Test func envelopeMatchesThePlanShape() throws {
        let data = try SignalEnvelope(message: .bye(.userEnded), session: "s", seq: 1, ts: 5).encoded()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["v", "type", "session", "seq", "ts", "body"])
        #expect(json["v"] as? Int == 1)
        #expect(json["type"] as? String == "bye")
    }

    @Test func rejectsOversized() {
        let data = Data(repeating: 0x20, count: SignalEnvelope.maxBytes + 1)
        #expect(throws: SignalEnvelope.DecodeError.tooLarge) { try SignalEnvelope.decoded(data) }
    }

    @Test func rejectsOtherVersions() throws {
        var envelope = SignalEnvelope(message: .offer("x"), session: "s", seq: 1, ts: 0)
        envelope.v = 2
        let data = try envelope.encoded()
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

    /// The real WebSocket path: an advertiser on this Mac and a connection to its port on loopback.
    /// Messages arrive in order, stamped with the client's session id.
    @Test(.timeLimit(.minutes(1)))
    func webSocketRoundTripOnLoopback() async throws {
        let (portStream, portContinuation) = AsyncStream.makeStream(of: UInt16.self)
        let (hostReceived, hostContinuation) = AsyncStream.makeStream(of: SignalMessage.self)
        let (clientReceived, clientContinuation) = AsyncStream.makeStream(of: SignalMessage.self)
        let accepted = Locked<SignalingConnection?>(nil)

        let advertiser = LANAdvertiser(
            id: "test-host", name: "Farside test \(UUID().uuidString.prefix(6))",
            onConnection: { connection in
                accepted.set(connection)
                connection.start(onState: { _ in }, onMessage: { message in
                    hostContinuation.yield(message)
                    if message.kind == .offer { connection.send(.answer("answer-sdp")) }
                })
            },
            onState: { state in if case .ready(let port) = state { portContinuation.yield(port) } })
        try advertiser.start()
        defer { advertiser.stop() }

        var ports = portStream.makeAsyncIterator()
        let port = try #require(await ports.next())
        let client = SignalingConnection.connect(host: "127.0.0.1", port: port)
        client.start(onState: { state in
            if state == .ready {
                client.send(.offer("offer-sdp"))
                client.send(.candidate("c1", mid: "0", lineIndex: 0))
            }
        }, onMessage: { clientContinuation.yield($0) })
        defer { client.close() }

        var hostIterator = hostReceived.makeAsyncIterator()
        #expect(await hostIterator.next() == .offer("offer-sdp"))
        #expect(await hostIterator.next() == .candidate("c1", mid: "0", lineIndex: 0))
        var clientIterator = clientReceived.makeAsyncIterator()
        #expect(await clientIterator.next() == .answer("answer-sdp"))
        accepted.get()?.close()
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
        await host.drain()
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
