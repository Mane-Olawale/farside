import Foundation
import Pairing

/// Where the backend is. The socket URL carries the Reverb app key, which is public.
public struct BackendConfig: Sendable, Equatable {
    public var api: URL
    public var socket: URL

    public init(api: URL, socket: URL) {
        self.api = api
        self.socket = socket
    }

    /// `ws(s)://host:port/app/{key}` with the Pusher protocol version Reverb speaks.
    public init(api: URL, reverbHost: URL, appKey: String) {
        self.api = api
        var components = URLComponents(url: reverbHost.appending(path: "app/\(appKey)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "protocol", value: "7"), .init(name: "client", value: "farside"),
                                 .init(name: "version", value: "1")]
        socket = components.url!
    }
}

/// What a device tells the backend about itself at sign-in (plan section 13, devices table).
public struct DeviceRegistration: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var platform: String
    public var model: String?
    public var osVersion: String?
    public var appVersion: String?
    public var publicKey: String

    public init(identity: LocalIdentity, platform: String, model: String?, osVersion: String?, appVersion: String?) {
        id = identity.id.rawValue
        name = identity.name
        self.platform = platform
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        publicKey = identity.publicKey.x963.base64EncodedString()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, model
        case osVersion = "os_version"
        case appVersion = "app_version"
        case publicKey = "public_key"
    }
}

/// A device on the account, as `GET /v1/devices` lists it.
public struct AccountDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var model: String?
    public var osVersion: String?
    public var appVersion: String?
    public var publicKey: String
    public var keyFingerprint: String
    public var lastSeenAt: String?

    public var isHost: Bool { platform == "macOS" }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, model
        case osVersion = "os_version"
        case appVersion = "app_version"
        case publicKey = "public_key"
        case keyFingerprint = "key_fingerprint"
        case lastSeenAt = "last_seen_at"
    }
}

public struct SignInResult: Codable, Sendable, Equatable {
    public var token: String
    public var accountID: String
    public var device: AccountDevice

    enum CodingKeys: String, CodingKey { case token, account, device }
    enum AccountKeys: String, CodingKey { case id }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        accountID = try c.nestedContainer(keyedBy: AccountKeys.self, forKey: .account).decode(String.self, forKey: .id)
        device = try c.decode(AccountDevice.self, forKey: .device)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        var account = c.nestedContainer(keyedBy: AccountKeys.self, forKey: .account)
        try account.encode(accountID, forKey: .id)
        try c.encode(device, forKey: .device)
    }
}

/// One STUN or TURN server, in the shape WebRTC takes.
public struct IceServer: Codable, Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct IceServerList: Codable, Sendable, Equatable {
    public var iceServers: [IceServer]
    /// Seconds the credentials last.
    public var ttl: Int

    enum CodingKeys: String, CodingKey {
        case iceServers = "ice_servers"
        case ttl
    }
}

public struct CreatedSession: Codable, Sendable, Equatable {
    public var session: String
    public var iceServers: [IceServer]
    public var ttl: Int

    enum CodingKeys: String, CodingKey {
        case session, ttl
        case iceServers = "ice_servers"
    }
}

/// `POST /v1/sessions/{id}/events`: metadata only.
public struct SessionReport: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case connected, ended }
    public var type: Kind
    public var pathType: String?
    public var endReason: String?
    public var avgBitrate: Int?
    public var avgRtt: Int?

    public init(type: Kind, pathType: String? = nil, endReason: String? = nil, avgBitrate: Int? = nil, avgRtt: Int? = nil) {
        self.type = type
        self.pathType = pathType
        self.endReason = endReason
        self.avgBitrate = avgBitrate
        self.avgRtt = avgRtt
    }

    enum CodingKeys: String, CodingKey {
        case type
        case pathType = "path_type"
        case endReason = "end_reason"
        case avgBitrate = "avg_bitrate"
        case avgRtt = "avg_rtt"
    }
}

public enum BackendError: Error, Equatable, Sendable {
    /// No token, or the token was refused: sign in again.
    case unauthorized
    /// The backend or the relay is down (plan section 13: a clear service unavailable message).
    case unavailable
    case rateLimited
    case notFound
    case rejected(status: Int, message: String?)
    case network(String)
    case malformed
}
