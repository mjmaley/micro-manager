# Agent entry point

Read **[docs/HANDOFF.md](docs/HANDOFF.md)** before changing, building, installing,
or diagnosing this fork. It records the installed/source distinction, current
incidents, test limitations, and next steps. Update it after consequential work.

- Fork: `mjmaley/micro-manager`; working branch: `layer-aware-herdr`.
  `origin` is the user's fork; `upstream` is `schacon/micro-manager`.
- This branch preserves deferred HID-queue/lighting-coalescing experiments.
  **Do not install the primary working tree as if it were the validated release.**
  Reconstruct the synchronous source profile in separate staging as documented.
- Preserve uncommitted work. No force pushes, destructive resets, or changes to
  upstream/main/release tags without explicit scope. Pushing this feature branch
  is a checkpoint, not a declaration that the experiments are production-ready.
- Keep Herdr server, clients, and agents running during diagnosis. Do not inject
  keys, prompts, approvals, synthetic statuses, or restart sessions to obtain a
  convenient test result. Ask before disruptive recovery/installation changes.
- Never disable another application's Secure Input, globally disable automatic
  protection, or terminate loginwindow. PID associations may be stale. A secure
  scope can exist without a visible password prompt. Do not blame an application
  without evidence. The September 23 recovery did **not** involve quitting Brave.
- Leave FineTune unchanged. Media resume requires retained ownership of an
  explicitly confirmed pause; never use a blind media toggle.
- Layer departure clearing is one-shot; do not activate Codex, inject keys, or
  rewrite its keymap just to refresh lighting.
- Run non-live tests first. Bare `swift test` can discover local hardware/services;
  use `--skip Live` with full Xcode, or the documented standalone suite runners.
- No credentials, raw terminal contents, private project titles, or runtime logs
  in commits. This fork is public. Commit focused diagnostic summaries instead.
- Application ID is shared by local bundles. Check exact process paths before
  recovery; an obsolete `build/MicroManager.app` was launched during
  the September 23 investigation. Do not leave two copies driving the pad.
