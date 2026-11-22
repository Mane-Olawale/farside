# S3: Transport plumbing

**Result: go.** Custom encoder and decoder factories carry our VideoToolbox HEVC frames through WebRTC from the Mac to the iPad at 60 fps, with no loss. The Objective-C API has no playout-delay setting, but two field trials reach it, and either one cuts the jitter buffer from 10–22 ms to under 1 ms. WebRTC adds 11.9 MB to the iPad app, 5.5 MB compressed.

Measured Nov 22, 2026: MacBook Pro M3 Pro on macOS 26.0.1 to an iPad Pro 13-inch M4 (iPad16,5, 120 Hz) on iPadOS 27.2.1, over home Wi-Fi with a 4–8 ms round trip. stasel/WebRTC 158.0.0. HEVC stream at 2752×1152, the rung 5 cap. Raw reports are in `S3/`.

## Method

`S3Host` captures the test pattern with `HostCapture` and pushes frames into a WebRTC screencast source. The encoder factory wraps `VideoEncoder`, and the decoder factory wraps `VideoDecoder`. Signaling is a WebSocket over Bonjour (`_farside._tcp`), with all four data channels pre-negotiated as in section 11. In local mode, a second peer in the same process receives and renders. In serve mode, `S3Viewer` on the iPad receives, renders full screen, reads each decoded frame's block code and echoes it on the control channel. The Mac then times its own glass to the echo's arrival, on one clock. That figure includes the echo's trip back, about half the round trip, or 2–4 ms. Each run is 15–20 s after a 3 s warm-up.

## Results

Mac to iPad, HEVC, 60 fps, no loss, NACKs, freezes or dropped frames in any run:

| Playout mode | Jitter buffer, avg | Mac glass to iPad decoded, plus trip back (p50 / p95) | Mac glass to iPad presented, plus trip back (p50 / p95) |
| --- | --- | --- | --- |
| standard | 22.0 ms | 36.4 / 39.5 | 75.7 / 87.2 |
| receiverZero | 0.80 ms | 12.3 / 20.2 | 55.1 / 63.6 |
| senderZero | 0.78 ms | 11.6 / 19.2 | 55.3 / 56.7 |
| both | 0.59 ms | 12.9 / 16.6 | 48.5 / 57.5 |

iPad decode averaged 1.8–1.9 ms. WebRTC's own encode timing on the Mac averaged 9.9 ms.

In-process on the Mac, same clock, no network:

| Run | Jitter buffer, avg | Mac glass to decoded (p50 / p95) |
| --- | --- | --- |
| HEVC standard | 10.0 ms | 15.9 / 18.1 |
| HEVC receiverZero | 0.28 ms | 2.8 / 6.0 |
| HEVC senderZero | 0.32 ms | 2.1 / 4.8 |
| HEVC both | 0.27 ms | 3.2 / 6.1 |
| H.264 standard | 12.4 ms | 15.7 / 17.8 |

Binary size, Release builds:

| Item | Size |
| --- | --- |
| WebRTC.framework in the iPad app, arm64 | 11.9 MB, 5.5 MB zipped |
| Whole S3Viewer app | 12.7 MB |
| WebRTC.framework in the Mac app, universal | 28.1 MB, of which the arm64 slice is 12.0 MB |

## Findings

1. **The SDK has HEVC but no Objective-C names for it.** No header mentions H.265, yet the binary contains the H.265 bitstream parsers, the RTP packetizer and depacketizer, and the codec name. A factory that advertises `RTCVideoCodecInfo(name: "H265")` with standard fmtp parameters negotiates `video/H265`. Each encoded frame is passed with a plain `RTCCodecSpecificInfo` object, because the packetizer follows the negotiated payload type. WebRTC's stats name our adapters as the encoder and decoder.
2. **Playout delay is reachable only through field trials.** The receiver exposes no delay setting. Two trials work, each set with min 0 and max 0 before the factory is created: `WebRTC-ForcePlayoutDelay` on the receiver, and `WebRTC-ForceSendPlayoutDelay` on the sender. The sender's value reaches the receiver in the `playout-delay` header extension, which this build negotiates by default. Either alone is enough. The only public setter, `RTCInitFieldTrialDictionary`, is deprecated, and the factory builder that replaces it is not in the Objective-C headers.
3. **With zero playout delay, the transport adds almost nothing on a LAN.** In-process, Mac glass to decoded fell from 15.9 to 2–3 ms at the median. To the iPad, it fell from 36.4 to 11.6–12.9 ms including the trip back. That puts the plan's 40 ms LAN glass-to-glass target within reach, once presenting is fixed. Zero delay also removes all jitter smoothing, so Phase 5 has to check it against the lossy and jittery network profiles.
4. **Presenting on the iPad costs 36–43 ms.** This is the gap between decoded and presented, and the main remaining latency. The viewer uses the S1 renderer, which blocks in `nextDrawable` with two drawables, the pattern section 8 now forbids. The presented handler may also fire late. The Phase 2 renderer and the camera method will settle the real figure.
5. **The SDP start bitrate works.** With `x-google-start-bitrate` set to 20 Mbps, the target reached 37 Mbps within the warm-up, and the quality limitation reason stayed none. Degradation preference disabled and no QP scaler kept the stream at 2752×1152 throughout.
6. **Three pitfalls:**
   - `RTCVideoTrack` removes its renderers when its Objective-C wrapper is deallocated, so the session must keep the received track.
   - Swift imports the throwing and the deprecated `setCodecPreferences` under one name and picks the deprecated one; both work.
   - Field trials are process-wide, so a test that compares modes needs a fresh process for each.
7. **The binary ships its own privacy manifest** (`PrivacyInfo.xcprivacy`), which settles the check listed in section 18.

## Plan changes, applied Nov 22, 2026

- **Section 8, transport settings:** the playout delay row becomes zero, set with `WebRTC-ForceSendPlayoutDelay` on the host and `WebRTC-ForcePlayoutDelay` on the client, before the factory is created. Setting both covers a client or host built without one. Phase 5 decides whether the network profiles need a small non-zero maximum.
- **Section 12, transport configuration:** add a start bitrate row: 20 Mbps on a LAN through `x-google-start-bitrate` in the session description.
- **Section 20, risks:** R3 is settled for HEVC and playout delay. Add to R11 that field trials depend on a deprecated function. If a later milestone removes it, the fallback is the own-build script already listed for Phase 8.

None is a no-go, so no ADR changes.

## Not covered

- Internet paths, STUN and TURN. Those are Phase 3.
- Lossy, jittery or slow networks with zero playout delay. That is Phase 5.
- H.264 to the iPad; it ran only in-process.
- The Mac-to-iPad camera measurement and the real present latency, which wait for the Phase 2 renderer.
- Audio, which is spike S4.
- Sessions longer than 20 s, and memory over time.

## Reproduce

Grant S3Host Screen Recording and allow Local Network on both devices. Then, on the Mac only:

```bash
make run-s3-local
```

Then, for the iPad, with the device identifier from `xcrun devicectl list devices`:

```bash
make install-s3-viewer IPAD=<device id>
```

Start `S3Host.app --mode serve --playout <mode> --duration 20`, then open Farside S3 on the iPad. Reports go to `~/Library/Logs/Farside/s3-*.json`.
