import Foundation
import SecureStore

/// A device this one has paired with. Its key is the only thing that lets it in (plan section 14,
/// authorization on the Mac).
public struct PairedPeer: Codable, Sendable, Equatable, Identifiable {
    public var id: DeviceID
    public var name: String
    public var platform: String
    public var key: PublicKey
    /// Unix seconds.
    public var pairedAt: Int64

    public init(id: DeviceID, name: String, platform: String, key: PublicKey, pairedAt: Int64) {
        self.id = id
        self.name = name
        self.platform = platform
        self.key = key
        self.pairedAt = pairedAt
    }
}

/// Pinned peers in the keychain, this device only. Written only by pairing; the backend can ask
/// for a removal but never adds one.
public struct PeerStore: Sendable {
    private let store: any SecretStore
    private static let prefix = "peer."

    public init(store: any SecretStore) {
        self.store = store
    }

    public func all() throws -> [PairedPeer] {
        try store.names(prefix: Self.prefix).compactMap { name in
            try store.data(for: name).flatMap { try? JSONDecoder().decode(PairedPeer.self, from: $0) }
        }.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func peer(_ id: DeviceID) throws -> PairedPeer? {
        try store.data(for: Self.prefix + id.rawValue).flatMap { try? JSONDecoder().decode(PairedPeer.self, from: $0) }
    }

    /// The pinned key for a sender, if it is paired.
    public func key(for id: DeviceID) throws -> PublicKey? { try peer(id)?.key }

    public func pin(_ peer: PairedPeer) throws {
        try store.set(JSONEncoder.sorted.encode(peer), for: Self.prefix + peer.id.rawValue)
    }

    public func remove(_ id: DeviceID) throws {
        try store.delete(Self.prefix + id.rawValue)
    }
}
