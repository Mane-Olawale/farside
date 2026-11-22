# S5: Lock screen

**Result: go.** On macOS 26.0.1, screen capture keeps running through the lock screen at the full frame rate, and the frames show the lock screen. Keys posted by the host reach the password field. The real login password, typed by key code, unlocked the Mac 1.24 s after Return. Control-Command-Q locks the Mac, as section 6 assumes. Risk R2 is settled for macOS 26. macOS 27 is still untested.

Measured Nov 22, 2026 on a MacBook Pro M3 Pro (Mac15,6), macOS 26.0.1, U.S. keyboard layout, capturing the 3440×1440 main display at 30 fps. The person was at the Mac and typed their password into the probe's secure field. It stayed in the probe's memory and was never logged, written to disk, or shown to anyone else. The report and cropped password-field images are in `S5/`. The full snapshots stay in `~/Library/Logs/Farside/s5`, because they show the wallpaper and account picture.

## Method

`Tools/LockProbe` starts an `SCStream` on the main display with `HostCapture`, logs frame counts and lock state (`CGSSessionScreenIsLocked`) every second, and saves numbered snapshots. After Start, it:

1. Locks the Mac by posting Control-Command-Q through `EventInjector`.
2. Wakes the password field with a Shift press and a small pointer move.
3. Types "abc" by key code, erases it with three Deletes, then types "xyz" as Unicode text events and erases that too. A snapshot after each step shows whether characters reached the field.
4. Types the password by key code with `LayoutKeyMap`, then posts Return.

## Results

| Step | Time | Result |
| --- | --- | --- |
| Control-Command-Q posted | 0 s | Locked within 0.3 s |
| Capture while locked, 11 s | | 25–33 complete frames per second (30 requested), at most 2 idle per second, 0 errors, no restart |
| Captured image while locked | | The lock screen: clock, account picture, "Enter Password" field, and macOS's "Your screen is being observed" indicator |
| "abc" by key code | | Three dots in the field (`S5/04`) |
| Three Deletes | | Field empty again (`S5/05`) |
| "xyz" as Unicode text events | | Three dots in the field (`S5/06`) |
| Three Deletes | | Field empty again (`S5/07`) |
| Password by key code, then Return | | Unlocked 1.24 s later. All characters mapped to keys; none needed text events |
| Capture after unlock | | Continued at about 31 frames per second on the same stream |

## Findings

1. **Display capture works on the lock screen.** The host's `SCStream` keeps delivering complete frames of the lock screen while locked. There is no gap, black frame or restart at the lock or the unlock, so the iPad sees the lock screen and can drive it.
2. **Posted keys reach the password field.** The lock screen accepts both key codes and Unicode text events at the HID event tap. Secure input does not block the host's events.
3. **Key codes unlock the Mac.** That supports section 9's choice of real key codes for the lock screen password. `LayoutKeyMap` (in `HostInput`) maps characters to keys on the active layout with `UCKeyTranslate`, so the iPad's text reaches the field as the Mac's layout expects. Unlocking with Unicode text events alone was not tested; the dots show only the character count, not the characters.
4. **Control-Command-Q locks immediately.** Lock when session ends (section 6) can use it as planned.
5. **macOS marks the lock screen as observed.** The "Your screen is being observed" indicator appears on the lock screen during capture, so a person at the Mac can tell.

## Plan changes, applied Nov 22, 2026

- **Section 6, lock screen:** replace "The plan expects" with the measured result. Capture continues through lock and unlock, and key codes typed by the host unlock the Mac on macOS 26.
- **Section 20, risks:** R2 is settled for macOS 26. Keep it open for macOS 27 until the same probe runs there.

Neither is a no-go, so no ADR changes.

## Not covered

- **macOS 27.** Not available on this Mac. Rerun `make build-lockprobe` on a macOS 27 machine.
- **A sleeping display behind the lock screen.** The display stayed on through the 11 s locked. Phase 4 covers waking it from the iPad.
- **Unlocking by text events alone,** and passwords with characters only reachable through dead keys. The test password needed neither.
- **Other keyboard layouts.** The layout tests belong to Phase 2.
- **The login window after a reboot, FileVault, and fast user switching.** All are out of scope for v1 (section 6).
- **Unlocking from the iPad end to end.** The probe posted keys on the Mac itself; the iPad path arrives with Phase 2 input.

## Reproduce

Grant LockProbe Screen Recording and Accessibility. Run it only while you are at the Mac, because it locks the screen:

```bash
make build-lockprobe
```

```bash
open .build/DerivedData/Build/Products/Release/LockProbe.app
```

Type the password into its field, or leave it empty and unlock yourself, then click Start.
