# S7: iPad input

**Result: go.** Letters, arrows, Escape, Caps Lock, most Command shortcuts and the plan's remap keys (Option-Tab, Option-Space) all reach the app. Hover, primary and secondary clicks, trackpad scroll and mouse wheel all arrive. Four things change the plan:

1. iPadOS keeps more shortcuts than the plan lists.
2. One delivered shortcut arrives without its modifier flag.
3. Trackpad momentum appears only in GameController's scroll stream, not UIKit's.
4. Pointer lock engaged in one run and not the other.

Measured Nov 22, 2026 on an iPad Pro 13-inch M4 (iPad16,5), iPadOS 27.2.1, with Apple's Magic Keyboard for iPad Pro and a Logitech MX Master 3S mouse. GameController reports the keyboard as "Generic Keyboard". `S7/report.json` is the run used here. `S7/run1-discarded.json` is a first run whose 7 s timeouts could not tell a swallowed key from a late press; only its pointer-lock reading is used below.

## Method

`Tools/InputLogger` is a full-screen iPad app with every screen edge deferred for system gestures. It is first responder and logs every key event from UIKit (`pressesBegan`/`Ended`) and from GameController (`GCKeyboard.keyChangedHandler`), plus scene resign events. A checklist shows one combination at a time. The person presses it, then taps the screen to move on.

Each step is classified from its raw log:
- **Delivered:** the main key arrived with the expected modifiers.
- **Swallowed:** the modifiers arrived but the main key never did.
- **System action:** the scene left the foreground.

The pointer steps count hover events, clicks with their button masks, continuous and discrete scroll pan states, and GameController mouse and scroll events. The last step requests pointer lock with `prefersPointerLocked`.

## Keys

| Reaches the app | Swallowed by iPadOS (modifiers only) | Takes the app out of the foreground |
| --- | --- | --- |
| A, Left arrow, Escape, Caps Lock | Command-` | Globe alone |
| Command-C, Command-V, Command-Z, Command-W | Command-Space | Globe-C |
| Command-Shift-H | Command-Option-D | Globe-H |
| Command-Option-Escape | Command-Shift-3 | Command-Tab |
| Option-Space, Option-Tab, Control-Space | Globe-A | Command-H |
| Command-. (Command flag missing, see finding 2) | Control-Up, Control-Left (likely, see finding 3) | Command-Q, Command-Shift-4 |
| Option alone | | |

Inconclusive: nothing at all was logged for Command alone and Control alone. Escape arrived during the next step. Neither case says anything about iPadOS.

## Pointer

| Step | Result |
| --- | --- |
| Hover | 1,370 hover events. GameController mouse deltas arrived alongside, 1,371 of them |
| Primary click | 3 clicks as indirect-pointer touches with the primary button |
| Secondary click | 3 clicks with the secondary button |
| Trackpad two-finger scroll | UIKit continuous pan: began, changed, ended, five times. GameController scroll: 264 events, 30 of them after UIKit's pan had ended |
| Mouse wheel | UIKit discrete pan: began, changed, ended. 642 GameController scroll events |
| Pointer lock | Run 1: locked, hover events stopped, GameController deltas kept flowing. Run 2: not locked, hover continued |

## Findings

1. **iPadOS keeps more than section 9 lists.** On top of Command-Tab, Command-Space and Command-H:
   - **Swallowed:** Command-backtick, Command-Option-D and Command-Shift-3.
   - **Takes the app out of the foreground:** Command-Q, Command-Shift-4, and the Globe key alone or with C, A or H.

   For Command-Q, the main key never arrived. The scene may have left the foreground because of iPadOS's overlay that appears while Command is held, not because of Q itself. Either way, the app does not see it. The planned remaps both work, because Option-Tab and Option-Space reach the app.
2. **Command-period arrives without the Command flag.** The Command key-down was logged, then the period arrived with no modifier flags. The iPad should therefore build the modifier set it sends from the modifier keys it has seen go down, not from each event's flags. Section 9 already says the Mac corrects drift against its own record; the iPad needs the same rule.
3. **Control with arrows likely does not reach the app.** In both Control-arrow steps, Control went down and up with no arrow, and the person then retried with Command. That fits iPadOS taking the arrow. The toolbar and the three-finger gestures already cover Mission Control and Spaces, which send these keys from the host.
4. **The Globe key never reaches an app as a modifier.** Its usage (0x29D) arrives on its own, but its combinations go to the system. The toolbar's sticky Fn modifier, already in section 7, is the way to send Fn to the Mac.
5. **Trackpad momentum is visible only through GameController.** UIKit's scroll pan ends when the fingers lift and has no momentum phase. GameController's scroll stream keeps reporting after the lift. Section 9 says scroll phases and momentum pass through. In practice, the iPad must either derive the momentum phase from GameController's stream, or synthesize momentum from the release velocity. Spike S2 found that NSScrollView adds its own momentum when none is posted, but other apps may not.
6. **GameController reports relative mouse deltas even without pointer lock.** This is useful for trackpad mode's acceleration curve, whatever the lock state.
7. **Pointer lock is not reliable yet.** It engaged in run 1 and not in run 2, with the same code path. The difference may be the scene state (Stage Manager or full screen) or the finger tap just before the request. Section 7 already allows absolute pointer mode as a fallback. Phase 6 must find the exact conditions.

## Plan changes, applied Nov 22, 2026

- **Section 9, shortcuts iPadOS keeps for itself:** replace the list with the measured one from finding 1, keep the Option-Tab and Option-Space remaps, and add Option-backtick for Command-backtick. Screenshots and the Dock go in the toolbar's shortcuts menu.
- **Section 9, physical keys:** the iPad builds the modifier set from the modifier keys it has seen go down, not from each event's flags (finding 2).
- **Section 9, hardware pointer:** trackpad momentum comes from the GameController scroll stream, or is synthesized from the release velocity, decided in Phase 2 (finding 5).
- **Section 20, risks:** add a risk that pointer lock is unreliable: medium likelihood, low impact, mitigated by absolute pointer mode, settled in Phase 6.

None is a no-go, so no ADR changes.

## Not covered

- **A clean pointer-lock run:** with Stage Manager off and no finger tap before the request.
- **Apple Pencil hover and pressure:** these are the Phase 6 experiment.
- **The software keyboard and dictation:** the Phase 2 text path.
- **The top function row** on the Magic Keyboard for iPad Pro, and the media keys.
- **Other keyboard layouts on the iPad.**
- **A repeat run** to confirm the inconclusive steps: Command alone, Control alone, Command-period.

## Reproduce

```bash
make generate
```

```bash
xcodebuild -project Farside.xcodeproj -scheme InputLogger -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Install it with `xcrun devicectl device install app`. Follow the on-screen checklist, then copy `Documents/s7-report.json` from the app's container with `xcrun devicectl device copy from`.
