import Foundation

// Signaling (plan section 11, signaling envelope). Small JSON objects that travel over the LAN
// WebSocket now, and through the backend from Phase 3. Phase 3 also adds `from`, `to` and `sig`;
// until then nothing is signed, which is acceptable only on a LAN with no pairing.

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

    public init(sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil,
                reason: String? = nil, extra: [String: String]? = nil) {
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.reason = reason
        self.extra = extra
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
    public var seq: UInt64
    /// Unix seconds.
    public var ts: Int64
    public var body: SignalBody

    public init(message: SignalMessage, session: String, seq: UInt64, ts: Int64) {
        v = Self.version
        type = message.kind
        self.session = session
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
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
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
