# Micro Manager

> This is [mjmaley's fork](https://github.com/mjmaley/micro-manager) of
> [schacon/micro-manager](https://github.com/schacon/micro-manager). Custom
> Codex Micro, Pi, notification, and herdr-core work is on
> `layer-aware-herdr`. The upstream download links below do not include these
> changes. **The herdr-core source cutover is uncommitted and uninstalled.** The
> installed app remains the September 9 synchronous build, which only speaks to
> the retired Herdr 0.9 server. Before building or resuming work, read the
> [current handoff](docs/HANDOFF.md): the primary tree also retains deferred
> HID/lighting experiments that are not hardware-cleared for installation.

A macOS menu-bar app that lights each running [Herdr](https://herdr.dev) agent
on its own key of a Work Louder **Codex Micro** or
**[Creator Micro 2](https://worklouder.cc/creator-micro-2)**, and jumps to that agent
when you press the key. On Codex Micro, native Codex remains on Layer 1 while
Herdr gets the complete controls and live lighting on Layer 2.

The bridge needs no Node process or additional daemon. It polls
[herdr-core](https://herdr.dev) (`herdr-core connect`, JSON-RPC) for terminals
and their statuses on this computer and every connected machine, asks the
Herdr desktop app (`herdr-app`) where they are shown and which pane has focus,
and drives the pad over raw HID. Status is whatever each program reports over
OSC 7501; a program that never reports is a terminal, not an agent. The Herdr
0.9 TUI hooks (`herdr integration install …`) do not run under herdr-core.

**[Download the latest release](https://github.com/schacon/micro-manager/releases/latest/download/MicroManager.zip)**
· [website](https://schacon.github.io/micro-manager/)
· [hacking guide](docs/hacking.md)

---

## Install

For the **upstream release**, download, unzip, drag `MicroManager.app` to
Applications, and launch it. macOS will ask for **Input Monitoring** — grant it,
then toggle the manager off and on from the menu-bar panel so it reconnects with
the permission. This does not install the fork behavior described below.

**Fork builders:** use the [handoff's synchronous source reconstruction](docs/HANDOFF.md#reconstruct-the-synchronous-source-profile-safely)
in a separate stage; do not apply exclusions to the experimental primary tree.
Command Line Tools 27.0 lack the SwiftUI macro plugin the macOS 27 SDK needs for
`@State`; fork builds stay on the installed 26.5 SDK, the same SDK as the
validated September 9 build:
`WL_MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/bundle.sh`.
The script also tells the linker that SDK version and refuses a binary that
records any other (SwiftPM alone records 13.0). Then validate on physical hardware before any separately
authorized packaging or installation. No existing Herdr terminal needs
restarting for this cutover.

Pi Guardrails setup is independent of building or installing MicroManager:

```bash
pi install npm:@aliou/pi-guardrails
```

Run `/guardrails:onboarding` once to choose the safety defaults. Run `/reload`
in existing Pi sessions after installing Guardrails; new sessions discover it
automatically.

You will also need a supported pad, herdr-core and the Herdr desktop app
(installed to `~/.local/bin` by Herdr's installer; see [Herdr setup](#herdr-setup)),
and agents that report their status.
Quit Work Louder's Input app while you use this. Creator Micro 2 remains a
single-owner integration, so quit Codex there too. Codex Micro is layer-aware:
Codex desktop may stay open and keeps Layer 1; switch to Layer 2 for Herdr.

## Secure Input protection

When macOS Secure Input is active, MicroManager shows **Paused by macOS Secure
Input** with a lock icon instead of treating the restriction as a missing pad.
It pauses physical HID traffic and reconnect attempts, while ordinary menu
agent navigation remains available. The reported application/PID is diagnostic
metadata and may be stale or unavailable; no password fields or keys are read.

After protection clears, MicroManager waits briefly, reopens the device, checks
the current layer and keymap without rewriting it, and restores hardware input
and lighting. Old button presses and approvals are not replayed. Normal startup
keymap management is unchanged. If validation fails, the actual error remains
visible and normal retry handling continues.

MicroManager never disables Secure Input or changes another application's
security settings. Finish secure entry normally; password protection is expected
to temporarily block the pad's raw-HID features. Diagnostics record transitions,
reported app identity, HID errors, and successful recovery:

```bash
/usr/bin/log show --last 15m --style compact --info \
  --predicate 'subsystem == "cc.worklouder.micromanager" AND category == "HardwareInput"'
```

## What the pad does

**The icon** shows state at a glance: dimmed when off, a coloured dot when
running — green all idle, amber something working, red something needs you —
and a badge when the pad is missing or permission is denied.

**The six agent keys** show one bank of agents at a time, in the order the
Herdr app shows them: space → tab → terminal, a sub-agent after its parent, then
any agent the app does not show, in herdr-core's order. Rows include the
machine. With more than six agents, joystick left/right pages the banks when no
model picker is open. Colours are:

- **Red, breathing:** blocked / needs attention.
- **Red:** the program reported an error.
- **Amber:** working.
- **Green:** finished and not yet seen in the Herdr app.
- **White:** idle, or a finished turn you have seen.
- **Grey-blue:** a status word MicroManager does not know.

"Seen" is the Herdr app's own record (`herdr.seen`, the last turn shown to you),
so a key turns white exactly when the app's lists stop calling that agent done.
MicroManager keeps no read state of its own.

The **underglow follows the agent in the Herdr app's focused pane**, including
one outside the visible six-key bank. It keeps following that pane while another
app is in front; if the focused pane is not an agent, the ring goes dark. The
menu-bar icon summarizes the worst state across all agents.

Pressing an agent key runs the app's `agent.focus` for that terminal and brings
the Herdr app forward (set `WL_TERMINAL_BUNDLE_ID` if your panes live somewhere
else). Every target is the terminal's address (`t7`, or `rohan/t7` on another
machine) plus its start time; before acting, MicroManager re-reads that address
and refuses if a different terminal now holds it. This is read-before-action,
not an atomic compare-and-act. Keys go through herdr-core `terminal.keys`;
slash commands through `terminal.send`, which waits for a draft you are typing
and refuses a program that is asking a question. Tab cycling is the app's
`tab.next` in the shown space. No synthetic macOS keystrokes are used.

**Row 3** follows the printed Codex keycaps and controls Pi:

| key | what it does |
|---|---|
| FAST | allows a pending dangerous command for the Pi Guardrails session |
| APPR | allows the active Guardrails prompt once (Enter) |
| REJ | denies the active Guardrails prompt (Escape) |
| SPLIT | opens Pi's `/fork` flow |

**Row 4** is the wide key — it sends Command+/, which starts and stops
OpenWhispr with this machine's tap-activation setup — and the **Submit** key,
which sends Enter to the agent in the Herdr app's focused pane.

**The dial** tunes reasoning effort. In Pi it opens `/thinking`, rotation moves
through the choices, and pressing the dial confirms. **The joystick** switches
model: it opens `/model`, north and south move, east confirms, west cancels. When
no model picker is open, east/right and west/left page the six-agent bank.

### Pause media during dictation (optional)

Enable **Pause media during dictation** in MicroManager's menu. First turn off
OpenWhispr's own **Settings → General → Sound Effects → Pause media** so the two
apps do not compete. FineTune can stay running; its settings are not changed.

This watches **actual microphone input activity** in Codex (`com.openai.codex`,
including the ChatGPT-named desktop bundle) and OpenWhispr, including their nested
helpers. Keyboard shortcuts, the Micro, and on-screen recording buttons all use
the same path. It works independently of the HID bridge's on/off switch and pad
layer. With observation enabled, the wide key's recording light follows input
activity instead of counting button presses.

- Requires **macOS 15.4+** and an installed OpenWhispr that includes
  `mediaremote-adapter.pl` and `MediaRemoteAdapter.framework` (tested with the
  installed helper). The helper stays in OpenWhispr's bundle; it is not copied,
  downloaded, or linked into MicroManager. An app/OS update can break this
  optional integration; errors disable actions rather than sending media keys.
- Pauses only a playing, identifiable **Now Playing** session. Confirms the
  pause with two settled samples, polling for up to two seconds (plus an
  in-flight helper call), then waits for both dictation apps to stop input.
  A reported nonzero playback rate is treated as unsettled even if `playing`
  has already become false. Pause is sent only once.
- Brave regenerates its Now Playing item ID during play/pause. During pause
  confirmation only, an ID change is accepted if browser/process, nonempty
  title/channel, and finite positive duration still match. Once settled, the
  new ID is held strictly for validation/resume. This is metadata matching,
  not tab-URL identification; identically labelled videos cannot be distinguished
  during that transition. Other players retain strict ID checks.
- Resumes after a short idle debounce, only if the same player/process/item is
  still paused. Observed playback, item, or seek changes cancel automatic resume.
- Brief microphone-read failures suspend decisions without immediately cancelling
  an owned pause. Recovery requires a fresh 600 ms of known-idle input and a new
  media-state check. Input unavailable for 2 seconds cancels automatic resume.
  The menu retains the last microphone error after recovery; state transitions
  and Core Audio errors are logged under subsystem `cc.worklouder.micromanager`,
  category `DictationMedia` (no recorded audio or media titles).
- No blind play/pause toggles. Media-control errors, prolonged input uncertainty,
  disabling the feature, quitting, or lock/sleep leave media paused rather than
  risking an unexpected play command.
- Does **not** pause every browser tab or every audio source. Media without Now
  Playing support is left alone. No mute/volume fallback is used.
- Input is sampled every 200 ms; owned media is checked about every 750 ms and
  again before resuming. Very short transitions or manual changes between polls
  can be missed. Now Playing query/send is not atomic. If an app keeps its mic
  stream open between takes, the feature sees continuous recording; validate
  with the mic status before relying on it. No microphone samples are captured.

**Check media access** is read-only. For a terminal diagnostic (no HID access or
playback changes):

```bash
swift run WLMediaProbe          # media identity/state and target input activity
swift run WLMediaProbe --watch  # input transitions for 60 seconds
```

Try browser playback, then start/stop each dictation app using both keyboard and
Micro triggers. Confirm the menu changes from **Mic: idle** to the right app and
back; playback should pause and then resume. Also try already-paused media,
cancelling recording, changing media during a take, and turning the feature off.

The media regression suite uses fake playback and a fake helper, never live
transport commands:

```bash
./scripts/test-dictation-media.sh  # also works with recent Command Line Tools
# Full repository suite requires Xcode's XCTest framework:
swift test
```

### Pi Guardrails

Install [`@aliou/pi-guardrails`](https://github.com/aliou/pi-guardrails) for
file protection, outside-workspace path checks, and dangerous-command prompts.
Under herdr-core the key breathes red only if Pi reports its waiting prompt as
`blocked` over OSC 7501; that is not yet verified for Pi. At a dangerous-command prompt, APPR allows once, FAST allows
the exact command for the session, and REJ denies. At a path-access prompt,
APPR chooses the highlighted grant (initially allow once) and REJ denies; FAST
is reserved for dangerous-command session grants. Non-interactive operations
that require confirmation fail closed.

## The panel

Click the menu-bar icon. It draws the pad in its real shape with every key
showing its live colour, then one row per agent. Click a key or a row to jump to
that agent. It also carries the on/off switch, an "Open at login" toggle, a
warning when another app is fighting for the device, and the **Inspector**
button.

**Stack and Land are local-only.** These filesystem/GitButler panels reject a
Remote agent's working directory, even if the same path exists locally. They do
not silently operate on a local same-path checkout.

**Off** clears the lights and stops driving, but deliberately leaves the device
keymap alone: rebinding is a flash write, and the keys light instantly on the
way back in if the bindings are still there.

## Clickable agent notifications

MicroManager can send native macOS notifications when a Herdr agent needs
input or finishes work. Enable **Agent notifications** in the menu and allow
**Micro Manager** in System Settings → Notifications. Clicking an alert focuses
that agent in the Herdr app, brings the app forward, and selects the agent's pad
bank; no AppleScript or `terminal-notifier`.

- The bridge must be **On**, but a connected pad is not required.
- Initial discovery, reconnect, and wake establish a silent baseline. Repeated
  polls do not repeat an alert; the agent in the focused pane is silent while
  the Herdr app is active.
- Destinations are a terminal address plus its start time. An ended or replaced
  terminal, or a machine renamed since, produces an explanatory error rather
  than focusing a different terminal.
- **Test notification (5s)** gives you time to switch apps before delivery. It
  prefers a background agent. Right-click an agent row to test that exact agent.
- Notifications are silent. The Herdr app has its own alerts; turn one of the
  two off in its settings or here if you see both.

Agents on a machine that is not connected are absent until it reconnects; the
menu shows that machine's state. Without a running Herdr app window the keys
still light in herdr-core's order, but nothing is focused and agent keys report
the app error. Native notifications require the app bundle; `swift run` skips
notification delivery while retaining the other controls.

## The Inspector

The debug UI ships inside the app — the **Inspector** button in the panel opens
it. It logs every message in both directions (`TX`, `RX`, `NOTIFY`, `DEVICE`),
decodes the device's abbreviated notifications, and drives the lighting by hand:
per-key colours and effects, the two zones, a key walk, and a raw JSON-RPC
console with presets.

It lives at `MicroManager.app/Contents/Library/Inspector.app`, signed by the
same identity as its host, so it is one download and one trust decision. During
development there is no surrounding bundle, so run it directly:

```bash
swift run WLInspector
```

Run that **from your terminal**, not from Finder: macOS attributes Input
Monitoring to the responsible process, so a terminal that already has the grant
passes it on.

## No pad to hand

Tick **Emulate the pad** in the panel and a window opens with a virtual Creator
Micro 2 in it. The bridge drives its lights exactly as it drives the hardware,
and clicking a key — or the dial, or the joystick — sends the same
`v.oai.hid` report back, so the whole loop works with nothing plugged in.

```bash
WL_EMULATE=1 swift run WLMicroManager    # start emulated, no clicking required
```

It is a stand-in for the firmware rather than a picture of one, and it
reproduces the firmware's more awkward habits deliberately, because those are
the ones that cost time on real hardware:

- it answers `{"ok":1}` to any lighting payload, right or wrong;
- it boots on the **stock F-key keymap**, so the app has to bind the keys
  before anything can light — and a key that is not bound to `KV_OAI_AG*`
  accepts its colour in silence and stays dark;
- an unbound key reports nothing when pressed, because on the pad it would be
  sending a keystroke instead.

The window also shows the RPC traffic, and **Reset** puts a factory pad back.

The emulator lives inside the app, so it stands in for the device for Micro
Manager only — the Inspector is a separate process and still needs hardware.

## Configuration

Macro configuration needs no config file by default. To rebind the macro keys
or change what the dial and joystick offer, drop a `config.json` into
`~/.config/micromanager/`:

```json
{
  "keys": {
    "12":    "Run the tests before submitting",
    "10+11": "Summarise what you are working on"
  },
  "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
  "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
}
```

A bound string is typed into the agent in the Herdr app's focused pane,
unsubmitted — you still read it and press Enter. herdr-core has no unsubmitted
paste, so it is typed as named keys: letters, digits, spaces, and
`` , - . / ; = [ \ ] ` ' ``. Text with any other character (`?`, `!`, `:`,
newlines, non-ASCII) is refused before anything is typed. `"10+11"`
addresses the wide key as one; `"10"`
and `"11"` address its halves. Keys the file does not mention keep their
defaults. Key 12 submits by default; assigning text to `"12"` overrides that.
Binding the wide key to text replaces its OpenWhispr shortcut.

`codex.models` is your copy of what Codex's own `/model` menu offers, in its
order — the joystick steers that menu rather than owning it, so there is nothing
to read it from. Agent-bank paging uses only the joystick's otherwise-idle
horizontal directions and does not change model-picker behavior.

### Herdr setup

MicroManager uses Herdr's desktop-app generation: herdr-core (`hc`) and the
Herdr app, both installed to `~/.local/bin` by
`curl -fsSL https://releases.herdr.dev/app/install.sh | sh` or the DMG. Add
other machines in the app or with `hc machine add`; their agents appear without
further setup. Pick a machine's name when adding it and keep it: a terminal on
it is addressed as `name/t7`, so renaming the machine ends existing pad targets
and alerts.

Verified against herdr-core 0.1.20 and Herdr app 0.1.15. Read-only checks:

```bash
hc ls                 # terminals here and on connected machines, with status
hc machine ls         # machines and whether they are connected
herdr-app status      # the focused pane
```

Set these variables in the environment of the MicroManager process you
deliberately launch; a Finder-launched app does not inherit terminal exports.

| variable | what it overrides |
|---|---|
| `WL_TERMINAL_BUNDLE_ID` | the app to raise (default `dev.herdr.app`) |
| `WL_HERDR_CORE_BINARY` | absolute herdr-core path (default `~/.local/bin/herdr-core`) |
| `WL_HERDR_APP_BINARY` | absolute herdr-app path (default `~/.local/bin/herdr-app`) |
| `HC_SESSION`, `HERDR_APP_HOME` | passed through: which herdr-core session and app window to use |
| `WL_SIGN_IDENTITY` | the signing identity `bundle.sh` uses |
| `WL_MACOS_SDK` | SDK directory `bundle.sh` builds against (fork: the CLT `MacOSX26.5.sdk`) |
| `WL_HERDR_LAYER` | override the Herdr layer number (Codex Micro defaults to 2; Creator Micro 2 to 1) |

## Why it must be bundled and signed

`swift run` works for development because it inherits your terminal's Input
Monitoring grant. A background app needs its own, and macOS keys that grant to
the **designated code requirement**. `bundle.sh` prefers a real Apple
Development or Developer ID identity from your keychain. For local ad-hoc
builds it supplies a stable bundle-identifier requirement so rebuilding does
not silently leave the permission attached to an obsolete binary hash. It also
sets `LSUIElement` so there is no Dock icon, and gives `SMAppService` a bundle
it will actually register as a login item.

The upstream release workflow republishes **`latest`** on pushes to main and
cuts permanent versioned releases for `v*` tags. The download link above targets
that upstream repository, not this uninstalled fork source. See
[the release workflow](.github/workflows/release.yml); do not push main or create
release tags merely to checkpoint experimental work.

That workflow signs with a Developer ID and notarizes when the repository has
the secrets for it — the file lists them — and falls back to an ad-hoc
signature when it does not, rather than failing. An ad-hoc build works, but
macOS may stop it until you right-click → Open. Its stable local requirement is
less tamper-resistant than a certificate-backed identity, so distributed builds
should still be signed and notarized. The release notes say which kind you are
downloading.

## Shared clients and layer ownership

Work Louder's Input app, Codex desktop, and this app share the same HID channel;
there is no protocol-level lock. Keep Input closed. On Creator Micro 2, keep
Codex closed as well. On Codex Micro, both bridges can run: Codex owns Layer 1
and Micro Manager gates its HID controls and lighting on the configured Herdr
layer (default Layer 2). Shared agent keys get a fresh layer check; Layer-2-only
controls dispatch immediately once the Codex Micro keymap is verified. Lighting
is last-writer-wins, so detected external writes invalidate the next repaint.

When a Codex Micro leaves a Herdr layer that MicroManager has painted, the bridge
now clears thread and zone lighting **once**, then stops writing on that layer.
This removes stale Herdr colours; it does not reconstruct Codex's picture or
force Codex to repaint. Layer 1 may stay dark until Codex's next lighting update.
A layer switch is detected by the existing ~1.25-second status poll. Re-entry,
disconnect, and sleep invalidate pending writes so an old handoff cannot continue
clearing a newly observed Herdr layer. This is a best-effort shared-HID handoff:
the physical switch and another client's writes are not atomic with our poll.
No keypresses, app activation, or keymap writes are used for the clear.

**Deferred latency experiment (not installed).** Normal RPC report writes run on a serial
background queue, keeping the main queue available for button/dial input. Each
JSON message stays contiguous on the wire. Lighting keeps only the latest pending
picture and waits for 120 ms of input quiet before painting; the resulting small
lighting delay is intentional. Only changed keys/zones are sent, so changing the
ring does not resend all keys. Another client's read-only status replies do not
invalidate lighting. Reconnects and explicit Refresh still restore a full picture.
Synchronous off/sleep flushing remains serialized with queued writes, and a
transport is not closed until its current message finishes.

**Known limitation:** Codex itself does not check the layer for `AG00`–`AG05`.
Double-pressing one of those keys can still bring Codex forward, even on Layer 2.
The current mapping intentionally retains those codes; shared HID access cannot
prevent Codex from receiving them. See [the probe correction](docs/layer-2-probe.md).
Codex may also need restarting after sleep if its own HID handle becomes stale.

## Development

These are developer commands, not an installation recipe. With Command Line Tools
27.x, pass `--sdk` for the 26.5 SDK to `swift build` (see [Install](#install));
full XCTest requires a matching complete Xcode toolchain. WLKit and the targeted
standalone suites can be used independently. The herdr-core cutover passed 92
targeted primary-tree and 80 synchronous-stage tests plus live read-only and
isolated-session action checks; it did not validate an installed app, physical
pad, or Windows. Consult the [handoff](docs/HANDOFF.md) before staging or packaging.

```bash
swift build            # both apps/library; with CLT 27.x add --sdk …/MacOSX26.5.sdk
swift test --skip Live  # non-live suite; matching full Xcode required
./scripts/test-swift-suite.sh LayerLightingTests  # also works with recent CLT
./scripts/test-swift-suite.sh HerdrFocusTests
./scripts/test-swift-suite.sh HerdrMachineTests
./scripts/test-swift-suite.sh AgentNotificationTests
./scripts/test-swift-suite.sh SecureInputTests
./scripts/test-swift-suite.sh InputResponsivenessTests
./scripts/test-dictation-media.sh
swift run WLInspector  # the debug UI
WL_MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/bundle.sh  # packaging only after hardware validation; no --install
```

| | |
|---|---|
| `Sources/WLKit` | device transport, vendor protocol, Herdr client, bridge engine |
| `Sources/WLMicroManager` | the menu-bar app and its panels |
| `Sources/WLInspector` | the debug UI |
| `docs/HANDOFF.md` | current state, validation, installation precautions, next work |
| `docs/hacking.md` | how the pad protocol works, and how to drive it yourself |
| `docs/index.html` | the website, served by GitHub Pages from `docs/` |

The device protocol — raw-HID JSON-RPC, per-key colour, key and joystick events,
and the keymap binding that makes per-key lighting possible at all — is written
up in full in **[docs/hacking.md](docs/hacking.md)**.

---

An independent interoperability tool for hardware I own. Not affiliated with
Work Louder.
