# Work Louder official-source check

Checked 2026-09-02 for public documentation relevant to driving a Creator Micro 2 from a third-party macOS application.

## Findings

1. **The hardware is officially named Creator Micro 2.** Work Louder's product page advertises Bluetooth/USB-C operation, the Work Louder Input application, and direct integration with ChatGPT Codex. The page says Codex can remap commands and adjust layouts, but it does not publish a third-party HID, lighting, or integration API.
   - Source: [Work Louder — Creator Micro 2](https://worklouder.cc/creator-micro-2)

2. **Work Louder says the current per-key integration is private and unstable.** In its official feedback portal, Davide // Work Louder answered a request for a stable per-key RGB API: “the current implementation is private to the OpenAI and could change without notice. We’re considering a public implementation but I cannot 100% confirm it as of now.”
   - Source: [Work Louder feedback — Can a third-party app drive per-key RGB on the Creator Micro 2?](https://feedback.worklouder.cc/en/p/can-a-third-party-app-drive-per-key-rgb-on)

3. **A public implementation is planned, but not committed or documented.** The same official feedback request is currently marked **Planned**. That status indicates intent, not an API compatibility guarantee or release date.
   - Source: [Work Louder feedback request](https://feedback.worklouder.cc/en/p/can-a-third-party-app-drive-per-key-rgb-on)

4. **Official firmware and Input release repositories do not contain protocol documentation.** The public repositories provide release artifacts and minimal READMEs. No source-level specification for `v.oai.*`, raw-HID framing, key events, or per-key lighting is published there.
   - Source: [worklouder/cm-v2-fw-releases](https://github.com/worklouder/cm-v2-fw-releases)
   - Source: [worklouder/input-releases](https://github.com/worklouder/input-releases)
   - Source: [Work Louder public GitHub repositories](https://github.com/orgs/worklouder/repositories)

5. **Micro Manager therefore relies on an undocumented private protocol.** Its `docs/hacking.md` says the behavior was verified experimentally on firmware `v0.6.0-rc.10`; its source says the `v.oai.*` calls were recovered from `@worklouder/device-kit-oai` shipped inside the Codex desktop application. This is useful interoperability evidence, but it is not an official compatibility contract.
   - Source: [`micro-manager/docs/hacking.md`](hacking.md)
   - Source: [`micro-manager/Sources/WLKit/OAIProtocol.swift`](../Sources/WLKit/OAIProtocol.swift)

## Engineering implication

The Herdr integration is demonstrably feasible, and Micro Manager already implements nearly the exact bridge under consideration. However, we should treat the Work Louder side as an **unsupported, version-sensitive adapter**:

- isolate all HID/RPC behavior behind a narrow device interface;
- probe firmware capabilities rather than assuming methods exist;
- pin and record tested firmware versions;
- preserve and restore the user's keymap;
- detect competing Input/Codex clients;
- keep an ordinary-keyboard fallback that does not depend on per-key RGB;
- expect to replace the private adapter if Work Louder publishes a supported API.

## Related community implementation

A Work Louder feedback comment also points to [`alasano/house-of-herdr`](https://github.com/alasano/house-of-herdr) as another Herdr/Codex Micro integration. This is community evidence, not official documentation, but it is worth comparing before choosing whether to fork, extend, or reimplement Micro Manager.
