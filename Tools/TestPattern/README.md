# Test pattern

A Mac app for measuring glass-to-glass latency (plan section 17). Run it with `make run-testpattern`, put it full screen with Command-Control-F, and stream that display.

| Element | Use |
| --- | --- |
| Clock, `HH:MM:SS.mmm` | Film the Mac and the iPad side by side at 240 fps and subtract the two readings |
| Sweeping bar | Moves across the 100 ms ruler once per second. Its offset between the two screens is the delay |
| Block row, top left | Frame counter for the iPad's debug reader. Layout is in `Packages/Telemetry/Sources/Telemetry/FrameCode.swift` |
| Square, bottom right | Flips black and white on each click, for click-to-photon |
| Info line | Display refresh rate and window size in pixels |

All values describe the display link's target time, so they match the frame that is on the glass.
