# Transport

Sessions travel over WebRTC, used only as a network transport. It gives us ICE path selection, STUN and TURN, DTLS and SRTP, bandwidth estimation, retransmission and pacing.

WebRTC sits behind one Swift protocol, `SessionTransport`, in the package of the same name. Only that package imports WebRTC. `HostCapture` and `ClientVideo` never see a WebRTC type; `SessionTransport` adapts them to WebRTC's capturer, encoder, decoder and renderer interfaces. Our VideoToolbox HEVC codec fills the gap in the prebuilt package, which negotiates HEVC but ships no Apple encoder or decoder for it.

The dependency is the stasel/WebRTC XCFramework, pinned to an exact milestone and checksum. It is added in spike S3, not before.

On a LAN, the Mac advertises `_farside._tcp` over Bonjour and the iPad opens a WebSocket to it for signaling. Over the internet, the same signed envelopes go through the backend. Media and data share one bundled UDP flow with four pre-negotiated data channels.

A custom transport on Network.framework with QUIC datagrams was the alternative. It is fully native, but we would write hole punching, congestion control and loss recovery ourselves. It stays a candidate for a second `SessionTransport` implementation.

Revisit this if spike S3 shows that custom HEVC factories or minimum playout delay cannot be reached from the Objective-C API. Fallbacks in order: H.264 first, a patched WebRTC build, then the QUIC transport.
