# Secure Input / HID rejection investigation — 2026-09-09

Historical incident and implementation record. For current state see
[HANDOFF.md](HANDOFF.md) and the [September 23 incident](secure-input-20260923.md).
**Brave was quit in this September 9 incident, but was not quit during September
23 recovery.** Do not conflate the two or infer the later release cause.

## Observed incident and recovery

MicroManager's menu reports `IOHIDDeviceSetReport failed (0xE00002E2) — kIOReturnNotPermitted`.
A process sample shows the write-error callback disconnecting and reopening the pad.
Bluetooth reports connected and Herdr answers read-only requests.

The public Carbon `IsSecureEventInputEnabled()` query repeatedly returned true.
IORegistry's `kCGSSessionSecureInputPID` was successively reported as:

- Teams, PID 31825;
- the same PID after Teams exited;
- Ghostty, PID 7988, following a user lock/unlock cycle;
- Brave Browser, PID 591, on the latest check.

Treat this PID as the system's reported association, not proof that a single
application caused the original fault or that the field cannot be stale.

After the user quit Brave completely, `IsSecureEventInputEnabled()` returned
false and no Secure Input PID was reported. Without restarting MicroManager,
a subsequent five-second process sample captured HID writes and RPC response
processing, with no `scheduleReopen` or `markDeviceUnavailable` path sampled.
The user then confirmed that physical agent buttons worked again. Secure Input
clearing was followed by recovery without restarting MicroManager, Herdr, or the
pad. This supports the access-block mechanism below, but does not establish which
application originally caused the prolonged Secure Input state.

## Ghostty password detection

Installed Ghostty version: 1.3.1. Its bundled configuration documentation says
`macos-auto-secure-input` defaults to true and detection uses heuristics.

Tagged implementation:

- [Exec.zig](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/termio/Exec.zig):
  password input is inferred from `mode.canonical and !mode.echo`, with balanced
  state changes sent to the surface. This is terminal-mode detection, not a
  notification that sudo started or exited.
- [SecureInput.swift](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Features/Secure%20Input/SecureInput.swift):
  balances enables/disables, yields on application deactivation, and reacquires
  on activation if manual or focused scoped state still requests it.

A read-only `tcgetattr` check of the locally owned attached Herdr client TTY
(`ttys000`, Herdr PID 8144) showed `ICANON=false`, `ECHO=false`: normal raw-mode
flags, **not** Ghostty's password-input heuristic. No terminal contents or
keystrokes were read, and no terminal settings were changed. Thus the latest
check does not support a leftover password-mode flag on that outer Herdr TTY.
It cannot establish what happened earlier or inside a nested pane.

## Why the HID write was rejected

Apple's published implementations provide a direct mechanism consistent with
the observed error. These are source references, not a claim that we inspected
the exact compiled kernel on this Mac:

1. [IOHIDLibUserClient.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDLibUserClient.cpp)
   classifies devices whose primary usage is keyboard/keypad as keyboards
   (`fNubIsKeyboard`, approximately lines 480–488). The observed Bluetooth Codex
   Micro has keyboard primary usage with a vendor collection on the same device.
2. Its `resourceNotificationGated` checks `kIOClientPrivilegeSecureConsoleProcess`
   for such devices and sets client validity accordingly (approximately 562–644).
   [IOUserClient.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOUserClient.cpp)
   checks the console session's Secure Input PID against the requesting process
   (approximately 1493–1535). This is distinct from an Input Monitoring grant.
3. `setReport` in IOHIDLibUserClient rejects an invalid client with
   `kIOReturnNotPermitted` (approximately 1982–1996). The check covers the device,
   not just a particular keyboard report ID, explaining why vendor lighting and
   control traffic can also fail. `setValid` also changes HID queue availability.
4. In the pre-fix MicroManager source, `device.onWriteError` calls
   `markDeviceUnavailable`, closes the handle, and enters `scheduleReopen`, which
   retries every three seconds. Thus a temporary security restriction is shown
   and handled like a lost pad connection. Reopening cannot remove that restriction.

[Apple Technical Note TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)
states that Secure Input can block keyboard intercept processes even when the
process that enabled it is in the background. Applications must balance enables
with disables and release it when secure entry is no longer required.

[Chromium's password-input implementation](https://chromium.googlesource.com/chromium/src/+/main/ui/base/cocoa/secure_password_input.mm)
uses scoped, reference-counted enables/disables. This establishes a normal
password-protection mechanism in Brave's browser foundation; it does not identify
the exact Brave field, dialog, or bug involved in this incident. No browser
password contents, history, or saved credentials were inspected.

## What can and cannot be concluded

- The Secure Input/access-rejection/reconnect sequence is well supported by live
  observations, user-confirmed recovery, and the published access checks.
- Closing Brave was the final action after which protection cleared and the pad
  recovered. That does not prove Brave originally caused the entire sequence.
- The agent's elevated prompt is a plausible earlier trigger for terminal
  protection, but no evidence currently shows it left the outer Herdr terminal
  in password mode. The sampled flags were normal for a TUI.
- No historical enable/disable trace was available to establish whether a scope
  leaked, another legitimate secure field remained active, or macOS retained
  stale state. Reported PIDs changed, and one outlived its process in the readout.
- This does not establish that the earlier experimental background HID writer
  caused the same error. The currently installed synchronous transport also
  experienced it. Those deferred changes need separate validation.

## Prevention implemented 2026-09-09

1. Add an explicit `Paused by macOS Secure Input` status, separate from device
   disconnection or Input Monitoring denial. Show a reported app/PID only when
   available, qualify stale/unknown ownership, and retain the raw HID error.
2. While Secure Input is active, suspend normal HID traffic and reopening retries
   rather than repeatedly attempting denied access. Preserve independent Herdr
   read-only state and ordinary menu navigation where appropriate.
3. On the normal transition back to inactive, validate the device and active
   layer afresh, then repaint/re-enable hardware navigation. Never queue or replay
   button presses, approvals, or dictation actions across the protected interval.
4. Record timestamped state transitions, reported app identity, write error code,
   and recovery result in diagnostics. Do not record keys, terminal content,
   password fields, or credentials. These diagnostics aid investigation but do
   not prove which application caused or released a prolonged secure scope.
5. Keep password protection enabled. The goal is to prevent misleading silent
   freezes and recover cleanly, not to keep raw-HID access functioning through an
   OS security restriction. Do not install privileged helpers, change entitlements,
   globally disable automatic secure input, or force another application's secure
   scope off as a workaround.

## Installed implementation and validation

Implemented in `Sources/WLKit/SecureInputStatus.swift`, `BridgeController.swift`,
`WLDevice.swift`, and the menu views. The public Carbon state is checked every
200 ms and at physical request/input boundaries; reported owner metadata is
refreshed at most once per second while active. Real HID errors are retained
separately from proactive policy pauses. Transport callback generations and the
hardware input gate reject stale callbacks/status-waiting button events.

A cleared state schedules normal recovery after a three-second delay. Recovery
reads the keymap rather than rewriting it, and requires fresh layer/keymap
validation before enabling hardware input. Startup's existing keymap management
remains unchanged. Emulator and ordinary menu agent navigation remain usable.

Installed from `/tmp/micromanager-secure-input-fix-20260909`, preserving the
previous release's synchronous HID transport and lighting pipeline. Deferred
latency experiments remain in the primary working tree, merged with the new
security checks, but are **not** in this installed build. To reproduce this
release from this revision of the working tree, copy it into a separate staging
directory and check/apply `docs/secure-input-release-exclusions.patch` there.
Do not apply the exclusions to the primary working tree. The earlier focus-only
exclusions patch is historical and should not be used for this release.

Backup: `/tmp/MicroManager-before-secure-input-fix-20260909-112917.app`

Installed executable SHA-256:
`0b2ef2445f7c2d5437920771db0832acd92f4458bd77034dd38ec67e0b04ac36`

Validation:
- 89 staged Swift Testing tests passed: 14 Secure Input, 6 focus, 25 agent
  lighting, 10 layer lighting, and 34 dictation/media.
- Debug/release builds passed; installed signature verified.
- Live startup log: `Hardware input ready; fresh layer/keymap validated layer=2`.
- The merged primary working tree also builds; its 14 security and 12 deferred
  input-responsiveness tests pass.
- Full XCTest remains unavailable with Command Line Tools; the pre-existing
  non-Sendable WLDevice warning remains.
- Automated tests simulate security transitions through an internal injectable
  reader, without changing OS protection. The controlled live validation below
  subsequently confirmed the installed pause/recovery path.

### Live validation passed — 2026-09-09

The user manually enabled then disabled Ghostty's normal Secure Keyboard Entry
menu option; no password was entered and the assistant did not toggle security
through an API. Secure Input was off before and after the test.

- 12:02:37.211: `Secure Input active; reported association=Ghostty (PID 7988)`.
  The user pressed the top-left agent key once. The displayed session stayed put;
  read-only `agent.list` still identified `w6:p3` as focused. A five-second sample
  contained no HID-write, reconnect, or device-unavailable path.
- 12:03:55.617: `Secure Input cleared; scheduling fresh hardware validation (no input replay)`.
- 12:03:58.653: `Hardware validation starting; read-only recovery=true`.
- 12:03:59.131: `Hardware input ready; fresh layer/keymap validated layer=2`.
  Recovery completed 3.514 seconds after clear. The user waited without pressing
  another Micro key and confirmed that focus did not move; `agent.list` agreed.
- The user then pressed the top-left agent key again and confirmed it visibly
  switched to the intended different agent. Thus the old press was discarded and a fresh
  post-recovery press worked.

No MicroManager, Herdr, pad, or Mac restart was needed during validation.

No Secure Input disabling API, permission change, forced process termination,
or Herdr restart was performed as part of these checks or the preventive fix.

## Read-only ownership follow-up — 2026-09-30

The user chose to preserve running sessions after a keypad freeze following
unlock. Ghostty's manual menu was unchecked, a user-operated on/off toggle did
not establish recovery, and a subsequent user-operated Ghostty restart left
Carbon reporting Secure Input enabled with the old, exited PID association.
See [the current incident](HANDOFF.md#september-30-keypad-stuck-after-unlock-secure-input-reactivated).

### Public observation is not complete ownership introspection

The installed Apple macOS 27 SDK's `CarbonEventsCore.h`, lines 2970–3065,
documents balanced enable/disable counts, conditional cleanup after an application
crash if no other application has enabled protection, and a global Boolean query:
`IsSecureEventInputEnabled` reports whether **any process** has enabled it.
It does not return the count or a holder list. This is the public API contract,
not proof of which process or internal bookkeeping is responsible in this incident.
The header is under
`/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/`.
[Apple TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)
also describes any-process/background protection and the obligation to release
secure entry when no longer needed.

Published [XNU's secure-console privilege check](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOUserClient.cpp#L1490-L1532)
compares the requesting process against a single numeric console-session PID.
It does not test that association's liveness or enumerate Carbon callers.
[IOHIDFamily consumes this privilege result](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDLibUserClient.cpp#L569-L644)
to control keyboard-client validity. Neither published snapshot was established
as the installed macOS 27 implementation. No supported public read-only command
for resolving an exited association to all remaining holders was established.

### Why an unchecked Ghostty menu is inconclusive

Installed Ghostty metadata identifies version 1.3.1, build 15212, commit
`332b2aefc`. Its tagged [menu/action implementation](https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/macos/Sources/App/macOS/AppDelegate.swift)
sets the checkmark from the manual `SecureInput.global` flag, not the aggregate
enabled state. The [scope manager](https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/macos/Sources/Features/Secure%20Input/SecureInput.swift)
requests protection for `global || any focused scoped object`; switching the
manual flag off need not issue a disable when an automatic scope still requests
protection. This explains a diagnostic limitation, not current ownership.

The [automatic terminal heuristic](https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/src/termio/Exec.zig)
requires ICANON=true and ECHO=false. A read-only snapshot of the current outer
Herdr TTY instead found both false. That excludes the predicate at the sampled
instant, not every possible stale scope or another application's secure field.
No protected text or terminal contents were inspected.

### Remaining non-disruptive evidence path

Sampled HID registry classes exposed no additional secure-holder property.
Existing loginwindow logs recorded a release request just before the observed
clear/reactivation; this does not establish loginwindow as the current holder.
No matching Ghostty SecureInput entries were retained in the inspected historical
window. Ghostty's successful transitions use debug-level OSLog, and
[Apple documents logging persistence limits](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code);
missing historical rows cannot establish that no transition happened.

Passive, narrowly filtered unified-log observation can capture future naturally
occurring Ghostty transitions without changing protection or provoking activity:

```bash
/usr/bin/log stream --level debug --style compact \
  --predicate 'subsystem == "com.mitchellh.ghostty" AND category == "SecureInput"'
```

The tagged scope manager logs its own successful calls and OSStatus failures,
not every application's scope. This proposed observer was not launched as a
persistent service. Read-only registry snapshots, existing logs, TTY mode
metadata, and public state queries were exercised; no bypass, forced release,
new instrumentation, session interruption, build, or test was performed.
