# Architecture

Farside is two native Swift apps and a small backend. The iPad client sees and controls a Mac; the Mac host captures, encodes and replays input. Control runs one way only, iPad to Mac, because iPadOS has no public API for injecting input.

We own the media pipeline: ScreenCaptureKit for capture, VideoToolbox for hardware encode and decode, Metal for rendering, CGEvent for input. The network transport is a separate, replaceable piece (ADR 0003).

The backend introduces devices and relays signed signaling. It never carries media and never sees content. Trust rests on device keys pinned at pairing, so a compromised backend cannot start or read a session. On a LAN, sessions work with no backend at all.

The host is a single headless-first menu bar process, started by launchd. Every host feature works with no window open.

Shared code lives in twelve local Swift packages, imported by both apps. Views call session objects, session objects call packages. Pure-logic packages test on macOS with `swift test`. The hot path runs on serial queues, not actors. Tooling matches Porthole: XcodeGen, local packages, xcconfig, Makefile.

Minimum OS is iPadOS 26 and macOS 26 on Apple silicon. No private API, kernel extension or driver in v1.

Revisit this if login-window access is added (it needs a privileged helper and a split host), or if the Mac must also control the iPad.
