# MicroManager fork handoff

**Updated: 2026-09-23.** Start here rather than treating older incident notes as
current instructions. No application was installed or restarted for this handoff.

## Repository and checkpoint scope

- Public fork: https://github.com/mjmaley/micro-manager
- Parent: https://github.com/schacon/micro-manager
- Development branch: `layer-aware-herdr`; `origin` is the fork, `upstream` the
  parent. Preserve existing work and use normal fast-forward pushes to this branch.
- The September checkpoint preserves all accumulated media, lighting, focus,
  Secure Input, test, documentation, and **deferred latency** work. It is not a
  stable release promotion. Do not merge into `main` or create release tags merely
  to back up work: this repository's release workflow publishes on main/tag pushes.
- `git log -1`, `git status --short`, and `git rev-parse origin/layer-aware-herdr`
  establish the actual checkpoint and sync state; do not rely on a hardcoded
  commit ID in this file. The baseline before accumulated changes was `31f0322`.
- The official OMP hook installed outside this repository is **not** part of a git
  push. Its installation command and activation checks are documented below.

## Installed app is NOT the full branch build

Installed: `/Applications/MicroManager.app`, bundle ID `cc.worklouder.micromanager`.
Executable SHA-256, rechecked September 23:

```text
0b2ef2445f7c2d5437920771db0832acd92f4458bd77034dd38ec67e0b04ac36
```

This is the September 9 Secure Input build. It includes the Herdr focus repair,
media ownership, read-aware lighting, and one-time layer handoff, but uses the
**original synchronous HID writer and lighting pipeline**. The working branch
also includes `HIDWriteQueue.swift`, `PadLightingCache.swift`, background writes,
latest-wins lighting, changed-key/zone writes, and 120 ms input-quiet coalescing.
Those changes are preserved for later validation, **not installed or cleared for
production**. Secure Input alone can explain `kIOReturnNotPermitted`; the earlier
write-queue experiment was not proven to cause that error.

The original staging directory and app backups were under `/tmp` and may no
longer exist. Do not depend on them. The durable reconstruction is the checked-in
`docs/secure-input-release-exclusions.patch`; the older
`herdr-090-focus-only-exclusions.patch` is historical and wrong for this checkpoint.

### Reconstruct the synchronous source profile safely

Use the committed checkpoint, not a dirty tree. This reconstructs the source
profile, not a byte-identical binary across different toolchains. The current
local SwiftUI build blocker below must be resolved before packaging/installing.

```bash
# Run at the repository root after confirming the desired committed revision.
stage="$(mktemp -d "${TMPDIR:-/tmp}/micromanager-synchronous.XXXXXX")"
git archive HEAD | tar -x -C "$stage"
(
  cd "$stage" || exit 1
  git apply --check docs/secure-input-release-exclusions.patch || exit 1
  git apply docs/secure-input-release-exclusions.patch || exit 1
  for suite in SecureInputTests HerdrFocusTests AgentLightingTests LayerLightingTests DictationMediaTests; do
    ./scripts/test-swift-suite.sh "$suite" || exit 1
  done
)
printf 'Staged source: %s\n' "$stage"
```

Never apply the exclusions to the primary working tree. Check applicability after
future source edits; update the patch deliberately when equivalent guards move.
Before any actual installation, back up the installed bundle, verify signatures,
check running copies by exact path, and obtain physical validation. Do not launch
an old local `build/MicroManager.app`; it may predate critical fixes.

## Implemented behavior and source map

| Area | Behavior / key files |
|---|---|
| Dictation media | Actual Codex/OpenWhispr microphone use, independent of trigger. `DictationInputMonitor`, `DictationMediaSession`, `NowPlayingMediaBackend`, app `DictationMediaController`. Uses the installed OpenWhispr MediaRemote helper, not FineTune. |
| Playback ownership | Explicit pause/play; confirmed pause; idle debounce; brief uncertainty tolerated without acting; prolonged uncertainty, changed media, manual playback, disable/sleep/quit abandon ownership. Narrow Brave identity exception only while confirming pause. Never blindly resume. |
| Layer handoff | `LayerLightingState` and `BridgeController`: leaving a painted Herdr layer clears threads/zones once. Native Layer 1 may remain dark until Codex updates it. No fake keys, app activation, or handoff keymap writes. |
| Read-aware keys | `AgentLightingTracker`: working amber, blocked red breathing, unacknowledged completion green, idle/seen white, unknown neutral. Green remains while viewed; leaving the foreground pane acknowledges it. No timer. |
| Ring / menu | Ring follows the selected Herdr agent, even off-page or while terminal is backgrounded. Menu icon uses raw aggregate state across agents. These are intentionally different. |
| Navigation | `HerdrClient.focusAgent` uses public `pane.focus` with `pane_id`, rejects blank targets/mismatched acknowledgements. Physical buttons and notification clicks share it. No fallback synthetic keys. |
| Secure Input | `SecureInputStatus`, `HardwareInputGate`, `WLDevice`, `BridgeController`, menu views. Show paused status, suppress HID/reopen churn, discard stale events, then reopen/read-validate layer/keymap before accepting fresh input. No replay and no security bypass. |
| Deferred latency | `HIDWriteQueue`, `PadLightingCache`, transport/callback changes, coalescing worker, `InputResponsivenessTests`. Keep separate from the installed source profile until hardware validation. |

All agents are observed, but only the current six get key lights/menu rows.
Joystick left/right pages when no model picker intercepts it. `agent.list` order
is workspace → tab → pane traversal, not Herdr's priority/custom Agent view sort.
Notifications can surface off-page blocked/completed transitions if enabled and
permitted; they suppress the currently viewed foreground agent. There is no
individual-key history log with which to reconstruct the previous 30 seconds.

### Ring attention proposal — NOT implemented

The user asked for the outer ring to expose off-page completions and questions.
Proposed priority: breathing red for any blocked agent, then breathing green for
an off-page unacknowledged completion, otherwise the selected agent's status.
This would make the ring attention-first without shuffling key assignments.
Work paused to fix OMP reporting and investigate Secure Input. Do not claim this
behavior is installed. Confirm the policy before implementing and test simultaneous
blocked/completed states, focus acknowledgement, page changes, and layer handoff.

## Latest live state and incidents

### September 23: pad recovered; release cause unknown

Secure Input is currently off, only the installed MicroManager is running, and
HID writes/RPC replies were sampled after user-confirmed recovery. No app restart
was needed. The user explicitly **did not quit Brave**; its PID stayed unchanged.
Do not attribute this recovery to Brave quitting or blame Brave for this episode.

The reported Secure Input association moved from Ghostty to loginwindow after a
normal lock/unlock. Ghostty's manual menu option had been unchecked, and checking/
unchecking it did not immediately clear the flag. Its outer terminal was normal
raw TUI mode (`ICANON=false`, `ECHO=false`), not the password heuristic. There was
no observed password prompt. A short foreground-switch observer expired before
the response and did not identify the foreground app, so that test was inconclusive.

An obsolete September 5 local build also briefly ran alongside the installed app
and retried opening the device. It subsequently exited; the assistant did not
terminate it. This was an extra contention risk, not proof of the secure-scope
cause. See [the incident record](secure-input-20260923.md).

The **separate September 9** incident did clear after the user quit Brave; that
older observation must not be substituted for the September 23 facts. The
September 9 fixed build passed a controlled live pause → no-replay → recovery →
fresh-agent-press test (about 3.5 seconds after clearing).

### OMP reporting: hook is now installed AND loaded

September 22 diagnosis found Herdr's OMP integration missing. OMP panes fell back
to idle rather than reporting lifecycle state, explaining missing working/blocked/
completion transitions upstream of MicroManager. The user authorized only:

```bash
herdr integration install omp
```

It installed the official v10 hook at
`~/.omp/agent/extensions/herdr-omp-agent-state.ts`. No other integration or running
session was changed by the assistant. September 23 read-only checks now show
**all six current OMP panes have `full_lifecycle_hook_authority`**, with no fallback
reason, and are idle. Pi's v8 hook remains unchanged (Herdr offers v9).

Still pending: a user-observed OMP working → question/approval → resumed → finished
cycle compared against Herdr metadata and the appropriate keypad key. Hook
activation alone does not prove every transition/UI edge case. Use `herdr agent
explain <pane> --json` and `agent.list`, not fabricated status reports. Existing
sessions that have not loaded an integration need an explicit safe activation;
OMP 18.2.10 has `/restart` to resume the same session with the same launch flags.
Never send it into active work automatically. `/reload-plugins` was not established
as an extension-runtime reload. See [OMP investigation](omp-status-investigation.md).

## Environment and validation at checkpoint

Current machine: macOS 27.0; Swift 6.4; Command Line Tools selected at
`/Library/Developer/CommandLineTools`. Herdr CLI/server: 0.9.1. Ghostty: 1.3.1.
OMP installed CLI: 18.2.10 (not proof of every existing process version).

**September 23: 101 targeted Swift Testing tests pass in the primary branch:**

```bash
./scripts/test-swift-suite.sh SecureInputTests          # 14
./scripts/test-swift-suite.sh HerdrFocusTests            # 6
./scripts/test-swift-suite.sh AgentLightingTests         # 25
./scripts/test-swift-suite.sh LayerLightingTests         # 10
./scripts/test-swift-suite.sh DictationMediaTests        # 34
./scripts/test-swift-suite.sh InputResponsivenessTests   # 12, deferred experiment
```

The standalone runner explicitly selects SwiftPM's native build system because
Swift 6.4 defaults to `swiftbuild`, whose module/object layout differs. WLKit
builds successfully under that runner. Reconstructing the synchronous profile
from the staged checkpoint and applying the exclusions patch also passed all
**89 targeted tests on September 23**. The original synchronous release had
successful debug/release/signature validation on September 9; that historical
full-app validation is distinct from the current library-only checks.

**Current full-app build is blocked by the updated local toolchain:** both default
and native `swift build` fail in `WLInspector/ContentView.swift` because
`SwiftUIMacros.StateMacro` / the `SwiftUIMacros` plugin cannot be found. Do not
misreport the historical successful release build as a successful macOS 27 rebuild.
Full XCTest also remains unavailable (`import XCTest` fails with the selected
CLT). Obtain a matching complete toolchain or investigate the SDK/plugin mismatch
separately; do not rewrite application state behavior just to mask it. The known
non-Sendable `WLDevice` warning also remains. No new bundle was installed.

With full Xcode, prefer `swift test --skip Live` before considering live suites;
bare `swift test` can discover actual devices/services. Tests cannot establish
Bluetooth timing or lighting ownership against another writer on their own.

## Next work, in order

1. Verify an actual OMP lifecycle/question cycle end-to-end with the user. Record
   which page/key and raw Herdr status disagree if a mismatch remains.
2. Resolve the macOS 27 / Swift 6.4 build environment before attempting installation.
3. Confirm and implement the ring-attention policy separately from deferred latency
   work; preserve current completion acknowledgement and layer/security guards.
4. If latency work resumes, validate background HID writing on the physical device
   without Secure Input active and distinguish errors from permission/OS gating.
   Core Audio sampling on the main thread is another known possible latency source.
5. Consider single-instance protection or safer build-bundle handling, and better
   durable transition diagnostics. Do not claim to know why an OS scope stayed on
   merely from a reported PID, missing prompt, or a short process sample.

## Read-only checks and references

```bash
pgrep -fl 'MicroManager|WLMicroManager'  # inspect exact paths; do not pkill broadly
shasum -a 256 /Applications/MicroManager.app/Contents/MacOS/MicroManager
swift -e 'import Carbon; print(IsSecureEventInputEnabled())'
herdr status server
herdr integration status
herdr agent list
herdr agent explain <pane-id> --json
/usr/bin/log show --last 15m --style compact --info \
  --predicate 'subsystem == "cc.worklouder.micromanager" AND category == "HardwareInput"'
```

- [Secure Input implementation / original investigation](secure-input-investigation.md)
- [September 23 incident](secure-input-20260923.md)
- [OMP status investigation](omp-status-investigation.md)
- [Herdr agent ordering](herdr-agent-ordering.md)
- [Historical Herdr 0.9.0 focus repair](herdr-090-focus-fix.md)
- [Media / FineTune research](voice-media-finetune-research.md)

Temporary traces/source downloads are only supporting artifacts and may vanish.
Keep the durable findings here; do not commit raw terminal transcripts, credentials,
private project names, device snapshots, binaries, or session files to this public fork.
