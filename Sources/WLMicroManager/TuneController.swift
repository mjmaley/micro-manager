import Foundation
import WLKit

/// The dial and joystick: effort and model for whichever agent has focus.
///
/// Claude Code takes orders directly — `/effort <level>` and `/model <name>`
/// are commands, so the dial climbs an effort ladder and the joystick cycles
/// a model list, both configurable. Codex has bindable effort commands but
/// only a picker for models. Pi exposes both as TUI pickers: the dial drives
/// `/thinking` (with its click confirming), while the joystick drives `/model`.
///
/// Either way the joystick is working a list you cannot see from the pad, so
/// every deflection also puts that list on screen — see `TunePanelController`.
@MainActor
final class TuneController {

    static let shared = TuneController()

    /// The chords `~/.codex/config.toml` binds to
    /// `chat.increase_reasoning_effort` / `chat.decrease_reasoning_effort`.
    static let codexEffortUpChord = "ctrl+alt+u"
    static let codexEffortDownChord = "ctrl+alt+d"

    var onError: ((String) -> Void)?
    /// The bridge owns the loaded config; this reads through to it.
    var bindings: () -> KeyBindings = { KeyBindings() }
    /// Called by joystick east/right and west/left when no model picker is
    /// active. Vertical directions and picker-confirm/cancel behavior remain
    /// unchanged.
    var onAgentPage: ((Int) -> Void)?

    /// Where each Claude pane sits on the effort ladder and model list. Blind
    /// state: it starts at the defaults and follows our own commands, so a
    /// change made by hand inside the session drifts it until the next nudge.
    private var claudeEffortIndex: [HerdrAgentTarget: Int] = [:]
    private var claudeModelIndex: [HerdrAgentTarget: Int] = [:]

    /// The codex pane whose `/model` picker we opened, if any. Deflections
    /// steer the picker only while this is fresh; a stale entry means the
    /// picker was dealt with by hand.
    private var modelPickerPane: HerdrAgentTarget?
    private var modelPickerOpened: Date?
    private var thinkingPickerPane: HerdrAgentTarget?
    private var thinkingPickerOpened: Date?
    private static let pickerLifetime: TimeInterval = 30

    /// Hardware detents can arrive faster than Herdr RPC round trips. Keep
    /// picker operations ordered so several quick turns do not each try to
    /// open a fresh selector.
    private var controlTask: Task<Void, Never>?

    // MARK: - Dial: effort

    func handleDial(_ step: Int) {
        let previous = controlTask
        controlTask = Task { [weak self] in
            await previous?.value
            await self?.dial(step)
        }
    }

    func handleDialClick() {
        let previous = controlTask
        controlTask = Task { [weak self] in
            await previous?.value
            await self?.dialClick()
        }
    }

    private func dial(_ step: Int) async {
        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                let ladder = bindings().claudeEfforts
                let index = climb(claudeEffortIndex[pane] ?? ladder.count / 2,
                                  by: step, within: ladder.count)
                claudeEffortIndex[pane] = index
                try await send(command: "/effort \(ladder[index])", to: pane)
            } else if kind.contains("codex") {
                try await HerdrClient.sendKeys(
                    target: pane,
                    keys: [step > 0 ? Self.codexEffortUpChord : Self.codexEffortDownChord]
                )
            } else if isPi(kind) {
                try await piThinking(step, pane: pane)
            } else {
                onError?("No effort control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func dialClick() async {
        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        guard isPi(kind) else { return }
        do {
            if pickerIsOpen(pane: thinkingPickerPane, opened: thinkingPickerOpened, target: pane) {
                try await HerdrClient.sendKeys(target: pane, keys: ["enter"])
                thinkingPickerPane = nil
                thinkingPickerOpened = nil
            } else {
                modelPickerPane = nil
                modelPickerOpened = nil
                TunePanelController.shared.hide()
                try await send(command: "/thinking", to: pane)
                thinkingPickerPane = pane
                thinkingPickerOpened = Date()
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func piThinking(_ step: Int, pane: HerdrAgentTarget) async throws {
        if !pickerIsOpen(pane: thinkingPickerPane, opened: thinkingPickerOpened, target: pane) {
            modelPickerPane = nil
            modelPickerOpened = nil
            TunePanelController.shared.hide()
            try await send(command: "/thinking", to: pane)
            thinkingPickerPane = pane
            // Give Pi one rendering turn before steering the new picker.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try await HerdrClient.sendKeys(target: pane, keys: [step > 0 ? "down" : "up"])
        thinkingPickerOpened = Date()
    }

    /// Clamped, not wrapping: turning past the top should pin at max, not
    /// jump to low — a dial has ends even when the hardware spins freely.
    private func climb(_ index: Int, by step: Int, within count: Int) -> Int {
        max(0, min(count - 1, index + step))
    }

    // MARK: - Joystick: model

    func handleJoystick(_ direction: Pad.JoystickDirection) {
        let previous = controlTask
        controlTask = Task { [weak self] in
            await previous?.value
            await self?.joystick(direction)
        }
    }

    private func joystick(_ direction: Pad.JoystickDirection) async {
        if direction == .east || direction == .west {
            // Horizontal movement keeps its existing meaning while Pi/Codex's
            // model picker is open. Otherwise it is an agent-bank gesture.
            var focusedTarget: HerdrAgentTarget?
            do {
                focusedTarget = try await HerdrClient.focusedAgent()?.focusTarget
            } catch {
                focusedTarget = nil
            }
            let pickerOpen = focusedTarget.map {
                pickerIsOpen(pane: modelPickerPane, opened: modelPickerOpened, target: $0)
            } ?? false
            if !pickerOpen {
                modelPickerPane = nil
                modelPickerOpened = nil
                TunePanelController.shared.hide()
                onAgentPage?(direction == .east ? 1 : -1)
                return
            }
        }

        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                try await claudeModel(direction, pane: pane, agent: agent.shortName)
            } else if kind.contains("codex") {
                try await tuiModel(
                    direction, pane: pane, agent: agent.shortName,
                    showCodexGuide: true, invertVertical: false
                )
            } else if isPi(kind) {
                try await tuiModel(
                    direction, pane: pane, agent: agent.shortName,
                    showCodexGuide: false, invertVertical: true
                )
            } else {
                onError?("No model control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Models cycle with wraparound — unlike effort, a list of names has no
    /// natural top or bottom.
    private func claudeModel(
        _ direction: Pad.JoystickDirection,
        pane: HerdrAgentTarget,
        agent: String
    ) async throws {
        let models = bindings().claudeModels
        let step: Int
        switch direction {
        case .north: step = -1
        case .south: step = 1
        case .east, .west: return
        }
        let index = ((claudeModelIndex[pane] ?? 0) + step + models.count) % models.count
        claudeModelIndex[pane] = index
        // Up before the command goes out: the panel is the answer to "what did
        // I just land on", and waiting for the TUI to echo would show it late.
        TunePanelController.shared.showModels(
            models,
            current: index,
            agent: agent,
            hint: "north and south cycle the list"
        )
        try await send(command: "/model \(models[index])", to: pane)
    }

    private func tuiModel(
        _ direction: Pad.JoystickDirection,
        pane: HerdrAgentTarget,
        agent: String,
        showCodexGuide: Bool,
        invertVertical: Bool
    ) async throws {
        let pickerOpen = pickerIsOpen(pane: modelPickerPane, opened: modelPickerOpened, target: pane)

        guard pickerOpen else {
            // Any vertical deflection opens the picker; the rest is steering.
            guard direction == .north || direction == .south else { return }
            thinkingPickerPane = nil
            thinkingPickerOpened = nil
            try await send(command: "/model", to: pane)
            modelPickerPane = pane
            modelPickerOpened = Date()
            if showCodexGuide { showCodexModels(agent: agent) }
            return
        }

        switch direction {
        case .north:
            try await HerdrClient.sendKeys(target: pane, keys: [invertVertical ? "down" : "up"])
            if showCodexGuide { showCodexModels(agent: agent) }
        case .south:
            try await HerdrClient.sendKeys(target: pane, keys: [invertVertical ? "up" : "down"])
            if showCodexGuide { showCodexModels(agent: agent) }
        case .east:
            try await HerdrClient.sendKeys(target: pane, keys: ["enter"])
            modelPickerPane = nil
            modelPickerOpened = nil
            TunePanelController.shared.hide()
        case .west:
            try await HerdrClient.sendKeys(target: pane, keys: ["esc"])
            modelPickerPane = nil
            modelPickerOpened = nil
            TunePanelController.shared.hide()
        }
        modelPickerOpened = Date()
    }

    /// Codex's picker is its own; we push arrow keys at it without being told
    /// where the cursor sits, so the panel is a numbered reading of the list
    /// and nothing is marked as current.
    private func showCodexModels(agent: String) {
        TunePanelController.shared.showModels(
            bindings().codexModels,
            current: nil,
            agent: agent,
            hint: "north and south move · east confirms · west cancels"
        )
    }

    // MARK: - Plumbing

    private func isPi(_ kind: String) -> Bool {
        kind == "pi" || kind.contains("pi-coding-agent")
    }

    private func pickerIsOpen(pane: HerdrAgentTarget?, opened: Date?, target: HerdrAgentTarget) -> Bool {
        pane == target && Date().timeIntervalSince(opened ?? .distantPast) < Self.pickerLifetime
    }

    private func focusedPane() async -> (HerdrAgent, HerdrAgentTarget)? {
        guard let agent = try? await HerdrClient.focusedAgent(), let pane = agent.focusTarget else {
            onError?("Nothing has focus in Herdr right now.")
            return nil
        }
        return (agent, pane)
    }

    /// Slash commands are pasted and submitted. herdr-core holds them behind
    /// a person's unsent draft and refuses a program that is asking something.
    private func send(command: String, to pane: HerdrAgentTarget) async throws {
        try await HerdrClient.submitText(target: pane, text: command)
    }
}
