import Foundation

/// The small part of the Pusher protocol that Reverb speaks (plan section 13, Swift side):
/// connect, authorize, subscribe, ping, receive.
enum Pusher {
    struct Message: Equatable, Sendable {
        var event: String
        var channel: String?
        /// Pusher sends event data as a JSON string inside the JSON message.
        var data: String?
    }

    static func decode(_ text: String) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        let data: String?
        switch object["data"] {
        case let string as String: data = string
        case let other? where JSONSerialization.isValidJSONObject(other):
            data = (try? JSONSerialization.data(withJSONObject: other)).map { String(decoding: $0, as: UTF8.self) }
        default: data = nil
        }
        return Message(event: event, channel: object["channel"] as? String, data: data)
    }

    static func encode(event: String, data: [String: Any]) -> String {
        let object: [String: Any] = ["event": event, "data": data]
        let bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    static func subscribe(channel: String, auth: ChannelAuth) -> String {
        var data: [String: Any] = ["channel": channel, "auth": auth.auth]
        if let channelData = auth.channelData { data["channel_data"] = channelData }
        return encode(event: "pusher:subscribe", data: data)
    }

    static let ping = encode(event: "pusher:ping", data: [:])
    static let pong = encode(event: "pusher:pong", data: [:])

    /// `pusher:connection_established`: the socket id that channel authorization signs.
    static func established(_ message: Message) -> (socketID: String, activityTimeout: Int)? {
        guard message.event == "pusher:connection_established", let data = message.data,
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let id = object["socket_id"] as? String else { return nil }
        return (id, object["activity_timeout"] as? Int ?? 30)
    }

    /// A field of a custom event's data, such as `envelope` in `signal`.
    static func field(_ name: String, in message: Message) -> String? {
        guard let data = message.data,
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return nil }
        return object[name] as? String
    }
}

struct ChannelAuth: Decodable, Equatable, Sendable {
    var auth: String
    var channelData: String?

    enum CodingKeys: String, CodingKey {
        case auth
        case channelData = "channel_data"
    }
}

/// A device on the account's presence channel.
public struct PresenceMember: Equatable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
}

/// The account presence channel's member list (plan section 13, presence): which devices are
/// online, from subscription and member added and removed events.
struct PresenceTracker: Sendable {
    private(set) var members: [String: PresenceMember] = [:]

    /// Applies one presence event. Returns whether the list changed.
    mutating func apply(_ message: Pusher.Message) -> Bool {
        guard let data = message.data,
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return false }
        switch message.event {
        case "pusher_internal:subscription_succeeded":
            let hash = (object["presence"] as? [String: Any])?["hash"] as? [String: Any] ?? [:]
            members = hash.reduce(into: [:]) { out, entry in
                if let member = Self.member(id: entry.key, info: entry.value) { out[entry.key] = member }
            }
            return true
        case "pusher_internal:member_added":
            guard let id = Self.userID(object), let member = Self.member(id: id, info: object["user_info"]) else { return false }
            members[id] = member
            return true
        case "pusher_internal:member_removed":
            guard let id = Self.userID(object) else { return false }
            return members.removeValue(forKey: id) != nil
        default:
            return false
        }
    }

    private static func userID(_ object: [String: Any]) -> String? {
        (object["user_id"] as? String) ?? (object["user_id"] as? Int).map(String.init)
    }

    private static func member(id: String, info: Any?) -> PresenceMember? {
        guard let info = info as? [String: Any] else { return nil }
        return PresenceMember(id: id, name: info["name"] as? String ?? "", platform: info["platform"] as? String ?? "")
    }
}

/// Reconnect delays: 1, 2, 4, 8, 16, then 30 seconds, with up to 20% jitter so a fleet of Macs
/// does not come back at the same instant.
struct Backoff: Sendable {
    private(set) var attempt = 0

    mutating func next(jitter: Double = Double.random(in: 0.8...1.2)) -> Duration {
        let base = min(30.0, pow(2.0, Double(attempt)))
        attempt += 1
        return .milliseconds(Int(base * jitter * 1000))
    }

    mutating func reset() { attempt = 0 }
}
