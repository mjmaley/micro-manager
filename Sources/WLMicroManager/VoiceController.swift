import AppKit

/// The wide bottom key: sends **Command+/**, matching this machine's
/// OpenWhispr `DICTATION_KEY` with tap activation.
///
/// OpenWhispr is system-wide and types into whatever holds focus, so this
/// deliberately does not care which agent Herdr has focused, or whether Herdr
/// is running at all. That is the difference from what this key used to do: it
/// asked Herdr for the focused agent and forked — Claude Code got a chord
/// injected into its pane for its own voice mode, everything else got macOS
/// dictation. One transcriber for every harness is simpler, and it is the one
/// press that has to work when you are mid-thought.
///
/// Posting a key event needs the **Accessibility** grant, on top of the Input
/// Monitoring grant the pad needs. The check below raises the system prompt the
/// first time.
@MainActor
final class VoiceController {

    static let shared = VoiceController()

    /// ANSI slash (`/`). OpenWhispr's configured chord is Command+/.
    static let triggerKey: CGKeyCode = 0x2C

    /// Mirrors an open take, for the key light.
    var onActiveChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// Fallback estimate used only when microphone observation is disabled.
    /// Keyboard/native-app start/stop can make this estimate drift.
    private var takeOpen = false
    private var activityIsObserved = false

    /// Actual input activity wins over button-count guessing when the optional
    /// media feature is running. nil restores the legacy lighting behavior.
    func setObservedRecording(_ active: Bool?) {
        activityIsObserved = active != nil
        let value = active ?? false
        guard takeOpen != value else { return }
        takeOpen = value
        onActiveChange?(value)
    }

    func handleVoiceKey() {
        do {
            try tapTriggerKey()
            if !activityIsObserved {
                takeOpen.toggle()
                onActiveChange?(takeOpen)
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func tapTriggerKey() throws {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            throw VoiceFailure.accessibilityDenied
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source,
                               virtualKey: Self.triggerKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source,
                             virtualKey: Self.triggerKey, keyDown: false)
        else { throw VoiceFailure.eventFailed }

        // Flags belong to each synthetic slash event. Keeping Command present
        // on both halves makes this a complete Command+/ chord without posting
        // a standalone modifier that could become stuck.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    enum VoiceFailure: LocalizedError {
        case accessibilityDenied
        case eventFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Sending Command+/ needs the Accessibility permission: "
                    + "System Settings → Privacy & Security → Accessibility → Micro Manager."
            case .eventFailed:
                return "Could not synthesise the OpenWhispr Command+/ shortcut."
            }
        }
    }
}
