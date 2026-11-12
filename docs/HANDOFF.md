# MicroManager fork handoff

**Updated: 2026-11-12.** Start here rather than treating older incident notes as
current instructions. Installed applications and existing user sessions remain
unchanged; the Herdr fork trial used disposable isolated instances only.

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
**November 12 (user-approved): the herdr-core synchronous build is installed.**
Executable SHA-256:

```text
e8425c02ceb60b2efabbb2df3c16c46dd83f3ec2714ad03efff6eb25de86ca29
```

Built from commit `fe76859` with the reconstruction recipe below and
`WL_MACOS_SDK=…/MacOSX26.5.sdk ./scripts/bundle.sh` (`minos 13.0 sdk 26.5`,
ad-hoc, designated requirement `identifier "cc.worklouder.micromanager"`).
Previous September 9 build (`0b2ef244…ac36`) backed up with `ditto` to
`~/.config/micromanager/app-backups/MicroManager-pre-herdr-core-20261112.app`
(signature verified). Installation: verified PID 2227's exact path, SIGTERM,
`ditto` the staged bundle, `open`. The new process started from
`/Applications`, is the only copy, and a process sample showed its
`HerdrClient.loadSnapshot` → `herdr-core`/`herdr-app` polling. The pad was
absent from the HID bus both before (old app's log) and after installation, so
lighting, keys, Input Monitoring carry-over, and focus actions are unverified
until the pad reconnects. To roll back: quit it, `ditto` the backup back.

Like the September 9 build, it uses the
**original synchronous HID writer and lighting pipeline**. The working branch
also includes `HIDWriteQueue.swift`, `PadLightingCache.swift`, background writes,
latest-wins lighting, changed-key/zone writes, and 120 ms input-quiet coalescing.
Those changes are preserved for later validation, **not installed or cleared for
production**. Secure Input alone can explain `kIOReturnNotPermitted`; the earlier
write-queue experiment was not proven to cause that error.

Older staging directories and the September backups under `/tmp` may no
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
  for suite in SecureInputTests HerdrFocusTests HerdrMachineTests AgentNotificationTests LayerLightingTests DictationMediaTests; do
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

### herdr-core adapter — source only

The November 12 cutover replaces the TUI-fork adapter. It is committed on
`layer-aware-herdr` and its synchronous build is **installed** (see above); pad
behavior awaits physical validation. The
`mjmaley/herdr` fork branch is no longer used by MicroManager.

The committed recipe above (with the regenerated patch) passed 80 synchronous
tests and `WL_MACOS_SDK=…/MacOSX26.5.sdk ./scripts/bundle.sh` produced a staged
bundle: `minos 13.0 sdk 26.5`, ad-hoc signed with the same designated requirement
as the installed app (`identifier "cc.worklouder.micromanager"`), executable
SHA-256 `e8425c02ceb60b2efabbb2df3c16c46dd83f3ec2714ad03efff6eb25de86ca29`. It was
then installed from that stage (see [installed app](#installed-app-is-not-the-full-branch-build)).

- `HerdrClient` reads `terminal.list` through `herdr-core connect` (JSON-RPC on
  stdin/stdout, one process per request) plus `herdr-app ls` and `herdr-app
  status`, every `pollInterval` (2.5 s) and on frontmost-app changes.
  `HerdrSnapshot` keeps live terminals with an OSC 7501 status, applies the
  app's `herdr.seen` (done with `seen >= turn` → idle), orders by app placement
  (space → tab → terminal → sub-agents) then core order, and marks the agent in
  `focused_pane`. Without the app, agents keep core order and none is focused.
  A non-connected machine is reported in `lastError`. `AgentLightingTracker`,
  `HerdrClientSnapshot`, `HerdrBinaryCapabilities`, the TUI picker, and
  `WL_HERDR_BINARY`/`WL_HERDR_CLIENT_ID` are removed.
- `HerdrAgentTarget` is address (`t7`, `machine/t7`) + `created_ms`. Every
  action first re-reads `terminal.get` and refuses a different/ended occupant
  (read-before-action, not atomic). Focus: `herdr-app do agent.focus`; keys:
  `terminal.keys`; slash commands (`/fork`, `/model`, `/effort`, `/thinking`):
  `terminal.send` (pastes + Enter, waits for a draft, refuses blocked);
  tab cycling: `herdr-app do tab.next`. Unsubmitted macros are typed as named
  keys and refuse `?`, `!`, `:`, newlines, and non-ASCII before typing, because
  herdr-core has no unsubmitted paste and shifted punctuation has no key name.
- `error` status lights solid red, ranks after blocked, and raises an attention
  notification. Raise target defaults to `dev.herdr.app`. Binaries default to
  `~/.local/bin/herdr-core` / `herdr-app` (GUI apps lack the login PATH);
  `WL_HERDR_CORE_BINARY` / `WL_HERDR_APP_BINARY` override.
- `docs/secure-input-release-exclusions.patch` was regenerated: same exclusions,
  minus three context lines that referenced the removed tracker.

Verification: primary standalone suites 92 tests (Herdr machine 8, focus 4,
notifications 10, Secure Input 14, layer 10, dictation 34, input responsiveness
12); synchronous staging (HEAD archive + current Sources/Tests + new patch)
80 tests. WLMicroManager compiles except the known SwiftUI `@State` macro
errors. A read-only live snapshot against the user's core/app returned both
agents (local focused OMP, remote `rohan/t1` idle-after-seen) in ~100 ms.
Actions were exercised only in a disposable `HC_SESSION` core running `cat`:
typed text, unspellable-text refusal, Enter, submitted `/fork`, and stale-target
refusal behaved as designed (~0.3 s per key action, ~1 s per send). No action
was sent to a user terminal; `agent.focus`/`tab.next` on the real app window,
physical HID, and installed-app behavior remain unverified.

## Implemented behavior and source map

| Area | Behavior / key files |
|---|---|
| Dictation media | Actual Codex/OpenWhispr microphone use, independent of trigger. `DictationInputMonitor`, `DictationMediaSession`, `NowPlayingMediaBackend`, app `DictationMediaController`. Uses the installed OpenWhispr MediaRemote helper, not FineTune. |
| Playback ownership | Explicit pause/play; confirmed pause; idle debounce; brief uncertainty tolerated without acting; prolonged uncertainty, changed media, manual playback, disable/sleep/quit abandon ownership. Narrow Brave identity exception only while confirming pause. Never blindly resume. |
| Layer handoff | `LayerLightingState` and `BridgeController`: leaving a painted Herdr layer clears threads/zones once. Native Layer 1 may remain dark until Codex updates it. No fake keys, app activation, or handoff keymap writes. |
| Read-aware keys | `HerdrSnapshot` applies the Herdr app's `herdr.seen`: working amber, blocked red breathing, error red, unseen done green, idle/seen white, unknown neutral. MicroManager keeps no read state. |
| Ring / menu | Ring follows the agent in the Herdr app's focused pane, even off-page or while the app is backgrounded. Menu icon uses the aggregate across agents. These are intentionally different. |
| Navigation / input | `HerdrClient`, `HerdrAgentTarget`, and `BridgeController`: address + start-time targets, occupant re-read before each action, app `agent.focus`/`tab.next`, core `terminal.keys`/`terminal.send`. No synthetic macOS keys. |
| Secure Input | `SecureInputStatus`, `HardwareInputGate`, `WLDevice`, `BridgeController`, menu views. Show paused status, suppress HID/reopen churn, discard stale events, then reopen/read-validate layer/keymap before accepting fresh input. No replay and no security bypass. |
| Deferred latency | `HIDWriteQueue`, `PadLightingCache`, transport/callback changes, coalescing worker, `InputResponsivenessTests`. Keep separate from the installed source profile until hardware validation. |

All agents are observed, but only the current six get key lights/menu rows.
Joystick left/right pages when no model picker intercepts it. Ordering is the
Herdr app's space → tab → terminal placement (sub-agents after their parent),
then agents the app does not show, not the app's status-sorted Agents list.
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

### November 12: Herdr moved to herdr-core + Herdr app

Read-only survey. The user now runs `herdr-core`/`hc` 0.1.20 (from
`~/.local/bin`) and `~/Applications/Herdr.app` 0.1.15 (`dev.herdr.app`); no
`herdr server` 0.9.x is running (Homebrew `herdr` 0.9.5 is still installed).
The installed MicroManager (September 9 build, old server socket) and the
uncommitted fork adapter (`herdr client …`, `controller-capabilities`) both
target the retired runtime; neither can see herdr-core terminals.

New contract, observed locally:

- Core API: JSON-RPC on `~/.local/state/herdr-core/default/default.sock`, documented
  by `hc schema` (OpenRPC). `terminal.list` / `events.subscribe` already include
  connected machines as `machine/tN`; machine aggregation is native, so the
  `mjmaley/herdr` client-control fork is no longer needed.
- Status is the program's OSC 7501 record: `status.state` ∈ idle, working,
  done, blocked, error (`kind` permission/question/auth); null if never reported.
  `status.app` names the agent (`omp`, `claude-code`). OMP reports natively;
  TUI-era hooks need `HERDR_ENV` and do not run under hc.
- Read tracking moved into the app: label `herdr.seen` holds the last viewed
  `turn`; the app shows `done` as idle once `seen == turn`.
- Input: `terminal.keys` (named keys) and `terminal.send` (paste **plus Enter**,
  waits for the person's draft, refuses blocked programs unless `force`).
  There is no paste-without-submit. Disposable isolated-session probe:
  `hc keys` ≈55 ms per CLI call; `hc send` ≈1 s.
- UI: `herdr-app status` (`focused_pane`, `agent`, `space`, `tab`), `herdr-app ls`
  (spaces → tabs → terminals with pane IDs/machine), and `herdr-app do
  agent.focus|pane.focus|tab.next|agent.next …`. No push/subscribe for UI focus
  was found; `view.json` is app-written state, not a documented contract.

The probe used `HC_SESSION=mmprobe`, then stopped that core and removed its state;
the default core (same PID/uptime) and its terminals were untouched. The user
then approved the cutover; see [herdr-core adapter](#herdr-core-adapter--source-only).

### October 5: connected external machine missing from pad agents

The user connected an external Herdr instance and reported that its sessions
were absent from keypad assignments/status updates. Read-only checks found
Herdr 0.9.3, one enabled/reachable saved SSH machine, four agents returned by
the local `agent.list`, and five additional agents returned by
`herdr --machine <profile-id> agent list`. The remote list included a working
OMP pane with `full_lifecycle_hook_authority` and no fallback reason. Another
remote pane used `default_known_agent_idle_fallback`; its reporting is a
separate issue, not the cause of all remote agents being absent locally.
Three remote snapshots five seconds apart showed unchanged states/sequences;
no natural status transition or event delivery was verified.

Only `/Applications/MicroManager.app` was running; its executable still matched
the September 9 hash above. Secure Input was off during this check.
The installed local-only `HerdrClient` uses one socket for enumeration, requests,
and subscriptions; the new source adapter described above replaces that path.
Herdr's combined machine list belongs to the TUI, not that server's JSON API.
The 0.9.3 schema has no machine selector for `agent.list`, pane targets, or events.
This establishes a discovery/routing gap; no hardware recovery or hook reinstall
can make the existing local-only client enumerate those remote agents.

Remote status is reachable today via saved-machine CLI queries or a separate
remote socket transport. Multi-machine support must namespace identities by
machine/session as well as pane, including notifications and completion tracking.
Visible cross-machine navigation also needs a supported TUI endpoint-selection
API: remote server focus is not equivalent to selecting that machine in the
existing client. Do not implement a status-only merge and claim full keypad
navigation, or work around this with synthetic keys.

Sources: [connected machines](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.3/docs/next/website/src/content/docs/connecting-machines.mdx),
[socket API](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.3/docs/next/website/src/content/docs/socket-api.mdx),
and [method schema](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.3/src/api/schema.rs).
No application/session/integration/hardware changes or input injection were made.

Pending upstream support was checked the same day: none of the 15 open PRs,
master `c4653a4f10502601ac110b12b2c45a5f7134082b`, or the published preview
exposes external TUI machine selection. The exact request is already
[discussion #4396](https://github.com/herdrdev/herdr/discussions/4396), raised
by another hardware-controller author; no implementation or release commitment
was visible. Per-machine CLI routing is already shipped, not pending.
See [upstream support findings](herdr-external-machine-api.md) for pinned sources
and related merged PRs. No preview/master binary was installed or exercised.

The user subsequently authorized trying an implementation in a fork.
Created https://github.com/mjmaley/herdr and cloned it to
`/Users/mmaley/Tools/herdr`; branch `feature/client-machine-control` starts from
stable `v0.9.3`. Implemented a separate private per-full-TUI JSON control socket:
`client.snapshot` exposes machine-scoped online metadata, and `client.focus`
selects a machine/pane through the existing coherent activation transaction.
Existing server/client wire codecs are unchanged. More than one live TUI
requires an explicit client ID; navigation never broadcasts.

The implementation is integrated and built at
`/Users/mmaley/Tools/herdr/target/debug/herdr`. Native macOS validation passed
`just lint`, the complete `just test` recipe (3,720 Rust tests passed, 12 skipped),
`cargo build --locked`, and localized draft-document heading parity. Use pinned
Rust 1.96.1, Zig 0.16.0, and Bun 1.4.2; isolated toolchains are under
`/Users/mmaley/Tools/_ai-working/toolchains/`. Homebrew's Rust 1.99 adds unrelated
lint failures, and the previously installed Bun 1.2.21 mishandles YAML `on`.

The runtime smoke used two real disposable local servers, full TUIs in PTYs,
and an isolated SSH shim executing the real discovery/stdio bridge. Observed
Local-to-Remote-to-Local pane switching and destination terminal markers,
identical pane IDs scoped to different boot/machine IDs, rejection of a pane
from the wrong machine, explicit targeting with two TUIs, and same-machine
pane switching. Disconnecting the selected test server exposed a frozen-screen
recovery bug; a failing regression test reproduced it, and both the fixed
regression and a fresh runtime trial confirmed API recovery to Local.
Offline metadata is excluded. All disposable processes and artifacts were removed.
No real SSH-host trial, physical keypad test, or installed-client cutover occurred.
Windows remains compile/runtime-unverified: the user chose macOS-only verification
instead of Microsoft SDK/license setup.

The user approved commit message
`feat(client): add machine-aware control of running TUI`.
Published [commit `a0f0c31e`](https://github.com/mjmaley/herdr/commit/a0f0c31e)
on [`feature/client-machine-control`](https://github.com/mjmaley/herdr/tree/feature/client-machine-control).
The HTTPS credential lacked `workflow` scope; publication used existing verified
GitHub SSH authentication over port 443 instead. This checkout's `origin` now
uses `ssh://git@ssh.github.com:443/mjmaley/herdr.git`, with repo-local SSH host-key
alias `github.com`; no global SSH configuration or OAuth scope was changed.
The unrelated visualization interruption was explicitly withdrawn.
See [fork trial procedure](herdr-external-machine-api.md#fork-implementation-and-trial)
before any live trial. MicroManager's installed local-only adapter is unchanged.
The subsequent source adapter cutover above is not an installed keypad cutover.

### September 30: keypad stuck after unlock; Secure Input reactivated

The user reported keypad state stuck after unlock. Read-only checks found
Secure Input active, with the Codex Micro still enumerated over USB. Only the
installed MicroManager was running under the same PID; its executable SHA-256
still matches the September 9 build above. Herdr server remained healthy at
0.9.1, and `agent.list` returned five idle, one done, and one working agent.

MicroManager logged Secure Input clearing at 09:48:24.780 and becoming active
again at 09:48:25.197, a 417 ms gap. This was shorter than its three-second
hardware-reopen delay. The reported association was Ghostty, resolving to its
running application path. A later live metadata check still found protection
active while Microsoft Teams was foreground. Association does not establish
which application is keeping the scope active or whether a password prompt exists.

An eight-second process sample captured the Secure Input monitor, Herdr polling/
refresh, and socket readers; it contained no sampled HID-write/reopen path.
The current observed blocker is protection gating, not pad absence or a stopped
Herdr feed. MicroManager deliberately releases HID and withholds hardware input/
lighting writes while Secure Input is active; the pad may retain its old colors.
The underlying reason protection reactivated after unlock remains unknown.

The user confirmed Ghostty's Secure Keyboard Entry menu was unchecked, then
manually turned it on and off again. Subsequent read-only Carbon checks still
reported Secure Input active; IORegistry still associated the scope with Ghostty.
The pad remained present over USB. A five-second MicroManager sample captured
the protection monitor and Herdr polling, without sampled HID writes. No new
HardwareInput entries appeared in the inspected six-minute log window; a brief
unsampled transition cannot be excluded. The toggle did not establish recovery.

The user subsequently restarted Ghostty. Its new PID was 72018, but Carbon still
reported Secure Input active and IORegistry still reported the exited Ghostty
PID 51136. MicroManager logged an unknown/exited association at 09:58:34.355.
This is stale association metadata, not evidence that the new Ghostty process
owns the scope. Protection remained active while another application was
foreground. The underlying holder/release failure remains unidentified.

The pad remained present over USB; Herdr returned all seven agents, including
one working and one done. The same installed MicroManager process continued its
protection monitor and Herdr refresh path in a five-second sample, without
sampled HID writes. Restarting Ghostty did not establish recovery.

Do not repeat the menu check or restart additional apps based on the stale PID.
A normal macOS logout/login is a possible disruptive session-recovery option,
not an established fix; preserve work and obtain approval before any such action.
Never globally disable protection or kill loginwindow. Once the scope clears,
verify fresh layer/keymap validation and a user-operated key. No security
settings, applications, agents, or hardware state were changed by the assistant.

#### Additional read-only ownership checks

The user chose to preserve running sessions rather than prepare logout/login.
No additional secure-holder field was found in the sampled IOHIDSystem,
IOHIDUserClient, IOHIDParamUserClient, IOHIDEventSystemUserClient, or
IOHIDLibUserClient registry entries. IOHIDUserClient identified WindowServer
as its creator; that identifies a HID client, not the Secure Input holder.
IOResources still exposed the old console-session association.

Existing loginwindow diagnostics recorded a secure-input release request at
09:48:24.756, before MicroManager's observed clear and subsequent reactivation.
This does not establish loginwindow as the current holder. The inspected
twenty-five-minute WindowServer/loginwindow/hidd log window contained no later
matching secure-input entries; absent logs are not proof of absent scopes.
No Ghostty SecureInput-category entries appeared in the inspected thirty-minute
window. Its current outer Herdr terminal had ICANON=false and ECHO=false, normal
raw-TUI mode rather than the tagged Ghostty password heuristic. Terminal contents
were not read and flags were not changed.

Primary-source follow-up confirmed that the public query reports any-process
state, while the registry PID is a single authorization association, not a
complete holder list. No supported public read-only holder-enumeration command
was established. Ghostty 1.3.1's unchecked menu reflects only manual demand;
automatic scoped demand is separate. The final live check still reported
protection active with the exited PID association. No non-disruptive forced
recovery path was established. See the cited
[ownership follow-up](secure-input-investigation.md#read-only-ownership-follow-up--2026-09-30)
for source limits and a proposed passive Ghostty transition-log observer.

### September 29: live agent reporting; pad absent from HID enumeration

Read-only status diagnosis found only `/Applications/MicroManager.app` running;
its executable still matches the September 9 SHA-256 above. Herdr server is
0.9.1 and its OMP integration remains current at v10.

- Seven OMP panes all report `full_lifecycle_hook_authority`, with no fallback
  reason. Live `agent.list` observations included working states and a natural
  working → done change with an advancing `state_change_seq`. The final snapshot
  had five idle, one done, and one working pane. This is evidence of live reports,
  not validation of question/approval handling or every pane's state accuracy.
- A six-second sample of the installed MicroManager captured `startPoll` →
  `refresh` and eight long-lived `SocketConnection.readLoop` stacks, consistent
  with lifecycle plus seven per-pane subscriptions. The sample does not expose
  the app's exact agent snapshot or prove physical lighting delivery.
- A separate read-only subscription using MicroManager's per-pane status-event
  filters was acknowledged. No natural transition occurred during that
  twenty-second window; event delivery remains unverified.
- Secure Input was false. MicroManager's recent hardware diagnostics repeatedly
  reported no Work Louder device on the HID bus. An independent read-only
  `IOHIDManager` enumeration opened successfully and found zero vendor `0x303A`
  devices. Pad lighting cannot update while the device is unavailable; sleep,
  power, and transport-disconnection causes were not distinguished.

Next: physically wake/check the pad connection, then compare a real agent
transition with the current page/key and menu. Herdr reporting is not showing
the old missing-hook idle fallback. Do not restart agents or install a build to
address a device absent from HID enumeration. No sessions, integrations,
hardware settings, or statuses were changed; no synthetic input was sent.

#### Post-restart function check

After the user reported restarting the device and completing an update, the pad
was visible again as **Codex Micro over USB** (vendor `0x303A`, product `0x8360`).
The diagnostic enumerator found one matching HID device; its manager-open call
returned `kIOReturnNotPermitted`, so this probe establishes enumeration, not
permission to communicate. It sent no device reports.

The installed MicroManager retained the same PID. A ten-second process sample
captured its automatic reopen path registering the input-report callback and
issuing `IOHIDDeviceSetReport` from `WLDevice.callAsync`. A subsequent eight-second
sample again captured RPC writes. A sixteen-second live HardwareInput log
observation contained no new diagnostics/errors. These establish resumed write
activity, not RPC acknowledgements or a confirmed lighting result.

Secure Input remained off; Herdr server remained healthy at 0.9.1. All seven OMP
panes still had lifecycle-hook authority without fallback; the sampled list had
six idle and one working pane. Accessibility inspection was unavailable without
additional permission; no permission prompt was requested.

Physical key navigation, actual LED colors, active layer/keymap validation, and
the updated firmware version were not independently verified. Compare a real
user-operated key and agent transition next; do not treat this software-side
check as a complete hardware acceptance test. No app/agent restart, synthetic
input, keymap write, or integration change was performed by the assistant.

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

Recorded September 23 environment: macOS 27.0; Swift 6.4; Command Line Tools selected at
`/Library/Developer/CommandLineTools`. Herdr CLI/server: 0.9.1. Ghostty: 1.3.1.
OMP installed CLI: 18.2.10 (not proof of every existing process version).

**November 12 source verification: 92 targeted Swift Testing tests passed:**

```bash
./scripts/test-swift-suite.sh SecureInputTests          # 14
./scripts/test-swift-suite.sh HerdrFocusTests            # 4
./scripts/test-swift-suite.sh HerdrMachineTests          # 8
./scripts/test-swift-suite.sh AgentNotificationTests     # 10
./scripts/test-swift-suite.sh LayerLightingTests         # 10
./scripts/test-swift-suite.sh DictationMediaTests        # 34
./scripts/test-swift-suite.sh InputResponsivenessTests   # 12, deferred experiment
```

The standalone runner explicitly selects SwiftPM's native build system because
Swift 6.4 defaults to `swiftbuild`, whose module/object layout differs. It links
every `WLKit.build/*.swift.o`, so delete objects of removed sources from
`.build` after deleting a file, or linking fails on stale symbols. Reconstructing
the synchronous profile from HEAD plus current Sources/Tests overlays and the
regenerated exclusions patch passed **80 targeted tests** (no deferred input
tests). The original synchronous release had successful debug/release/signature
validation on September 9; that historical full-app validation is distinct from
current library/runtime-adapter checks.

**Full-app build: decided to stay on the macOS 26.5 SDK** (user decision,
November 12), matching the validated September 9 build. The
macOS 27 SDK declares SwiftUI's `@State` as a macro implemented by the
`SwiftUIMacros` compiler plugin, which ships with Xcode but not with CLT 27.0
(its `usr/lib/swift/host/plugins` has only Observation/Swift macros and
testing). The installed `MacOSX26.5.sdk` still declares `State` as a property
wrapper. On November 12, `swift build` (native, debug, all products) and
`swift build -c release --product WLMicroManager` / `WLInspector` both finished
with zero errors when given that SDK:

```bash
WL_MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/bundle.sh
```

`bundle.sh` passes `--sdk` plus `-Xlinker -platform_version -Xlinker macos
-Xlinker 13.0 -Xlinker <SDK version>`, then fails unless both binaries record
that SDK version. **The linker flag is required:** with `SDKROOT` or `--sdk`
alone, the binary records `sdk 13.0` in `LC_BUILD_VERSION` (`vtool
-show-build`), so AppKit/SwiftUI would apply macOS 13 linked-on-or-after
compatibility behavior. Unset, `bundle.sh` keeps the toolchain default (CI's
`macos-14` runners have no 26.5 SDK). For plain `swift build`, pass
`--sdk <26.5 SDK>`; add the same linker flags for anything you will run.

Deployment target stays macOS 13. A CLT update may remove the 26.5 SDK. Moving
to the macOS 27 SDK needs full Xcode 27 (has the plugin and XCTest), selected for
this build via `DEVELOPER_DIR`. Do it as its own validated step: it changes
linked-on-or-after AppKit/SwiftUI behavior independently of Herdr work. Full
XCTest remains unavailable with CLT.
No source change was made to work around the macro. The resulting binaries were
not launched (to avoid a second copy driving the pad) and no bundle was installed.
Xcode is not installed. The user updated to **CLT 27.2** (Swift 6.4.2; SDKs
27.2 default and 26.5 retained) on November 12. It still lacks the
`SwiftUIMacros` plugin: a default-SDK release build of `WLMicroManager` fails
with the same `StateMacro` errors (the 27.2 SDK declares `State` in
SwiftUICore as a macro). The 26.5 SDK build with the linker flag still succeeds.
Xcode 27.2 (App Store, free, 3.1 GB) remains the only route to the 27 SDK.

With full Xcode, prefer `swift test --skip Live` before considering live suites;
bare `swift test` can discover actual devices/services. Tests cannot establish
Bluetooth timing or lighting ownership against another writer on their own.

## Next work, in order

1. With approval, commit, reconstruct the synchronous profile, run
   `WL_MACOS_SDK=…/MacOSX26.5.sdk ./scripts/bundle.sh` in that stage, back up and replace
   the installed app, and check on the real Herdr app: agent-key
   `agent.focus`, Submit, tab cycling, notification clicks, and lighting with a
   remote agent. Do not install the experimental primary tree.
2. Verify which agents report OSC 7501 under herdr-core (OMP observed here; Claude Code per a published third-party test;
   Pi, Pi Guardrails' blocked prompt, and Codex are unverified) and their
   `status.app` names against `TuneController`/`PiControlController` checks.
3. Consider `events.subscribe` (or `hc events`) to trigger refreshes instead of
   waiting up to one 2.5 s poll for status changes.
4. Confirm and implement the ring-attention policy separately from deferred latency
   work; preserve current completion acknowledgement and layer/security guards.
5. If latency work resumes, validate background HID writing on the physical device
   without Secure Input active and distinguish errors from permission/OS gating.
   Core Audio sampling on the main thread is another known possible latency source.
6. Consider single-instance protection or safer build-bundle handling, and better
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
