# S6: Permissions

**Result: go, with one question still open.** Two of the spike's three questions are answered, and one is waiting:

| Question | Status |
| --- | --- |
| Which APIs report permission status reliably? | Answered. Several common preflight calls are stale for the life of the process, so the host must use the live signals in the table below |
| How often does the capture prompt return without the entitlement? | Waiting. It needs weeks of observation; an hourly check and a written log started on Nov 22, 2026 |
| Does macOS 27 show a separate Remote Desktop entry? | Not testable on this Mac |

Measured Nov 22, 2026 on a MacBook Pro M3 Pro, macOS 26.0.1. The probe app was new, with no prior grants, which stood in for a fresh install. A fresh user account was not used. Raw events are in `S6/events-2026-11-22.jsonl`.

## Method

`Tools/PermissionProbe` polls every status API from section 6 once a second and logs each change with a timestamp:
- `CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted` and `CGPreflightPostEventAccess`.
- `SMAppService.mainApp.status`, notification settings, and a Bonjour browser's state.
- Every 5 s, a ScreenCaptureKit display list and a real 64×36 screenshot.

Buttons request each permission or open its System Settings pane. The person granted each permission, relaunched the probe, then revoked Screen Recording and Accessibility while it ran.

## Results

| Signal | On grant, same process | After relaunch | On revoke, same process | Reliable as a live signal |
| --- | --- | --- | --- | --- |
| `CGPreflightScreenCaptureAccess` | Stayed denied (macOS offered to quit and reopen) | Granted | Stayed granted (stale) | No. Only at launch |
| `CGRequestScreenCaptureAccess` | — | Returned true | Still returned true after revoke (stale) | No |
| ScreenCaptureKit display list and real capture | Failed (error −3801) until relaunch | Worked | Failed with −3801 | **Yes. The only live screen recording signal** |
| `AXIsProcessTrusted` | Flipped to trusted in about 11 s | Trusted | Flipped to not trusted live | **Yes** |
| `CGPreflightPostEventAccess` | Stayed denied while `AXIsProcessTrusted` said trusted | Granted | Stayed granted (stale) | No. Only at launch |
| `CGRequestPostEventAccess` | Returned false repeatedly | Returned true | — | No |
| Notification authorization | Denied, then authorized, both live | Authorized | — | Yes |
| Bonjour browser state | "ready" from the first second, before any Local Network decision | ready | — | No. Says nothing about the grant |
| `SMAppService.mainApp.status` | notFound (never registered) | notFound | — | Not tested; needs registration (Phase 4) |

All four System Settings links opened the right pane, as the person confirmed:
- Screen Recording: `…security?Privacy_ScreenCapture`
- Accessibility: `…security?Privacy_Accessibility`
- Local Network: `…security?Privacy_LocalNetwork`
- Login Items: `com.apple.LoginItems-Settings.extension`

Revoking Screen Recording made macOS offer to restart the app; it did not force a quit.

## Findings

1. **Screen recording status must come from ScreenCaptureKit itself.** The preflight and request calls report the state at launch for as long as the process lives, in both directions. A running capture stream or a display list fetch fails with error −3801 once the grant is gone. That is what the host should watch, and what its permission-lost notice (Phase 4) should trigger on.
2. **A new grant needs a relaunch.** It takes effect only in a new process, which matches section 6's "after the app restarts" and the plan to exit and let launchd restart the host.
3. **For input, use `AXIsProcessTrusted`, not the post-event preflight.** `AXIsProcessTrusted` follows grants and revokes live. `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` stay at their launch value. Section 6 lists all three as if they were equivalent.
4. **Local Network has no status API.** A Bonjour browser reported ready with no decision made, so the host can only infer a denial from failed connections, and the onboarding row must say so.
5. **The guided-fix links work.** The four pane URLs are confirmed for macOS 26.

## The long-running check

An hourly LaunchAgent, `app.farside.permprobe.check`, runs a copy of the probe from `~/Library/Application Support/Farside`. Each run appends one line to `~/Library/Logs/Farside/s6/events.jsonl`: preflight status, Accessibility trust, and whether a real capture worked. No image is kept. When macOS asks for re-approval, these lines should show capture failing or stopping. The written log below records what the prompt said and when.

Remove the agent with:

```bash
sh Tools/PermissionProbe/uninstall-check-agent.sh
```

| Date and time | What macOS showed | Your answer | Capture in the hourly log afterwards |
| --- | --- | --- | --- |
| 2026-11-22 10:16 | Screen Recording granted to PermissionProbe | Allowed | Working |
| | | | |

## Plan changes, applied Nov 22, 2026

- **Section 6, permissions table:**
  - **Screen recording:** status comes from ScreenCaptureKit errors while running; the preflight call counts only at launch.
  - **Accessibility:** live status from `AXIsProcessTrusted`, and the post-event preflight only at launch.
  - **Local Network:** note that it has no status API.
- **Section 6, development notes:** add the four confirmed System Settings pane URLs.
- **Section 20, R1:** its mitigation records the cadence from the hourly log, starting Nov 22, 2026.

## Not covered

- **The re-approval cadence:** in progress, as above.
- **macOS 27's reported Remote Desktop privacy entry:** needs a macOS 27 machine.
- **A fresh user account.** A new app identity was used instead.
- **Login item registration and approval:** in Phase 4 with `SMAppService.agent`.
- **The Persistent Content Capture entitlement request:** only you can submit Apple's form.
