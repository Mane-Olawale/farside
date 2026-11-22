import Foundation
import SessionTransport
import Testing
import WireProtocol
@testable import SessionTransportWebRTC

@Suite struct SDPTests {
    let sdp = [
        "v=0",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=rtpmap:96 H265/90000",
        "a=fmtp:96 profile-id=1",
        "a=rtpmap:97 H264/90000",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=rtpmap:111 opus/48000/2",
        "a=fmtp:111 minptime=10;useinbandfec=1",
        "",
    ].joined(separator: "\r\n")

    @Test func addsStartBitrateToEveryVideoFormat() {
        let out = WebRTCTransport.munged(sdp, configuration: .lan)
        #expect(out.contains("a=fmtp:96 profile-id=1;x-google-start-bitrate=20000;x-google-min-bitrate=1500;x-google-max-bitrate=40000"))
        // H.264 had no fmtp line, so one is inserted after its rtpmap.
        #expect(out.contains("a=rtpmap:97 H264/90000\r\na=fmtp:97 x-google-start-bitrate=20000"))
    }

    /// Spike S4: the custom audio device records mono only, so Opus is negotiated as mono.
    @Test func opusIsMono() {
        let out = WebRTCTransport.munged(sdp, configuration: .lan)
        #expect(out.contains("a=fmtp:111 minptime=10;useinbandfec=1;stereo=0;sprop-stereo=0;maxaveragebitrate=96000;usedtx=0"))
        #expect(!out.contains("stereo=1"))
    }
}

/// A real WebRTC host and client in one process, signaling handed across directly. Proves the
/// protocol wrapper negotiates, opens all four pre-negotiated channels, and carries bytes.
@Suite struct WebRTCLoopbackTests {
    @Test(.timeLimit(.minutes(1)))
    func negotiatesAndCarriesDataChannelMessages() async throws {
        let box = Peers()
        let (hostOpen, hostOpenContinuation) = AsyncStream.makeStream(of: Wire.Channel.self)
        let (clientMessages, clientMessageContinuation) = AsyncStream.makeStream(of: (Wire.Channel, Data).self)
        let (clientOpen, clientOpenContinuation) = AsyncStream.makeStream(of: Wire.Channel.self)

        let host = WebRTCTransport(role: .host, handlers: TransportHandlers(
            signal: { box.client?.handle($0) },
            event: { event in if case .channelOpen(let c) = event { hostOpenContinuation.yield(c) } }))
        let client = WebRTCTransport(role: .client, handlers: TransportHandlers(
            signal: { box.host?.handle($0) },
            event: { event in
                switch event {
                case .channelOpen(let c): clientOpenContinuation.yield(c)
                case .message(let c, let d): clientMessageContinuation.yield((c, d))
                default: break
                }
            }))
        box.host = host
        box.client = client
        defer { host.close(); client.close() }

        host.start()
        var opened = Set<Wire.Channel>()
        for await channel in hostOpen {
            opened.insert(channel)
            if opened.count == Wire.Channel.allCases.count { break }
        }
        var clientOpened = Set<Wire.Channel>()
        for await channel in clientOpen {
            clientOpened.insert(channel)
            if clientOpened.count == Wire.Channel.allCases.count { break }
        }

        let ping = try Envelope(seq: 1, sentAtMicroseconds: 7, body: .ping(.with { $0.senderTimeUs = 7 })).encoded()
        host.send(ping, on: .control)
        var iterator = clientMessages.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.0 == .control)
        #expect(try Envelope.decoded(received.1, on: .control).ping.senderTimeUs == 7)
    }
}

final class Peers: @unchecked Sendable {
    var host: WebRTCTransport?
    var client: WebRTCTransport?
}
