import Foundation
import Pairing

// Signaling (plan section 11, signaling envelope). Small JSON objects that travel over the LAN
// WebSocket, and through the backend over the internet. Every envelope is signed with the
// sender's device key (plan section 14, signed signaling).

/// One signaling message as a transport produces and consumes it.
public struct SignalMessage: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The client's first message on a LAN socket. It carries the session id the host stamps
        /// its own messages with, so the host can speak first (it sends the offer).
        case join
        case offer, answer, candidate
        /// The host refuses this session, for example because it is busy.
        case reject
        /// End of session, sent when the data channels are not up yet or already gone.
        case bye
        /// The iPad's answer to a pairing QR code, and the Mac's acceptance (plan section 14).
        case pair, paired
        /// Over the internet: the backend's unsigned hint that an iPad is calling, and the Mac's
        /// signed answer that it will take the session (plan section 12).
        case ring, accept
    }

    public var kind: Kind
    public var body: SignalBody

    public init(kind: Kind, body: SignalBody = SignalBody()) {
        self.kind = kind
        self.body = body
    }

    public static func offer(_ sdp: String) -> Self { .init(kind: .offer, body: .init(sdp: sdp)) }
    public static func answer(_ sdp: String) -> Self { .init(kind: .answer, body: .init(sdp: sdp)) }
    public static func candidate(_ sdp: String, mid: String?, lineIndex: Int32) -> Self {
        .init(kind: .candidate, body: .init(candidate: sdp, sdpMid: mid, sdpMLineIndex: lineIndex))
    }
    public static func reject(_ reason: SessionEndReason) -> Self { .init(kind: .reject, body: .init(reason: reason.rawValue)) }
    public static func bye(_ reason: SessionEndReason) -> Self { .init(kind: .bye, body: .init(reason: reason.rawValue)) }
    public static func pair(_ request: PairingRequest) -> Self { .init(kind: .pair, body: .init(pairing: request)) }

    /// The end reason carried by `reject` and `bye`.
    public var endReason: SessionEndReason? { body.reason.flatMap(SessionEndReason.init(rawValue:)) }
}

public struct SignalBody: Codable, Sendable, Equatable {
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?
    /// A `SessionEndReason` raw value.
    public var reason: String?
    /// Test rigs only. The product never reads it.
    public var extra: [String: String]?
    /// `pair` only.
    public var pairing: PairingRequest?
    /// `join` and `ring`: end the Mac's current session and take this one (plan section 6, busy
    /// and take over).
    public var takeOver: Bool?

    public init(sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil,
                reason: String? = nil, extra: [String: String]? = nil, pairing: PairingRequest? = nil,
                takeOver: Bool? = nil) {
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.reason = reason
        self.extra = extra
        self.pairing = pairing
        self.takeOver = takeOver
    }
}

/// The JSON object on the wire.
public struct SignalEnvelope: Codable, Sendable, Equatable {
    public static let version = 1
    /// Larger envelopes are dropped before parsing. A LAN offer with candidates is about 6 KB.
    public static let maxBytes = 32 * 1024

    public var v: Int
    public var type: SignalMessage.Kind
    public var session: String
    /// Sender and receiver device ids.
    public var from: String
    public var to: String
    public var seq: UInt64
    /// Unix seconds.
    public var ts: Int64
    public var body: SignalBody
    /// The sender's signature over every other field, base64.
    public var sig: String?

    public init(message: SignalMessage, session: String, from: String, to: String, seq: UInt64, ts: Int64) {
        v = Self.version
        type = message.kind
        self.session = session
        self.from = from
        self.to = to
        self.seq = seq
        self.ts = ts
        body = message.body
    }

    public var message: SignalMessage { SignalMessage(kind: type, body: body) }

    public enum DecodeError: Error, Equatable {
        case tooLarge
        case malformed
        case unsupportedVersion(Int)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// What the signature covers: the envelope without `sig`, as sorted JSON.
    public func signedBytes() throws -> Data {
        var unsigned = self
        unsigned.sig = nil
        return try unsigned.encoded()
    }

    public mutating func sign(with identity: LocalIdentity) throws {
        sig = try identity.sign(signedBytes(), as: .signal).base64EncodedString()
    }

    public func isSigned(by key: PublicKey) -> Bool {
        guard let sig, let signature = Data(base64Encoded: sig), let bytes = try? signedBytes() else { return false }
        return key.verify(signature, for: bytes, as: .signal)
    }

    public static func decoded(_ data: Data) throws(DecodeError) -> SignalEnvelope {
        guard data.count <= maxBytes else { throw .tooLarge }
        let envelope: SignalEnvelope
        do {
            envelope = try JSONDecoder().decode(SignalEnvelope.self, from: data)
        } catch {
            throw .malformed
        }
        guard envelope.v == version else { throw .unsupportedVersion(envelope.v) }
        return envelope
    }
}
