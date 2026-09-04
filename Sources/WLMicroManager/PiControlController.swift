import Foundation
import WLKit

/// The four controls printed FAST/APPR/REJ/SPLIT on Codex Micro.
///
/// They drive Pi through its focused Herdr pane. In Pi Guardrails' dangerous-
/// command prompt, FAST grants the command for the session while APPR/REJ
/// allow once or deny. SPLIT invokes Pi's built-in `/fork` command.
@MainActor
final class PiControlController {

    static let shared = PiControlController()

    var onError: ((String) -> Void)?

    func allowForSession() { Task { await sendKeys(["a"], onlyWhenBlocked: true) } }
    func approve() { Task { await sendKeys(["enter"]) } }
    func reject() { Task { await sendKeys(["esc"]) } }
    func split() {
        Task {
            guard let pane = await focusedPiPane() else { return }
            do {
                try await HerdrClient.sendText(paneID: pane, text: "/fork")
                try await HerdrClient.sendKeys(paneID: pane, keys: ["enter"])
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    private func sendKeys(_ keys: [String], onlyWhenBlocked: Bool = false) async {
        guard let pane = await focusedPiPane(requireBlocked: onlyWhenBlocked) else { return }
        do {
            try await HerdrClient.sendKeys(paneID: pane, keys: keys)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func focusedPiPane(requireBlocked: Bool = false) async -> String? {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let pane = agent.paneID else {
                onError?("Nothing has focus in Herdr right now.")
                return nil
            }
            let kind = agent.agent.lowercased()
            guard kind == "pi" || kind.contains("pi-coding-agent") else {
                onError?("The focused agent is \(agent.agent), not Pi.")
                return nil
            }
            if requireBlocked && agent.status.lowercased() != "blocked" {
                onError?("Pi is not waiting for an approval right now.")
                return nil
            }
            return pane
        } catch {
            onError?(error.localizedDescription)
            return nil
        }
    }
}
