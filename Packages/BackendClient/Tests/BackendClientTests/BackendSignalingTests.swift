import Foundation
import Pairing
import SecureStore
import SessionTransport
import Testing
@testable import BackendClient

/// The routing and checking half of internet signaling. Sending goes through `BackendAPI`, which
/// has its own tests.
@Suite struct BackendSignalingTests {
    let mac = try! LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: "Mac", allowEnclave: false)
    let iPad = try! LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: "iPad", allowEnclave: false)
    let api = BackendAPI(config: BackendConfig(api: URL(string: "http://127.0.0.1:9")!, socket: URL(string: "ws://127.0.0.1:9")!), token: { nil })

    func clientSignaling(router: SignalRouter, session: String = "S1") -> BackendSignaling {
        let mac = self.mac
        let credentials = SessionCredentials(identity: iPad, trust: .pinned { $0 == mac.id ? mac.publicKey : nil })
        return BackendSignaling(api: api, credentials: credentials, session: session, peer: mac.id, role: .client, router: router)
    }

    func fromMac(_ message: SignalMessage, session: String = "S1", seq: UInt64 = 1, signer: LocalIdentity? = nil) throws -> Data {
        var envelope = SignalEnvelope(message: message, session: session, from: mac.id.rawValue, to: iPad.id.rawValue,
                                      seq: seq, ts: Int64(Date().timeIntervalSince1970))
        try envelope.sign(with: signer ?? mac)
        return try envelope.encoded()
    }

    @Test func clientIsReadyOnlyAfterTheMacsSignedAccept() async throws {
        let router = SignalRouter()
        let signaling = clientSignaling(router: router)
        let states = Inbox<SignalingConnection.State>(), messages = Inbox<SignalMessage>()
        signaling.start(onState: { states.add($0) }, onMessage: { messages.add($0) })
        #expect(states.all == [.connecting])
        router.receive(try fromMac(.init(kind: .accept), signer: try LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: "x", allowEnclave: false)))
        #expect(states.all == [.connecting], "an accept signed by another key is dropped")
        router.receive(try fromMac(.init(kind: .accept), seq: 2))
        #expect(states.all == [.connecting, .ready])
        router.receive(try fromMac(.offer("v=0"), seq: 3))
        #expect(messages.all == [.offer("v=0")])
        #expect(states.all == [.connecting, .ready], "the accept is not passed on")
    }

    @Test func otherSessionsAndReplaysAreNotDelivered() throws {
        let router = SignalRouter()
        let signaling = clientSignaling(router: router)
        let messages = Inbox<SignalMessage>()
        signaling.start(onState: { _ in }, onMessage: { messages.add($0) })
        router.receive(try fromMac(.offer("other"), session: "S2"))
        let offer = try fromMac(.offer("v=0"), seq: 5)
        router.receive(offer)
        router.receive(offer)
        #expect(messages.all == [.offer("v=0")])
    }

    /// The Mac's accept and offer can arrive before the iPad's side starts listening.
    @Test func envelopesThatArriveEarlyAreHeldForTheSession() throws {
        let router = SignalRouter()
        router.receive(try fromMac(.init(kind: .accept), seq: 1))
        router.receive(try fromMac(.offer("v=0"), seq: 2))
        router.receive(try fromMac(.offer("elsewhere"), session: "S2", seq: 1))
        let signaling = clientSignaling(router: router)
        let states = Inbox<SignalingConnection.State>(), messages = Inbox<SignalMessage>()
        signaling.start(onState: { states.add($0) }, onMessage: { messages.add($0) })
        #expect(states.all == [.connecting, .ready])
        #expect(messages.all == [.offer("v=0")])
    }

    @Test func ringsGoToTheRingHandler() throws {
        let router = SignalRouter()
        let rings = Inbox<SignalEnvelope>()
        router.setRingHandler { rings.add($0) }
        let ring = #"{"v":1,"type":"ring","session":"S9","from":"FROM","to":"TO","seq":0,"ts":1,"body":{}}"#
            .replacingOccurrences(of: "FROM", with: iPad.id.rawValue).replacingOccurrences(of: "TO", with: mac.id.rawValue)
        router.receive(Data(ring.utf8))
        #expect(rings.all.map(\.session) == ["S9"])
        #expect(rings.all.first?.from == iPad.id.rawValue)
    }

    @Test func closedSignalingHearsNothing() throws {
        let router = SignalRouter()
        let signaling = clientSignaling(router: router)
        let messages = Inbox<SignalMessage>(), states = Inbox<SignalingConnection.State>()
        signaling.start(onState: { states.add($0) }, onMessage: { messages.add($0) })
        signaling.close()
        router.receive(try fromMac(.offer("late")))
        #expect(messages.all.isEmpty)
        #expect(states.all.last == .closed(nil))
    }

    @Test func accountRoundTrips() throws {
        let store = AccountStore(store: MemorySecretStore())
        #expect(store.load() == nil)
        let account = SignedInAccount(token: "1|t", accountID: "A", deviceID: "dev_X")
        try store.save(account)
        #expect(store.load() == account)
        try store.clear()
        #expect(store.load() == nil)
    }
}
