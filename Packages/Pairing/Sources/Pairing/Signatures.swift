import CryptoKit
import Foundation

/// What each signature covers. Every signed message starts with its own label, so a signature
/// made for one purpose can never be replayed as another.
public enum SignatureDomain: String, Sendable {
    case signal = "farside.signal.v1"
    case hello = "farside.hello.v1"
    case helloAck = "farside.hello-ack.v1"

    public func message(_ body: Data) -> Data {
        Data(rawValue.utf8) + Data([0]) + body
    }
}

extension LocalIdentity {
    public func sign(_ body: Data, as domain: SignatureDomain) throws -> Data {
        try key.signature(for: domain.message(body))
    }
}

extension PublicKey {
    public func verify(_ signature: Data, for body: Data, as domain: SignatureDomain) -> Bool {
        isValid(signature: signature, for: domain.message(body))
    }
}

/// Signaling freshness (plan section 11): a timestamp within 60 s of now, and a sequence number
/// above the last one seen from that sender in that session.
public struct FreshnessGuard: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case stale
        case future
        case replayed
    }

    public var maxSkew: Int64
    private var lastSeq: [Key: (seq: UInt64, seen: Int64)] = [:]

    struct Key: Hashable {
        let sender: String
        let session: String
    }

    public init(maxSkew: Int64 = 60) {
        self.maxSkew = maxSkew
    }

    /// Checks one envelope and records it when it passes. `ts` and `now` are Unix seconds.
    public mutating func check(sender: String, session: String, seq: UInt64, ts: Int64, now: Int64) throws(Rejection) {
        if ts < now - maxSkew { throw .stale }
        if ts > now + maxSkew { throw .future }
        let key = Key(sender: sender, session: session)
        if let last = lastSeq[key], seq <= last.seq { throw .replayed }
        lastSeq[key] = (seq, now)
        // Anything older than the skew window can no longer pass the timestamp check anyway.
        if lastSeq.count > 256 { lastSeq = lastSeq.filter { now - $0.value.seen <= maxSkew * 2 } }
    }
}

/// Single-use nonces for `Hello` (plan section 14, freshness).
public struct NonceGuard: Sendable {
    public var lifetime: Int64
    private var seen: [Data: Int64] = [:]

    public init(lifetime: Int64 = 600) {
        self.lifetime = lifetime
    }

    /// False if this nonce was already used.
    public mutating func use(_ nonce: Data, now: Int64) -> Bool {
        seen = seen.filter { now - $0.value < lifetime }
        guard seen[nonce] == nil else { return false }
        seen[nonce] = now
        return true
    }

    public static func make() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// The identity handshake after the encrypted channel is up (plan section 11). Both signatures
/// cover the session id, both devices' ids, both transport certificate fingerprints and fresh
/// nonces, which ties the device keys to this one connection.
public struct HelloTranscript: Sendable, Equatable {
    public var session: String
    public var client: DeviceID
    public var host: DeviceID
    /// The `a=fingerprint` values of the iPad's and the Mac's DTLS certificates.
    public var clientCertificate: String
    public var hostCertificate: String
    public var clientNonce: Data

    public init(session: String, client: DeviceID, host: DeviceID, clientCertificate: String,
                hostCertificate: String, clientNonce: Data) {
        self.session = session
        self.client = client
        self.host = host
        self.clientCertificate = clientCertificate
        self.hostCertificate = hostCertificate
        self.clientNonce = clientNonce
    }

    /// What the iPad signs in `Hello`.
    public var helloBody: Data { fields([]) }

    /// What the Mac signs in `HelloAck`: the iPad's fields and the Mac's own nonce.
    public func helloAckBody(hostNonce: Data) -> Data { fields([hostNonce]) }

    private func fields(_ extra: [Data]) -> Data {
        let parts = [Data(session.utf8), Data(client.rawValue.utf8), Data(host.rawValue.utf8),
                     Data(clientCertificate.utf8), Data(hostCertificate.utf8), clientNonce] + extra
        // Length-prefixed, so no two different field lists produce the same bytes.
        return parts.reduce(into: Data()) { out, part in
            withUnsafeBytes(of: UInt32(part.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(part)
        }
    }
}

/// The DTLS certificate fingerprint a session description carries, normalized to lowercase.
public enum SDPFingerprint {
    public static func value(in sdp: String) -> String? {
        for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=fingerprint:") {
            return line.dropFirst("a=fingerprint:".count).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return nil
    }
}
