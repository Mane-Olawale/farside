# S2: Synthetic input

**Result: go.** Events posted at the HID event tap behave like hardware for clicks, double and triple clicks, all three buttons, drags, pointer deltas, phased scrolls with momentum, every modifier, Unicode text and key codes. A held synthetic key does not auto-repeat, as section 9 assumed, so the host generates repeats itself. Caps Lock is the one key that does not work synthetically, which changes one detail of the plan.

Measured Nov 22, 2026 on a MacBook Pro M3 Pro (Mac15,6), macOS 26.0.1, U.S. keyboard layout, system key repeat 0.5 s delay and 83 ms interval. Raw reports are in `S2/`.

## Method

`Tools/InputProbe` posts input with `HostInput.EventInjector` into its own window and records every event AppKit delivers through a local monitor. The window has a plain event surface, a text view and a tall scroll view. Each case checks the delivered events against what was posted. The injector follows section 9: an HID-state event source with the local suppression interval at zero (read back as 0), posting at the HID tap, dragged events while a button is held, and click state on each down and up. Keyboard cases run only while the probe window is key, so nothing can land in another app.

## Results

| Area | Case | Result |
| --- | --- | --- |
| Pointer | Absolute move | Lands exactly, 0.00 pt error, no acceleration |
| | Click, double, triple | Click counts 1; 1,2; 1,2,3 |
| | Right and middle buttons | Right mouse events; middle arrives as button 2 |
| | Drag | 12 of 12 dragged events, end within 0.00 pt, no moved events |
| | Moved events with the button held | 6 moved, 0 dragged. Confirms the rule that moves must post as drags |
| | Pointer deltas | deltaX 7 and deltaY −4 reach the app, location unchanged |
| Scroll | Pixel gesture with momentum, plain view | 18 of 18 events. Phases, momentum phases and precise flag exact, deltas sum to −124 of −124 |
| | Same gesture into NSScrollView | Moved 155 pt and settled at the last event |
| | Gesture with no momentum into NSScrollView | Moved 176 pt for 100 px posted, still moving 300 ms after the last event |
| | Line-unit wheel | Not precise, deltaY −3, NSScrollView moved 30 pt |
| Keys | Modifier keys | Each of 8 left and right modifiers sends flags-changed that sets then clears its flag |
| | Explicit flags | Command+K arrives with Command set |
| | Inherited flags | A key posted with no flags while synthetic Shift is held arrives as "K" with Shift |
| | Held key, 1.53 s | 1 key down, 0 repeats. Hardware would have repeated about 12 times |
| | Caps Lock | **Fails.** The app sees flags-changed with Caps Lock, but the system lock state never toggles |
| | fn alone | Flags-changed with Function. No system panel opened, focus kept |
| Text | ASCII, accents, combining marks, CJK, ZWJ emoji, flags | Identical Unicode scalars in the text view |
| | 500 characters, chunked | Intact. 0.5 ms to post, all arrived within 40 ms |
| | One event's Unicode string | 20, 21, 40 and 100 UTF-16 units all arrived whole |
| | Typing by virtual key code | "hello world" on the U.S. layout. This is the lock screen path |
| | Delete and Return as key codes | Edited the text as a keyboard would |
| Safety | Release all | Held Shift, K and left button released. System key and button state reads clear afterwards |
| | Source tag | 404 of 404 delivered input events carried the injector's user data tag |
| Timing | Post to event timestamp | p50 0.06 ms, p95 0.55 ms |
| | Event timestamp to the app's run loop | p50 8.1 ms, p95 17.3 ms, the same when posting from a background queue |

## Findings

1. **Section 9's replay rules hold as written.** Moves must post as drags while a button is held, click state drives double and triple clicks, phases and momentum pass through unchanged, and modifier keys posted as keys produce the flags-changed events apps expect.
2. **Synthetic keys never auto-repeat.** The host repeat timer in section 9 is required.
3. **Synthetic Caps Lock does not toggle the lock.** If the host replays the iPad's Caps Lock key, the Mac's state and later typing disagree. The host should not post Caps Lock. Instead, it should apply Shift to letters while the iPad's Caps Lock is on, or send printable text as text events.
4. **NSScrollView applies its own physics.** Given posted momentum, it moved about 25 % further than the deltas sum to. Given a gesture with no momentum, it added its own. Forwarding the iPad's momentum, as the plan says, keeps behavior consistent for apps that do not use NSScrollView. Phase 2's component test calibrates the feel.
5. **The source user data tag reaches the app on every event.** The host can use it to tell its own events from a person at the Mac. That is the test for when the Mac reports cursor position (section 9, local cursor prediction) and for attended-mode notices.
6. **Posting costs well under 1 ms,** inside the 3 ms input target. The 8 to 17 ms between the window server and the app's run loop is never longer than one 60 Hz frame and does not depend on the posting thread. Event delivery appears to be paced by the display. Whether hardware events see the same delay is not measured yet.
7. **One event carries at least 100 UTF-16 units into AppKit.** Keep the 20-unit chunks anyway: the cost is tiny, and other text stacks are less tolerant.
8. **Correction from the first runs:** the probe lost focus twice while pressing modifiers in quick succession. Neither run pressed fn alone at that moment, and a lone fn kept focus in the final run. The likely cause is a double-press system shortcut, such as Control twice for Dictation, triggered by back-to-back left and right presses of the same modifier. With presses 700 ms apart it did not recur. The host should replay modifier timing faithfully, so a person who double-taps a modifier on the iPad gets the same system action as on the Mac.

## Plan changes, applied Nov 22, 2026

- **Section 9, keyboard: physical keys:** add that the host never posts Caps Lock. The iPad's Caps Lock state is applied as Shift on letter keys, and the Mac's own Caps Lock state is left alone.
- **Section 9, event model:** add that every posted event carries the host's tag in the source user data field.

Neither is a no-go, so no ADR changes.

## Not covered

- **Local hardware alongside injected input.** The suppression interval reads back as zero, but a person typing on the Mac during injection was not tested.
- **Hardware delivery delay.** Comparing a physical key press with finding 6 needs a person at the keyboard.
- **Other layouts.** Key-code typing on UK, AZERTY and QWERTZ is the Phase 2 layout test.
- **Apps outside AppKit,** such as browsers, Electron apps, games and the lock screen. The lock screen is spike S5.
- **Tablet pressure and tilt fields.** These are the Phase 6 experiment.

## Reproduce

Grant InputProbe Accessibility once. Keep hands off the keyboard and mouse for about a minute, then run:

```bash
make run-s2
```

Reports go to `~/Library/Logs/Farside`. To rerun only some cases, add `--only name,name` after `open ... --args`.
