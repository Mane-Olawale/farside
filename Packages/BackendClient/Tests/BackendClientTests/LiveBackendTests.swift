import Foundation
import Testing
@testable import BackendClient

/// Against the real backend from `make server-up`: make backend-live-test mints two devices and
/// runs these. Skipped otherwise.
struct LiveBackend: Decodable {
    struct Device: Decodable {
        let id: String
        let token: String
    }

    let account: String
    let mac: Device
    let ipad: Device

    static let current: LiveBackend? = ProcessInfo.processInfo.environment["FARSIDE_LIVE_BACKEND"]
        .flatMap { try? JSONDecoder().decode(LiveBackend.self, from: Data($0.utf8)) }

    static let config = BackendConfig(
        api: URL(string: ProcessInfo.processInfo.environment["FARSIDE_API"] ?? "http://localhost:47880")!,
        reverbHost: URL(string: ProcessInfo.processInfo.environment["FARSIDE_REVERB"] ?? "ws://localhost:47881")!,
        appKey: ProcessInfo.processInfo.environment["FARSIDE_REVERB_KEY"] ?? "")
}

final class Inbox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@Suite(.enabled(if: LiveBackend.current != nil), .serialized)
struct LiveBackendTests {
    let live = LiveBackend.current!

    /// The Mac's standing socket hears the ring and the iPad's envelope byte for byte, and the
    /// presence channel shows it online.
    @Test(.timeLimit(.minutes(1)))
    func ringAndSignalReachTheMac() async throws {
        let live = self.live
        let mac = BackendAPI(config: LiveBackend.config, token: { live.mac.token })
        let ipad = BackendAPI(config: LiveBackend.config, token: { live.ipad.token })
        let states = Inbox<BackendSocket.State>(), signals = Inbox<Data>(), presence = Inbox<[String: PresenceMember]>()
        let socket = BackendSocket(api: mac, deviceID: live.mac.id, accountID: live.account, handlers: .init(
            onState: { states.add($0) }, onSignal: { signals.add($0) }, onPresence: { presence.add($0) }))
        await socket.start()
        #expect(await until { presence.all.last?[live.mac.id]?.platform == "macOS" })

        let created = try await ipad.createSession(to: live.mac.id)
        #expect(!created.iceServers.isEmpty)
        #expect(await until { signals.all.count == 1 })
        let ring = try #require(try JSONSerialization.jsonObject(with: signals.all[0]) as? [String: Any])
        #expect(ring["type"] as? String == "ring")
        #expect(ring["session"] as? String == created.session)

        let ts = Int(Date().timeIntervalSince1970)
        let text = #"{"body":{"sdp":"v=0\r\na=fingerprint:sha-256 AA"},"from":"@from@","seq":1,"session":"@session@","sig":"c2ln","to":"@to@","ts":@ts@,"type":"offer","v":1}"#
            .replacingOccurrences(of: "@from@", with: live.ipad.id).replacingOccurrences(of: "@to@", with: live.mac.id)
            .replacingOccurrences(of: "@session@", with: created.session).replacingOccurrences(of: "@ts@", with: String(ts))
        let envelope = Data(text.utf8)
        try await ipad.signal(envelope)
        #expect(await until { signals.all.count == 2 })
        #expect(signals.all.last == envelope)

        try await mac.report(SessionReport(type: .connected, pathType: "host"), session: created.session)
        await socket.stop()
        #expect(states.all.contains(.connected))
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedTokenStopsTheSocket() async {
        let api = BackendAPI(config: LiveBackend.config, token: { "1|not-a-token" })
        let states = Inbox<BackendSocket.State>()
        let socket = BackendSocket(api: api, deviceID: live.mac.id, accountID: live.account, handlers: .init(onState: { states.add($0) }))
        await socket.start()
        #expect(await until { states.all.contains(.unauthorized) })
    }
}
