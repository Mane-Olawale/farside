import Foundation
import SwiftProtobuf
import Testing
@testable import WireProtocol

@Suite struct EnvelopeTests {
    @Test func roundTrip() throws {
        let envelope = Envelope(seq: 9, sentAtMicroseconds: 42, body: .ping(.with { $0.senderTimeUs = 42 }))
        #expect(try Envelope.decoded(envelope.encoded(), on: .control) == envelope)
    }

    @Test func rejectsOversizedEnvelopeOnEncode() {
        let envelope = Envelope(seq: 1, sentAtMicroseconds: 1, body: .bye(.with {
            $0.detail = String(repeating: "x", count: Wire.maxEnvelopeBytes)
        }))
        #expect {
            _ = try envelope.encoded()
        } throws: { error in
            if case WireError.tooLarge = error { return true }
            return false
        }
    }

    @Test func rejectsOversizedBytesBeforeParsing() {
        let data = Data(repeating: 0, count: Wire.maxEnvelopeBytes + 1)
        #expect(throws: WireError.tooLarge(Wire.maxEnvelopeBytes + 1)) {
            _ = try Envelope.decoded(data, on: .control)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: WireError.malformed) {
            _ = try Envelope.decoded(Data([0xFF, 0xFF, 0xFF, 0xFF]), on: .control)
        }
    }

    @Test func emptyBodyIsUnknown() {
        var envelope = Envelope()
        envelope.seq = 1
        #expect(throws: WireError.unknownBody) {
            _ = try Envelope.decoded(try envelope.serializedData(), on: .control)
        }
    }

    @Test func controlMessagesAreRejectedOnOtherChannels() throws {
        let data = try Envelope(seq: 1, sentAtMicroseconds: 1, body: .ping(.init())).encoded()
        #expect(throws: WireError.wrongChannel(expected: .control, actual: .pointer)) {
            _ = try Envelope.decoded(data, on: .pointer)
        }
    }

    /// A newer peer may send a body this version does not know. It parses, and the receiver
    /// sees no body and ignores it (plan section 11).
    @Test func unknownBodyFromNewerPeerIsIgnored() throws {
        // Field 99, length-delimited, two bytes of payload, after a known seq field.
        var data = Data([0x08, 0x05])  // seq = 5
        data.append(contentsOf: [0x9A, 0x06, 0x02, 0x08, 0x01])  // tag (99 << 3 | 2), len 2, payload
        #expect(throws: WireError.unknownBody) {
            _ = try Envelope.decoded(data, on: .control)
        }
    }

    /// An unknown field inside a known message is kept and does not break decoding.
    @Test func unknownFieldInsideKnownMessageIsKept() throws {
        var ping = Farside_V1_Ping()
        ping.senderTimeUs = 7
        var pingBytes = try ping.serializedData()
        pingBytes.append(contentsOf: [0xF8, 0x06, 0x01])  // field 111, varint 1
        var envelopeBytes = Data([0x08, 0x01])  // seq = 1
        envelopeBytes.append(0x7A)  // field 15 (ping), length-delimited
        envelopeBytes.append(UInt8(pingBytes.count))
        envelopeBytes.append(pingBytes)
        let envelope = try Envelope.decoded(envelopeBytes, on: .control)
        guard case .ping(let decoded) = envelope.body else {
            Issue.record("expected a ping")
            return
        }
        #expect(decoded.senderTimeUs == 7)
        #expect(!decoded.unknownFields.data.isEmpty)
    }

    @Test func versionCompatibility() {
        #expect(Wire.isCompatible(major: Wire.major))
        #expect(!Wire.isCompatible(major: Wire.major + 1))
    }

    @Test func channelIdsMatchThePlan() {
        #expect(Wire.Channel.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(Wire.Channel.control.isReliable && Wire.Channel.input.isReliable)
        #expect(!Wire.Channel.pointer.isReliable && !Wire.Channel.cursor.isReliable)
    }
}
