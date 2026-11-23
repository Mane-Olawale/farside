# iPad to Mac Remote Control: Architecture and Build Plan

Nov 21, 2026 · @Mane

## 1. Summary and scope

The product is two native Swift apps and a small backend that let an iPad see and fully control a Mac from any network, at 60 fps with a pointer that feels local. One engineer who is comfortable with Swift can reach an in-house release in about 20 weeks. LAN control works by week 8 and internet control by week 11. All durations in this doc are estimates.

- **What gets built:** an iPad client app, a Mac host app that runs in the background, and a backend made of an account and signaling service plus STUN and TURN.
- **How it is built:** ScreenCaptureKit for capture, VideoToolbox for hardware encode and decode, Metal for rendering, CGEvent for input injection. WebRTC is used only as the network transport, hidden behind one Swift protocol.
- **Who it is for first:** you, on your own iPad and Macs. The design already has accounts, device pairing and end-to-end verification, so it can become a product without a rewrite.
- **Direction:** iPad controls Mac only. Mac controlling iPad is set aside because iPadOS has no public API for injecting input.

**Definition of done for v1.** Holding only an iPad on a different network from the Mac, you can do these seven things:

1. See the Mac in a device list with a live online status.
2. Connect and see the first frame in under 5 seconds.
3. Unlock the Mac's lock screen by typing the password.
4. Work with keyboard, trackpad, mouse and touch at 60 fps, with a cursor that tracks your hand without visible lag.
5. Copy text on one device and paste it on the other.
6. Lose Wi-Fi mid-session and be back in control within 3 seconds, without pairing again.
7. Reboot the Mac, log in once, and find the host reachable again without opening any app.

### In scope for v1

| Capability | What ships | Phase |
| --- | --- | --- |
| Video | One display at a time, up to 60 fps, HEVC with H.264 fallback, adaptive bitrate and resolution | 1, 5 |
| Pointer | Direct touch mode, trackpad mode, Magic Keyboard trackpad and mouse, scroll with momentum, locally drawn Mac cursor | 2, 6 |
| Keyboard | Hardware keyboard with physical key mapping, software keyboard, on-screen modifier bar, remaps for system-reserved shortcuts | 2, 6 |
| Connectivity | Bonjour on LAN, direct peer to peer over the internet, TURN relay fallback, automatic reconnect on network change | 1, 3, 4 |
| Accounts and pairing | Sign in with Apple, device registry, one-time pairing with key pinning, per-session end-to-end verification | 3 |
| Host reliability | Starts at login, stays reachable, survives network changes, works on the lock screen, guided permission setup | 4 |
| Comfort | Text clipboard sync, display picker for multi-monitor Macs, system audio | 5, 6 |
| Operations | Stats overlay, session metrics, signed auto-update for the host, TestFlight for the client | 7 |

### Out of scope for v1

| Item | Why | Revisit |
| --- | --- | --- |
| Mac controlling iPad | No public input injection API on iPadOS | Only if Apple opens it |
| Access before any user has logged in (login window after reboot) | Pre-login screen capture is unreliable on macOS 15 and later, see section 20 | Phase 8 spike |
| File transfer and drag and drop | Not needed for control; clipboard covers text | Phase 8 |
| Several viewers on one Mac, or several Macs at once | Adds session arbitration and UI | After v1 |
| iPhone and Mac client apps | Same shared package makes them cheap later | Phase 8 |
| HDR and 4:4:4 chroma | Needs hardware encoder checks per Mac model | Phase 8 spike |
| Virtual display that matches the iPad's shape | Only possible with private API today | Phase 8 |
| Windows or Linux hosts | The whole point is an Apple-native host | Not planned |

### Assumptions to confirm

Each of these changes the plan if it is wrong.

- [ ] Hosts are Apple silicon Macs on macOS 26 or later, and the iPad runs iPadOS 26 or later. This matches the Porthole project settings.
- [ ] The Mac stays logged in and awake. A sleeping or logged-out Mac is not reachable in v1.
- [ ] The host app ships outside the Mac App Store, signed with Developer ID and notarized.
- [ ] You have a paid Apple Developer account that can request managed entitlements.
- [ ] The backend is Laravel, since that is your strongest stack, with TURN from a managed provider at first.
- [ ] The RustDesk server you set up locally was an experiment, not a commitment. Section 4 explains why this plan does not build on it.

## 2. Requirements and performance targets

The product succeeds or fails on latency, so every target below is a number that Phase 0 measures and later phases must hold. Targets marked as starting points get tuned in Phase 5.

### Functional requirements

| ID | Requirement | Phase |
| --- | --- | --- |
| F1 | Discover Macs on the same network with Bonjour and connect without any server | 1 |
| F2 | Stream one selected Mac display to the iPad with hardware encode and decode | 1 |
| F3 | Send pointer, button, scroll, key and text input from the iPad and replay it on the Mac | 2 |
| F4 | Draw the Mac cursor on the iPad from shape and position data, not from video | 2 |
| F5 | Sign in, register devices, and list the account's Macs with online status | 3 |
| F6 | Connect across networks, direct when possible and relayed when not | 3 |
| F7 | Pair a Mac and an iPad once, in person, and pin each other's identity keys | 3 |
| F8 | Start the host at login, keep it reachable, and recover from network loss | 4 |
| F9 | Adapt bitrate, resolution and frame rate to the network without user action | 5 |
| F10 | Play the Mac's system audio on the iPad, with a mute toggle | 5 |
| F11 | Sync text clipboard in both directions | 6 |
| F12 | Switch between displays on a multi-monitor Mac during a session | 6 |
| F13 | Show a live stats overlay and record session quality metrics | 7 |

### Latency budget, glass to glass

This is the time from a pixel changing on the Mac to the same pixel changing on the iPad, at 60 fps capture and a 120 Hz iPad display.

| Stage | Runs on | Target (ms) | Ceiling (ms) | Main lever |
| --- | --- | --- | --- | --- |
| Mac glass to encoded bits | Mac | 9 | 15 | Shallow capture queue, hardware encoder in low-latency mode, no frame reordering, stream no larger than the iPad panel |
| Packetize and send | Mac | 1 | 2 | Paced sending, no batching |
| Network, one way | Path | 2 on LAN | Half the round trip | Direct path first, nearest relay second |
| Receive and jitter buffer | iPad | 2 | 15 | Minimum playout delay |
| Decode | iPad | 4 | 8 | Hardware decoder, asynchronous output |
| Render and wait for refresh | iPad | 4 | 8 | Present on the next 120 Hz refresh |
| **Total without network** |  | **20** | **48** |  |

Capture and encode share one row because they overlap. Spike S1 found that ScreenCaptureKit delivers each frame 7 to 13 ms before it reaches the Mac's glass, while the encoder alone takes 15 to 16 ms at iPad panel sizes on an M3 Pro. Measured from the glass, bits were ready in 4 to 5.5 ms at the median and 6 to 9 ms at p95 (`Docs/spikes/S1-capture-encode.md`).

The resulting session targets are:

- **LAN:** 40 ms or less glass to glass.
- **Internet:** one-way network delay plus 45 ms or less.
- **Click to visible result:** 70 ms or less on LAN. This adds the input uplink and one or two frames of app reaction on the Mac.
- **Pointer movement:** no perceived lag, because the iPad draws the cursor locally and the Mac only confirms position.

### Quality and reliability targets

| Measure | Target | Notes |
| --- | --- | --- |
| Frame rate during motion | 60 fps sustained | Drops to 30 fps only below about 4 Mbps |
| Frame rate when the screen is static | 0 fps sent | Idle frames are never encoded |
| Resolution | The smaller of the Mac display and the iPad panel, in pixels | Scales down in steps under bandwidth pressure |
| Bitrate on LAN | 20 to 40 Mbps | Starting point |
| Bitrate on good internet | 8 to 15 Mbps | Starting point |
| Bitrate floor | 1.5 Mbps | Below this the session shows a poor-connection banner |
| Text sharpness after motion stops | Crisp within 500 ms | Encoder refines quality on a static screen |
| Time to first frame | 1.5 s on LAN, 5 s over internet | Measured from tapping Connect |
| Recovery after network change | 3 s or less | Wi-Fi to cellular and back |
| Session length | 8 hours without restart | Memory stays flat |
| Host CPU while streaming | Under 10 percent of total | To validate in Phase 0 on your Macs |
| iPad thermal state | Stays at nominal or fair | Checked in soak tests |

### Non-functional requirements

- **Privacy:** screen content, keystrokes and clipboard data never touch the backend in readable form. Only the two paired devices hold session keys.
- **Security:** a compromised backend cannot start a session or read one. Section 14 sets out how.
- **Footprint:** no kernel extensions, no drivers, no private API in v1.
- **Operability:** the backend runs on one small server. The relay is the only part whose cost grows with usage.

## 3. System overview

Five parts cooperate: the iPad client, the Mac host, the account and signaling service, a STUN and TURN service, and one Swift package compiled into both apps. Video and input travel directly between the iPad and the Mac whenever a direct path exists. The backend only introduces the two devices to each other.

&#91;embedded content: architecture · two apps, relay and backend\]

The bold arrows are the direct path: video one way, input the other. The relay carries the same encrypted packets only when no direct path works, and the backend never carries media.

### Components

| Component | Runs on | Responsibility | Built with |
| --- | --- | --- | --- |
| Client app | iPad | Device list, pairing, decode, render, input capture, local cursor, stats overlay | SwiftUI shell, UIKit and Metal session view, VideoToolbox |
| Host app | Mac, in the user's login session | Capture, encode, input injection, cursor tracking, clipboard, permissions, pairing UI | AppKit menu bar app, ScreenCaptureKit, VideoToolbox, Core Graphics events |
| Shared package | Both apps | Wire protocol, transport, pairing crypto, key maps, coordinate math, stats | Swift 6.2 packages with tests that run on macOS |
| Account and signaling service | One small server | Sign-in, device registry, presence, relaying signaling messages, minting TURN credentials | Laravel, Reverb WebSockets, PostgreSQL, Redis |
| STUN | Managed or self-hosted | Tells each device its public address so they can connect directly | Cloudflare STUN or coturn |
| TURN relay | Managed or self-hosted | Carries encrypted media only when no direct path works | Cloudflare Realtime TURN or coturn |

### Three planes

- **Control plane.** HTTPS and one WebSocket per device to the backend. It carries sign-in, presence, signaling and relay credentials. Volume is a few kilobytes per session.
- **Media plane.** Encrypted video and audio from the Mac to the iPad over UDP, peer to peer or through the relay.
- **Input plane.** Encrypted data channels on the same UDP flow. Input goes from iPad to Mac. Cursor, clipboard and control messages go both ways.

### What happens when you tap Connect

1. The iPad asks the backend to ring the chosen Mac and receives short-lived relay credentials.
2. The backend pushes the ring to the Mac over the Mac's standing WebSocket.
3. The iPad creates a session offer, signs it with its device key, and sends it through the backend.
4. The Mac verifies the signature against the key it pinned at pairing, then answers with its own signed description.
5. Both sides trade network candidates and probe every path at once: same LAN, public addresses, and relay.
6. The best working path wins, an encrypted channel comes up, and both apps exchange capabilities.
7. The Mac starts capture and sends a key frame. The iPad renders it and starts sending input.

Section 12 covers each step in detail, and section 15 covers what happens when a step fails.

### Design rules

1. **The backend never sees content.** It relays opaque signaling and, at worst, encrypted packets.
2. **Native pipeline, replaceable transport.** Capture, encode, decode, render and input are our code. WebRTC sits behind one protocol and can be swapped later.
3. **One definition of the protocol.** Both apps import it from the shared package. Nothing is declared twice.
4. **The host is headless first.** Every host feature works with no window open and nobody at the Mac.
5. **The Mac is the authority.** Cursor position and display geometry come from the Mac. The iPad predicts and then corrects.
6. **Newest wins.** For anything continuous, such as pointer position or video frames, stale data is dropped and never queued.
7. **No private API in v1.** Anything that needs one is listed in Phase 8 with its risk.
8. **Every permission failure has a guided fix.** The host detects a missing grant and shows the exact System Settings pane.

## 4. Key decisions

Sixteen decisions shape everything else, and the first four carry most of the risk. Each one should become a short ADR in `Docs/adr`, in the same style as Porthole.

### Decision table

| # | Decision | Choice | Main reason |
| --- | --- | --- | --- |
| D1 | Network transport | WebRTC, behind a `SessionTransport` protocol | NAT traversal, encryption, congestion control and loss recovery already solved |
| D2 | Who owns the media pipeline | We do. WebRTC only moves packets | The stock Apple build has no HEVC encoder or decoder, and we need full control of latency settings |
| D3 | Codec | HEVC Main, 4:2:0, 8-bit. H.264 High as fallback | Better quality per bit, hardware support on every target device |
| D4 | RustDesk server as the backend | No | Foreign protocol, TCP-only relay, AGPL license |
| D5 | Backend stack | Laravel, Reverb, PostgreSQL, Redis | Your strongest stack. The service is small and low traffic |
| D6 | Relay | Cloudflare Realtime TURN first, coturn as the self-hosted option | Anycast edge near each device, no servers to run, generous free tier |
| D7 | Message encoding | Protocol Buffers on data channels, JSON for signaling | Schema evolution without breaking old clients |
| D8 | Trust model | Device keys in the Secure Enclave, pinned at pairing. The server is not trusted | A backend breach must not expose any Mac |
| D9 | Account sign-in | Sign in with Apple | Native on both platforms, no passwords to store |
| D10 | Host distribution | Developer ID and notarization, Sparkle for updates | Needs a background agent, synthetic input, and a managed entitlement |
| D11 | Client distribution | TestFlight, then App Store | Standard path. Generic remote desktop clients are allowed |
| D12 | Minimum OS | iPadOS 26 and macOS 26, Apple silicon hosts | Matches Porthole. Newest capture and encode APIs without availability checks |
| D13 | UI stack | SwiftUI for app chrome, UIKit and Metal for the session surface, AppKit for the host | The session view needs raw touches, key presses and pointer lock |
| D14 | Cursor | Drawn by the iPad from shape and position messages | Removes video latency from pointer feel |
| D15 | Project tooling | XcodeGen, local Swift packages, xcconfig, Makefile | Same conventions as Porthole |
| D16 | Screen capture entitlement | Request Persistent Content Capture from Apple in week 1 | Without it macOS asks to re-approve capture on a schedule, which breaks unattended use |

### D1. WebRTC as transport, hidden behind a protocol

WebRTC gives the project six hard things on day one: ICE path selection, a STUN and TURN client, DTLS and SRTP encryption, bandwidth estimation, retransmission of lost packets, and send pacing. Writing those well is more work than the rest of the product combined.

The cost is a large binary dependency with an Objective-C API. The plan contains that cost in one package. No other package imports WebRTC types.

| Alternative | Why not now |
| --- | --- |
| Custom protocol on Network.framework with QUIC datagrams | Fully native, but you write hole punching, congestion control and loss recovery yourself. Good candidate for a v2 transport behind the same protocol |
| VNC or Apple Screen Sharing protocol | Not built for 60 fps, and no NAT traversal |
| RustDesk protocol | See D4 |
| Tailscale or WireGuard as the only network layer | Solves reachability but not media transport. Still useful as a shortcut before Phase 3 |

### D2. We own capture, encode, decode and render

WebRTC accepts custom encoder and decoder factories, a custom capturer and a custom renderer. The plan uses all four.

- The prebuilt WebRTC package compiles HEVC negotiation and packetization, but ships no HEVC encoder or decoder for Apple platforms, according to the [stasel/WebRTC](https://github.com/stasel/WebRTC) readme. Our VideoToolbox codec fills that gap.
- Low-latency rate control, key frame policy and static-screen refinement need direct access to the compression session.
- If WebRTC is replaced later, the pipeline does not change.

### D3. HEVC first, H.264 as fallback

HEVC produces sharper text than H.264 at the same bitrate, which is what a desktop stream mostly shows. Apple's [low-latency conferencing sample](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing) accepts both codecs with low-latency rate control enabled.

H.264 stays as a negotiated fallback because its low-latency mode is older and better documented. AV1 is not chosen because hardware AV1 encoding is not something to rely on across Macs. 4:4:4 chroma and 10-bit are Phase 8 spikes.

### D4. Why not build on the RustDesk server

The local `rustdeskserver` compose file runs `hbbs` and `hbbr`. They are a working rendezvous and relay pair, but they are the wrong foundation for this product.

- **Protocol lock-in.** They speak RustDesk's own rendezvous protocol. Using them means implementing RustDesk's client protocol in Swift or embedding its Rust core, which defeats the Apple-native goal.
- **TCP relay.** `hbbr` relays over TCP, as your compose file notes. One lost packet stalls everything behind it, which shows up as stutter in real-time video.
- **License.** [rustdesk-server](https://github.com/rustdesk/rustdesk-server) is AGPL-3.0. That matters if you modify it or reuse its protocol definitions in a closed product. This is not legal advice, so get a proper opinion before building on it commercially.
- **No account model.** Accounts and device management are part of the paid Pro server.

Keep the local server for one job: install the RustDesk apps on the same Mac and iPad and use them as a latency and quality benchmark in Phase 5.

### D6. Managed relay first

A relay adds the least delay when it sits close to both devices. Cloudflare's [TURN service](https://developers.cloudflare.com/realtime/turn/) is anycast, so each device reaches a nearby edge. DigitalOcean's regions are in North America, Europe, Asia and Australia, so a droplet relay is a long detour when both devices are in Nigeria.

The backend hides the provider behind one endpoint that returns ICE servers. Switching to coturn later changes server config only. Section 13 has the cost comparison.

### Dependencies

| Dependency | Used for | License | Notes |
| --- | --- | --- | --- |
| [WebRTC XCFramework](https://github.com/stasel/WebRTC) | Transport | BSD 3-Clause | Swift Package, iOS 15 and macOS 12 or later, pin an exact milestone |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Message encoding | Apache 2.0 | Maintained by Apple |
| [Sparkle 2](https://sparkle-project.org) | Host auto-update | MIT | EdDSA-signed updates |
| Laravel and Reverb | Backend API and WebSockets | MIT |  |
| coturn | Optional self-hosted STUN and TURN | BSD 3-Clause | Only if you leave the managed relay |

Everything else comes from Apple frameworks.

## 5. Repository and shared packages

One repository holds both apps, twelve local Swift packages and the server, laid out like Porthole so the tooling carries over unchanged. The product needs a working name before the first commit. Record it as ADR 0002, as Porthole did.

### Layout

```text
<working-name>/
  Apps/
    Client/              iPad app target
    Host/                Mac app target (menu bar UI and agent mode)
  Packages/
    WireProtocol/        .proto files, generated Swift, versioning
    InputModel/          Key codes, modifiers, coordinate mapping
    MediaCore/           Frame types, NAL unit handling, clocks
    Pairing/             Identity keys, QR payload, signatures, trust store
    SecureStore/         Keychain and Secure Enclave wrapper (from Porthole)
    BackendClient/       REST client and signaling socket
    SessionTransport/    Transport protocol, WebRTC implementation, LAN signaling
    Telemetry/           Stats model, signposts, overlay data
    HostCapture/         macOS: ScreenCaptureKit, encoder, cursor tracker, audio tap
    HostInput/           macOS: event injection, clipboard
    ClientVideo/         iPadOS: decoder, Metal renderer
    ClientInput/         iPadOS: touch, pointer, keyboard, Pencil capture
  Server/
    api/                 Laravel app
    turn/                coturn config, only if self-hosting
    deploy/              Compose files and provisioning
  Docs/adr/
  Config/                Shared.xcconfig, Local.xcconfig.example
  Tools/                 Git hooks, latency rig, network shaping scripts
  project.yml
  Makefile
```

### Packages

| Package | Platforms | Depends on | Owns |
| --- | --- | --- | --- |
| `WireProtocol` | Both | swift-protobuf | Every message that crosses a data channel or the signaling socket, plus protocol version constants |
| `InputModel` | Both | None | HID usage to macOS virtual key table, modifier sets, view to display coordinate transforms |
| `MediaCore` | Both | None | `EncodedFrame`, codec identifiers, parameter set parsing, length-prefixed to Annex B conversion, clock offset estimation |
| `Pairing` | Both | `SecureStore` | Device identity keys, pairing payloads, session signature creation and checks, pinned peer store |
| `SecureStore` | Both | None | Keychain items and Secure Enclave keys |
| `BackendClient` | Both | `WireProtocol`, `Pairing` | Sign-in, device registry calls, ICE server fetch, signaling WebSocket with reconnect |
| `SessionTransport` | Both | WebRTC, `WireProtocol`, `MediaCore` | `SessionTransport` protocol, WebRTC adapter, Bonjour discovery and LAN signaling |
| `Telemetry` | Both | None | Stats snapshots, signposts, logging categories |
| `HostCapture` | macOS | `MediaCore` | Display enumeration, capture stream, hardware encoder, cursor tracker, system audio |
| `HostInput` | macOS | `InputModel` | CGEvent injection, stuck-key protection, clipboard access |
| `ClientVideo` | iPadOS | `MediaCore` | Hardware decoder, Metal renderer, frame pacing |
| `ClientInput` | iPadOS | `InputModel`, `WireProtocol` | Gesture recognizers, pointer and keyboard capture, software keyboard bridge |

### Package rules

1. **Only `SessionTransport` imports WebRTC.** It adapts `HostCapture` and `ClientVideo` to WebRTC's encoder, decoder, capturer and renderer interfaces. Those packages never see a WebRTC type.
2. **Pure-logic packages test on macOS.** `WireProtocol`, `InputModel`, `MediaCore`, `Pairing` and `BackendClient` have no UI or hardware dependency, so `swift test` covers them in seconds.
3. **Views call session objects, session objects call packages.** No view touches a socket, a codec or a key.
4. **The hot path avoids actor hops.** Capture, encode, send, receive, decode and render run on dedicated serial queues. Actors hold session state, not frames.
5. **Pixel buffers cross boundaries in a small `@unchecked Sendable` box.** That keeps Swift 6.2 strict concurrency on without copying frames.
6. **Generated code is committed.** `make proto` regenerates Swift from `.proto` files, and CI fails if the output differs.

### Tooling

| Item | Setting |
| --- | --- |
| Project generation | XcodeGen from `project.yml`, two app targets |
| Swift | 6.2, `SWIFT_STRICT_CONCURRENCY = complete` |
| Deployment targets | iPadOS 26.0, macOS 26.0 |
| Signing | Team and bundle identifiers in `Config/Local.xcconfig`, not committed |
| Make targets | `test`, `build-client`, `build-host`, `proto`, `hooks`, `server-up` |
| CI | Package tests and both app builds on every push. Hardware codec tests run on a self-hosted Mac, see section 17 |

## 6. Mac host app

The host is one menu bar app that launchd starts at login and restarts if it crashes. It holds the standing connection to the backend, captures the screen, replays input, and needs three macOS permissions to do so.

### Process model

V1 uses a single process, because macOS ties privacy grants to one code identity and a single process keeps that simple.

| Aspect | Design |
| --- | --- |
| Bundle | One app, one executable, `LSUIElement` set so there is no Dock icon |
| Launch | A LaunchAgent plist inside the bundle, registered with `SMAppService.agent(plistName:)` |
| Restart | `KeepAlive` with `SuccessfulExit` false, so launchd relaunches the app after a crash or a deliberate non-zero exit (the restart for a new permission), while Quit stays quit. `ThrottleInterval` 2 s |
| Session type | `LimitLoadToSessionType` set to `Aqua`, so it runs only inside a logged-in graphical session |
| Priority | `ProcessType` set to `Interactive`, plus a latency-critical activity during sessions to keep App Nap away |
| UI | Status item, onboarding window, pairing window and settings window, all in the same process |
| Second launch | Opening the app from Finder asks the running instance to show its window, then exits. The agent's environment marks the copy launchd runs; a copy opened another way registers the login item if needed, starts the agent with `launchctl kickstart`, and hands over |

A split into a UI app and a separate agent talking over XPC is deferred. It only becomes necessary if login-window access is added in Phase 8, because that needs a privileged helper.

### Permissions

| Permission | Needed for | How the app checks and asks | Takes effect |
| --- | --- | --- | --- |
| Screen and System Audio Recording | Capturing the display and audio | Ask with `CGRequestScreenCaptureAccess`. At launch, `CGPreflightScreenCaptureAccess` gives the status. While running, only ScreenCaptureKit is live: a display list fetch or a running stream fails with error −3801 once the grant is revoked. Both CG calls keep reporting the launch value (spike S6) | After the app restarts |
| Accessibility | Posting synthetic mouse and keyboard events | Ask with `AXIsProcessTrustedWithOptions`. `AXIsProcessTrusted` follows grants and revokes live. `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` keep their launch value, so they count only at launch (spike S6) | Immediately |
| Local Network | Bonjour advertising and LAN connections | First use of the listener triggers the prompt. Needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`. There is no status API: a Bonjour browser reports ready before any decision, so a denial shows only as failed connections (spike S6) | Immediately |
| Login item | Starting at login | `SMAppService` status. The user can switch it off in System Settings | Next login |
| Notifications, optional | Telling the person at the Mac that a session started | `UNUserNotificationCenter` | Immediately |

The onboarding window shows these as a checklist with live status. Each row has a button that opens the exact System Settings pane. After the screen recording grant, the app exits and launchd restarts it.

### The recurring capture prompt

This is the biggest operational risk for an unattended host, so it gets handled in week 1.

- Since macOS 15, the system periodically asks the user to re-approve apps that capture the screen without the system picker. TidBITS reported the interval as [monthly in macOS 15.0](https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/).
- Nobody is at an unattended Mac to click that prompt.
- Apple's [Persistent Content Capture entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture) exists for this class of app. It is available from macOS 14.4 and is granted through a request form.
- A developer testing a macOS 27 beta [reported](https://developer.apple.com/forums/thread/841530) a separate Remote Desktop entry in Privacy and Security for entitled apps. Apple has not documented it.

Phase 0 therefore does two things: submit the entitlement request, and record the real prompt behavior on the macOS versions you run, with and without the entitlement.

### Capture and input in one paragraph each

**Capture.** One `SCStream` per session captures the selected display at the negotiated size, without the cursor. Frames arrive as IOSurface-backed pixel buffers and go to the hardware encoder without a copy. When nothing on screen changes, no frame is encoded. Section 8 has every setting.

**Input.** Protocol events from the iPad become `CGEvent` objects posted at the HID event tap. The host tracks every key and button it has pressed, and releases them all if the session drops. Section 9 has the mapping rules.

### Staying reachable

| Situation | Behavior |
| --- | --- |
| Idle, setting Keep this Mac reachable is on | Hold a `PreventUserIdleSystemSleep` power assertion. The display may still sleep |
| Session starts | Wake the display with `IOPMAssertionDeclareUserActivity`, then hold `PreventUserIdleDisplaySleep` for the session |
| Session ends | Release assertions. If Lock when session ends is on, post Control Command Q to lock the screen |
| Mac is about to sleep | Close the session cleanly and tell the backend the Mac is going offline |
| Mac wakes | Reconnect the signaling socket at once |
| Network path changes | `NWPathMonitor` triggers a reconnect with backoff from 0.5 s to 30 s, with jitter |
| Quiet connection | WebSocket ping every 25 s. The backend marks the Mac offline after 60 s of silence |
| Laptop lid closes | The Mac sleeps unless it is on power with an external display. Public API cannot prevent this, so the app warns about it |

No public mechanism wakes a sleeping Mac from the internet. Wake for network access only works from the local network.

### Lock screen, login window and other users

- **Locked screen.** The host keeps running inside the locked session. Spike S5 measured this on macOS 26.0.1. The capture stream continued through lock and unlock at the full frame rate, with no restart, and showed the lock screen. Posted key codes and Unicode text both reached the password field. The login password typed by key code unlocked the Mac in about 1.2 s. Control-Command-Q locked it within 0.3 s. macOS shows its "screen is being observed" indicator on the lock screen during capture. macOS 27 is still to be checked with the same probe.
- **Login window after a reboot.** Out of scope for v1. No user session exists, so the agent is not running. An Apple forum thread on [pre-login capture](https://developer.apple.com/forums/thread/768146) shows no confirmed working approach on macOS 15.
- **FileVault.** After a reboot the disk stays locked until someone types the password at the Mac. For a planned restart, `sudo fdesetup authrestart` restarts once without that stop.
- **Fast user switching.** If another user becomes active, capture stops. The host reports that the Mac is in use by another user.

### Who may connect, and what the Mac shows

- Only devices whose keys were pinned at pairing can start a session. The backend cannot add one.
- **Unattended mode** is the default for your own devices. **Attended mode** requires a click on the Mac for each session.
- One session at a time. A second paired device gets a busy reply with a Take over option.
- While controlled, the status item changes appearance and shows the iPad's name. macOS also shows its own screen capture indicator.
- The menu has a Disconnect item, and a global shortcut ends the session from the Mac's keyboard.
- Local keyboard and mouse stay active. Public API cannot block them reliably, so v1 does not try.

### Menu bar contents

| Item | Purpose |
| --- | --- |
| Status line | Reachable, offline, or in session with device name, path type and bitrate |
| Pair new device | Shows the pairing QR code |
| Paired devices | List with last used time and a Revoke button |
| Permissions | Reopens the checklist |
| Settings | Start at login, keep reachable, lock on disconnect, attended mode, default display, quality cap |
| Check for updates | Sparkle |
| Quit | Stops the agent until next login |

### Development notes

- Privacy grants follow the code signature. Sign debug builds with a stable development certificate and bundle identifier, or every build loses its grants.
- `tccutil reset ScreenCapture <bundle id>` and `tccutil reset Accessibility <bundle id>` clear grants when testing onboarding.
- System Settings panes for the guided fixes, confirmed on macOS 26 in spike S6:
  - Screen Recording: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
  - Accessibility: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  - Local Network: `x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`
  - Login Items: `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
- On startup the host posts key-up events for all modifiers, in case a previous crash left one held down.

## 7. iPad client app

The client is a SwiftUI app with one UIKit and Metal view at its center: the session surface that shows the Mac and captures every kind of input an iPad offers. Everything outside that surface is ordinary list and form UI.

### Screens

| Screen | Contents | Built with |
| --- | --- | --- |
| Welcome | Sign in with Apple, privacy summary | SwiftUI |
| Devices | Macs on this network (Bonjour), Macs on the account with online status, last connected time | SwiftUI |
| Pair a Mac | QR scanner, manual code entry, confirmation of the Mac's name and key fingerprint | SwiftUI, AVFoundation camera |
| Session | Video surface, floating toolbar, stats overlay, connection banners | UIKit view controller, Metal layer, SwiftUI overlays |
| Settings | Input mode defaults, scroll direction, quality preference, cellular limits, app lock, key remaps | SwiftUI |
| Connect by address | Host name or IP entry for VPN use without the backend | SwiftUI |

### Session view controller

The session screen is a `UIViewController` because it needs behavior that SwiftUI does not expose well.

| Need | UIKit mechanism |
| --- | --- |
| Raw touches with type, force and timestamp | `touchesBegan` family on a custom `UIView` |
| Hardware key down and up | `pressesBegan` and `pressesEnded` with `UIKey`, plus `GCKeyboard` |
| Pointer position from trackpad or mouse | `UIHoverGestureRecognizer` and indirect pointer touches |
| Hiding the iPadOS pointer over the video | `UIPointerInteraction` with a hidden pointer style |
| Relative mouse movement | `prefersPointerLocked` with `GCMouse` deltas |
| Fewer accidental system gestures | `preferredScreenEdgesDeferringSystemGestures` set to all edges |
| Full screen | Hidden status bar and auto-hidden home indicator |
| Screen stays on | Idle timer disabled during a session |

### Viewport

- **Fit** shows the whole Mac display with letterboxing. This is the default.
- **Fill** crops to the iPad's aspect ratio and pans to follow the cursor near the edges.
- **Actual size** maps one Mac pixel to one iPad pixel.
- Pinch zooms up to 4x and two fingers pan while zoomed. Zoom is local to the iPad and costs no bandwidth.
- The stream size follows the viewport. Zooming in past 1.5x asks the host for a higher resolution if the network allows.

### Floating toolbar

A small pill that collapses to a handle and can be dragged to any edge.

| Control | Function |
| --- | --- |
| Keyboard | Shows or hides the software keyboard |
| Modifiers | Sticky Command, Option, Control, Shift and Fn. Tap once for the next key, double tap to lock |
| Keys | Escape, Tab, arrows, forward delete, F1 to F12 |
| Shortcuts | Mission Control, Spotlight, app switcher, lock screen, screenshot, force quit |
| Input mode | Direct touch or trackpad |
| Display | Picks which Mac display to show |
| Quality | Sharper, balanced, or smoother, plus a data saver switch |
| Stats | Toggles the overlay |
| Disconnect | Ends the session |

### App lifecycle

iPadOS suspends background apps within seconds, so the session cannot survive in the background. The design makes leaving and returning cheap instead.

| Scene state | Client behavior |
| --- | --- |
| Active | Streaming and sending input |
| Inactive, for example Control Center is open | Stream continues. All held keys and buttons are released on the Mac |
| Background | Request a few seconds of background time, send a pause message, release keys, close the transport, keep a resume token |
| Back to active | Reconnect with the resume token. Target is under 2 s on the same network |
| Terminated | Normal cold connect next time |

Split View and Stage Manager windows work normally while visible. Pointer lock is only honored when the scene is full screen, so the app falls back to absolute pointer mode otherwise.

### Device conditions

| Condition | Signal | Response |
| --- | --- | --- |
| ProMotion display | 120 Hz available | Render loop asks for 120 Hz so a decoded frame waits at most 8.3 ms |
| Cellular or Low Data Mode | `NWPath` reports expensive or constrained | Cap bitrate at 4 Mbps unless the user lifts the limit |
| Heat | Thermal state serious or critical | Ask the host for 30 fps and one resolution step down |
| Low Power Mode | Process info flag | Same as heat |
| Hardware keyboard attached | `GCKeyboard.coalesced` is not nil | Hide the software keyboard bar |

### Privacy on the device

- Face ID or Touch ID gates the device list. Porthole's `AppLock` carries over.
- A privacy cover replaces the session view in the app switcher, so no Mac screenshot is stored by iPadOS.
- Pinned keys and tokens live in the Keychain, marked as this-device-only.

### Info.plist entries

| Key | Reason |
| --- | --- |
| `NSLocalNetworkUsageDescription` | LAN discovery and direct LAN connections |
| `NSBonjourServices` | The product's service type, for example `_<name>._tcp` |
| `NSCameraUsageDescription` | Scanning the pairing QR code |
| `NSFaceIDUsageDescription` | App lock |
| `UIRequiresFullScreen` set to false | Allow Split View and Stage Manager |
| `UIApplicationSupportsIndirectInputEvents` set to true | Receive trackpad and mouse as indirect pointer events |
| `ITSAppUsesNonExemptEncryption` | Set only after the export compliance check in section 18 |

### Error messages

Each failure state gets a specific message and one action.

| State | Message | Action |
| --- | --- | --- |
| Mac offline | The Mac is asleep, off, or not signed in | Retry |
| Permission missing on the Mac | The Mac needs screen recording or accessibility access | Shows which one |
| Busy | Another device is controlling this Mac | Take over |
| Version mismatch | The Mac's app is too old or too new | Update prompt |
| Not paired | This iPad is not trusted by that Mac | Pair |
| Relay only and poor | Connection is relayed and slow | Lower quality |

VoiceOver labels cover all chrome. The video surface itself is not accessible to VoiceOver in v1.

## 8. Media pipeline in depth

A frame passes through nine stages between the Mac's compositor and the iPad's display, and the pipeline never copies pixels on the CPU and never queues more than one frame at any stage. Every setting below is a starting value to confirm in Phase 0 and tune in Phase 5.

### Stages

1. **Capture.** ScreenCaptureKit delivers a pixel buffer when the display changes.
2. **Gate.** The host drops idle frames and keeps only the newest frame if the encoder is busy.
3. **Encode.** VideoToolbox compresses the buffer in hardware with low-latency rate control.
4. **Package.** The host converts the output to the byte format the transport expects and adds parameter sets to key frames.
5. **Send.** WebRTC packetizes, paces, encrypts and sends over UDP.
6. **Receive.** WebRTC reorders packets, requests retransmission of gaps, and hands over a complete frame.
7. **Decode.** VideoToolbox decodes in hardware to a Metal-compatible pixel buffer.
8. **Render.** A Metal pass converts to RGB, applies zoom and pan, and draws the cursor on top.
9. **Present.** The frame goes out on the next display refresh.

### Capture settings

These are properties of [`SCStreamConfiguration`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration).

| Property | Value | Why |
| --- | --- | --- |
| `width`, `height` | Negotiated stream size in pixels, even numbers | The capture system scales on the GPU, so the encoder gets the final size |
| `minimumFrameInterval` | 0.9 × 1/60 s | Caps capture at 60 fps. At exactly 1/60 s, vsync jitter on a 60 Hz display drops about 2 frames a second (spike S1) |
| `pixelFormat` | 8-bit 4:2:0 biplanar, video range | The encoder's native input. No color conversion pass |
| `colorSpaceName` | sRGB | One known color space end to end in v1 |
| `colorMatrix` | ITU-R BT.709 | Matches what the decoder and shader assume |
| `queueDepth` | 3 | Shallow queue. Fewer buffered frames means less latency |
| `showsCursor` | false | The iPad draws the cursor itself |
| `scalesToFit` | true | Fill the requested size |
| `preservesAspectRatio` | true | Never stretch |
| `captureResolution` | Best | Capture at full pixel density, then scale |
| `shouldBeOpaque` | true | No alpha channel to carry |
| `capturesAudio` | true when audio is on | System audio arrives from the same stream |
| `sampleRate`, `channelCount` | 48000, 2 | Matches Opus |
| `excludesCurrentProcessAudio` | true | The host's own sounds stay out |
| `captureDynamicRange` | SDR | HDR is a Phase 8 item |
| `showMouseClicks` | false | No click rings in the stream |

The content filter selects one display and excludes nothing. Changing display or size calls `updateContentFilter` or `updateConfiguration` on the running stream.

### Frame gating rules

- Read the frame status from the sample buffer attachments. Encode only complete frames.
- An idle status means nothing changed. Send nothing.
- If a new frame arrives while the encoder is still working, replace the waiting frame. The waiting slot holds one frame, never a queue.
- Take the capture timestamp from the frame's display time and carry it with the frame for latency measurement.
- Use the dirty rectangles only as a signal, for example to tell typing from video playback. The encoder still gets the whole frame.
- Release each surface as soon as the encoder has it, so the capture queue never fills.

### Encoder settings

The session is created with `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` set to true. Apple describes this mode in its [WWDC21 low-latency session](https://developer.apple.com/videos/play/wwdc2021/10158/): one frame in, one frame out, no reordering, faster rate adaptation, and always a hardware encoder.

| Setting | Value | Why |
| --- | --- | --- |
| Codec | HEVC, or H.264 when negotiated | See decision D3 |
| Preset | Start from the video conferencing preset, then override | Apple's current sample reads the encoder's supported presets and applies that one |
| `RealTime` | true | Live encoding |
| `ExpectedFrameRate` | 60 | A hint for rate control |
| `ProfileLevel` | HEVC Main auto level, or H.264 High auto level | Widest hardware decode support |
| `AverageBitRate` | The live target from bandwidth estimation | Updated whenever the estimate moves |
| `AllowFrameReordering` | false | No B-frames, so no added delay |
| `MaxKeyFrameInterval` | Very large | Key frames happen on request, never on a timer |
| `MaxAllowedFrameQP` | About 40 | Keeps text readable. The encoder drops frames before it smears them |
| Color tags | BT.709 primaries, transfer and matrix | Correct colors on the iPad |
| Force key frame, per frame | Set when a key frame is requested | Recovery and session start |

Apple's sample notes that different encoders accept different properties. Treat a failed property as a warning unless the session cannot work without it. If HEVC low-latency creation fails on a given Mac, renegotiate to H.264.

### Packaging the bitstream

- VideoToolbox emits NAL units with a 4-byte length prefix and keeps parameter sets in the format description.
- The transport expects Annex B start codes, with VPS, SPS and PPS in front of every key frame.
- `MediaCore` converts in both directions and has tests with recorded streams.
- The receiver rebuilds a format description from the parameter sets and recreates the decoder when they change.

### Key frame policy

A key frame is many times larger than a normal frame and causes a visible delay spike, so the host sends one only when needed.

| Trigger | Action |
| --- | --- |
| Session start or resume | One key frame |
| Resolution or codec change | New encoder session, one key frame |
| Receiver reports an unrecoverable gap | One key frame, at most one every 300 ms |
| Network path restarted | One key frame |
| Timer | Never |

### Adaptation ladder

WebRTC's bandwidth estimate feeds the encoder's bitrate directly. When bitrate alone is not enough, the host moves between these rungs.

| Rung | Long edge (px) | Frame rate | HEVC bitrate window (Mbps) |
| --- | --- | --- | --- |
| 5 | The smaller of the Mac display and the iPad panel, capped at 2752 | 60 | 20 to 40 |
| 4 | 2560 | 60 | 10 to 20 |
| 3 | 1920 | 60 | 5 to 10 |
| 2 | 1600 | 60, then 30 | 3 to 5 |
| 1 | 1280 | 30 | 1.5 to 3 |
| 0 | 960 | 15 to 30 | Below 1.5 |

- **Step down** when the estimate stays under the rung's floor for 2 s, or the average quantizer stays above the cap for 2 s.
- **Step up** when the estimate stays 20 percent above the next rung's floor for 10 s.
- **Order of sacrifice** for desktop work: bitrate first, then frame rate from 60 to 30, then resolution. The Smoother preference reverses the last two.
- A resolution change costs a key frame, which is why stepping up is slow and stepping down is fast.
- H.264 uses the same rungs with about 40 percent more bitrate.
- Rung 5 stops at 2752 px, the long edge of a 13-inch iPad Pro panel, because encode time grows with pixel count. On an M3 Pro, a 3840×2160 stream reaches only 45 fps, and 2752×2064 holds 60 fps with no headroom (spike S1). When rung 5 is smaller than 2560, rung 4 is skipped.

### Loss recovery

| Layer | Mechanism | Phase |
| --- | --- | --- |
| 1 | Retransmission of lost packets on request. Works well when round trip is under about 100 ms | 1 |
| 2 | Key frame request when a frame cannot be completed in time | 1 |
| 3 | If nothing decodes for 300 ms the iPad asks again. After 1 s it shows a reconnecting hint over the last good frame | 4 |
| 4 | Long-term reference frames, so the encoder answers loss with a small frame instead of a key frame | 5, experiment |
| 5 | Forward error correction | Not planned. Support for these codecs in the transport is limited |

Long-term reference needs acknowledgements from the iPad on the control channel. Apple documents the mechanism for H.264 in the WWDC21 session. HEVC support must be checked on your hardware.

### Static screen refinement

When motion stops, the last frame sent may be soft because it was encoded under pressure. The host then feeds the same pixel buffer to the encoder a few more times, about 100 ms apart, until the reported quantizer falls below a threshold. Text turns crisp within the 500 ms target, and then the stream goes silent.

### Decoder settings

| Setting | Value | Why |
| --- | --- | --- |
| Format description | Built from received parameter sets | Standard VideoToolbox setup |
| Output pixel format | 8-bit 4:2:0 biplanar, video range | Matches the encoder, cheap to sample in Metal |
| Metal compatibility | Requested in the buffer attributes | Zero-copy textures |
| Decode flags | Asynchronous decompression | Does not block the network thread |
| `RealTime` | true | Prioritizes latency |
| On bad data error | Request a key frame | Recovery |
| On invalid session, for example after returning from background | Recreate the session | iPadOS reclaims decoders |

### Renderer

- A texture cache wraps the decoded buffer's two planes as Metal textures without copying.
- The fragment shader converts YCbCr to RGB with the BT.709 video-range matrix.
- The vertex stage applies the viewport transform for fit, fill, zoom and pan.
- The cursor is a second textured quad drawn in the same pass at the predicted position. It moves at display rate even when video is at 0 fps.
- The Metal layer keeps two drawables and presents without waiting on Core Animation transactions.
- A display link asks for 120 Hz. Each tick draws the newest decoded frame, or only the cursor if no new frame arrived, or nothing if neither changed.
- The display link sets the pace. The render loop never waits in `nextDrawable`: if no drawable is free on a tick, it skips that tick, and the newest frame is drawn on the next one. In the S1 loopback, a renderer that blocked on `nextDrawable` with two drawables waited 10 to 26 ms per frame.
- Scaling uses linear filtering by default. A sharper filter for zoomed text is a Phase 6 polish item.

Phase 1 can use WebRTC's stock Metal view to get pixels on screen. Phase 2 replaces it with this renderer, because the cursor and zoom need it.

### Transport settings that affect media

| Setting | Value | Why |
| --- | --- | --- |
| Video source mode | Screencast | Tells the stack this is screen content |
| Degradation preference | Disabled | The ladder above decides, not the stack |
| Playout delay | Zero: min 0 ms, max 0 ms. Set with the field trial `WebRTC-ForceSendPlayoutDelay` on the host and `WebRTC-ForcePlayoutDelay` on the client, before the peer connection factory is created | Frames render on arrival. The Objective-C API has no receiver delay setting. In spike S3, either trial cut the jitter buffer from 22 ms to under 1 ms on Wi-Fi; setting both covers a peer built without one. Phase 5 decides whether lossy networks need a small non-zero maximum |
| Audio and video stream grouping | Separate stream identifiers | Stops lip-sync logic from delaying video to match audio |
| Simulcast | Off | One viewer, one stream |
| Per-rung maximum bitrate | Set on the sender | Keeps the estimator inside the rung |

### Measuring frame age

The host sends a small message once a second that pairs a media timestamp with its own monotonic clock. The two devices estimate clock offset from ping and pong on the control channel. The iPad can then compute, for every frame, the time from capture to present. That number drives the stats overlay and the Phase 5 tuning.

### Color

V1 is sRGB, BT.709, 8-bit SDR at every stage. Mac displays are wider than sRGB, so very saturated colors are clipped slightly. Display P3 and 10-bit are Phase 8 items and need Main 10 on both ends.

## 9. Input pipeline in depth

The iPad sends physical events, meaning which key, which button and where, and the Mac replays them with `CGEvent`. Keys, buttons and scroll travel on a reliable channel. Pointer movement travels on an unreliable channel where the newest position wins.

### Event model

| Event | Main fields | Channel | Replayed on the Mac as |
| --- | --- | --- | --- |
| Pointer move | Normalized x and y, display, held buttons, sequence | Unreliable | Mouse moved, or mouse dragged if a button is held |
| Pointer delta | dx, dy | Unreliable | Mouse moved with delta fields, for pointer-lock mode |
| Button | Which button, down or up, click count, position | Reliable | Mouse down or up with the click state set |
| Scroll | dx, dy in points, gesture phase, momentum phase, continuous flag | Reliable | Scroll wheel event in pixel units with phases |
| Key | HID usage code, down or up, full modifier set | Reliable | Keyboard event with the mapped virtual key and flags |
| Text | UTF-8 string | Reliable | Keyboard event carrying a Unicode string |
| Release all | None | Reliable | Key up and button up for everything held |
| Input heartbeat | Sequence | Unreliable | Nothing. Proves the iPad is still there |
| Tablet sample | Pressure, tilt, hover distance | Unreliable | Mouse event with tablet fields, Phase 6 experiment |

Every event the host posts carries the host's tag in the event source user data field. The tag reaches apps on every event (spike S2), so the host can tell its own input from a person at the Mac. That is how it decides when to report cursor position and when to show attended-mode notices.

### Coordinate mapping

1. The iPad converts a touch point to a position inside the video content by undoing zoom, pan and letterboxing.
2. It normalizes that position to the range 0 to 1 on each axis and clamps it.
3. The Mac multiplies by the selected display's bounds in points and adds the display's origin in the global coordinate space.
4. The Mac posts the event, then reads back the real cursor location.

Core Graphics events use points, not pixels, so Retina scale never enters the math. `InputModel` owns these transforms and tests them with round-trip property tests across zoom levels and display layouts.

### Touch gestures in direct touch mode

The finger acts where it touches.

| Gesture | Mac action |
| --- | --- |
| Tap | Move there and left click |
| Double tap | Double click |
| One-finger drag | Move the pointer without a button |
| Long press, then drag | Left button drag, for selecting and moving |
| Long press, then lift | Right click |
| Two-finger tap | Right click |
| Two-finger drag | Scroll, with momentum |
| Pinch | Zoom the iPad's viewport. Nothing is sent |
| Three-finger swipe up | Mission Control, sent as Control Up |
| Three-finger swipe left or right | Switch Spaces, sent as Control Left or Right |
| Three-finger tap | Show or hide the toolbar |

### Touch gestures in trackpad mode

The whole screen behaves like a laptop trackpad.

| Gesture | Mac action |
| --- | --- |
| One-finger drag | Move the cursor relatively, with an acceleration curve |
| Tap | Left click at the cursor |
| Two-finger tap | Right click |
| Two-finger drag | Scroll |
| Double tap and hold, then drag | Left button drag |
| Pinch | Zoom the viewport |

### Hardware pointer and Pencil

| Device | Capture on iPad | Behavior |
| --- | --- | --- |
| Magic Keyboard trackpad or mouse | Hover recognizer for position, button mask for primary and secondary click | Absolute pointer. The iPadOS pointer is hidden over the video |
| Trackpad scroll | Pan recognizer accepting continuous scroll, plus the GameController scroll stream | Gesture deltas and phases pass through. UIKit's pan ends at finger lift with no momentum phase, so the iPad synthesizes momentum from the release velocity and sends it with momentum phases, using the same model as two-finger touch scrolling. Decided in Phase 2: GameController's scroll stream keeps reporting after the lift (spike S7) but carries no phases and its units would need calibrating against UIKit's |
| Mouse wheel | Pan recognizer accepting discrete scroll | Sent as line-based scroll |
| Pointer lock | `prefersPointerLocked` with `GCMouse` deltas | Relative movement for apps that grab the mouse. Full screen only |
| Apple Pencil | Touches of type pencil, plus hover on supported iPads | Tap clicks, drag presses the left button at once, hover moves the pointer |
| Pencil pressure and tilt | Force and angle from each touch | Phase 6 experiment using tablet fields on mouse events |

### Local cursor prediction

The pointer feels instant because the iPad does not wait for the Mac.

1. On local input, the iPad moves its drawn cursor immediately and sends the move with a sequence number.
2. The Mac posts the event and reads the real cursor location.
3. The Mac reports cursor position only when something else moved it, such as an app warping it or a person at the Mac. Each report echoes the last input sequence it processed.
4. The iPad ignores reports older than its own newest move and snaps to the Mac's position if a difference persists for 100 ms.

Pointer moves are coalesced to one per display refresh, at most 120 per second. That is under 60 kbit/s.

### Keyboard: physical keys

- The iPad reads hardware keys as HID usage codes from `UIKey` and `GCKeyboard`.
- `InputModel` maps each usage code to a macOS virtual key code. The Mac's active keyboard layout then decides the character.
- Mac shortcuts therefore work exactly as on a keyboard plugged into the Mac.
- Every key event carries the full modifier set. The iPad builds that set from the modifier keys it has seen go down, not from each event's own flags: in spike S7, Command period arrived with no Command flag although Command was held. The Mac compares the set with its own record and corrects any drift.
- A setting named Type what I see sends printable keys as text events instead, for people whose iPad and Mac layouts differ.
- The host never posts Caps Lock. A synthetic Caps Lock reaches apps as a flags change but does not toggle the Mac's lock state (spike S2). While the iPad's Caps Lock is on, the host adds Shift to letter keys instead and leaves the Mac's own Caps Lock state alone.

### Keyboard: repeat

macOS does not auto-repeat synthetic key events, so the host generates repeats itself.

- The host starts a timer on key down, using the Mac's own repeat delay and interval settings.
- Repeats stop on key up, on release-all, or when no heartbeat has arrived from the iPad for 300 ms.
- The heartbeat rule prevents a runaway repeat when the network stalls with a key held.
- A stall only pauses the repeat: if the key is still held when the iPad is heard again, repeats carry on at the repeat interval.

Phase 0 spike S2 confirms the no-repeat behavior before this is built.

### Keyboard: shortcuts iPadOS keeps for itself

iPadOS handles some shortcuts before any app sees them. Spike S7 measured these on iPadOS 27.2 with the Magic Keyboard for iPad Pro.

| What happens | Shortcuts |
| --- | --- |
| Swallowed: the modifiers arrive, the main key never does | Command `, Command Space, Command Option D, Command Shift 3, Globe A, and likely Control with the arrow keys |
| Takes the app out of the foreground | Command Tab, Command H, Command Q, Command Shift 4, Globe alone, Globe C, Globe H |
| Reaches the app | Letters, arrows, Escape, Caps Lock, Command C, V, Z and W, Command Shift H, Command Option Escape, Option Tab, Option Space, Control Space |

The Globe key never reaches an app as a modifier, so the toolbar's sticky Fn is the way to send Fn to the Mac.

| Workaround | Detail |
| --- | --- |
| Remap table, editable | Option Tab sends Command Tab. Option Space sends Command Space. Option ` sends Command `. S7 confirmed the Option combinations reach the app |
| Toolbar shortcuts menu | Mission Control, Spotlight, app switcher, show Dock, lock, screenshot, screenshot of a selection, force quit |
| Sticky modifiers | Tap Command on the toolbar, then press Tab on the keyboard |

### Keyboard: software keyboard and text

- A hidden text input responder receives typed text, dictation and input-method output, with autocorrect, smart punctuation and capitalization off.
- Committed text goes out as text events. Backspace and Return go out as key events.
- The Mac injects text by attaching a Unicode string to a keyboard event, in small chunks.
- Where a character exists on the Mac's layout, the host can send real key codes instead. That path is preferred for the lock screen password field, and spike S5 tests it.

### Replay rules on the Mac

| Topic | Rule |
| --- | --- |
| Event source | A HID-state event source with the local-event suppression interval set to zero, so the Mac's own keyboard and mouse keep working |
| Tap location | The HID event tap |
| Moves with a button down | Posted as dragged events, or apps will not see a drag |
| Double click | Second down and up carry click state 2, within the system double-click interval |
| Trackpad scroll | Pixel units, continuous flag set, gesture and momentum phases copied from the iPad |
| Modifiers | Posted as key events for the modifier keys, which generate the flags-changed events apps expect |
| Ordering | One serial queue posts events in arrival order |
| Stuck keys | The host tracks everything held and releases it on disconnect, pause, client inactive, or missing heartbeat |
| Display asleep | The first input declares user activity, which wakes the display |
| Multi-touch gestures | No public API can synthesize pinch, rotate or multi-finger swipes. They are mapped to keyboard shortcuts instead |
| Media and brightness keys | Not in v1. Function keys and shortcuts cover the need |

### Input latency target

From the iPad's event timestamp to the event being posted on the Mac: one-way network delay plus 3 ms or less. The stats overlay shows this number live.

## 10. Secondary channels: cursor, audio, clipboard, displays

Four smaller data flows make the session feel like sitting at the Mac: the cursor's shape and position, system audio, the text clipboard, and the list of displays. Each has one platform limit worth knowing before building it.

### Cursor

| Aspect | Design |
| --- | --- |
| Shape source | Poll `NSCursor.currentSystem` about 30 times a second, and right after posting input |
| Shape cache | Hash the image and hot spot. Send each new shape once on the reliable control channel, then refer to it by id |
| Shape message | Id, image at 2x, size, hot spot, scale |
| Visibility | Sent when the system cursor hides or shows, for example during typing or video playback |
| Position | Mac to iPad on the unreliable cursor channel, up to 60 times a second, only when something other than this iPad moved it |
| Fallback | If shape tracking fails, capture switches to include the cursor in the video and the iPad stops drawing its own |

A normal desktop session uses a small set of distinct cursor shapes, so the cache stays tiny.

### Audio

| Aspect | Design |
| --- | --- |
| Capture | The same `SCStream` delivers system audio as 48 kHz stereo PCM |
| Preferred send path | A custom audio device module feeds the PCM into WebRTC's audio track. The Objective-C SDK defines an [`RTCAudioDevice`](https://webrtc.googlesource.com/src/+/main/sdk/objc/components/audio/RTCAudioDevice.h) protocol for this |
| Codec | Opus, mono, 64 to 96 kbit/s. The custom audio device path records mono only (spike S4) |
| Fallback send path | Encode Opus with AudioToolbox and send packets on an unreliable data channel, with a small jitter buffer and `AVAudioEngine` playback on the iPad. This is the route to stereo, a Phase 5 option alongside a patched audio device module |
| Playback | Playback audio session category on the iPad, with a mute button in the toolbar |
| Sync | Audio is not synchronized with video, so it can never hold video back |
| Latency target | 120 ms or less in v1, with 100 ms as the Phase 5 goal. Spike S4 measured about 107 ms to the iPad's speaker; most of it is ScreenCaptureKit's audio buffering (about 40 ms) and WebRTC's audio jitter buffer (50 to 70 ms) |

Spike S4 chose the preferred send path for v1, in mono. The macOS headers omit `RTCAudioDevice.h`, so `SessionTransport` re-declares the protocol in a small Objective-C target. Two limits apply to v1:

- The Mac keeps playing sound through its own speakers. Silencing it during a session needs either a volume change that may also affect captured audio, or a virtual audio device. This is an open question for Phase 5.
- Sending the iPad's microphone to the Mac needs a virtual input device on the Mac. It is out of scope.

### Clipboard

Text sync works in both directions, but iPadOS privacy rules make the two directions behave differently.

| Direction | Trigger | Detail |
| --- | --- | --- |
| Mac to iPad | Automatic | The host polls `NSPasteboard` change count every 500 ms during a session. Writing to the iPad pasteboard needs no permission |
| iPad to Mac | On demand | Reading the iPad pasteboard in code can show a paste permission prompt, so the app only reads when the user pastes |

The iPad to Mac flow on Command V:

1. The iPad checks whether its pasteboard changed since the last sync, using the change count and content-type checks that do not prompt.
2. If it changed, the iPad reads the text and sends it on the control channel.
3. The Mac writes it to its pasteboard and acknowledges.
4. The iPad forwards the Command V key event. If no acknowledgement arrives within 150 ms, it forwards anyway.

Other rules:

- A Paste to Mac toolbar button uses the system paste control, which never prompts.
- The host skips pasteboard items marked concealed or transient, which is how password managers flag secrets.
- Each side remembers a hash of the last content it received, so a synced value never echoes back.
- Text is capped at 1 MB. Images and files wait for Phase 8.
- Clipboard content only ever travels on the end-to-end encrypted control channel.

### Displays

| Aspect | Design |
| --- | --- |
| Display list | Sent on connect and whenever the Mac's display configuration changes |
| Per display | Id, name, pixel size, point size, scale, origin in the global space, main flag, built-in flag, refresh rate |
| Switching | The iPad picks one. The host updates the capture filter and sends a key frame. Target is under 500 ms |
| Coordinate space | Input mapping uses the selected display's origin and bounds |
| Match iPad shape, optional | The host can switch the Mac display to its closest-aspect mode for the session using public display mode APIs, and restores it afterward |
| Mode restore safety | The original mode is saved to disk before switching and restored at next launch if the host crashed |

Two limits:

- **Headless Macs.** A Mac with no monitor may expose only a low-resolution default display. Test this on your hardware in Phase 4. An HDMI dummy plug is the reliable fix.
- **True virtual displays.** Creating a display that exactly matches the iPad needs private API. It is a Phase 8 item for Developer ID builds only.

### Control messages

The control channel also carries the session's housekeeping.

| Message | Direction | Purpose |
| --- | --- | --- |
| Hello and hello acknowledgement | Both | Versions, capabilities, identity proof |
| Stream config and applied config | iPad asks, Mac decides | Display, size, frame rate, quality preference |
| Ping and pong | Both, every second | Round trip time and clock offset |
| Clock map | Mac to iPad, every second | Pairs a media timestamp with the Mac's clock |
| Stats report | Both, every second | Each side's pipeline numbers for the overlay |
| Key frame request | iPad to Mac | Backup path beside the transport's own request |
| Pause and resume | iPad to Mac | App leaving and returning to the foreground |
| Notice | Mac to iPad | Permission lost, display asleep, local user took over, Mac going to sleep |
| Bye | Both | Clean end with a reason code |

## 11. Wire protocol

A session is one encrypted connection that carries two media tracks and four data channels. Every data channel message is a Protocol Buffers envelope defined once in `WireProtocol`. Signaling messages are signed JSON.

### Channels

| Channel | Kind | Delivery | Direction | Carries |
| --- | --- | --- | --- | --- |
| Video | Media track | Real-time with retransmission | Mac to iPad | HEVC or H.264 |
| Audio | Media track | Real-time | Mac to iPad | Opus |
| `control`, id 0 | Data channel | Reliable, ordered | Both | Hello, config, displays, cursor shapes, clipboard, stats, notices, ping |
| `input`, id 1 | Data channel | Reliable, ordered | iPad to Mac | Keys, buttons, scroll, text, release-all |
| `pointer`, id 2 | Data channel | Unreliable, unordered, no retransmits | iPad to Mac | Pointer moves, tablet samples, heartbeat |
| `cursor`, id 3 | Data channel | Unreliable, unordered, no retransmits | Mac to iPad | Cursor position |

The data channels are pre-negotiated with fixed ids. Both sides create them at once, which skips the in-band open handshake and saves a round trip at session start.

### Envelope

Each data channel message is exactly one envelope. The channel preserves message boundaries, so there is no length prefix.

```proto
syntax = "proto3";
package remote.v1;

message Envelope {
  uint32 seq = 1;          // per channel, wraps
  uint64 sent_at_us = 2;   // sender's monotonic clock

  oneof body {
    // control
    Hello hello = 10;
    HelloAck hello_ack = 11;
    StreamConfig stream_config = 12;
    StreamConfigApplied stream_config_applied = 13;
    DisplayList display_list = 14;
    Ping ping = 15;
    Pong pong = 16;
    ClockMap clock_map = 17;
    StatsReport stats = 18;
    KeyFrameRequest key_frame_request = 19;
    Pause pause = 20;
    Resume resume = 21;
    Notice notice = 22;
    Bye bye = 23;
    LtrAck ltr_ack = 24;

    // input and pointer
    PointerMove pointer_move = 30;
    PointerDelta pointer_delta = 31;
    Button button = 32;
    Scroll scroll = 33;
    Key key = 34;
    Text text = 35;
    ReleaseAll release_all = 36;
    TabletSample tablet = 37;
    InputHeartbeat input_heartbeat = 38;

    // cursor
    CursorShape cursor_shape = 40;
    CursorState cursor_state = 41;
    CursorPosition cursor_position = 42;

    // clipboard and large payloads
    ClipboardOffer clipboard_offer = 50;
    ClipboardData clipboard_data = 51;
    ClipboardAck clipboard_ack = 52;
    Chunk chunk = 60;
  }
}

message Hello {
  uint32 protocol_major = 1;
  uint32 protocol_minor = 2;
  string app_version = 3;
  string device_model = 4;
  string os_version = 5;
  Capabilities capabilities = 6;
  bytes session_nonce = 7;
  bytes identity_signature = 8;  // binds device key to this connection
  bytes resume_token = 9;        // optional
}

message PointerMove {
  uint32 display_id = 1;
  float x = 2;                   // 0...1 across the display
  float y = 3;
  uint32 buttons = 4;            // bit set of held buttons
}

message Key {
  uint32 hid_usage = 1;          // USB HID keyboard usage
  bool down = 2;
  uint32 modifiers = 3;          // full modifier bit set
}

message Scroll {
  float dx = 1;                  // points
  float dy = 2;
  Phase phase = 3;
  Phase momentum_phase = 4;
  bool continuous = 5;
}
```

Section 21 lists every message with its fields.

### Size limits

| Item | Limit | Handling |
| --- | --- | --- |
| One envelope | 64 KiB | Larger payloads are split into `Chunk` messages with a stream id, index and last flag |
| Cursor image | 256 KiB | Chunked on `control` |
| Clipboard text | 1 MB | Chunked on `control` |
| Pointer move | About 20 bytes | One per display refresh at most |

### Handshake after the encrypted channel is up

1. The iPad sends `Hello` with its versions, capabilities, a nonce and an identity signature.
2. The Mac verifies the signature against the pinned key. If it fails, the Mac closes the connection without replying.
3. The Mac sends `HelloAck` with its own signature and a resume token, then `DisplayList`.
4. The iPad verifies, then sends `StreamConfig` with the display, size, frame rate and quality preference it wants.
5. The Mac replies with `StreamConfigApplied`, which is authoritative, and starts capture.
6. The Mac sends the current cursor shape and state. The first key frame follows on the video track.
7. Both sides start one-second pings.

If `Hello` does not arrive within 3 seconds of the channel opening, the Mac closes the connection.

### Versioning rules

- The protocol has a major and a minor number. A major mismatch ends the handshake with a clear update message on both devices.
- Minor differences are handled by the capability set. The Mac uses only what both sides list.
- Fields are only ever added. Field numbers are never reused, and removed fields are marked reserved.
- Unknown fields and unknown message types are ignored, which proto3 does by default.
- `WireProtocol` keeps golden files of encoded messages from every released version, and tests decode all of them.

### Signaling envelope

Signaling messages are small JSON objects. They travel through the backend over the internet, or straight to the Mac on a LAN.

```json
{
  "v": 1,
  "type": "offer",
  "session": "01JDF3Q8ZK4W7N2M5R6T8V9XYA",
  "from": "dev_01JD...ipad",
  "to": "dev_01JD...mac",
  "seq": 1,
  "ts": 1763750000,
  "body": { "sdp": "..." },
  "sig": "base64 ECDSA P-256 signature"
}
```

| Type | Sent by | Meaning |
| --- | --- | --- |
| `ring` | Backend, on the iPad's request | A paired device wants to connect |
| `accept`, `reject` | Mac | Ready, or refused with a reason such as busy, attended mode declined, or not paired |
| `offer`, `answer` | iPad, Mac | Session descriptions |
| `candidate` | Both | One or more network candidates, batched over 50 ms |
| `restart` | Either | New offer after a path failure |
| `bye` | Either | End of session |

The signature covers every field except itself. A receiver rejects envelopes with a timestamp more than 60 seconds old, a repeated sequence number, or a sender it has not pinned.

## 12. Connectivity

Every session tries three kinds of path at the same moment and keeps the fastest one that works: same network, public address to public address, and through the relay. The Mac needs no port forwarding, because both devices only ever make outbound connections.

&#91;embedded content: connection sequence · 11 steps\]

Steps 1 to 6 pass through the backend and carry only signed setup messages. From step 9 onward everything travels on the path the two devices found, directly or through the relay.

### Path types

| Path | How it is found | When it works | Cost |
| --- | --- | --- | --- |
| Same network | Each device offers its local addresses | Both on one LAN or one VPN | Free, lowest latency |
| Direct over IPv6 | Each device offers its global IPv6 address | Both networks have IPv6 and allow inbound replies | Free |
| Direct through NAT | STUN reveals each device's public address, and both send to each other at once | Most home and office routers | Free |
| Relay over UDP | Each device gets an address on the TURN server | Strict NATs, including many mobile carriers | Relay bandwidth |
| Relay over TLS on port 443 | Same, wrapped in TLS over TCP | Networks that block UDP entirely | Relay bandwidth, higher latency |

### Transport configuration

| Setting | Value | Why |
| --- | --- | --- |
| ICE servers | STUN and TURN entries from the backend, with short-lived credentials | Nothing secret ships in the app |
| Transport policy | All paths. Relay-only is a debug switch | Lets tests force the relay |
| Bundle policy | Maximum bundle | Media and data share one UDP flow, so one path to establish |
| Continual gathering | On | New candidates appear when the network changes |
| Candidate pool | 1 on the Mac, 0 on the iPad | Gathering starts before the offer is ready. Only the Mac makes offers, and on the iPad a pool stalled gathering entirely (Phase 3) |
| IPv6 | On | Often gives a direct path with no NAT |
| TURN credential lifetime | 12 hours | Longer than any session. Cloudflare allows up to 48 hours |
| Start bitrate | 20 Mbps on a LAN, set with `x-google-start-bitrate` (and min and max) in the session description | The bandwidth estimate otherwise starts at 300 kbps. In spike S3 the target reached 37 Mbps within 3 s |

### On a LAN, with no backend

1. The Mac advertises a Bonjour service with its device id, name and protocol version in the TXT record.
2. The iPad browses for that service and lists what it finds.
3. The iPad opens a WebSocket straight to the Mac's listener.
4. The same signed signaling envelopes flow over that socket.
5. With no ICE servers configured, only local addresses are offered, and the session connects in well under a second.

On Wi-Fi, AirDrop and Universal Control on the Mac make its radio pause several times a second (risk R18). The host shows a tip while either is on.

Connect by address uses the same path with a typed host name or IP. That makes the product usable over Tailscale or any VPN before Phase 3 exists.

### Over the internet

1. The iPad calls the backend to create a session. The reply holds a session id and ICE servers.
2. The backend pushes `ring` to the Mac. The Mac fetches its own ICE servers and replies `accept`.
3. The iPad sends a signed `offer`. The Mac verifies it and returns a signed `answer`.
4. Both sides send candidates as they are discovered. Checks begin as soon as the first pair exists.
5. The first working pair carries the encrypted handshake. Better pairs can replace it later.
6. The app-level handshake from section 11 runs, and video starts.

| Step | Timeout | On timeout |
| --- | --- | --- |
| Ring to accept | 10 s | Mac offline message |
| Offer to answer | 5 s | Retry once, then fail |
| Path checks | 15 s | Could not reach the Mac message, with a hint to check the network |
| Whole connect | 20 s | Fail with the last known stage, for diagnostics |

### Path quality and upgrades

- The stats overlay shows the active path type and its round trip time.
- A session that starts on the relay keeps probing. If a direct path opens, traffic moves to it without interruption.
- The session record stores the path type, so you learn how often your real networks need the relay.

### When the network changes

| Event | Detection | Response |
| --- | --- | --- |
| iPad moves between Wi-Fi and cellular | New candidates from continual gathering | Usually switches paths by itself within a second or two |
| No packets for 2 s | Transport reports disconnected, pings go unanswered | Start a path restart with a new offer |
| Path restart while the control channel still works | Control channel is alive | Send the restart offer in-band, without the backend |
| Path restart with everything down | Control channel is dead | Send the restart through the backend |
| No recovery after 15 s | Timer | Tear down and reconnect from scratch using the resume token |
| Mac's network changes | Path monitor on the Mac | Mac reconnects signaling, then accepts the restart |

During any of these, the iPad keeps the last frame on screen with a reconnecting hint, and all held keys are released on the Mac.

Decided in Phase 4: recovery is a fast fresh reconnect. On the LAN the signaling socket dies with the Wi-Fi, so the iPad waits for a network, then connects again at once and asks for the same display; the Mac is idle again within a second of the old session ending. The in-band path restart with a new offer is deferred to Phase 5, and built only if measurements show the reconnect is too slow over the internet.

### Firewall summary

| Traffic | Destination | Port |
| --- | --- | --- |
| API and signaling | Backend | 443 TCP |
| STUN and TURN | Relay provider | 3478 UDP, with 443 TCP and TLS as fallback |
| Direct media | The other device | Dynamic UDP ports, outbound from both sides |
| LAN discovery | Local network | Bonjour, plus the host's listener port |

Both platforms ask for Local Network permission the first time the LAN path is used.

## 13. Backend services

The backend is one Laravel app with six jobs and no access to session content. It handles a few kilobytes per session, so one small server is enough for a long time. The relay is a separate, managed service.

### Responsibilities

| Job | How |
| --- | --- |
| Accounts | Verifies a Sign in with Apple identity token, then issues one Sanctum token per device |
| Device registry | Stores each device's name, platform and public key |
| Presence | A Reverb presence channel per account shows which Macs are online |
| Signaling | Accepts signed envelopes over HTTPS, validates routing, and pushes them to the target device's private channel |
| ICE servers | Mints short-lived TURN credentials and returns them with the STUN address |
| Session records | Stores metadata only: who, when, how long, path type, quality summary |

### API

| Method and path | Purpose |
| --- | --- |
| `POST /v1/auth/apple` | Exchange an Apple identity token for a device token |
| `POST /v1/devices` | Register this device with its public key |
| `GET /v1/devices` | List the account's devices |
| `PATCH /v1/devices/{id}` | Rename |
| `DELETE /v1/devices/{id}` | Revoke. Closes that device's sockets |
| `POST /v1/sessions` | Create a session to a target device. Returns session id and ICE servers, and rings the target |
| `GET /v1/ice-servers` | ICE servers for the host side of a session |
| `POST /v1/signal` | Send one signed envelope to another device on the same account |
| `POST /v1/sessions/{id}/events` | Report connected and ended, with path type and stats summary |
| `POST /broadcasting/auth` | Authorize a WebSocket channel subscription |
| `DELETE /v1/account` | Delete the account and all its data |

### Signaling design

Messages go up over HTTPS and come down over the WebSocket.

- **Up.** A device posts an envelope to `/v1/signal`. An ordinary controller checks the token, checks that sender and target share an account, applies rate limits and a 16 KB size cap, and broadcasts it.
- **Down.** Each device subscribes to `private-device.{id}`. Only that device's token can authorize the subscription.
- **Presence.** Each device also joins `presence-account.{id}`. The iPad reads online status straight from the channel's member list.
- **Swift side.** `BackendClient` implements the small part of the Pusher protocol that Reverb speaks: connect, authorize, subscribe, ping, receive. That is roughly 300 lines over `URLSessionWebSocketTask`.
- **Portability.** The envelope format does not depend on Reverb. The service can be replaced by any WebSocket server later.

The backend never parses envelope bodies. It reads the routing fields and passes the rest through.

Decided in Phase 3:

- **Device ids come from the device.** Each app makes its own id (`dev_` and 26 base32 characters) with its key, so pairing and LAN sessions need no backend. `POST /v1/auth/apple` takes the device's id, name and public key with the Apple token, registers the device on first sign-in, and returns its token. A device id stays with one account and one key; a new key means a new id. `POST /v1/devices` refreshes the other details.
- **The ring is unsigned.** The backend has no device key, so `ring` is only a hint. The Mac checks the caller against its pins and answers with a signed `accept`.
- **Pairing can go through the backend.** `pair` and `paired` envelopes need no session record, so a QR code can be answered when the iPad and the Mac are on different networks.
- **Local ports.** `make server-up` serves the API on 47880 and Reverb on 47881, next to the LAN listener on 47870.

### Data model

| Table | Key columns | Notes |
| --- | --- | --- |
| `accounts` | id, apple\_subject, created\_at | No password, no profile data |
| `devices` | id, account\_id, name, platform, model, os\_version, app\_version, public\_key, key\_fingerprint, last\_seen\_at, revoked\_at | Public keys only |
| `sessions` | id, account\_id, client\_device\_id, host\_device\_id, started\_at, connected\_at, ended\_at, path\_type, end\_reason, avg\_bitrate, avg\_rtt | Metadata only |
| `personal_access_tokens` | Sanctum default | Tokens stored hashed |
| `audit_events` | id, account\_id, device\_id, type, ip, created\_at | Sign-ins, registrations, revocations |

Never stored: session descriptions, network candidates, screen content, input, clipboard, or anything from a data channel.

### TURN credentials

| Provider | How the backend mints credentials |
| --- | --- |
| Cloudflare Realtime TURN | Calls Cloudflare's credential API with the TURN key and a lifetime. Credentials can last up to 48 hours, per the [TURN FAQ](https://developers.cloudflare.com/realtime/turn/faq/) |
| coturn, self-hosted | Shared-secret mode. Username is an expiry timestamp plus the device id. Password is an HMAC of the username with the shared secret |

The FAQ notes that a connection drops shortly after its credential expires. The 12-hour lifetime in section 12 covers the 8-hour session target.

### Relay cost

A relayed session at 8 Mbit/s moves 3.6 GB per hour.

| Option | Price | 8 Mbit/s relayed | Free allowance | Operations |
| --- | --- | --- | --- | --- |
| [Cloudflare Realtime TURN](https://developers.cloudflare.com/realtime/turn/) | $0.05 per GB sent from Cloudflare to the TURN client | About $0.18 per hour | First 1,000 GB, about 277 relayed hours | None. Anycast |
| coturn on a DigitalOcean droplet | [$0.01 per GiB](https://docs.digitalocean.com/products/billing/bandwidth) outbound beyond the pooled allowance. Inbound is free | About $0.03 per hour past the allowance | The droplet plan's included transfer | You patch, monitor and place it |

Direct sessions cost nothing in either case. For personal and in-house use, the Cloudflare allowance likely covers everything. Phase 3 measures relay round trip time from Lagos and Ibadan before this is final.

### Self-hosted coturn baseline

If you move to coturn, start from this hardened configuration.

```ini
listening-port=3478
tls-listening-port=5349
fingerprint
use-auth-secret
static-auth-secret=<from the secret store>
realm=turn.example.com
min-port=49152
max-port=65535
no-cli
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
user-quota=4
total-quota=200
```

The denied ranges stop anyone from using the relay to reach private addresses next to the server.

### Deployment

| Piece | Choice |
| --- | --- |
| Server | One small droplet, or a namespace in a cluster you already run |
| Processes | Web server with TLS, PHP application server, Reverb, one queue worker |
| Data | PostgreSQL and Redis |
| Local development | `make server-up` starts everything with Docker Compose |
| Backups | Nightly database dump. The data is small and rebuildable |
| Monitoring | Health endpoint, error tracking, count of connected hosts |

### Limits and failure behavior

| Rule | Value |
| --- | --- |
| Session creation | 10 per minute per device |
| Signaling | 60 envelopes per minute per session |
| Sign-in | 5 per minute per IP |
| Backend down, same LAN | Sessions still work through Bonjour and connect by address |
| Backend down, session running | The session continues. In-band path restarts still work |
| Backend down, new internet session | Fails with a clear service unavailable message |

## 14. Security model

Trust rests on two device keys that are exchanged once, in person, and pinned. The backend can introduce devices to each other, but it cannot impersonate one, read a session, or add a device to a Mac's allow list.

### Secrets and where they live

| Secret | Location | Protection | Lifetime |
| --- | --- | --- | --- |
| Device identity key, P-256 | Secure Enclave on each device | Never leaves the chip. On the Mac it is usable after first unlock, so the host can sign while the screen is locked | Until the app is removed or the key is reset |
| Pinned peer public keys | Keychain, this device only | Written only during pairing | Until revoked |
| Account token | Keychain | Hashed on the server | Until sign-out or revocation |
| Session keys | Memory | Fresh key exchange per session, with forward secrecy | One session |
| TURN credentials | Memory | Short-lived, issued per session | 12 hours |
| Pairing secret | Shown in the QR code | Single use, expires in 2 minutes | One pairing |
| Server secrets | Server secret store | TURN key, Apple keys, database credentials | Rotated on a schedule |

### Pairing, once and in person

1. On the Mac, choose Pair new device. The Mac shows a QR code for 2 minutes. It holds the Mac's device id, public key, name and a one-time secret.
2. The iPad scans it and shows the Mac's name and key fingerprint for confirmation.
3. The iPad sends its own device id, public key and name, with an HMAC keyed by the one-time secret. That proves it saw the QR code.
4. The Mac verifies the HMAC and asks the person at the Mac to allow this iPad, showing its name and fingerprint.
5. Both devices pin each other's public key. The backend records the pairing as metadata only.

Without a camera, both devices show a 6-digit code derived from both keys and the secret, and the person confirms on the Mac that they match.

### Verification in every session

| Layer | What is checked | What it stops |
| --- | --- | --- |
| Signed signaling | Offer and answer are signed with the device key and include the session's certificate fingerprint | A backend or network attacker swapping session descriptions |
| Encrypted transport | The transport checks the peer's certificate against the signed fingerprint | Anyone on the path reading or altering media and input |
| Identity handshake | `Hello` and `HelloAck` sign the session id, both fingerprints and fresh nonces | A replay of an earlier session's messages |
| Freshness | Timestamps within 60 s, sequence numbers, single-use nonces | Replays of signaling |

A session whose signatures do not match the pinned keys never reaches the point where capture starts.

### Authorization on the Mac

- The allow list is the set of pinned keys in the Mac's Keychain. Nothing else grants access.
- **The backend may remove trust but never add it.** A revocation from the account's device list blocks signaling at once, and the Mac drops the pin when it next syncs.
- Attended mode asks for a click at the Mac before each session.
- Five failed handshakes from one source within a minute cause that source to be ignored for 10 minutes.
- Recommended setup: the Mac locks itself automatically, and Lock when session ends is on. A person holding a stolen, unlocked iPad still faces the app lock and the Mac's lock screen.

### Threat model

| Threat | Mitigation | What remains |
| --- | --- | --- |
| Backend is breached or run maliciously | Cannot forge device signatures, so cannot start or read sessions | Denial of service, and visibility of metadata such as times and IP addresses |
| Attacker on the network path | End-to-end encrypted transport plus signed fingerprints | Traffic volume and timing |
| Relay operator | Sees only ciphertext | Traffic volume and both endpoints' addresses |
| Stolen iPad | Device passcode, app lock with Face ID, revocation, Mac lock screen | The window before you revoke, if the iPad was unlocked and the Mac was not locked |
| Stolen Apple account | A new device can register, but it is paired with nothing. Pairing needs presence at the Mac | Device list is visible to the attacker |
| Stranger on the same LAN reaching the host's listener | Unsigned or unknown envelopes are dropped after a size-capped parse and a signature check | A small pre-authentication parsing surface, covered by fuzz tests |
| Replay of captured signaling | Timestamps, sequence numbers and nonces | None known |
| Malformed messages from a paired device | Strict decoding with bounds checks, fuzz tests | A paired device is fully trusted for control by design |
| Clipboard secrets leaking | Concealed and transient items are skipped. Sync can be turned off | Ordinary copied text is synced on purpose |
| Keystrokes ending up in logs | Key codes and text are never logged, in any build | None known |
| Someone watching the Mac's physical screen | None in v1. No public API blanks the display while capturing | Real. Listed in section 20 |
| Tampered WebRTC binary | Exact version and checksum are pinned in the package manifest | Trust in the upstream build. Building from source is a later option |
| Tampered host update | Sparkle signature, notarization, HTTPS | Compromise of your signing keys |
| Relay used as an open proxy | Credentials only for signed-in devices, short lifetimes, denied private ranges on coturn | Abuse within quota by a real account |

The host runs as the logged-in user. V1 installs no root helper and no system extension.

### Algorithms

| Purpose | Algorithm |
| --- | --- |
| Device signatures | ECDSA with P-256 and SHA-256 |
| Pairing proof | HMAC with SHA-256 |
| Transport key exchange | DTLS with ephemeral elliptic-curve Diffie-Hellman |
| Media encryption | SRTP, preferring the AES-GCM suites |
| API and signaling transport | TLS 1.3 |

### Security work items

- [ ] Fuzz the signaling envelope parser and every protobuf decoder.
- [ ] Unit tests for every signature failure: wrong key, wrong fingerprint, stale timestamp, reused nonce.
- [ ] A test that proves capture never starts before the identity handshake completes.
- [ ] A log audit that greps release logs for key codes, text and clipboard content.
- [ ] An outside review before any public release.

## 15. Session lifecycle

A session is always in exactly one of eight states, and both apps run the same state machine from the shared package. Every state has a timeout, a visible meaning on the iPad, and a defined set of resources on the Mac.

&#91;embedded content: session state machine · 7 states plus Ended\]

The top row is the normal connect sequence. Streaming is the only state where video and input flow, and it can step aside into Recovering or Paused and come back without a new pairing or sign-in.

### States

| State | Meaning | iPad shows | Leaves when |
| --- | --- | --- | --- |
| Idle | No session | Device list | The user taps Connect |
| Ringing | Waiting for the Mac to accept | Connecting, step 1 | Accept, reject, or 10 s timeout |
| Negotiating | Exchanging descriptions and probing paths | Connecting, step 2 | A path works, or 15 s timeout |
| Securing | Encrypted channel and identity handshake | Connecting, step 3 | Handshake passes or fails, or 3 s timeout |
| Streaming | Video and input flowing | The Mac | Pause, path loss, or end |
| Paused | The iPad app left the foreground | Nothing, the app is in the background | Resume within 60 s, or the Mac ends the session |
| Recovering | Path restart in progress | Last frame with a reconnecting hint | Path returns, or 15 s timeout |
| Ended | Finished, with a reason code | A message matched to the reason | The user dismisses it, or an automatic retry starts |

Reduced quality is a flag on Streaming, not a state. It drives the poor-connection banner.

### What the Mac runs in each state

| State | Signaling socket | Capture and encoder | Input injection | Power assertion |
| --- | --- | --- | --- | --- |
| Idle | Connected | Off | Off | System stays awake, if enabled |
| Ringing, Negotiating, Securing | Connected | Off | Off | Same |
| Streaming | Connected | On | On | Display stays awake |
| Paused | Connected | Off | Off, all keys released | System stays awake |
| Recovering | Connected or reconnecting | On, frames dropped | Off, all keys released | Display stays awake |
| Ended | Connected | Off | Off | Back to idle |

### End reasons

| Code | Shown on the iPad as |
| --- | --- |
| `user_ended` | Nothing. Returns to the device list |
| `host_ended` | The session was ended from the Mac |
| `taken_over` | Another device took control |
| `ring_timeout` | The Mac did not answer. It may be asleep or offline |
| `path_timeout` | Could not reach the Mac from this network |
| `auth_failed` | This iPad is not trusted by that Mac. Pair again |
| `version_mismatch` | Update the app on the iPad or the Mac |
| `permission_missing` | The Mac needs a permission, with its name |
| `host_sleeping` | The Mac went to sleep |
| `network_lost` | Connection lost. Retrying |
| `internal_error` | Something went wrong, with a diagnostics id |

### Invariants

1. Capture is on only in Streaming and Recovering. It stops within 100 ms of leaving them.
2. Input injection is on only in Streaming. Leaving Streaming releases every held key and button.
3. The Mac has at most one session that is not Idle.
4. No state can last forever. Each has a timer that moves it forward or ends the session.
5. Capture never starts before the identity handshake passes.
6. The state machine is a pure function from state and event to new state and effects. Its tests need no network, no codec and no UI.

### Automatic retry

After `network_lost`, the iPad retries by itself while the app is in the foreground: up to 3 attempts, waiting 1, 2 and 4 seconds. Each attempt uses the resume token, so the Mac restores the last display and stream settings without a new negotiation of preferences.

## 16. Observability

One stats snapshot per second from each device is enough to answer why a session feels slow. The iPad overlay shows it live, the backend keeps a per-session summary, and nothing that was on screen or typed is ever recorded.

### Stats overlay

| Metric | Source | Healthy |
| --- | --- | --- |
| Path type | Selected network pair | Same network or direct |
| Round trip time | Transport and control pings | Under 60 ms |
| Frame age, capture to present | Clock map and local present time | Under 40 ms plus one-way network delay |
| Frames received and rendered per second | Decoder and display link | 60 during motion |
| Bitrate and ladder rung | Transport and host report | Inside the rung's window |
| Resolution and codec | Host report | As negotiated |
| Mac glass to encoded bits | Host report | Under 9 ms |
| Encode time, submit to output | Host report | Under 16 ms at rung 5 |
| Decode time | Decoder | Under 8 ms |
| Jitter buffer delay | Transport stats | Under 15 ms |
| Packet loss | Transport stats | Under 1 percent |
| Retransmissions and key frames | Transport stats | Rare |
| Average quantizer | Host report | Under the cap |
| Input delay | Event timestamps | Network delay plus 3 ms |
| Frames dropped, by stage | Host gate, decoder, renderer | Near zero |

### Transport statistics to read

| Report | Fields |
| --- | --- |
| Outbound video, on the Mac | Frames encoded, key frames encoded, total encode time, target bitrate, quality limitation reason, retransmitted bytes, picture loss requests received |
| Inbound video, on the iPad | Frames decoded, frames dropped, freeze count, total decode time, jitter buffer delay, packets lost |
| Selected candidate pair | Current round trip time, available outgoing bitrate, local and remote candidate types |

### Logging

- Both apps use the system `Logger` with one subsystem per app.
- Categories: session, transport, capture, encoder, decoder, render, input, pairing, backend, power.
- Names, addresses and identifiers are marked private, so they are redacted outside a debugger.
- Key codes, typed text and clipboard content are never passed to a log call. Input logs carry counts only.
- Signpost intervals wrap capture to encode, encode, decode and render. Instruments then shows per-frame timing with no extra code.

### Diagnostics export

Each app has an Export diagnostics action that writes one archive:

- The last 30 minutes of the app's own log entries.
- The stats time series of the last session.
- App version, OS version, device model, and on the Mac the state of each permission.

The user shares the file by hand. Nothing uploads automatically.

### Session summary

The iPad posts this to the backend when a session ends.

| Field | Use |
| --- | --- |
| Duration and end reason | Reliability tracking |
| Path type, and time on relay | Relay cost forecasting |
| Connect time by stage | Finding slow steps |
| Round trip time, median and 95th percentile | Network quality |
| Average bitrate and time per rung | Ladder tuning |
| Freeze count and reconnect count | Stability |
| App versions on both sides | Regression tracking |

### Backend metrics and alerts

| Metric | Alert when |
| --- | --- |
| Connected hosts | Drops by more than half in 5 minutes |
| Connect success rate | Below 95 percent over 15 minutes |
| Connect time, median and 95th percentile | 95th percentile above 8 s |
| Share of sessions on relay | Tracked, no alert |
| Sessions by end reason | Any error reason spikes |
| API and WebSocket error rate | Above 1 percent |

### Crash and performance reports

- MetricKit on both platforms collects crash and hang diagnostics.
- TestFlight adds crash reports and tester feedback for the iPad app.
- For the Developer ID host, MetricKit payloads are written to the diagnostics archive. Automatic upload is opt-in and off by default.

A single quality score per session, built from frame age, freezes, frame rate and rung, is defined in Phase 5 once real data exists.

## 17. Testing strategy

Testing has four layers, and the two that matter most are unusual for an app project: scripted bad-network runs and a repeatable latency measurement. Without those two, tuning in Phase 5 is guesswork.

### Layers

| Layer | Covers | Runs on | When |
| --- | --- | --- | --- |
| Unit | Protocol encode and decode with golden files, key map, coordinate transforms, pairing crypto, signaling validation, session state machine with a fake clock, NAL conversion with recorded streams, ladder controller with synthetic bandwidth traces | Any Mac, `swift test` | Every push |
| Component | Capture to encode to decode on one Mac. Event injection into a test window that records what arrives. Cursor tracker. Clipboard | A self-hosted Mac with permissions granted | Every push to main |
| End to end | A command-line test client built from the shared packages connects to the host, decodes video, sends input and checks results | Two Macs, or one Mac and the test client | Nightly |
| Manual | Gestures, keyboards, Pencil, multitasking, real networks | Real iPad and Mac | Each release |

Hosted CI runners are virtual machines without dependable hardware encoding or privacy grants. That is why component tests need a Mac you control.

### What the component tests assert

| Area | Assertions |
| --- | --- |
| Capture and encode | Frame count matches screen changes. Timestamps increase. A forced key frame arrives within one frame. Measured bitrate is within 15 percent of target. A static screen produces no frames after refinement |
| Decode | Every encoded frame decodes. A dropped frame triggers a key frame request. A parameter set change recreates the decoder |
| Mouse | Click count, button, position within 1 point, drag sequence of down, dragged, up |
| Scroll | Deltas sum correctly. Phases arrive in order |
| Keyboard | Every mapped key produces the expected virtual key code. Modifier state matches. Release-all leaves nothing held |
| Text | Unicode strings arrive intact, including emoji and combined characters |

### Network profiles

Each profile runs the same scripted session: scroll a long page, play a video window, type, then idle.

| Profile | One-way delay | Loss | Bandwidth | Expected result |
| --- | --- | --- | --- | --- |
| LAN | 1 ms | 0 | Unlimited | Top rung, frame age under 40 ms |
| Good home | 15 ms | 0.1 percent | 50 Mbit/s | Rung 4 or 5, no freezes |
| Average | 30 ms | 0.5 percent | 15 Mbit/s | Rung 3 or 4, no freezes |
| Mobile | 50 ms, 20 ms jitter | 1 percent | 6 Mbit/s | Rung 2 or 3, recovery from loss under 300 ms |
| Poor | 100 ms | 3 percent | 2 Mbit/s | Rung 1, usable, banner shown |
| Very poor | 200 ms | 5 percent | 1 Mbit/s | Rung 0, stays connected |
| Relay forced | Any | Any | Any | Connects, path shows relay |
| UDP blocked | Any | Any | Any | Connects through relay over TLS on 443 |
| Handover | Interface down for 3 s |  |  | Back in control within 3 s of the network returning |

Tools: Network Link Conditioner on the Mac and in the iPad's developer settings for manual runs, and `dnctl` with `pfctl` scripts in `Tools/` for scripted runs.

### Latency measurement

| Method | How | Precision | Use |
| --- | --- | --- | --- |
| Camera | A test pattern app on the Mac shows a millisecond counter and a moving bar. Film the Mac's display and the iPad side by side at 240 fps and compare | About 4 ms | Ground truth at each phase exit |
| Embedded counter | The test pattern also draws a frame counter as a row of black and white blocks. A debug mode on the iPad reads it from decoded frames and computes capture to present | About 1 ms | Continuous histograms with median, 95th and 99th percentile |
| Click to photon | A test window flips color on click. The iPad timestamps the click and detects the flip in the video | One frame | Input path regression check |

### Soak and performance

- An 8-hour scripted session with active and idle periods.
- Record memory footprint, CPU, thermal state, dropped frames and reconnects every minute.
- Pass when memory shows no upward trend, thermal state stays at nominal or fair, and no reconnect was unexplained.
- Run Instruments allocations and leaks on both apps before each release.

### Device matrix

| Dimension | Minimum coverage |
| --- | --- |
| Macs | A laptop with built-in display, a desktop with one or two external displays, a headless Mac mini |
| macOS | 26 and 27 |
| iPads | One 120 Hz iPad Pro, one 60 Hz iPad, one small-screen iPad |
| iPadOS | 26 and 27 |
| Input devices | Magic Keyboard with trackpad, a Bluetooth keyboard, a mouse, Apple Pencil |
| Mac keyboard layouts | US, UK, French AZERTY, German QWERTZ |
| Networks | Home Wi-Fi, office network, mobile hotspot, and one network that blocks UDP |

### Release checklist

- [ ] All unit, component and end-to-end tests pass.
- [ ] Network profiles meet their expected results.
- [ ] Camera latency on LAN is at or under the target.
- [ ] Soak test passes.
- [ ] Fresh-install onboarding works on a Mac with no prior grants.
- [ ] Old client against new host, and new client against old host, both connect or fail with the update message.
- [ ] Security work items from section 14 are done for this release.

## 18. Distribution

The iPad app ships through TestFlight and then the App Store. The Mac host ships as a notarized Developer ID app with its own updater. The host's managed entitlement is the one long-lead item, so its request goes to Apple in week 1.

### iPad client

| Topic | Plan |
| --- | --- |
| Signing | Automatic signing with your team. Capability: Sign in with Apple |
| Channel | TestFlight internal testing first, then external testers, then the App Store |
| Review category | A generic remote desktop client for the user's own Mac |
| Guideline 4.2.7 | Its LAN-only conditions apply when an app mirrors specific software or services rather than the host device in general, per the [guideline text](https://developer.apple.com/support/downloads/terms/app-review-guidelines/App-Review-Guidelines-English-UK.pdf). This product is a generic mirror |
| Reviewer access | A demo mode that plays a recorded session, like Porthole's demo cluster, plus a review note with the host download link and a short video |
| Account deletion | In-app, calling `DELETE /v1/account` |
| Privacy labels | Account identifier, device identifiers, diagnostics. No content |
| Privacy manifest | Declare required-reason API use, and check that the pinned WebRTC binary ships its own manifest |
| Export compliance | The app carries its own DTLS and SRTP stack inside WebRTC. Answer the encryption questions for this app specifically. Do not copy Porthole's setting |
| Acknowledgements | License notices for WebRTC and swift-protobuf in Settings |

The export compliance answer depends on your distribution countries and is worth a short check with someone who handles this, since it is a legal declaration.

### Mac host

| Topic | Plan |
| --- | --- |
| Signing | Developer ID Application certificate, hardened runtime on |
| Notarization | `notarytool` submit, then staple the ticket |
| Package | A disk image with the app. Drag to Applications |
| Sandbox | Off in v1 |
| Managed entitlement | `com.apple.developer.persistent-content-capture`, requested through Apple's form. Needs a provisioning profile embedded in the app once granted |
| Info.plist | `LSUIElement`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` |
| Login item | The embedded LaunchAgent plist, registered on first run with user consent |
| Updates | Sparkle 2 with EdDSA-signed updates over HTTPS |
| Update timing | Only while Idle. Never during a session |
| Privacy grants across updates | Kept as long as the bundle identifier and signing identity do not change |
| Uninstall | A menu action unregisters the login item, deletes Keychain items and revokes the device on the backend. The user then moves the app to the Trash |
| Mac App Store | Not in v1. Revisit after launch. The open questions are sandbox rules for synthetic input and for the background agent |

One detail needs a spike in Phase 7: Sparkle normally relaunches the app after an update, and launchd also restarts this app. The update flow must hand restart to exactly one of them.

### First-run flow on the Mac

1. Open the app. It explains what it does in two sentences.
2. Grant screen recording. The app restarts itself.
3. Grant accessibility.
4. Allow local network access.
5. Sign in with Apple.
6. Enable start at login.
7. Pair the first iPad with the QR code.

The checklist window stays open until every row is green, and each row explains why the permission is needed.

### Versions and channels

| Item | Rule |
| --- | --- |
| App version | Semantic versioning, the same number for client and host releases that ship together |
| Protocol version | Separate major and minor, checked in the handshake |
| Supported skew | A host accepts clients one minor protocol version behind. Anything older gets the update message |
| Channels | Internal, which is TestFlight internal plus a beta appcast, and stable |
| Release automation | `make release-host` archives, signs, notarizes, staples, builds the disk image and writes the appcast entry. TestFlight upload runs from CI |

### Documents to publish before external testers

- [ ] Privacy policy that states plainly what the backend stores and what it cannot see.
- [ ] Terms of use.
- [ ] A setup guide for the Mac permissions, with screenshots.
- [ ] A security overview based on section 14.

## 19. Phased build plan

Eight phases take one full-time engineer from an empty repository to an in-house release in about 20 weeks. Phases 0 to 2 produce a working LAN product by week 8, Phase 3 adds the internet by week 11, and the rest is reliability, quality and rollout.

&#91;embedded content: build plan · 8 phases over 20 weeks, 3 milestones\]

Phases run one after another because one person is doing the work. The three diamonds are the points where the product becomes usable in a new way.

A shortcut worth knowing: after Phase 2, Connect by address over Tailscale gives you remote use at week 8, three weeks before the backend exists.

### Phase 0: Foundations and spikes (weeks 1 to 2)

Goal: prove the seven riskiest assumptions before writing product code.

Setup:

- [ ] Pick a working name and write ADRs 0001 (architecture), 0002 (name) and 0003 (transport).
- [ ] Create the repository with the section 5 layout, XcodeGen with both targets, empty packages, and CI for package tests.
- [ ] Submit the Persistent Content Capture entitlement request to Apple.
- [ ] Register bundle identifiers and the Sign in with Apple capability.
- [ ] Build the test pattern app: millisecond counter, moving bar, block-coded frame counter.

| Spike | Question | Method |
| --- | --- | --- |
| S1 Capture and encode | Can the Mac capture at 60 fps and encode HEVC in low-latency mode within 10 ms per frame? | A loopback app: capture, encode, decode, show in a window. Time each stage with signposts |
| S2 Synthetic input | Do posted events behave like hardware for clicks, drags, momentum scroll, modifiers and text? Does a held synthetic key repeat? | A test window that records every event it receives |
| S3 Transport plumbing | Can custom HEVC encoder and decoder factories carry our frames? How is minimum playout delay set from the Objective-C API? What is the binary size? | Mac to iPad sample with signaling over a local socket |
| S4 Audio injection | Can system audio PCM feed the audio track through a custom audio device on macOS? | Small prototype. If not, prototype Opus over a data channel |
| S5 Lock screen | Does capture show the lock screen, and does a typed password unlock it? | Manual test on macOS 26 and 27 |
| S6 Permissions | How often does the capture prompt return without the entitlement? Does macOS 27 show a separate Remote Desktop entry? Which APIs report status reliably? | Fresh user account, written log of every prompt |
| S7 iPad input | Which key combinations reach the app? Do pointer lock, hover and scroll phases work on the Magic Keyboard? | Key and pointer logger app on the iPad |

Exit criteria:

1. The loopback demo holds 60 fps with encode at or under 10 ms and decode at or under 8 ms.
2. Each spike has a one-page result in `Docs/spikes` with a go or no-go.
3. Every no-go has a matching ADR change.
4. The camera latency method has been run once on the loopback demo.

### Phase 1: Video on the LAN (weeks 3 to 5)

Goal: the iPad shows the Mac's display over the local network.

- [ ] `WireProtocol` first version: envelope, hello, stream config, ping.
- [ ] `MediaCore`: encoded frame type, NAL conversion, parameter sets, with tests.
- [ ] `HostCapture`: display list, stream wrapper, frame gate, encoder with live bitrate and key frame on request.
- [ ] `SessionTransport`: the protocol, the WebRTC adapter with custom capturer and codec factories, pre-negotiated data channels.
- [ ] LAN signaling: Bonjour advertise and browse, WebSocket listener.
- [ ] `ClientVideo`: decoder, with the stock renderer for now.
- [ ] Host shell: menu bar item, permission checklist for screen recording and local network.
- [ ] Client shell: Bonjour device list, session view, first stats overlay.
- [ ] Session state machine with tests.

Exit criteria:

1. The iPad shows the Mac at 60 fps on the LAN for 30 minutes without a freeze.
2. Camera-measured glass-to-glass latency is 60 ms or less. The 40 ms target arrives in Phase 5.
3. A static screen sends no frames.
4. Time to first frame is 2 s or less.
5. Quitting either app ends the session cleanly on the other.

### Phase 2: Control (weeks 6 to 8)

Goal: do real work on the Mac from the iPad over the LAN.

- [ ] `InputModel`: key table, modifiers, coordinate transforms, with tests.
- [ ] `HostInput`: injector for mouse, scroll, keys and text. Held-key tracking, release-all, repeat timer. Accessibility onboarding.
- [ ] `ClientInput`: direct touch gestures, hardware keyboard, hover pointer with buttons, scroll with phases, software keyboard and modifier bar.
- [ ] Own Metal renderer with viewport transform, zoom and pan.
- [ ] Cursor: shape tracker, cache, both cursor channels, local prediction with correction.
- [ ] Trackpad mode.
- [ ] Display wake on connect, and the lock screen unlock path.
- [ ] Connect by address.

Exit criteria:

1. You complete one hour of real work on the LAN using only the iPad.
2. Component tests for mouse, scroll and keyboard pass.
3. With 60 ms of simulated network delay, the cursor still tracks the finger with no visible lag.
4. Disconnecting with a key held leaves no stuck key on the Mac.
5. You can unlock the Mac's lock screen from the iPad.

### Phase 3: Internet (weeks 9 to 11)

Goal: connect from any network, with pairing and end-to-end verification.

- [ ] Backend: Apple sign-in, device registry, sessions, signal endpoint, Reverb channels, ICE servers endpoint, rate limits, deployment.
- [ ] `BackendClient`: REST calls and the WebSocket client with reconnect.
- [ ] `Pairing`: Secure Enclave keys, QR pairing, pin store, signed envelopes on every path including LAN, identity handshake.
- [ ] Client: sign-in, account device list with presence, QR scan flow.
- [ ] Host: sign-in, standing socket, ring and accept, pairing window, paired device list with revoke.
- [ ] ICE configuration with STUN and TURN, a forced-relay debug switch, path type in the overlay.
- [ ] Session records.

Exit criteria:

1. From a mobile hotspot to the Mac on a home network, the session connects on a direct path.
2. Forced relay works, and a network with UDP blocked works through TLS on 443.
3. An automated test tampers with an offer's fingerprint and the Mac rejects it.
4. A signed-in but unpaired device cannot connect.
5. Internet connect time is 5 s or less.
6. Relay round trip time from your usual locations is measured and written down.

Results (22 to 23 November 2026, M3 Pro Mac on home Wi-Fi in Nigeria, iPad Pro M4 on a phone hotspot, backend in DigitalOcean London, Cloudflare relay):

| Check | Result |
| --- | --- |
| 1. Hotspot to home, direct | Passed. Path Direct, round trip 52 ms at best, 128 ms averaged over the session |
| 2. Forced relay | Passed. Path Relay, 282 to 363 ms |
| 2. UDP blocked, TLS on 443 | Passed with the relay limited to TURN over TLS on 443, which is what a UDP-blocking network leaves: Relay, 359 ms, first frame after 8.6 s. A real UDP-blocking network is still to be tried |
| 3. Tampered offer fingerprint | Passed, automated (`SignedSignalingTests`) |
| 4. Signed-in but unpaired device | Passed, automated on the LAN; over the internet the Mac answers an unpaired caller's ring with not paired |
| 5. Connect time 5 s or less | Passed on the direct path: first frame 3.78 s after Connect. Over the relay 5.8 s, and 8.6 s over TLS only |
| 6. Relay round trip | 282 to 363 ms from a cellular hotspot. Other usual locations still to be measured |

The relay round trip is high for interactive use; Phase 5 looks at it with the playout delay and the ladder.

### Phase 4: Host reliability (weeks 12 to 13)

Goal: the Mac is always reachable and sessions survive real-world interruptions.

- [ ] LaunchAgent registration, restart on crash, second-launch handoff.
- [ ] Power assertions, sleep and wake handling, lid-close warning.
- [ ] Network change recovery on both sides, in-band restart, resume token, background and foreground flow, automatic retry.
- [ ] Full permission onboarding with live status and self-restart. Notices when a permission is lost mid-session.
- [ ] Attended mode, busy and take over, disconnect shortcut, lock on session end.
- [ ] Display list and switching. Headless Mac test.
- [ ] End reason codes and their messages.

Exit criteria:

1. After a reboot and login, the Mac is reachable within 30 s without touching it.
2. Turning the iPad's Wi-Fi off and on mid-session restores control within 3 s.
3. Backgrounding the iPad app for 20 s and returning restores the session within 2 s.
4. Killing the host process brings it back and reachable within 10 s.
5. After 8 idle hours, a connection still works on the first try.
6. Revoking screen recording mid-session produces the right message on the iPad.

Results (23 November 2026, M3 Pro Mac with an external display, iPad Pro M4, home Wi-Fi):

| Check | Result |
| --- | --- |
| 1. Reachable after a reboot and login | Passed. Farside Host was running 36 s after boot finished, within the minute of login, and the iPad connected without touching the Mac. Before login (FileVault's password screen) the Mac cannot answer, as expected |
| 2. iPad Wi-Fi off and on | Passed. The iPad reconnected by itself within the 3 s |
| 3. 20 s in the background | Passed. The session paused and resumed within 2 s |
| 4. Host killed | Passed. Back in 0.2 s and online with the backend 0.5 s later |
| 5. 8 idle hours | To run overnight |
| 6. Screen Recording revoked mid-session | Passed. The iPad says the Mac needs Screen Recording |

Also tried on the devices: display switching, the disconnect shortcut, attended mode (allow and decline) and lock when the session ends. Take over is covered by tests only, as there is one iPad.

### Phase 5: Stream quality (weeks 14 to 16)

Goal: hit the latency and quality targets on every network profile.

- [ ] Ladder controller with hysteresis, resolution switching without dropping the session, quality preference.
- [ ] Static screen refinement and quantizer cap tuning.
- [ ] Playout delay tuning, clock map, frame age histogram from the embedded counter.
- [ ] HEVC and H.264 negotiation with fallback.
- [ ] Long-term reference experiment, with a keep or drop decision.
- [ ] Audio on the path chosen in S4, with mute.
- [ ] Scripted network profiles running nightly.
- [ ] Thermal, Low Power Mode and cellular caps.
- [ ] Benchmark against RustDesk and Apple Screen Sharing on the same hardware and network.

Exit criteria:

1. LAN glass-to-glass latency is 40 ms or less by camera.
2. Every network profile in section 17 meets its expected result.
3. Text is crisp within 500 ms of motion stopping.
4. Audio delay is 100 ms or less.
5. The benchmark is written down, and latency is at least on par with RustDesk.

### Phase 6: Comfort (weeks 17 to 18)

Goal: the small things that decide whether you reach for it daily.

- [ ] Clipboard in both directions with the section 10 rules.
- [ ] Shortcut remaps, complete toolbar, sticky modifiers, function keys.
- [ ] Three-finger gestures, scroll direction setting, trackpad acceleration tuning.
- [ ] Pencil click, drag and hover. Pressure experiment, limited to 2 days.
- [ ] Pointer lock mode.
- [ ] Fill and actual-size viewports, sharper scaling filter, match-iPad-shape option.
- [ ] Type what I see mode, with layout tests.
- [ ] Settings screens in both apps, app lock, privacy cover.

Exit criteria:

1. The manual gesture checklist passes on the device matrix.
2. Copy and paste work in both directions, including the Command V flow.
3. A second person completes setup and a 30-minute session using only the setup guide.

### Phase 7: Hardening and rollout (weeks 19 to 20)

Goal: safe to run every day on your own machines, and ready for testers.

- [ ] Security work items: fuzzing, signature failure tests, log audit.
- [ ] Soak test, leak check, performance pass.
- [ ] Diagnostics export, session summary, backend metrics and alerts.
- [ ] Sparkle integration with the restart spike, release automation, notarization.
- [ ] TestFlight build, demo mode, privacy manifest, export compliance answers.
- [ ] Setup guide, privacy policy, security overview.
- [ ] Version skew tests.

Exit criteria:

1. The release checklist in section 17 passes.
2. Your Macs run the notarized build and have taken one update through Sparkle.
3. The iPad app is on TestFlight.
4. One week of daily use passes without a blocking bug.

### Phase 8: Later, unscheduled

| Item | Why later | First step |
| --- | --- | --- |
| Login window access | Needs a pre-login agent and a privileged helper, with no confirmed approach on current macOS | Spike based on Apple's PreLoginAgents sample |
| File transfer and drag and drop | Not needed for control | Reliable chunked channel with flow control |
| Images and files on the clipboard | Text covers most use | Add types to the clipboard messages |
| iPhone and Mac client apps | The shared package makes them mostly UI work | New targets in `project.yml` |
| Custom QUIC transport | Removes the WebRTC dependency | Second implementation of `SessionTransport` |
| Virtual display matching the iPad | Private API | Developer ID only experiment |
| HDR, 10-bit, Display P3, 4:4:4 | Hardware support varies by Mac | Query encoder capabilities per model |
| Mac App Store host | Sandbox questions | Prototype synthetic input in a sandboxed build |
| Wake a sleeping Mac | Needs a second always-on device on the same LAN | A tiny helper that sends the wake packet on request |
| Privacy curtain on the Mac | No public API | Watch for one |
| Own WebRTC build | Removes trust in a third-party binary | Scripted build of a pinned milestone |
| Sharing a Mac with another account | Product feature, not a personal need | Design access grants |

### Staffing notes

- The estimate assumes one engineer, full time, already comfortable with Swift.
- A second engineer can build the Phase 3 backend during Phases 1 and 2. That saves about 3 weeks.
- Part-time work scales the calendar roughly in proportion.
- The three biggest schedule risks are spikes S3 and S5 and the entitlement request. All three resolve in Phase 0.

## 20. Risks and open questions

Eighteen risks are tracked, and three of them can each break the definition of done: the recurring capture prompt, lock screen behavior, and the limits of WebRTC's Objective-C API. All three are tested in Phase 0, before product code exists.

### Risks

| # | Risk | Likelihood | Impact | Mitigation | Settled by |
| --- | --- | --- | --- | --- | --- |
| R1 | macOS re-asks for capture permission on a schedule, and the entitlement is denied or slow | Medium | High | Request in week 1. Until granted, approve the prompt whenever you are at the Mac. Spike S6's hourly check (`app.farside.permprobe.check`) has logged capture status since Nov 22, 2026, alongside a written log of each prompt, to record the real cadence | Phase 4 |
| R2 | Capture or typed input does not work on the lock screen on current macOS | Low to medium | High | Spike S5. If it fails, the unlock design must change before Phase 2. Settled for macOS 26: capture, typing and unlock by key code all work. Open for macOS 27 until `Tools/LockProbe` runs there | Phase 0 for macOS 26, macOS 27 beta cycle |
| R3 | The WebRTC Objective-C API cannot set minimum playout delay, carry custom HEVC cleanly, or accept injected audio | Medium | Medium to high | Spikes S3 and S4. Fallbacks: H.264 first, audio on a data channel, or a patched WebRTC build. S3 settled HEVC (advertised by name, no Objective-C types needed) and playout delay (field trials). S4 settled audio injection, but mono only; stereo needs the data-channel fallback or a patched module | Phase 0 |
| R4 | The 40 ms LAN target is missed because of buffering somewhere in the chain | Medium | Medium | Measure from Phase 1 with the camera method. Every stage has a signpost | Phase 5 |
| R5 | HEVC low-latency encoding behaves differently across Mac models | Medium | Low | Negotiated H.264 fallback. Device matrix | Phase 5 |
| R6 | iPadOS keeps Command Tab and similar shortcuts | Certain | Medium | Remaps, toolbar menu, sticky modifiers | Phase 6 |
| R7 | Mobile networks force the relay often, and relay latency from Nigeria is high | Medium | Medium | Measure in Phase 3. Anycast relay. IPv6. A self-hosted relay in the nearest region as an alternative | Phase 3 |
| R8 | The Mac is asleep, lid closed, or stuck at the FileVault screen after a reboot | Certain at times | Medium | Keep-awake setting, warnings, setup guide. Wake helper in Phase 8 | Phase 4 |
| R9 | A future macOS changes the privacy model for remote control, as the reported Remote Desktop entry in macOS 27 suggests | Medium | Medium | Test every beta cycle. Keep the host updater fast | Ongoing |
| R10 | App Review rejects the client | Low to medium | Medium | Demo mode, clear review notes. TestFlight keeps you working meanwhile | Phase 7 |
| R11 | The third-party WebRTC binary stops being maintained, or drops the deprecated `RTCInitFieldTrialDictionary` that zero playout delay depends on | Low | Medium | Pin a version. Document an alternative source and an own-build script, which can also expose the factory builder's field trials | Phase 8 |
| R12 | Scope grows beyond one engineer and 20 weeks | High | Medium | Phase gates and the Phase 8 list | Every phase exit |
| R13 | Some apps ignore synthetic input or grab the mouse | Low | Low | Pointer lock mode. Document known exceptions | Phase 6 |
| R14 | Someone near the Mac sees the session on its display | Certain | Low for personal use | Accepted in v1. Lock on session end | Phase 8 |
| R15 | A headless Mac offers only a low-resolution display | Medium | Low | Dummy display plug | Phase 4 |
| R16 | The backend is a single point of failure for new internet sessions | Low | Medium | LAN and VPN paths do not need it. Redeploy is simple | Phase 7 |
| R17 | Pointer lock does not engage reliably on iPadOS. Spike S7 saw it engage in one run and not in another with the same code | Medium | Low | Absolute pointer mode as the fallback, and GameController's relative deltas for trackpad mode. Phase 6 finds the exact conditions | Phase 6 |
| R18 | AWDL, Apple's peer-to-peer Wi-Fi, is kept busy by AirDrop and Universal Control and takes the Mac's Wi-Fi radio off the network's channel. Measured in Phase 1: about four stalls of about 100 ms a second, so the iPad showed about 44 of 60 frames and glass-to-glass reached 117 ms. With both features off: no stalls, about 60 fps shown, glass-to-glass about 22 ms on average | Certain on Wi-Fi with either feature on and an Apple device nearby | High for Wi-Fi sessions | Farside cannot turn AWDL off without a privileged helper. The host reads both settings and shows a tip in its menu and checklist while either is on. AWDL's own interface status cannot be used: it stays active either way. Ethernet on the Mac avoids the problem | Phase 1 (tip). A privileged helper is a Phase 8 option |

### Open questions

The answers change scope, so they are worth settling before Phase 0 ends.

- [ ] **Personal tool or product?** If it stays personal, accounts and the device registry can be cut. A signaling relay of a few hundred lines is then enough, and Phase 3 shrinks by about a week.
- [ ] **What is the working name?** It sets bundle identifiers, the Bonjour service type and the repository name.
- [ ] **Is macOS 26 as the minimum acceptable for every Mac you want to reach?** Supporting macOS 15 adds availability checks and a wider test matrix.
- [ ] **Which Macs are hosts?** A laptop that travels with its lid closed and a headless Mac mini each have limits described in sections 6 and 10.
- [ ] **What do your usual networks look like?** Carrier NAT on your home or mobile connection decides how often the relay is used. IPv6 availability helps.
- [ ] **Is audio needed in v1?** If not, drop spike S4 and the audio task in Phase 5, which saves a few days.
- [ ] **Open source later?** As with Porthole, deciding early keeps history clean and dependencies permissive.
- [ ] **Relay provider.** Confirm the managed relay after Phase 3 measurements, or move to coturn.
- [ ] **Mac audio during a session.** Should the Mac keep playing sound through its own speakers?

### Things to watch

- Apple's documentation now lists ScreenCaptureKit for iPadOS 27. It is worth a look if viewing the iPad from the Mac is ever revisited. It does not change the lack of input injection on iPadOS that this plan is built around.
- Network.framework gained a Swift concurrency API in the OS 26 releases. It is the natural base for a custom transport in Phase 8, once its QUIC support matures.

## 21. Appendix

Reference tables for implementation: which Apple API covers each need, the encoder keys, the full message catalog, a key map sample, a glossary and the sources.

### A. Apple API map

| Need | Framework | API |
| --- | --- | --- |
| List displays | ScreenCaptureKit | `SCShareableContent`, `SCDisplay` |
| Capture a display | ScreenCaptureKit | `SCStream`, `SCContentFilter`, `SCStreamConfiguration`, `SCStreamOutput` |
| Frame metadata | ScreenCaptureKit | `SCStreamFrameInfo` keys for status, display time, content rect, scale and dirty rects |
| Hardware encode | VideoToolbox | `VTCompressionSession` |
| Hardware decode | VideoToolbox | `VTDecompressionSession` |
| Format descriptions | Core Media | `CMVideoFormatDescription` from HEVC or H.264 parameter sets |
| Zero-copy textures | Core Video, Metal | `CVMetalTextureCache`, `CAMetalLayer` |
| Frame pacing on iPad | Quartz Core | `CAMetalDisplayLink` |
| Post mouse and key events | Core Graphics | `CGEvent`, `CGEventSource`, posting at the HID event tap |
| Display geometry and modes | Core Graphics | `CGDisplayBounds`, `CGDisplayCopyAllDisplayModes`, `CGDisplaySetDisplayMode`, reconfiguration callback |
| Cursor image | AppKit | `NSCursor.currentSystem` |
| Mac clipboard | AppKit | `NSPasteboard` change count and string access |
| iPad clipboard | UIKit | `UIPasteboard`, `UIPasteControl` |
| Screen recording permission | Core Graphics | `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess` |
| Input permission | Application Services, Core Graphics | `AXIsProcessTrustedWithOptions`, `CGPreflightPostEventAccess`, `CGRequestPostEventAccess` |
| Start at login | Service Management | `SMAppService.agent(plistName:)` |
| Keep awake, wake display | IOKit power management | `IOPMAssertionCreateWithName`, `IOPMAssertionDeclareUserActivity` |
| Sleep and wake events | AppKit | `NSWorkspace` sleep, wake and session notifications |
| Network changes | Network | `NWPathMonitor` |
| LAN discovery and listener | Network | `NWBrowser`, `NWListener` with Bonjour and WebSocket |
| Hardware keys on iPad | UIKit, Game Controller | `UIPress` with `UIKey`, `GCKeyboard` |
| Pointer on iPad | UIKit, Game Controller | `UIHoverGestureRecognizer`, `UIPointerInteraction`, `prefersPointerLocked`, `GCMouse` |
| Device keys | CryptoKit | `SecureEnclave.P256.Signing.PrivateKey` |
| Secrets | Security | Keychain items, this device only |
| App lock | LocalAuthentication | `LAContext` |
| Sign-in | AuthenticationServices | `ASAuthorizationAppleIDProvider` |
| Logging and timing | OSLog | `Logger`, `OSSignposter` |
| Diagnostics | MetricKit | `MXMetricManager` |

### B. Encoder keys

| Constant | Where | Value |
| --- | --- | --- |
| `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` | Encoder specification at creation | true |
| `kVTCompressionPropertyKey_SupportedPresetDictionaries` | Read after creation | Look up the video conferencing preset |
| `kVTCompressionPropertyKey_RealTime` | Session property | true |
| `kVTCompressionPropertyKey_ExpectedFrameRate` | Session property | 60 |
| `kVTCompressionPropertyKey_ProfileLevel` | Session property | `kVTProfileLevel_HEVC_Main_AutoLevel` or `kVTProfileLevel_H264_High_AutoLevel` |
| `kVTCompressionPropertyKey_AverageBitRate` | Session property, updated live | Target bits per second |
| `kVTCompressionPropertyKey_AllowFrameReordering` | Session property | false |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` | Session property | Very large |
| `kVTCompressionPropertyKey_MaxAllowedFrameQP` | Session property | About 40, tuned in Phase 5 |
| `kVTCompressionPropertyKey_ColorPrimaries`, `TransferFunction`, `YCbCrMatrix` | Session properties | ITU-R BT.709 |
| `kVTEncodeFrameOptionKey_ForceKeyFrame` | Per-frame option | true when a key frame is requested |
| `kVTCompressionPropertyKey_EnableLTR` | Session property | Phase 5 experiment |

### C. Message catalog

| Message | Channel | Fields |
| --- | --- | --- |
| `Hello` | control | Protocol major and minor, app version, device model, OS version, capabilities, nonce, identity signature, resume token |
| `HelloAck` | control | Same identity fields from the Mac, new resume token |
| `Capabilities` | inside hello | Codecs, maximum width, height and frame rate, audio, tablet, clipboard, long-term reference |
| `StreamConfig` | control | Display id, width, height, frame rate, codec preference, quality preference, audio on or off |
| `StreamConfigApplied` | control | The values the Mac actually applied, plus content rect and scale |
| `DisplayList` | control | One entry per display, as listed in section 10 |
| `Ping`, `Pong` | control | Sender time. Pong echoes it and adds receiver time |
| `ClockMap` | control | Media timestamp and the Mac's monotonic time |
| `StatsReport` | control | The sender's pipeline numbers for the last second |
| `KeyFrameRequest` | control | Reason |
| `Pause`, `Resume` | control | Resume carries the resume token |
| `Notice` | control | Code and optional detail |
| `Bye` | control | End reason code |
| `LtrAck` | control | Acknowledged reference tokens |
| `PointerMove` | pointer | Display id, x, y, held buttons |
| `PointerDelta` | pointer | dx, dy |
| `TabletSample` | pointer | Pressure, tilt x and y, hover distance |
| `InputHeartbeat` | pointer | None beyond the envelope |
| `Button` | input | Button, down or up, click count, x, y |
| `Scroll` | input | dx, dy, phase, momentum phase, continuous flag |
| `Key` | input | HID usage, down or up, modifiers |
| `Text` | input | UTF-8 string |
| `ReleaseAll` | input | None |
| `CursorShape` | control | Id, image, width, height, hot spot, scale |
| `CursorState` | control | Shape id, visible |
| `CursorPosition` | cursor | Display id, x, y, last input sequence processed |
| `ClipboardOffer` | control | Content hash, type, size |
| `ClipboardData` | control | Type, bytes |
| `ClipboardAck` | control | Content hash |
| `Chunk` | control | Stream id, index, last flag, bytes |

### D. Key map sample

`InputModel` holds the full table. These rows show the pattern.

| Key | USB HID usage | macOS virtual key |
| --- | --- | --- |
| A | 0x04 | 0x00 |
| Return | 0x28 | 0x24 |
| Escape | 0x29 | 0x35 |
| Delete (backspace) | 0x2A | 0x33 |
| Tab | 0x2B | 0x30 |
| Space | 0x2C | 0x31 |
| Caps Lock | 0x39 | 0x39 |
| F1 | 0x3A | 0x7A |
| Forward Delete | 0x4C | 0x75 |
| Right Arrow | 0x4F | 0x7C |
| Left Arrow | 0x50 | 0x7B |
| Down Arrow | 0x51 | 0x7D |
| Up Arrow | 0x52 | 0x7E |
| Left Control | 0xE0 | 0x3B |
| Left Shift | 0xE1 | 0x38 |
| Left Option | 0xE2 | 0x3A |
| Left Command | 0xE3 | 0x37 |

### E. Glossary

| Term | Meaning |
| --- | --- |
| ICE | The procedure that tries every possible network path between two devices and picks one that works |
| STUN | A small service that tells a device its public address |
| TURN | A relay that forwards packets when no direct path works |
| NAT, carrier NAT | Address translation at a router. Carrier NAT adds a second layer at the ISP, which often defeats direct paths |
| Session description | The text blob each side sends to describe its codecs, encryption fingerprint and network details |
| DTLS and SRTP | The key exchange and the media encryption used by the transport |
| Data channel | A message stream inside the encrypted connection, reliable or unreliable by choice |
| NAL unit | One packet of encoded video data |
| Annex B | The byte format that separates NAL units with start codes instead of length prefixes |
| Parameter sets | The headers a decoder needs before it can decode frames. VPS, SPS and PPS for HEVC |
| Key frame | A frame that decodes without reference to earlier frames. Large |
| Long-term reference | An older frame both sides keep, so the encoder can recover from loss without a key frame |
| Quantizer, QP | The encoder's compression strength. Higher means blurrier |
| Jitter buffer | A short receive-side queue that smooths uneven packet arrival, at the cost of delay |
| Rung | One step of the adaptation ladder: a resolution, frame rate and bitrate window |
| Glass to glass | Delay from a pixel changing on the Mac to the same change showing on the iPad |
| TCC | The macOS privacy system behind the permission prompts |
| Pinning | Remembering a peer's public key and refusing any other |

### F. Sources

Pages opened while writing this plan, as of November 21, 2026.

- [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration), Apple documentation
- [Explore low-latency video encoding with VideoToolbox](https://developer.apple.com/videos/play/wwdc2021/10158/), WWDC21
- [Encoding video for low-latency conferencing](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing), Apple sample code
- [Persistent Content Capture entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture), Apple documentation
- [Remote Desktop privacy entry on macOS 27](https://developer.apple.com/forums/thread/841530), Apple Developer Forums
- [Screen capture in the pre-login context on macOS 15](https://developer.apple.com/forums/thread/768146), Apple Developer Forums
- [Sequoia's repeating screen recording prompts](https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/), TidBITS
- [App Review Guidelines](https://developer.apple.com/support/downloads/terms/app-review-guidelines/App-Review-Guidelines-English-UK.pdf), guideline 4.2.7
- [stasel/WebRTC](https://github.com/stasel/WebRTC), prebuilt WebRTC package
- [Cloudflare Realtime TURN](https://developers.cloudflare.com/realtime/turn/) and its [FAQ](https://developers.cloudflare.com/realtime/turn/faq/)
- [DigitalOcean bandwidth billing](https://docs.digitalocean.com/products/billing/bandwidth)
- Local files: `rustdeskserver/compose.yml` and the Porthole project in your `my_eco` folder
