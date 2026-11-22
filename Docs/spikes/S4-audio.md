# S4: Audio injection

**Result: go for mono.** System audio from ScreenCaptureKit feeds WebRTC's audio track through a custom audio device on macOS and plays on the iPad, with 0.4 % concealment and no loss. Two things differ from the plan. The custom audio device path records mono only, so stereo needs the data-channel fallback or a patched module. And latency to the iPad's speaker is about 107 ms at the median, just over the 100 ms target.

Measured Nov 22, 2026 with the same Mac, iPad and network as S3: MacBook Pro M3 Pro on macOS 26.0.1, iPad Pro 13-inch M4 on iPadOS 27.2.1, home Wi-Fi, WebRTC 158.0.0. Raw reports are in `S4/`.

## Method

`S3Host --audio` captures system audio from the same `SCStream` as video (48 kHz, stereo, float) and pushes it into `InjectedAudioInput`. That is our `RTCAudioDevice`, which hands PCM to WebRTC's native audio module. The track is Opus, with speech processing switched off and its own stream id so it never holds video back. On the iPad, `AudioPlayout` is a second `RTCAudioDevice`. It pulls decoded PCM on the AVAudioEngine render thread and plays it.

Timing uses a marker: a separate process plays a 30 ms, 1 kHz burst at half scale once a second. The Mac detects its onset in the captured audio, and the iPad detects it in the PCM it pulls for playout and echoes back on the control channel. The result is Mac capture onset to iPad playout pull, plus the echo's trip back of about 3 ms. The in-process runs measure the same thing on one clock, with no network.

## Results

| Run | Capture onset to playout pull (p50 / p95) | Audio jitter buffer, avg | Concealed | Marker level, sent 0.5 |
| --- | --- | --- | --- | --- |
| iPad, over Wi-Fi, mono | 94.3 / 185.5 ms, plus trip back, 18 markers | 70.3 ms | 0.42 % | 0.50 |
| In-process, mono | 113.4 / 113.5 ms | 58.3 ms | 0.21 % | 0.50 |
| In-process, mono, fast accelerate | 113.6 ms | 56.5 ms | 0.21 % | — |
| In-process, mono, fast accelerate, max 5 packets | 110.2 ms | 51.7 ms | 0.22 % | — |
| In-process, stereo input | 163 ms, 8 markers | — | 53.9 % | — |

Other measurements:
- ScreenCaptureKit delivered each audio buffer 32–43 ms after its first sample (p50), in buffers of about 1,024 frames.
- The iPad reported 11.1 ms output latency and a 5 ms IO buffer.
- During the iPad audio run, video still echoed at 12.6 ms p50 from Mac glass to iPad decoded.

## Findings

1. **The macOS slice hides a working custom audio device module.** `RTCAudioDevice.h` is missing from the macOS headers, but the binary contains `objc_audio_device.mm`. A small Objective-C target (`WebRTCAudioShim`) re-declares the two protocols on macOS, copied from the iOS header under its BSD license, and the factory accepts our device.
2. **The module records mono only.** Given stereo, it consumes half of each buffer. WebRTC's own source stats count 5.0 s of input for 10.0 s delivered, about half the received audio is concealment, and the left and right samples are scrambled. Delivered as mono, all 10.0 s arrive, at 50 packets a second, with 0.4 % concealment. Playout came back identical on both channels in 3,201 of 3,204 buffers, so stereo is not available on either side through this path.
3. **Buffer size was not the problem.** The module asks for 20 ms buffers at 48 kHz, and ScreenCaptureKit hands over about 1,024 frames at a time. My first guess was that each delivery was being truncated, so `InjectedAudioInput` now queues PCM and delivers fixed 10 ms chunks. That change alone did not fix the halving; switching to mono did. The chunking stays, because it keeps deliveries regular.
4. **Our own process's audio was not captured,** even with `excludesCurrentProcessAudio` off: every buffer was digital silence until a separate process played the marker. The product excludes its own audio anyway (section 8), so this changes nothing in the plan. Test rigs must play markers from another process.
5. **No level processing.** The 0.5 marker arrived at 0.50 with the echo canceller, gain control, noise suppression and high-pass filter disabled through source constraints.
6. **Latency is about 7 ms over target.** About 94 ms from capture onset to the iPad's playout pull, plus 16 ms of iPad output, minus about 3 ms of trip back, is about 107 ms at the median. The large parts are ScreenCaptureKit's audio buffering (about 40 ms) and WebRTC's audio jitter buffer (50–70 ms). Fast acceleration and a 5-packet maximum saved only about 5 ms. The p95 of 185 ms comes from 18 markers, too few to trust.
7. **Audio never holds video back.** With separate stream ids, video latency was unchanged while audio flowed.

## Plan changes, applied Nov 22, 2026

- **Section 10, audio:** v1 ships mono system audio through the custom audio device. Stereo becomes a Phase 5 option, either through the fallback path (AudioToolbox Opus over an unreliable data channel, which keeps both channels) or through a patched audio device module. Update the codec row to Opus mono, 64 to 96 kbit/s.
- **Section 10, audio latency target:** 120 ms or less for v1. Phase 5 works on the jitter buffer and the capture buffer size, with 100 ms as the goal.
- **Section 20, risks:** R3 is settled for audio injection, but mono only.

None is a no-go, so no ADR changes.

## Not covered

- **The fallback path,** AudioToolbox Opus over a data channel, which is the route to stereo. It was not prototyped, because mono works through the preferred path.
- **Audio-to-video sync** as a person perceives it. The design leaves them unsynchronized on purpose.
- **Lossy networks,** and the jitter buffer's behavior on them.
- **Silencing the Mac's own speakers** during a session. That is still an open question in section 10.
- **Long sessions and drift** between the Mac's capture clock and the iPad's output clock.

## Reproduce

Both devices beep once a second during these runs.

```bash
make build-s3
```

```bash
open -W .build/DerivedData/Build/Products/Release/S3Host.app --args --mode local --playout both --audio --duration 15
```

For the iPad, start the host with `--mode serve --playout both --audio`, then open Farside S3 on the iPad. To try stereo input, set `FARSIDE_AUDIO_CHANNELS=2` through `open --env`.
