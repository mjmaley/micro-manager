# External-machine API support in Herdr

> **Historical (superseded 2026-11-12).** Herdr's herdr-core + desktop-app
> generation aggregates connected machines natively, and MicroManager now uses
> it directly. Nothing below is used by the current source; see
> [the handoff](HANDOFF.md#herdr-core-adapter--source-only).

Upstream support checked 2026-10-05. The subsequent authorized fork trial used
isolated disposable instances only; installed Herdr, existing user sessions,
MicroManager, and hardware configuration remain unchanged.

## Decision

No matching pending implementation was found. The exact external-controller
request exists as [Ideas discussion #4396][selection-discussion], but the current
open PR inventory, current master, and published preview do not expose a public
command/API for selecting a saved machine in an already-running Herdr TUI.
Remote agent discovery/status is already available through separate per-machine
queries; visible cross-machine navigation remains the missing Herdr capability.

The discussion comes from another hardware controller, `herdr-micro`. Its author
reports that remote `agent.focus` changes the remote server's selection without
changing the local window's selected machine. It proposes either a client-side
`machine select` command/API or explicit cross-machine focus-following. Four
replies support notification/session-picker use cases; one contributor offers
implementation help subject to PR approval. No implementation link or maintainer
commitment was visible in the inspected thread. Latest visible reply: October 3.
These are discussion reports, not new live tests performed here.

## Version and implementation state

| Surface | Checked revision/status | Result |
|---|---|---|
| Stable | [v0.9.3][stable-release], published September 29 | Already provides per-machine CLI routing; release is an Escape/Alt-input hotfix, not a machine-selection API. |
| Published preview | [Index][preview-index] points to `8e78f929d8f0306a5c68518969e90274c44cb1f0` | Same missing public selector; preview is a separately pinned September 29 snapshot, not current master. |
| Master | `c4653a4f10502601ac110b12b2c45a5f7134082b` | [Method schema][master-schema] remains server-local; no machine-qualified agent list, subscription, or external TUI endpoint-selection method. |
| Pending PRs | [Complete open listing][open-prs]: 15 entries during the check | No matching feature. Closest candidates concern agent suspend/background retention, Windows server hosting, and local attach environment, not external machine selection. |
| Exact feature request | [Discussion #4396][selection-discussion] | Ideas discussion, not an implementation PR or announced release. |

The [master agent schema][master-agents] has workspace/tab/pane identity but no
machine identity. The [event schema][master-events] remains server/pane scoped.
`client_shell.surface.set` is not an external selector: the [API server][master-server]
rejects ordinary JSON-socket calls with `connection_local_only`.
The [internal client navigation][master-navigation] already emits endpoint
activation actions; the missing contract is external access to that operation.

## Related work already shipped

- [PR #3670][federation-pr], merged September 5: multiple saved SSH machines in one
  client, combined UI agent list, and machine-scoped navigation. Client federation,
  not an external federated socket API.
- [PR #3918][routing-pr], merged September 10 and shipped in 0.9.1: route API-backed
  CLI commands to one saved SSH profile via `--machine`. The PR explicitly excludes
  combined listings and routing through another TUI's connections.
- [PR #3764][focus-pr], merged September 9 and shipped in 0.9.1: project public
  `agent.focus` to attached clients within the addressed server. It does not select
  that server's machine in another client's federated window.
- [Issue #3493][fleet-issue]: fleet-wide monitoring request was closed and redirected
  to Ideas; no aggregate API implementation was attached.

## MicroManager impact

Remote status can be implemented against existing per-machine contracts, with
machine/session-scoped identities for keys, notifications, and completion tracking.
Upstream full navigation still lacks a public client endpoint-selection contract.
The exact discussion is a better starting point than an unrelated new feature
request. Do not install upstream preview or master expecting this gap to be fixed.
The experimental fork now provides the client-local contract below.

## Fork implementation and trial

Fork: https://github.com/mjmaley/herdr; feature branch
`feature/client-machine-control`, based on stable `v0.9.3`.
Checkout: `/Users/mmaley/Tools/herdr`.
Published implementation: [commit `a0f0c31e`](https://github.com/mjmaley/herdr/commit/a0f0c31e).

- A private socket per full TUI exposes newline-framed `client.snapshot` and
  `client.focus`; existing server methods and frozen endpoint codecs are unchanged.
- Snapshots include saved machine IDs, online boot IDs, scoped agent metadata,
  selected machine/pane, and handoff state. Cached offline agents are excluded.
- Focus uses existing endpoint activation and presentation fences. Busy handoffs,
  invalid targets, rollback, and supersession return errors, never enqueue-success.
  Caller cancellation enters coherent rollback. A disconnected frozen screen does
  not prevent selecting a healthy machine.
- Multiple live TUIs require their exact client ID. Machine labels must resolve
  uniquely; pane IDs are meaningful only within the addressed machine and boot.

Native macOS verification passed `just lint`, the complete `just test` recipe
(3,720 Rust tests passed; 12 skipped), `cargo build --locked`, documentation
contracts, and English/Japanese/Chinese heading parity. Build with Rust 1.96.1,
Zig 0.16.0, and Bun 1.4.2. Newer Homebrew Rust exposes unrelated baseline lints;
the old Bun 1.2.21 parser mishandles workflow YAML's `on` key.

The runtime trial used two real disposable local Herdr servers and full PTY
clients. An isolated SSH shim executed real discovery and the real stdio bridge;
it did not connect to a user's SSH host. Reconstructed terminal screens confirmed
Local/Remote navigation and same-machine pane changes. The trial also verified
duplicate pane IDs across machines, wrong-machine rejection, explicit targeting
with two TUIs, and successful Local recovery after stopping the selected test
server. The recovery regression failed before the fix and passed afterward.
Disposable processes and files were removed. Windows compilation/runtime and
real SSH authentication remain unverified; the user chose macOS-only verification.

For a trial, use `/Users/mmaley/Tools/herdr/target/debug/herdr` for both the full
TUI and its controller commands, with the **same** `XDG_STATE_HOME`. The debug
build uses `herdr-dev`, not the installed release's `herdr` namespace. Isolate
`HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`, and socket paths
for disposable sessions; do not inherit a real session's `HERDR_ENV`, pane ID,
socket overrides, or remote-binary override.

```bash
/Users/mmaley/Tools/herdr/target/debug/herdr client list --json
/Users/mmaley/Tools/herdr/target/debug/herdr client snapshot --client <client-id>
/Users/mmaley/Tools/herdr/target/debug/herdr client focus <machine-id> --pane <pane-id> --client <client-id>
/Users/mmaley/Tools/herdr/target/debug/herdr client focus local --client <client-id>
```

Only fork-built full TUIs expose this socket; an already-running upstream TUI
does not gain the feature automatically. A live-client cutover or remote setup
needs separate approval. No installed application was replaced. The source
adapter below is implemented; the installed MicroManager remains local-only.

## MicroManager adapter cutover

The authorized adapter is implemented in the current MicroManager and Herdr
working trees. These additions are **uncommitted and unpublished**, not part of
Herdr commit `a0f0c31e`, an upstream release, or the installed September 9 app.
The primary MicroManager branch still includes deferred HID/lighting experiments;
do not install it as a validated release.

### Binding and runtime metadata

- `WL_HERDR_BINARY` chooses the fork executable; default is `herdr` on PATH.
  Before any client command, MicroManager calls offline
  `herdr api controller-capabilities` and requires protocol 1 with
  `runtime_snapshot` and `guarded_actions`. This safely rejects upstream binaries
  inside their existing `api` CLI family, without accidentally launching a TUI.
- The menu binds a full TUI by exact client ID, even while hardware is off.
  `WL_HERDR_CLIENT_ID` overrides the persisted choice. Automatic works only with
  exactly one live client; disappearance of an explicit choice never retargets
  another window. Terminal-app activation is still app-level, not exact OS-window
  activation.
- `herdr client snapshot --runtime --client <client-id>` joins the TUI's cached
  authoritative order/status/sequence with each online endpoint's public
  `session.snapshot` for real terminal IDs, working/foreground directories, tab
  labels/numbers, panes, tabs, and workspaces. It marks `runtime_metadata=true`.
  Each addressed fork server must provide optional JSON-only `snapshot.boot_id`
  matching the TUI boot; missing/mismatched metadata disables only that machine.
  The CLI fences the same-client projection after reads. No frozen endpoint codec
  or load-bearing method fields were changed.
- The Swift adapter coalesces overlapping combined polls instead of subscribing
  to a local-only event stream. Root selected machine/pane determines focus;
  another server's focused flag cannot make an agent appear selected. Failed
  machine metadata is reported and pruned; healthy machines remain. Whole-read
  failure clears old agents/lighting instead of leaving ghost entries.

### Targeted navigation and input

`HerdrAgentTarget` carries **client + machine + boot + pane + terminal** identity.
Notifications, completion lighting, and retained Pi/Claude picker state use that
scope. Server restarts, reused pane IDs, replacement occupants, or a different
bound TUI cannot inherit or act on the previous target. Stack/Land panels reject
Remote paths rather than treating the same path as a local repository.

MicroManager invokes `herdr client action --client <client-id> --request-json -`.
The strict stdin JSON contains `action`, `machine_id`, `boot_id`, `pane_id`, and
`terminal_id`; input text never enters argv or a shell. Supported actions:

| Action | Behavior |
|---|---|
| `focus_agent` | Requires a current agent; activates the addressed machine/pane with a real TUI presentation acknowledgement. |
| `send_keys` | Requires `keys`; exact selected machine/pane and current occupant. |
| `send_text` | Requires `text`; literal text without implicit Enter, to that selected occupant only. |
| `cycle_tabs` | Advances the selected pane's workspace by tab number, includes non-agent tabs, wraps, and no-ops for a single tab. |

Unknown/duplicate fields and stale identities are rejected. Read-before-action
fencing is **not atomic compare-and-mutate** and cannot undo already-written
input; do not blindly replay after uncertain results. CLI success is JSON on
stdout and structured failures on stderr. The Swift adapter decodes both failure
carriers, bounds output/time, and closes its owned subprocess group on timeout
or cancellation. Existing Secure Input, media ownership, one-shot layer departure,
and deferred HID experiments are unchanged.

### Verification and deployment boundary

Non-live verification preceded the disposable runtime trial:

- WLKit built in the primary tree and a separate synchronous profile reconstructed
  from the checkpoint plus current source/test overlays and the updated exclusions
  patch. Combined Swift Testing runs passed **117 primary / 105 synchronous tests**.
  Six migrated app UI files syntax-parsed. No full app/UI build is claimed: the
  selected macOS 27 CLT still lacks `SwiftUIMacros.StateMacro`.
- Native Herdr `just lint`, full `just test` (**3,737 Rust tests passed; 12 skipped**),
  and `cargo build --locked` passed with the pinned toolchains above. The generated
  public JSON schema includes optional boot metadata; frozen-codec checks passed.
  A cancellation regression exposed `BufRead::read_line` retrying `Interrupted`
  forever; cancellation is now a terminal read failure that closes the peer.
- Two real disposable servers and full PTY TUIs supplied natural unauthenticated
  Codex agents (`unknown` status), duplicate pane IDs, real cwd/terminal/boot data,
  and virtual `BridgeController` pad/notification navigation. No synthetic agent
  statuses, prompts, or approvals were injected.
- The trial confirmed independent explicit TUI selections, automatic ambiguity
  refusal, incompatible upstream preflight refusal, wrong-machine/client/occupant
  rejection, and Remote-only literal Unicode text plus explicit Enter into owned
  non-agent receivers with Local unchanged. Remote tab cycling included shell
  tabs and wrap. Bridge submit/macros refused a selected non-agent shell rather
  than falling through to another machine's agent.
- Stopping only the disposable Remote pruned its agents while retaining Local
  and allowed Local recovery. Restarting only that server produced new boot and
  terminal IDs; old notification/focus targets were rejected. Stalled-command
  timeout/cancellation smoke verified parent/child group cleanup even with a
  blocked stdin writer.
- Final documentation contracts passed all 7 tests and Japanese/Chinese heading
  parity passed. The documented standalone machine/notification suites passed
  8 and 10 tests after the final adapter change. Disposable servers, TUIs, and
  adapters were stopped; owned sockets and staging directories were removed.

The SSH shim executed real discovery and stdio bridging but no actual SSH host
or authentication. Physical HID/lighting, native panel visuals, real SSH, and
Windows remain unverified. User applications/sessions, installations, hardware
configuration, Secure Input, and FineTune were not changed. Before a live cutover,
resolve the full toolchain blocker and obtain separate approval for matching fork
TUIs/servers and a hardware-validated synchronous app build.


[selection-discussion]: https://github.com/herdrdev/herdr/discussions/4396
[stable-release]: https://github.com/herdrdev/herdr/releases/tag/v0.9.3
[preview-index]: https://herdr.dev/llms-preview.txt
[open-prs]: https://github.com/herdrdev/herdr/pulls?q=is%3Apr+state%3Aopen
[master-schema]: https://github.com/herdrdev/herdr/blob/c4653a4f10502601ac110b12b2c45a5f7134082b/src/api/schema.rs
[master-agents]: https://github.com/herdrdev/herdr/blob/c4653a4f10502601ac110b12b2c45a5f7134082b/src/api/schema/agents.rs
[master-events]: https://github.com/herdrdev/herdr/blob/c4653a4f10502601ac110b12b2c45a5f7134082b/src/api/schema/events.rs
[master-server]: https://github.com/herdrdev/herdr/blob/c4653a4f10502601ac110b12b2c45a5f7134082b/src/api/server.rs
[master-navigation]: https://github.com/herdrdev/herdr/blob/c4653a4f10502601ac110b12b2c45a5f7134082b/src/client/shell/endpoint_navigation.rs
[federation-pr]: https://github.com/herdrdev/herdr/pull/3670
[routing-pr]: https://github.com/herdrdev/herdr/pull/3918
[focus-pr]: https://github.com/herdrdev/herdr/pull/3764
[fleet-issue]: https://github.com/herdrdev/herdr/issues/3493
