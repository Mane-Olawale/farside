import CryptoKit
import Foundation

/// What the Mac's QR code holds (plan section 14, pairing): its id, key and name, a one-time
/// secret, and when the code expires.
public struct PairingInvite: Codable, Sendable, Equatable {
    public static let version = 1
    public static let lifetime: Int64 = 120
    public static let scheme = "farside"

    public var v: Int
    public var id: DeviceID
    public var name: String
    public var key: PublicKey
    public var secret: Data
    /// Unix seconds.
    public var exp: Int64

    public init(host: LocalIdentity, now: Int64, secret: Data = PairingInvite.makeSecret()) {
        v = Self.version
        id = host.id
        name = host.name
        key = host.publicKey
        self.secret = secret
        exp = now + Self.lifetime
    }

    public static func makeSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// `farside://pair#<base64url JSON>`. The fragment keeps it out of any URL logging.
    public var url: URL {
        let json = (try? JSONEncoder.sorted.encode(self)) ?? Data()
        return URL(string: "\(Self.scheme)://pair#\(json.base64URL)")!
    }

    public enum ParseError: Error, Equatable {
        case notAnInvite
        case unsupportedVersion
        case expired
    }

    public static func parse(_ text: String, now: Int64) throws(ParseError) -> PairingInvite {
        guard let url = URL(string: text), url.scheme == scheme, url.host == "pair",
              let fragment = url.fragment, let json = Data(base64URL: fragment),
              let invite = try? JSONDecoder().decode(PairingInvite.self, from: json),
              invite.secret.count == 32 else { throw .notAnInvite }
        guard invite.v == version else { throw .unsupportedVersion }
        guard invite.exp > now else { throw .expired }
        return invite
    }
}

/// The iPad's answer to an invite: who it is, with an HMAC keyed by the invite's secret that
/// proves it saw the QR code.
public struct PairingRequest: Codable, Sendable, Equatable {
    public var id: DeviceID
    public var name: String
    public var platform: String
    public var key: PublicKey
    public var proof: Data

    public init(client: LocalIdentity, platform: String, invite: PairingInvite) {
        id = client.id
        name = client.name
        self.platform = platform
        key = client.publicKey
        proof = Data()
        proof = Self.proof(for: self, invite: invite)
    }

    static func proof(for request: PairingRequest, invite: PairingInvite) -> Data {
        let fields = [invite.id.rawValue, invite.key.x963.base64EncodedString(), request.id.rawValue,
                      request.key.x963.base64EncodedString(), request.name, request.platform]
        let message = Data("farside.pair.v1".utf8) + Data(fields.joined(separator: "\n").utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: invite.secret)))
    }

    /// The 6-digit code both screens show when there is no camera, derived from both keys and
    /// the secret. The person at the Mac confirms they match.
    public static func code(invite: PairingInvite, client: PublicKey) -> String {
        let message = Data("farside.code.v1".utf8) + invite.key.x963 + client.x963
        let mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: invite.secret)))
        let value = mac.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }
}

/// The Mac's pairing window: one invite, open for 2 minutes, used at most once. A few wrong
/// proofs close it, so the secret cannot be guessed online.
public struct PairingWindow: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case closed
        case expired
        case badProof
    }

    public static let maxBadProofs = 3

    public let invite: PairingInvite
    public private(set) var isOpen = true
    private var badProofs = 0

    public init(invite: PairingInvite) {
        self.invite = invite
    }

    /// Checks a request. On success the window closes and the caller asks the person at the Mac
    /// to allow the device, then pins it.
    public mutating func accept(_ request: PairingRequest, now: Int64) throws(Failure) -> PairedPeer {
        guard isOpen else { throw .closed }
        guard now < invite.exp else {
            isOpen = false
            throw .expired
        }
        guard Self.constantTimeEqual(request.proof, PairingRequest.proof(for: request, invite: invite)) else {
            badProofs += 1
            if badProofs >= Self.maxBadProofs { isOpen = false }
            throw .badProof
        }
        isOpen = false
        return PairedPeer(id: request.id, name: request.name, platform: request.platform, key: request.key, pairedAt: now)
    }

    public mutating func close() { isOpen = false }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        self.init(base64Encoded: base)
    }
}
