# Secure Input / pad recovery — 2026-09-23

## Observations

- At 10:37 EDT, the user reported a frozen pad. Codex Micro remained present in
  IORegistry. Carbon reported Secure Input enabled, associated in IORegistry with
  Ghostty PID 51136. Association is diagnostic metadata, not proof of a prompt or
  of the process responsible for keeping the protection active.
- Installed MicroManager PID 27920 had the known September 9 Secure Input build
  (SHA-256 `0b2ef2445f7c2d5437920771db0832acd92f4458bd77034dd38ec67e0b04ac36`).
  Its sample showed the protection monitor, without HID-write/reopen paths.
- A second MicroManager, PID 40889, had launched at 10:36:46 from
  `build/MicroManager.app` in the repository. That executable was dated September
  5, before the Secure Input fix (SHA-256
  `4251f72cbd7e3dfb73229f91e3c1096b49b11a9b1b75c6ed2d5345e781966183`).
  Its sample showed repeated reopening. By 10:45 only the installed copy remained.
  The assistant did not terminate either process.
- The user reported no secure/password windows and found Ghostty's manual Secure
  Keyboard Entry unchecked. Checking and unchecking it did not clear the OS flag
  in the subsequent observation.
- Ghostty 1.3.1 had one terminal (`ttys000`, running the Herdr client). Read-only
  terminal flags were `ICANON=false`, `ECHO=false`, normal raw TUI mode rather
  than Ghostty's canonical/no-echo password heuristic.
- A two-minute read-only observer never saw Secure Input clear, but foreground
  app lookup returned unknown and the observer expired before the user's reply.
  The requested Finder-focus test was therefore inconclusive.
- The user locked and unlocked the Mac normally. At 11:13, Secure Input was still
  enabled; IORegistry now associated it with loginwindow PID 26605. No loginwindow
  termination, security API disabling, or session restart was attempted.
- The user subsequently reported recovery. Carbon then reported Secure Input
  disabled. At 11:30, a four-second sample of the same MicroManager PID 27920
  showed `IOHIDDeviceSetReport` and `drainRPC`, with no sampled reopening or
  device-unavailable paths. Brave was still running under the same PID 26750;
  recovery cannot be attributed to quitting/restarting Brave.

## Conclusion and limits

Protection eventually cleared and the installed MicroManager resumed without
being restarted. The original trigger and the action/timing that released Secure
Input remain unknown. The changed PID associations do not establish that either
Ghostty or loginwindow leaked the state. No legitimate password prompt was
observed. The separate obsolete app instance was an additional contention/retry
risk, not proof of the cause of Secure Input.

No application security settings, source code, running agents, or Herdr server
were changed by the assistant during this incident. Do not globally disable
Ghostty's automatic protection or kill loginwindow as a workaround.

## Evidence

- Carbon `IsSecureEventInputEnabled()`; IORegistry Secure Input PID metadata.
- `ps` process ancestry and read-only `tcgetattr` of Ghostty's terminal.
- `/tmp/micromanager-pad-20260923-27920.sample.txt`
- `/tmp/micromanager-pad-20260923-40889.sample.txt`
- `/tmp/micromanager-after-secure-toggle-20260923.sample.txt`
- `/tmp/micromanager-secure-focus-check.log`
- `/tmp/micromanager-pad-recovered-20260923.sample.txt`
- Ghostty's [SecureInput.swift at v1.3.1](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Features/Secure%20Input/SecureInput.swift): balanced enable/disable and release on deactivation are intended behavior, not proof those transitions occurred correctly in this episode.
