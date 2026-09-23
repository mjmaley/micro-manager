# FineTune integration for dictation media interruption

## Scope and inspected versions

Question: can FineTune help pause or suppress browser and other media while Codex Desktop or OpenWhispr records, regardless of keyboard or Codex Micro trigger?

- Installed `/Applications/FineTune.app/Contents/Info.plist`: version **1.9.0**, build **38**, bundle ID `com.finetuneapp.FineTune`, registered scheme `finetune`.
- Inspected upstream source at matching tag **v1.9.0**, commit `06b34eca720e426d955a1b00c7f88346c23125fc`. Current main was also checked for changes to the URL handler and URL guide; those files had no differences from the tag.
- Source checkout is a temporary inspection copy at `/tmp/finetune-inspection/source`. No FineTune configuration or playback commands were executed.

## Findings

### Existing integration: per-app mute and volume, not playback pause

FineTune exposes `finetune://` actions for setting/stepping volume, setting/toggling mute, routing output, and resetting settings. The handler has no playback pause/resume, recording lifecycle, external state query, or temporary attenuation-session action.

Sources: [URL guide](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/guide/url-schemes.md), [URLHandler.swift](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/FineTune/Utilities/URLHandler.swift).

For example, this would mute Brave (illustrative only, **not executed**):

```sh
open -g 'finetune://set-mute?app=com.brave.Browser&muted=true'
```

This suppresses the app's audio; it does not stop its media timeline. Control is by app identifier, not individual browser tab. The engine applies volume/mute to app audio taps rather than issuing player transport commands.

Source: [AudioEngine.swift, setVolume/setMute/applyTapOutputState](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/FineTune/Audio/Engine/AudioEngine.swift).

### Ordinary URL commands are unsuitable for robust temporary restoration

The URL handler sends normal engine volume/mute writes. `VolumeState` persists those values. There is no URL getter or transaction token with which MicroManager could safely capture and restore state. An unconditional unmute at recording end could undo an existing user mute; writing an old volume could overwrite a manual change made during recording. Interrupted automation could leave the changed setting persisted.

Sources: [URLHandler.swift](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/FineTune/Utilities/URLHandler.swift), [VolumeState.swift](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/FineTune/Models/VolumeState.swift).

### Audio monitoring is a useful foundation, not a ready-made dictation hook

FineTune already enumerates Core Audio processes, groups helper processes under their responsible application, and listens for `kAudioProcessPropertyIsRunning`. That is general audio I/O activity, not a dedicated indication of dictation or microphone input. Source searches found no existing dictation ducking or `kAudioProcessPropertyIsRunningInput` integration in the inspected release.

Source: [AudioProcessMonitor.swift](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/FineTune/Audio/Monitors/AudioProcessMonitor.swift).

FineTune's tap code has smoothed volume changes, providing a foundation for click-free attenuation. Existing input monitoring and audio capture must not be mistaken for a target dictation app recording.

Source: [ProcessTapController.swift](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/FineTune/Audio/Engine/ProcessTapController.swift).

## Recommendation (proposed design, not implemented)

1. Keep **true pause/resume** in MicroManager using a state-aware Now Playing backend. FineTune's existing automation cannot replace that. Coverage remains limited to compatible media sessions; browser support and session identity must be tested.
2. If silence is required even for unsupported media, optionally add **temporary attenuation** to FineTune rather than starting a second audio-tap engine in MicroManager.
3. Implement attenuation as a non-persistent multiplier layered over the user's normal volume, boost, and mute. Removing it should reveal the user's current settings, not restore a stale snapshot. Account for FineTune's device gain and loudness processing when choosing the insertion point.
4. Expose a tokenized begin/end suppression API with overlapping-session handling and an expiring lease/heartbeat so MicroManager crashes cannot leave audio suppressed indefinitely. These would be new APIs, not existing URL actions.
5. Detect input activity specifically for Codex/OpenWhispr, including helper-process attribution. Validate that each app closes its input stream between takes; if it keeps input warm, obtain a more specific recording lifecycle signal. Do not rely on MicroManager's current button-based `takeOpen` toggle or global microphone activity.
6. Exclude dictation cues, calls, and ignored apps by policy. FineTune control is app-wide, so suppressing a browser could also suppress a call in another tab. New media sources during a take and device changes require explicit handling.
7. Choose one owner for OpenWhispr's existing media-pause feature to avoid competing pause/resume controllers.

A simpler initial implementation is **pause-only in MicroManager**, leaving FineTune unchanged. Add a FineTune fork only if broader suppression is desired and letting unsupported media continue silently is acceptable.

## Licensing

FineTune is GPLv3. Treat copying its implementation into another project separately from calling its URL interface; check licensing compatibility before code reuse or redistribution.

Source: [LICENSE](https://github.com/ronitsingh10/FineTune/blob/v1.9.0/LICENSE).
