import Foundation
import SwiftProtobuf

// Every message that crosses a data channel lives in Proto/wire.proto. The Swift types in
// Generated/ come from `make proto` and are never edited by hand. This file adds the protocol
// version, the channel each message travels on, and size-checked encoding and decoding.

/// Protocol constants (plan section 11, versioning).
public enum Wire {
    /// A major mismatch ends the handshake with an update message on both devices.
    public static let major: UInt32 = 1
    /// Minor differences are handled through `Capabilities`.
    public static let minor: UInt32 = 2
    /// Largest single envelope. Bigger payloads are split into `Chunk` messages (Phase 6).
    public static let maxEnvelopeBytes = 64 * 1024
    /// Nesting limit while decoding. Our deepest message is three levels.
    static let maxMessageDepth = 16

    /// Whether a peer speaking `major` can talk to us at all.
    public static func isCompatible(major peerMajor: UInt32) -> Bool { peerMajor == major }

    /// The four pre-negotiated data channels (plan section 11). Ids are fixed on both sides.
    public enum Channel: Int32, CaseIterable, Sendable, CustomStringConvertible {
        case control = 0
        case input = 1
        case pointer = 2
        case cursor = 3

        /// Reliable and ordered, or unreliable, unordered and never retransmitted.
        public var isReliable: Bool { self == .control || self == .input }

        public var description: String {
            switch self {
            case .control: "control"
            case .input: "input"
            case .pointer: "pointer"
            case .cursor: "cursor"
            }
        }
    }
}

public enum WireError: Error, Equatable, Sendable {
    /// The envelope is larger than `Wire.maxEnvelopeBytes`.
    case tooLarge(Int)
    /// The bytes are not a valid envelope.
    case malformed
    /// A valid envelope with no body this version knows. Receivers ignore these.
    case unknownBody
    /// The body arrived on a channel it does not belong to.
    case wrongChannel(expected: Wire.Channel, actual: Wire.Channel)
}

public typealias Envelope = Farside_V1_Envelope

extension Farside_V1_Envelope.OneOf_Body {
    /// The channel this message must travel on.
    public var channel: Wire.Channel {
        switch self {
        case .hello, .helloAck, .streamConfig, .streamConfigApplied, .displayList, .ping, .pong, .bye,
             .pause, .resume, .notice,
             .cursorShape, .cursorState:
            .control
        case .button, .scroll, .key, .text, .releaseAll:
            .input
        case .pointerMove, .pointerDelta, .inputHeartbeat:
            .pointer
        case .cursorPosition:
            .cursor
        }
    }
}

extension Farside_V1_Envelope {
    public init(seq: UInt32, sentAtMicroseconds: UInt64, body: OneOf_Body) {
        self.init()
        self.seq = seq
        self.sentAtUs = sentAtMicroseconds
        self.body = body
    }

    /// Serializes and enforces the size limit.
    public func encoded() throws(WireError) -> Data {
        let data: Data
        do {
            data = try serializedData()
        } catch {
            throw .malformed
        }
        guard data.count <= Wire.maxEnvelopeBytes else { throw .tooLarge(data.count) }
        return data
    }

    /// Parses bytes from `channel`. Checks the size before parsing, the body after, and that the
    /// body belongs on that channel. Unknown fields are kept and ignored, as proto3 does.
    public static func decoded(_ data: Data, on channel: Wire.Channel) throws(WireError) -> Self {
        guard data.count <= Wire.maxEnvelopeBytes else { throw .tooLarge(data.count) }
        var options = BinaryDecodingOptions()
        options.messageDepthLimit = Wire.maxMessageDepth
        let envelope: Self
        do {
            envelope = try Self(serializedBytes: data, options: options)
        } catch {
            throw .malformed
        }
        guard let body = envelope.body else { throw .unknownBody }
        guard body.channel == channel else { throw .wrongChannel(expected: body.channel, actual: channel) }
        return envelope
    }
}
