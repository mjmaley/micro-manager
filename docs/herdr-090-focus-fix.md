# Herdr 0.9.0 visible focus repair — 2026-09-08

Historical release record, superseded by the September 9 Secure Input build.
See [HANDOFF.md](HANDOFF.md) for the current installed hash, safe source profile,
and pending work. Herdr CLI/server were observed at 0.9.1 on September 22–23.
Do not use the old focus-only exclusions patch for the current branch.

## Cause and verification

Both installed Herdr client and server report 0.9.0. In the tagged upstream
source, `src/server/headless/client_views.rs:804–872` recognizes public
`workspace.focus`, `tab.focus`, and `pane.focus` requests when propagating
navigation to client shells. `agent.focus` is omitted: it changes server
selection without switching the displayed client workspace/tab.

Source: https://github.com/herdrdev/herdr/blob/v0.9.0/src/server/headless/client_views.rs

A direct `pane.focus` request to the existing `_ai-working` pane succeeded,
and the user confirmed the displayed session switched. No keys were injected
and no Herdr client/server was restarted.

## Upstream intent and expected compatibility

Checked 2026-09-08 against upstream issue/PR metadata and the proposed patch:

- Independent client workspace/tab views were intentional: [PR #3526](https://github.com/herdrdev/herdr/pull/3526), included in the [0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0).
- The broken `agent.focus` viewport behavior is a regression, not the intended new contract. [Issue #3760](https://github.com/herdrdev/herdr/issues/3760) reports the same symptoms. Collaborator-authored [fix PR #3764](https://github.com/herdrdev/herdr/pull/3764) explicitly identifies missing public agent-focus propagation after independent client views were introduced.
- At inspection, #3764 was open and not merged; the latest stable release was still 0.9.0. Its patch adds successful `agent.focus` propagation and a client-viewport regression test while retaining existing `pane.focus` handling.
- Our repair uses a public API already present in the installed schema, not synthetic input or a private client protocol. It should remain compatible with the proposed upstream fix; there is no reason to revert it merely because `agent.focus` is repaired. This is an evidence-based expectation, not a guarantee against future API changes.

## Repair

`HerdrClient.focusAgent` now sends `pane.focus` with `pane_id`. Agent buttons
and notification clicks share this path. It rejects blank identities and
missing/mismatched acknowledgements. `HerdrAgent.focusTarget` no longer falls
back to a terminal ID, which is not a valid pane target.

## Installed build versus working tree

A focus-only build was installed from `/tmp/micromanager-focus-only-20260908`.
It preserves the pre-experiment HID transport and lighting pipeline. The
unfinished background HID writer and lighting-delta/coalescing work remain
in the main working tree, but **are not in the installed build**. Dictation,
read-aware lighting, and layer-departure clearing remain included.

`herdr-090-focus-only-exclusions.patch` records the staging-only exclusions
relative to this working tree at installation time. To reproduce this release,
copy the working tree to a separate staging directory, check and apply that
patch there, then build there. Do not apply it to the primary working tree or
assume it will still apply after subsequent changes.

Backup: `/tmp/MicroManager-before-herdr-focus-fix-20260908-143314.app`

Installed executable SHA-256:
`6e35cc3f788868a736aa4c80184aa740fb184d7a822410875ee7b76a83d2bdae`

Validation: 75 targeted Swift Testing tests passed in the staged source
(6 focus, 25 agent lighting, 10 layer lighting, 34 dictation media); debug and
release builds passed, installed signature verified, and the post-install
sample showed no reconnect path. Full XCTest suites remain unavailable under
Command Line Tools. The pre-existing non-Sendable WLDevice warning remains.
The user subsequently confirmed physical agent-session switching works with the installed repair.
