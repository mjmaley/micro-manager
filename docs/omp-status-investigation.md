# OMP → Herdr → MicroManager status investigation

Initial read-only diagnosis, 2026-09-22; installation and follow-up below.

## Confirmed upstream failure

- Both the installed Herdr CLI and running server report **0.9.1**. Installed OMP
  CLI reports **18.2.10**; this does not establish the version of every already
  running OMP process.
- `herdr integration status` reports:
  `omp: not installed (~/.omp/agent/extensions/herdr-omp-agent-state.ts)`.
- `herdr agent explain <pane> --json` for OMP panes `w5:p3`, `w6:p7`, and `wD:p1`
  reports `state: idle`, `fallback_reason: default_known_agent_idle_fallback`,
  no evaluated/matched rules, and no lifecycle-hook authority.
- `agent.list` reported all four OMP agents idle. Two had activity-spinner titles.
  Titles alone are not proof of current work, but the explicit fallback diagnostic
  confirms Herdr is not deriving trustworthy lifecycle state for these panes.
- The current Pi pane (`w6:p3`) reports working and
  `screen_detection_skip_reason: full_lifecycle_hook_authority`. Its installed
  Pi hook is v8 (Herdr offers v9); this is separate from the missing OMP hook.

## MicroManager observations and limits

- Installed executable SHA-256 still matches the September 9 Secure Input build:
  `0b2ef2445f7c2d5437920771db0832acd92f4458bd77034dd38ec67e0b04ac36`.
- Secure Input was false. Process sampling showed Herdr polling and HID writes,
  without the prior reconnect/error-loop paths in the inspected matches.
- No MicroManager events appeared in the inspected ten-minute unified-log window.
  This is not evidence that every physical lighting command was acknowledged.
- MicroManager maps `agent_status` from `agent.list` directly; it cannot infer
  OMP activity absent from Herdr. Missing working/blocked transitions also prevent
  reliable completion tracking and notifications. The whole keypad path has not
  yet been independently validated against a user-observed mismatched key.
- No app restart, agent interruption, synthetic input, device/keymap writes by a
  diagnostic probe, or status mutation was performed during diagnosis. Ring
  attention behavior remains only a proposal.

## Supported correction — installed after explicit user approval

`herdr integration install omp` installs the official OMP-only integration. The
0.9.1 source is integration version 10. It reports root interactive-session
working/idle, tool approvals, `ask` questions, retry failures, and session references
using the local Herdr socket. It ignores nested OMP sessions (`OMPCODE=1`) and
requires normal Herdr pane environment variables. It preserves working through
scheduled continuations (`agent_end.willContinue`) and briefly debounces idle.

After explicit approval, ran `herdr integration install omp` only. Status now
reports `omp: current (v10)`. The installed file at
`~/.omp/agent/extensions/herdr-omp-agent-state.ts` exactly matches the
reviewed upstream source (SHA-256
`e3c650752bb9c2eb8bc1eecc9ce845c27434f6b7331af161353dd06ca6de48b7`).
No sessions were restarted and no other integration was changed. A subsequent
check of `w5:p3` still reports idle fallback, confirming installation alone has
not activated the hook in that existing session.

Installing the file does not establish that existing agents have loaded it.
New OMP processes discover the default `~/.omp/agent/extensions` directory, unless
extensions are disabled or a different profile/agent directory is in use. Existing
sessions need an explicit safe activation step. OMP 18.2.10 provides `/restart`
(documented in code as restarting with the same launch flags and resuming the
session); do not send it automatically or interrupt active work. Do not assume
`/reload-plugins` loads new lifecycle extensions: its inspected TUI implementation
refreshes discovery and MCP state, not the extension runtime itself.

After activation, verify `agent explain` establishes lifecycle-hook authority and
observe actual working → blocked/question → working → idle transitions. Then
compare the appropriate current-page key with Herdr's reported state and derived
unviewed-completion green. Do not fabricate statuses to make the lights look right.

## Follow-up — 2026-09-23

Read-only handoff checks now find six OMP panes. All six report
`screen_detection_skip_reason: full_lifecycle_hook_authority`, with no fallback
reason, and are currently idle. The previously missing integration is now loaded
in these processes; the assistant did not restart them. The installed OMP hook
is current at v10; Pi's v8 hook remains unchanged (Herdr offers v9).

This confirms activation, not a full end-to-end test of every status transition
or physical light. Still verify a real OMP working → question/approval → resumed
→ finished cycle with the user before declaring every keypad-status issue fixed.
The global Secure Input incident is separate from agent lifecycle reporting.

## Primary references and artifacts

- Live CLI: `herdr status server`, `herdr integration status`,
  `herdr agent explain <pane> --json`; read-only socket `agent.list`.
- [Official Herdr OMP integration, 0.9.1](https://github.com/herdrdev/herdr/blob/v0.9.1/src/integration/assets/omp/herdr-agent-state.ts)
- [OMP extension loading, 18.2.10](https://github.com/can1357/oh-my-pi/blob/v18.2.10/docs/extension-loading.md)
- [OMP lifecycle commands](https://github.com/can1357/oh-my-pi/blob/v18.2.10/packages/coding-agent/src/slash-commands/builtin-lifecycle.ts)
- [OMP marketplace reload implementation](https://github.com/can1357/oh-my-pi/blob/v18.2.10/packages/coding-agent/src/slash-commands/builtin-marketplace.ts)
- Local source: `Sources/WLKit/HerdrClient.swift`, `AgentLightingTracker.swift`.
- Artifacts: `/tmp/herdr-omp-status-investigation/`,
  `/tmp/herdr-omp-explain-20260922.json`, `/tmp/herdr-pi-explain-20260922.json`,
  `/tmp/herdr-integration-status-20260922.json`,
  `/tmp/micromanager-status-20260922.sample.txt`.
