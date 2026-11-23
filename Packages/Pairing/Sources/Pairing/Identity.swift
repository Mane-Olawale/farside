import CryptoKit
import Foundation
import SecureStore

/// A device's id: `dev_` and 26 Crockford base32 characters from 128 random bits. Made on the
/// device, so pairing and LAN sessions work with no backend; the backend registers it as is.
public struct DeviceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("dev_"), rawValue.count == 30,
              rawValue.dropFirst(4).allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    public static func generate() -> DeviceID {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return DeviceID(rawValue: "dev_" + base32(bytes))!
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = DeviceID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad device id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func base32(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int(buffer >> UInt32(bits - 5) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits) & 31)]) }
        return out
    }
}

/// A peer's public key as it travels: the 65-byte uncompressed point, base64 in JSON.
public struct PublicKey: Hashable, Codable, Sendable {
    public let key: P256.Signing.PublicKey

    public init(_ key: P256.Signing.PublicKey) {
        self.key = key
    }

    public init(x963: Data) throws {
        key = try P256.Signing.PublicKey(x963Representation: x963)
    }

    public var x963: Data { key.x963Representation }

    /// SHA-256 of the uncompressed point (plan section 13, `key_fingerprint`).
    public var fingerprint: KeyFingerprint { KeyFingerprint(Data(SHA256.hash(data: x963))) }

    public func isValid(signature: Data, for data: Data) -> Bool {
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    public static func == (a: PublicKey, b: PublicKey) -> Bool { a.x963 == b.x963 }
    public func hash(into hasher: inout Hasher) { hasher.combine(x963) }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64Encoded: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad key"))
        }
        try self.init(x963: data)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(x963.base64EncodedString())
    }
}

public struct KeyFingerprint: Hashable, Sendable {
    public let bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// What people compare at pairing: the first 16 bytes as eight groups of four.
    public var display: String {
        let text = bytes.prefix(16).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: text.count, by: 4).map { start in
            let s = text.index(text.startIndex, offsetBy: start)
            return String(text[s..<text.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

/// This device: its id, its key, and what it calls itself.
public struct LocalIdentity: Sendable {
    public let id: DeviceID
    public let key: any SigningKey
    public var name: String

    public init(id: DeviceID, key: any SigningKey, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }

    public var publicKey: PublicKey { PublicKey(key.publicKey) }

    static let idName = "device-id"

    /// The stored identity, or a new one. A new key means a new id: pins elsewhere name both.
    public static func loadOrCreate(in store: any SecretStore, name: String, allowEnclave: Bool = true) throws -> LocalIdentity {
        let key = try DeviceKey.loadOrCreate(in: store, allowEnclave: allowEnclave)
        let stored = try store.data(for: idName).flatMap { String(data: $0, encoding: .utf8) }.flatMap(DeviceID.init(rawValue:))
        let id = stored ?? DeviceID.generate()
        if stored == nil { try store.set(Data(id.rawValue.utf8), for: idName) }
        return LocalIdentity(id: id, key: key, name: name)
    }

    /// Forgets the key and id. Every peer has to pair again.
    public static func reset(in store: any SecretStore) throws {
        try DeviceKey.reset(in: store)
        try store.delete(idName)
    }
}
