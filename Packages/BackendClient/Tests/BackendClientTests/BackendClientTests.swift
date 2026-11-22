import Foundation
import Pairing
import SecureStore
import Testing
@testable import BackendClient

/// Answers requests from a table, and records what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.bodies.append(data)
        } else {
            Self.bodies.append(request.httpBody ?? Data())
        }
        let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        let (status, body) = Self.responses[key] ?? (404, #"{"message":"No route"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct BackendAPITests {
    let config = BackendConfig(api: URL(string: "https://api.example.com")!, reverbHost: URL(string: "wss://ws.example.com")!, appKey: "key1")

    func api(token: String? = "1|secret") -> BackendAPI {
        StubProtocol.requests = []
        StubProtocol.bodies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return BackendAPI(config: config, session: URLSession(configuration: configuration), token: { token })
    }

    let device = #"{"id":"dev_AAAAAAAAAAAAAAAAAAAAAAAAAA","name":"iPad","platform":"iPadOS","model":null,"os_version":"26","app_version":"1","public_key":"BA==","key_fingerprint":"ab","last_seen_at":null}"#

    @Test func socketURLCarriesTheAppKeyAndProtocol() {
        #expect(config.socket.absoluteString == "wss://ws.example.com/app/key1?protocol=7&client=farside&version=1")
    }

    @Test func signInSendsTheTokenAndDeviceWithoutAuthorization() async throws {
        StubProtocol.responses = ["POST /v1/auth/apple": (201, #"{"token":"7|abc","account":{"id":"01ACC"},"device":\#(device)}"#)]
        let api = api(token: nil)
        let identity = try LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: "iPad", allowEnclave: false)
        let result = try await api.signInWithApple(identityToken: "jwt", device: DeviceRegistration(
            identity: identity, platform: "iPadOS", model: "iPad16,5", osVersion: "27.2", appVersion: "0.3"))
        #expect(result.token == "7|abc")
        #expect(result.accountID == "01ACC")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any])
        #expect(body["identity_token"] as? String == "jwt")
        let sent = try #require(body["device"] as? [String: Any])
        #expect(sent["id"] as? String == identity.id.rawValue)
        #expect(sent["public_key"] as? String == identity.publicKey.x963.base64EncodedString())
        #expect(sent["os_version"] as? String == "27.2")
    }

    @Test func authorizedCallsCarryTheBearerToken() async throws {
        StubProtocol.responses = ["GET /v1/devices": (200, #"{"devices":[\#(device)]}"#)]
        let api = api()
        let devices = try await api.devices()
        #expect(devices.map(\.platform) == ["iPadOS"])
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer 1|secret")
    }

    @Test func noTokenFailsWithoutCalling() async {
        let api = api(token: nil)
        await #expect(throws: BackendError.unauthorized) { try await api.devices() }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func signalSendsTheExactBytes() async throws {
        StubProtocol.responses = ["POST /v1/signal": (202, "")]
        let api = api()
        let envelope = Data(#"{"body":{"sdp":"v=0\r\n"},"from":"dev_A","sig":"x/y+z=","v":1}"#.utf8)
        try await api.signal(envelope)
        #expect(StubProtocol.bodies.first == envelope)
    }

    @Test func statusesMapToErrors() async {
        let api = api()
        for (status, error) in [(401, BackendError.unauthorized), (404, .notFound), (429, .rateLimited), (503, .unavailable)] {
            StubProtocol.responses = ["GET /v1/ice-servers": (status, #"{"message":"m"}"#)]
            await #expect(throws: error) { try await api.iceServers() }
        }
        StubProtocol.responses = ["GET /v1/ice-servers": (409, #"{"message":"Already registered."}"#)]
        await #expect(throws: BackendError.rejected(status: 409, message: "Already registered.")) { try await api.iceServers() }
    }

    @Test func createdSessionDecodesIceServers() async throws {
        StubProtocol.responses = ["POST /v1/sessions": (201, #"{"session":"01S","ice_servers":[{"urls":["stun:s:3478"]},{"urls":["turn:t:3478"],"username":"u","credential":"c"}],"ttl":43200}"#)]
        let created = try await api().createSession(to: "dev_B")
        #expect(created.session == "01S")
        #expect(created.iceServers == [IceServer(urls: ["stun:s:3478"]), IceServer(urls: ["turn:t:3478"], username: "u", credential: "c")])
    }
}

struct PusherTests {
    @Test func decodesEventsWithStringData() throws {
        let text = #"{"event":"signal","channel":"private-device.dev_A","data":"{\"envelope\":\"{\\\"v\\\":1}\"}"}"#
        let message = try #require(Pusher.decode(text))
        #expect(message.event == "signal")
        #expect(Pusher.field("envelope", in: message) == #"{"v":1}"#)
    }

    @Test func connectionEstablished() throws {
        let message = try #require(Pusher.decode(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"123.456\",\"activity_timeout\":30}"}"#))
        let established = try #require(Pusher.established(message))
        #expect(established.socketID == "123.456")
        #expect(established.activityTimeout == 30)
    }

    @Test func subscribeCarriesAuthAndChannelData() throws {
        let text = Pusher.subscribe(channel: "presence-account.A", auth: ChannelAuth(auth: "key:sig", channelData: #"{"user_id":"dev_A"}"#))
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["event"] as? String == "pusher:subscribe")
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["channel"] as? String == "presence-account.A")
        #expect(data["auth"] as? String == "key:sig")
        #expect(data["channel_data"] as? String == #"{"user_id":"dev_A"}"#)
    }

    @Test func garbageIsIgnored() {
        #expect(Pusher.decode("not json") == nil)
        #expect(Pusher.decode(#"{"data":"x"}"#) == nil)
    }

    @Test func presenceFollowsMembers() {
        var tracker = PresenceTracker()
        let joined = Pusher.Message(event: "pusher_internal:subscription_succeeded", channel: "presence-account.A",
                                    data: #"{"presence":{"ids":["dev_M"],"hash":{"dev_M":{"id":"dev_M","name":"Mac","platform":"macOS"}},"count":1}}"#)
        let joinedChanged = tracker.apply(joined)
        #expect(joinedChanged)
        #expect(tracker.members["dev_M"]?.platform == "macOS")
        let added = Pusher.Message(event: "pusher_internal:member_added", channel: nil,
                                   data: #"{"user_id":"dev_I","user_info":{"name":"iPad","platform":"iPadOS"}}"#)
        let addedChanged = tracker.apply(added)
        #expect(addedChanged)
        #expect(Set(tracker.members.keys) == ["dev_M", "dev_I"])
        let removed = Pusher.Message(event: "pusher_internal:member_removed", channel: nil, data: #"{"user_id":"dev_M"}"#)
        let removedChanged = tracker.apply(removed)
        #expect(removedChanged)
        #expect(Set(tracker.members.keys) == ["dev_I"])
        let removedAgain = tracker.apply(removed)
        #expect(!removedAgain)
    }

    @Test func backoffDoublesUpToThirtySeconds() {
        var backoff = Backoff()
        let delays = (0..<7).map { _ in backoff.next(jitter: 1) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        backoff.reset()
        #expect(backoff.next(jitter: 1) == .seconds(1))
    }
}
