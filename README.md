# Micro Manager

> This is [mjmaley's fork](https://github.com/mjmaley/micro-manager) of
> [schacon/micro-manager](https://github.com/schacon/micro-manager). Custom
> Codex Micro, Pi, and notification work is on `layer-aware-herdr`. Build that
> branch from source; the upstream download links below do not include these changes.

A macOS menu-bar app that lights each running [Herdr](https://herdr.dev) agent
on its own key of a Work Louder **Codex Micro** or
**[Creator Micro 2](https://worklouder.cc/creator-micro-2)**, and jumps to that agent
when you press the key. On Codex Micro, native Codex remains on Layer 1 while
Herdr gets the complete controls and live lighting on Layer 2.

It is the bridge itself — no Node, no daemon, nothing to install on the Herdr
side. It reads Herdr's socket directly and drives the pad over raw HID.

**[Download the latest release](https://github.com/schacon/micro-manager/releases/latest/download/MicroManager.zip)**
· [website](https://schacon.github.io/micro-manager/)
· [hacking guide](docs/hacking.md)

---

## Install

Download, unzip, drag `MicroManager.app` to Applications, and launch it. macOS
will ask for **Input Monitoring** — grant it, then toggle the manager off and on
from the menu-bar panel so it reconnects with the permission.

Or build it yourself:

```bash
./scripts/bundle.sh --install     # build, sign, install to /Applications, launch
pi install npm:@aliou/pi-guardrails
```

Run `/guardrails:onboarding` once to choose the safety defaults. Run `/reload`
in existing Pi sessions after installing Guardrails; new sessions discover it
automatically.

You will also need a supported pad and a running Herdr server with agents in
it. Quit Work Louder's Input app while you use this. Creator Micro 2 remains a
single-owner integration, so quit Codex there too. Codex Micro is layer-aware:
Codex desktop may stay open and keeps Layer 1; switch to Layer 2 for Herdr.

## What the pad does

**The icon** shows state at a glance: dimmed when off, a coloured dot when
running — green all idle, amber something working, red something needs you —
and a badge when the pad is missing or permission is denied.

**The six agent keys** show one bank of agents at a time, in the order Herdr's
own panel lists them. With more than six agents, joystick left/right pages the
banks when no model picker is open. Colours are red (blocked, breathing), amber
(working), blue (done — finished but not yet looked at) and green (idle —
finished and seen). Herdr
distinguishes done from idle by whether you have focused the pane yet, so blue
means something is waiting to be read and green means quiet. The **underglow**
carries the worst state across all agents, so "does anything need me?" is
readable from across the room.

Pressing an agent key focuses that agent in Herdr **and brings the terminal
forward** — Herdr selects the pane but leaves the window where it was, so an
agent key pressed from a browser used to move a cursor you could not see. Set
`WL_TERMINAL_BUNDLE_ID` if your panes do not live in Ghostty.

**Row 3** follows the printed Codex keycaps and controls Pi:

| key | what it does |
|---|---|
| FAST | allows a pending dangerous command for the Pi Guardrails session |
| APPR | allows the active Guardrails prompt once (Enter) |
| REJ | denies the active Guardrails prompt (Escape) |
| SPLIT | opens Pi's `/fork` flow |

**Row 4** is the wide key — it sends Command+/, which starts and stops
OpenWhispr with this machine's tap-activation setup — and the **Submit** key,
which sends Enter to the focused Herdr pane.

**The dial** tunes reasoning effort. In Pi it opens `/thinking`, rotation moves
through the choices, and pressing the dial confirms. **The joystick** switches
model: it opens `/model`, north and south move, east confirms, west cancels. When
no model picker is open, east/right and west/left page the six-agent bank.

### Pi Guardrails

Install [`@aliou/pi-guardrails`](https://github.com/aliou/pi-guardrails) for
file protection, outside-workspace path checks, and dangerous-command prompts.
Its Herdr adapter marks a waiting Pi pane as blocked, so the corresponding agent
key breathes red. At a dangerous-command prompt, APPR allows once, FAST allows
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

**Off** clears the lights and stops driving, but deliberately leaves the device
keymap alone: rebinding is a flash write, and the keys light instantly on the
way back in if the bindings are still there.

## Clickable agent notifications

The installed app can send native macOS notifications when a Herdr agent needs
input or finishes work. Enable **Agent notifications** in the menu and allow
**Micro Manager** in System Settings → Notifications. Click an alert to focus
its exact Herdr pane, bring Ghostty forward, and select that agent's pad bank.
This uses Herdr's socket API directly, not AppleScript or `terminal-notifier`.

- The bridge must be **On**, but a connected pad is not required.
- Initial discovery, reconnect, and wake establish a silent baseline. Repeated
  polls do not repeat an alert; the focused pane is silent while Ghostty is active.
- Destinations include the configured socket's incarnation, pane ID, and terminal
  ID. A closed/replaced pane or restarted server produces an explanatory error
  rather than focusing whichever agent later occupies the same slot.
- **Test notification (5s)** gives you time to switch apps before delivery. It
  prefers a background agent. Right-click an agent row to test that exact pane.
- Notifications are silent; Herdr can continue providing its existing sounds.
- Once permission and clicks are verified, avoid duplicate popups by backing up
  `~/.config/herdr/config.toml`, setting `[ui.toast] delivery = "off"`, and running
  `herdr server reload-config`. Micro Manager does not rewrite Herdr's config.
  Restore the previous delivery setting if you stop using Micro Manager alerts.

Only the Herdr socket configured for this Micro Manager process is monitored
(default `~/.config/herdr/herdr.sock`; override with `HERDR_SOCKET_PATH`). This
is not discovery of every named Herdr server. Ghostty activation is app-level:
when multiple Ghostty windows exist, selecting the correct OS window is not
implemented. Native notifications require the app bundle; `swift run` skips
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

Everything works without a config file. To rebind the macro keys or change what
the dial and joystick offer, drop a `config.json` into
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

A bound string is injected into the focused agent's prompt, unsubmitted — you
still read it and press enter. `"10+11"` addresses the wide key as one; `"10"`
and `"11"` address its halves. Keys the file does not mention keep their
defaults. Key 12 submits by default; assigning text to `"12"` overrides that.
Binding the wide key to text replaces its OpenWhispr shortcut.

`codex.models` is your copy of what Codex's own `/model` menu offers, in its
order — the joystick steers that menu rather than owning it, so there is nothing
to read it from. Agent-bank paging uses only the joystick's otherwise-idle
horizontal directions and does not change model-picker behavior.

| variable | what it overrides |
|---|---|
| `WL_TERMINAL_BUNDLE_ID` | the terminal to raise (default Ghostty) |
| `HERDR_SOCKET_PATH` | the Herdr socket |
| `WL_SIGN_IDENTITY` | the signing identity `bundle.sh` uses |
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

Every push to main republishes the **`latest`** release, so the download link
above always points at the current build; tagging `v*` cuts a permanent
versioned release alongside it. Both go through
[the release workflow](.github/workflows/release.yml).

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

**Known limitation:** Codex itself does not check the layer for `AG00`–`AG05`.
Double-pressing one of those keys can still bring Codex forward, even on Layer 2.
The current mapping intentionally retains those codes; shared HID access cannot
prevent Codex from receiving them. See [the probe correction](docs/layer-2-probe.md).
Codex may also need restarting after sleep if its own HID handle becomes stale.

## Development

```bash
swift build            # both apps and the shared library
swift test             # live tests skip themselves without hardware
swift run WLInspector  # the debug UI
./scripts/bundle.sh    # assemble build/MicroManager.app, unsigned install
```

| | |
|---|---|
| `Sources/WLKit` | device transport, vendor protocol, Herdr client, bridge engine |
| `Sources/WLMicroManager` | the menu-bar app and its panels |
| `Sources/WLInspector` | the debug UI |
| `docs/hacking.md` | how the pad protocol works, and how to drive it yourself |
| `docs/index.html` | the website, served by GitHub Pages from `docs/` |

The device protocol — raw-HID JSON-RPC, per-key colour, key and joystick events,
and the keymap binding that makes per-key lighting possible at all — is written
up in full in **[docs/hacking.md](docs/hacking.md)**.

---

An independent interoperability tool for hardware I own. Not affiliated with
Work Louder.
