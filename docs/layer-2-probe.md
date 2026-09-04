# Codex Micro Layer 2 probe

Run 2026-09-03 against the connected Codex Micro while Codex desktop was running.

## Device

- Product: `Codex Micro`
- USB product ID: `0x8360`
- Firmware: `0.6.2`
- Active profile: `0` (`Default`)
- Active layer during test: wire `layer_index: 2`

Initial keymap summary:

- Layer 1: physical keys 0–5 bound to `KV_OAI_AG00`–`KV_OAI_AG05`
- Layer 2: no AG bindings

## Procedure and observed protocol results

1. Saved the complete original keymap to `.probe-backups/keymap-2026-09-03T05-38-19Z.json`.
2. Changed only Layer 2, physical key 0 from `KC_NONE` to `KV_OAI_AG00`.
3. Read the keymap back and verified the firmware retained the binding.
4. While Layer 2 was active, repeatedly sent alternating cyan/purple `v.oai.thstatus` updates for thread 0. Visual confirmation showed that **thread 0 illuminated the upper-left physical button**. The initial diagram had incorrectly labeled that button 1; on this Codex Micro it is physical/matrix button 0 and is also the Codex slot for the most recently active thread.
5. Pressing that illuminated upper-left button produced both expected `AG00` notifications:
   - `{"act":1,"k":"AG00"}`
   - `{"act":0,"k":"AG00"}`
6. Detected five RPC responses issued by another client, confirming Codex desktop was concurrently connected to the shared HID channel.
7. The operator observed no action or focus change in Codex after a single `AG00` press from Layer 2. This was initially—but incorrectly—taken as evidence that Codex gated handling by layer.
8. Re-read the latest keymap and restored only Layer 2, key 0 to `KC_NONE`; read-back verification passed.

## Follow-up correction

Inspection of Codex Desktop's packaged implementation showed that it does not
check `device.status.layer_index` before forwarding `v.oai.hid`. It recognizes
`AG00`–`AG05` as agent slots on every layer. A first press is forwarded to the
current Codex window; a second press on the same slot within 350 ms brings that
window forward unless single-tap agent keys are enabled. The original
single-press observation therefore did not exercise the visible context-switch
behavior and cannot establish layer isolation.

## Conclusion

`KV_OAI_AG*` input notifications are not restricted to Layer 1 on Codex Micro firmware 0.6.2. They work when installed on and activated from Layer 2. Per-thread lighting also works on Layer 2. For this Codex Micro, keymap position 0, `AG00`, lighting thread 0, and the upper-left physical button all align. This differs from Micro Manager's Creator Micro 2 assumption that the top pair is physically reversed, so the production bridge needs device-variant geometry.

Concurrent Codex traffic exists, and both clients receive the same Layer 2 AG notifications. Micro Manager can gate its own Herdr input and lighting on `device.status.layer_index`, but it cannot consume a shared notification before Codex sees it. True isolation requires Codex to gate its own input by layer or a Layer 2 keymap that avoids the Codex-reserved `AG00`–`AG05` slot identifiers.
