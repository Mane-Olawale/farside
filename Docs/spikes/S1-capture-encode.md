# S1: Capture and encode

**Result: go, with three plan changes.** The Mac captures at a steady 60 fps, and frames decode in 2.5 ms. The encoder alone misses its 10 ms budget at the sizes we stream, but ScreenCaptureKit delivers frames before they reach the Mac's glass, which hides most of that time. Encoded bits are ready 4 to 5.5 ms after the content hits the glass (p95 6 to 9 ms), inside the plan's combined 9 ms target for capture plus encode.

Measured Nov 21–22, 2026 on a MacBook Pro M3 Pro (Mac15,6, 11 cores), macOS 26.0.1, capturing a 60 Hz 3440×1440 external display. Raw reports are in `S1/`.

## Method

`Tools/Loopback` runs capture → frame gate → HEVC or H.264 encode → Annex B packaging → decode → Metal render, all in one process. The test pattern fills the captured display, and a floating preview window, which is left out of the capture, shows the decoded stream. Every frame carries host-clock timestamps from capture to present. The decoded frame's block code is read back and matched against the pattern's own record of when it drew that frame. `Tools/EncoderBench` times the same `VideoEncoder` on complete synthetic frames, with no capture involved. Runs were 30 s after a 2 s warm-up.

## Results, 30 s runs

| Stage, ms (p50 / p95) | HEVC 3440×1440 | H.264 3440×1440 | HEVC 1920×802 |
| --- | --- | --- | --- |
| Frames captured and shown per second | 60 / 60 | 60 / 60 | 60 / 60 |
| ScreenCaptureKit delivery vs display time | −10.6 / −7.1 | −11.1 / −8.3 | −13.0 / −11.3 |
| Encode, submit to output | 16.1 / 17.1 | 16.0 / 17.1 | 15.9 / 17.7 |
| Packaging to Annex B | 0.1 / 0.1 | 0.1 / 0.2 | 0.1 / 0.1 |
| Decode (hardware) | 2.1 / 2.3 | 2.2 / 2.5 | 1.7 / 2.1 |
| **Mac glass to encoded bits** | **5.4 / 9.0** | **4.9 / 7.8** | **3.6 / 6.1** |
| Mac glass to decoded frame | 7.7 / 11.4 | 7.3 / 10.2 | 5.4 / 8.1 |
| Mac glass to preview glass (same display) | 66.2 | 49.5 | 49.5 |
| Process CPU, share of all cores | 3.3 % | 3.1 % | 3.8 % |

No idle frames, no frames replaced at either gate, no encode or decode failures, and every decoded frame's block code read correctly. Bitrate was about 2.5 Mbps because the pattern compresses easily; no property was rejected, and the conferencing preset was applied.

Encoder alone, complete frames submitted at 60 fps (`EncoderBench`), HEVC low-latency mode:

| Size | p50 | p95 | Sustains 60 fps |
| --- | --- | --- | --- |
| 1280×720 | 7.2 | 7.8 | yes |
| 1920×1080 | 9.0 | 9.8 | yes |
| 2420×1668, 11-inch iPad panel | 14.6 | 15.3 | yes |
| 2752×2064, 13-inch iPad Pro panel | 15.9 | 16.2 | yes, no headroom |
| 3440×1440 | 14.5 | 15.0 | yes |
| 3024×1964 | 19.3 | 49.7 | output keeps up, but frames queue |
| 3840×2160 | 21.7 | 22.2 | no, 45 fps |

H.264 is about 10 % faster than HEVC at the same size. Normal rate control is slower (26.8 ms at 3440×1440). These made no difference: skipping the conferencing preset, removing the QP cap, clearing RealTime, and flushing with `CompleteFrames` after each frame. `PrioritizeEncodingSpeedOverQuality` is rejected in low-latency mode.

## Findings

1. **`displayTime` is the Mac's glass time.** A windowed layer takes two refreshes from commit to glass. That holds both for the preview, by Metal's presented time (32.4 ms), and for the pattern, by `displayTime` (33.2 ms). The display link's target time is only one refresh after the draw (16.0 ms), so it is the app's commit deadline, not the glass time. The camera method still has to confirm this (see Not covered).
2. **ScreenCaptureKit hands over frames 7 to 13 ms before they reach the glass.** That overlaps most of the encode. At 1080p, the bits would usually be ready before the pixels are even lit.
3. **Encode latency grows with pixel count:** about 2.5 ms plus 4.5 ms per megapixel. Above roughly 5.7 MP, the encoder cannot hold 60 fps with one frame in flight.
4. **At exactly 1/60 s, `minimumFrameInterval` drops frames.** It loses about 2 frames a second on a 60 Hz display because of vsync jitter. `DisplayCapture` now uses 0.9/fps, which gives 60/60 here and still caps a 120 Hz display at 60.
5. **The preview's renderer blocks.** `nextDrawable` with two drawables waits 10 to 26 ms, which is why glass to preview glass was sometimes 4 frames instead of 3. This affects only the loopback window, but the Phase 2 renderer must not block.
6. **A Developer-signed build keeps its Screen Recording grant across rebuilds,** as section 6 expects. `make build-loopback` signs with the team in `Config/Local.xcconfig`.

## Plan changes, applied Nov 22, 2026

`Docs/plan.md` now has the three changes below. It also has two follow-on edits: the capture interval in section 8, and the encode-time rows in the section 16 stats overlay.

- **Section 2, latency budget:** merge "screen update to captured frame" and "encode" into one row: Mac glass to encoded bits, target 9 ms, ceiling 15 ms. The separate encode row (5 / 10) cannot be met at panel sizes on an M3 Pro.
- **Section 8, adaptation ladder:** rung 5 becomes the iPad panel, capped at 2752 px on the long edge, instead of native up to 3840. A 4K stream cannot hold 60 fps on this Mac.
- **Section 8, renderer:** add the rule that the render loop paces from the display link and skips a tick when no drawable is free, never waiting in `nextDrawable`.
- **Phase 1:** keep one frame in flight. Revisit allowing two only if a Mac with a slower encoder shows queuing at panel sizes.

None of these is a no-go, so no ADR changes.

## Not covered

- **Camera latency (Phase 0 exit criterion 4).** This needs a 240 fps camera filming the Mac's display. Finding 1 rests on internal consistency until then.
- **Decode and present on an iPad.** That comes with S3. The figures here are Mac decode and windowed present.
- **Real desktop content at 10 to 40 Mbps,** such as scrolling text and video. The pattern only needed about 2.5 Mbps. Encode time may rise with content complexity.
- **Other Macs.** Base M-series chips have fewer media engines and may be slower; Max and Ultra chips have more.
- **Signposts** are in place (Encode, Decode, Render in the `app.farside` pipeline category), but no Instruments trace was recorded.

## Reproduce

Grant Loopback Screen Recording once, then:

```bash
make run-s1
```

```bash
swift run -c release --package-path Tools/EncoderBench EncoderBench 2752 2064 hevc
```

Reports go to `~/Library/Logs/Farside`. `Tools/Loopback/LoopbackOptions.swift` lists the flags.
