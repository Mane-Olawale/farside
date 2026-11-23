import Foundation

/// The REST half of the backend (plan section 13, API). One instance per device; the token is
/// set after sign-in and kept in the keychain by the app.
public final class BackendAPI: Sendable {
    public let config: BackendConfig
    private let token: @Sendable () -> String?
    private let session: URLSession

    public init(config: BackendConfig, session: URLSession = .shared, token: @escaping @Sendable () -> String?) {
        self.config = config
        self.session = session
        self.token = token
    }

    public func signInWithApple(identityToken: String, device: DeviceRegistration) async throws(BackendError) -> SignInResult {
        struct Body: Encodable {
            let identity_token: String
            let device: DeviceRegistration
        }
        return try await request("POST", "v1/auth/apple", body: Body(identity_token: identityToken, device: device), authorized: false)
    }

    public func devices() async throws(BackendError) -> [AccountDevice] {
        struct List: Decodable { let devices: [AccountDevice] }
        let list: List = try await request("GET", "v1/devices")
        return list.devices
    }

    public func rename(_ id: String, to name: String) async throws(BackendError) {
        struct Body: Encodable { let name: String }
        let _: Empty = try await request("PATCH", "v1/devices/\(id)", body: Body(name: name))
    }

    public func revoke(_ id: String) async throws(BackendError) {
        let _: Empty = try await request("DELETE", "v1/devices/\(id)")
    }

    /// `takeOver` asks the Mac to end its current session for this one.
    public func createSession(to target: String, takeOver: Bool = false) async throws(BackendError) -> CreatedSession {
        struct Body: Encodable {
            let target: String
            let take_over: Bool?
        }
        return try await request("POST", "v1/sessions", body: Body(target: target, take_over: takeOver ? true : nil))
    }

    public func iceServers() async throws(BackendError) -> IceServerList {
        try await request("GET", "v1/ice-servers")
    }

    /// One signed envelope, sent as its exact bytes: the receiver checks the signature over them.
    public func signal(_ envelope: Data) async throws(BackendError) {
        let _: Empty = try await send("POST", "v1/signal", body: envelope, authorized: true)
    }

    public func report(_ report: SessionReport, session: String) async throws(BackendError) {
        let _: Empty = try await request("POST", "v1/sessions/\(session)/events", body: report)
    }

    public func deleteAccount() async throws(BackendError) {
        let _: Empty = try await request("DELETE", "v1/account")
    }

    /// Authorizes a channel subscription on the socket (`POST /broadcasting/auth`).
    func authorize(socketID: String, channel: String) async throws(BackendError) -> ChannelAuth {
        struct Body: Encodable {
            let socket_id: String
            let channel_name: String
        }
        return try await request("POST", "broadcasting/auth", body: Body(socket_id: socketID, channel_name: channel))
    }

    // MARK: Plumbing

    struct Empty: Decodable {}

    private func request<T: Decodable>(_ method: String, _ path: String, authorized: Bool = true) async throws(BackendError) -> T {
        try await send(method, path, body: nil, authorized: authorized)
    }

    private func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B, authorized: Bool = true) async throws(BackendError) -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(body) else { throw .malformed }
        return try await send(method, path, body: data, authorized: authorized)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data?, authorized: Bool) async throws(BackendError) -> T {
        var request = URLRequest(url: config.api.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let token = token() else { throw .unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .malformed }
        switch http.statusCode {
        case 200..<300:
            if T.self == Empty.self { return Empty() as! T }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw .malformed }
            return value
        case 401: throw .unauthorized
        case 404: throw .notFound
        case 429: throw .rateLimited
        case 502, 503, 504: throw .unavailable
        default:
            let message = (try? JSONDecoder().decode([String: AnyDecodable].self, from: data))?["message"]?.string
            throw .rejected(status: http.statusCode, message: message)
        }
    }
}

/// Just enough to read a `message` string out of an error body.
struct AnyDecodable: Decodable {
    let string: String?
    init(from decoder: any Decoder) throws {
        string = try? decoder.singleValueContainer().decode(String.self)
    }
}
