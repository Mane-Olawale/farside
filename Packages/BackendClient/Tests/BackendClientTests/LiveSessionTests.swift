import Foundation
import Pairing
import SecureStore
import SessionTransport
import Testing
import WireProtocol
@testable import BackendClient

/// A whole internet session's signaling through the running backend: the iPad creates the
/// session, the Mac hears the ring and accepts, offer and answer cross through the backend, and
/// both sides pass the identity handshake to streaming. The media path is in memory; everything
/// else is real. make backend-live-test runs it.
@Suite(.enabled(if: LiveBackend.current != nil), .serialized)
struct LiveSessionTests {
    final class Host: HostSessionDelegate, @unchecked Sendable {
        func hostSessionDisplays() -> [Farside_V1_Display] { [.with { $0.id = 1 }] }
        func hostSessionApply(_ request: Farside_V1_StreamConfig, client: DeviceInfo) -> Farside_V1_StreamConfigApplied? {
            .with { $0.displayID = 1; $0.width = 1920; $0.height = 1080; $0.frameRate = 60 }
        }
        func hostSessionStartMedia(_ applied: Farside_V1_StreamConfigApplied) {}
        func hostSessionStopMedia() {}
        func hostSessionStateChanged(_ state: SessionState, client: DeviceInfo?) {}
    }

    final class Client: ClientSessionDelegate, @unchecked Sendable {
        func clientSessionChooseStream(displays: [Farside_V1_Display], host: DeviceInfo) -> Farside_V1_StreamConfig {
            .with { $0.displayID = displays.first?.id ?? 1 }
        }
        func clientSessionApplied(_ applied: Farside_V1_StreamConfigApplied) {}
        func clientSessionDisplaysChanged(_ displays: [Farside_V1_Display]) {}
        func clientSessionStateChanged(_ state: SessionState, host: DeviceInfo?) {}
        func clientSessionRoundTrip(_ seconds: Double) {}
    }

    /// Registers a Mac and an iPad with these identities on a throwaway account.
    static func mint(mac: LocalIdentity, iPad: LocalIdentity) throws -> LiveBackend {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let compose = ProcessInfo.processInfo.environment["FARSIDE_COMPOSE"] ?? "Server/deploy/compose.yml"
        process.arguments = ["docker", "compose", "-f", compose, "exec", "-T", "api", "php", "artisan", "farside:test-devices",
                             "--mac-id=\(mac.id.rawValue)", "--mac-key=\(mac.publicKey.x963.base64EncodedString())",
                             "--ipad-id=\(iPad.id.rawValue)", "--ipad-key=\(iPad.publicKey.x963.base64EncodedString())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return try JSONDecoder().decode(LiveBackend.self, from: pipe.fileHandleForReading.readDataToEndOfFile())
    }

    @Test(.timeLimit(.minutes(1)))
    func internetSessionReachesStreaming() async throws {
        let mac = try LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: "Mac", allowEnclave: false)
        let iPad = try LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: "iPad", allowEnclave: false)
        let live = try Self.mint(mac: mac, iPad: iPad)
        let macAPI = BackendAPI(config: LiveBackend.config, token: { live.mac.token })
        let iPadAPI = BackendAPI(config: LiveBackend.config, token: { live.ipad.token })
        let macRouter = SignalRouter(), iPadRouter = SignalRouter()
        let macStates = Inbox<BackendSocket.State>(), iPadStates = Inbox<BackendSocket.State>()
        let macSocket = BackendSocket(api: macAPI, deviceID: mac.id.rawValue, accountID: live.account,
                                      handlers: .init(onState: { macStates.add($0) }, onSignal: { macRouter.receive($0) }))
        let iPadSocket = BackendSocket(api: iPadAPI, deviceID: iPad.id.rawValue, accountID: live.account,
                                       handlers: .init(onState: { iPadStates.add($0) }, onSignal: { iPadRouter.receive($0) }))
        await macSocket.start()
        await iPadSocket.start()
        #expect(await until { macStates.all.contains(.connected) && iPadStates.all.contains(.connected) })
        try await Task.sleep(for: .milliseconds(300))  // subscriptions

        let macCredentials = SessionCredentials(identity: mac, trust: .pinned { $0 == iPad.id ? iPad.publicKey : nil })
        let iPadCredentials = SessionCredentials(identity: iPad, trust: .pinned { $0 == mac.id ? mac.publicKey : nil })
        let rings = Inbox<SignalEnvelope>()
        macRouter.setRingHandler { rings.add($0) }

        let created = try await iPadAPI.createSession(to: mac.id.rawValue)
        #expect(await until { !rings.all.isEmpty })
        let ring = try #require(rings.all.first)
        #expect(ring.session == created.session)

        // Sessions hold their delegates weakly.
        let hostDelegate = Host(), clientDelegate = Client()
        // The Mac accepts at once, as the app does, before the iPad's side is listening.
        let hostSignaling = BackendSignaling(api: macAPI, credentials: macCredentials, session: ring.session,
                                             peer: iPad.id, role: .host, router: macRouter, log: { print("HOST SIGNAL: \($0)") })
        hostSignaling.send(.init(kind: .accept))
        try await Task.sleep(for: .milliseconds(300))
        let host = HostSession(signaling: hostSignaling, local: DeviceInfo(name: "Mac", model: "t", osVersion: "26", appVersion: "1",
                                                                           capabilities: .init()), delegate: hostDelegate,
                               log: { print("HOST: \($0)") })
        let clientSignaling = BackendSignaling(api: iPadAPI, credentials: iPadCredentials, session: created.session,
                                               peer: mac.id, role: .client, router: iPadRouter, log: { print("CLIENT SIGNAL: \($0)") })
        let client = ClientSession(signaling: clientSignaling, local: DeviceInfo(name: "iPad", model: "t", osVersion: "26", appVersion: "1",
                                                                                 capabilities: .init()), delegate: clientDelegate,
                                   log: { print("CLIENT: \($0)") })
        let transports = InMemoryTransport.pair(host: host.transportHandlers(), client: client.transportHandlers())
        // The descriptions cross the backend before a real path could come up.
        transports.host.connectDelay = .seconds(1)
        client.start(transport: transports.client)
        host.start(transport: transports.host)

        #expect(await until(15) { host.state == .streaming && client.state == .streaming },
                "host \(host.state), client \(client.state)")
        client.end(.userEnded)
        withExtendedLifetime((hostDelegate, clientDelegate, transports)) {}
        await macSocket.stop()
        await iPadSocket.stop()
    }
}
