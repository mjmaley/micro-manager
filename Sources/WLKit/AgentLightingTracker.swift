import Foundation

/// Display-only states, aligned with the unmodified agent.list ordering.
/// The selected agent drives the ring even while the terminal is in background.
public struct AgentLightingSnapshot: Equatable, Sendable {
    public let states: [String]
    public let selectedState: String?

    public init(states: [String], selectedState: String?) {
        self.states = states
        self.selectedState = selectedState
    }
}

/// Tracks completion acknowledgement independently of Herdr's raw statuses.
/// A result remains green until it has been viewed in the foreground AND that
/// view loses focus. Merely selecting a pane behind another app is not a view.
/// No timer and no writes back to Herdr. Identity includes the server socket
/// incarnation, pane, terminal, and agent kind so history cannot move by slot.
public struct AgentLightingTracker {
    private struct Entry {
        var agentKind: String
        var status: String
        var awaitingCompletion = false
        var unread = false
        var viewed = false
    }
    private var entries: [AgentNotificationTarget: Entry] = [:]

    public init() {}
    public mutating func reset() { entries.removeAll() }

    /// Lock/sleep is an observed end of viewing, not a completion event.
    public mutating func endViewing() {
        for key in Array(entries.keys) where entries[key]?.viewed == true {
            entries[key]?.unread = false
            entries[key]?.viewed = false
        }
    }

    public mutating func consume(
        _ agents: [HerdrAgent], socketPath: String, socketIdentity: String?, terminalActive: Bool
    ) -> AgentLightingSnapshot {
        var next: [AgentNotificationTarget: Entry] = [:]
        let states = agents.map { agent -> String in
            guard let socketIdentity,
                  let key = AgentNotificationTarget(agent: agent, socketPath: socketPath,
                                                    socketIdentity: socketIdentity) else {
                // Without stable identity, use only Herdr's reported state.
                return Self.knownState(agent.status)
            }
            let old = entries[key].flatMap { $0.agentKind == agent.agent ? $0 : nil }
            var entry = old ?? Entry(agentKind: agent.agent, status: agent.status)
            // Losing a known view acknowledges its old result independently
            // of the next status (which may briefly be unknown).
            if entry.viewed && !(agent.focused && terminalActive) {
                entry.unread = false
                entry.viewed = false
            }
            switch agent.status {
            case "working", "blocked":
                entry.awaitingCompletion = true
                entry.unread = false
                entry.viewed = false
            case "done", "idle":
                // Pi commonly reports idle on completion, even for an unread
                // background result. Remember the preceding busy state. An
                // explicit new done state also announces a completion.
                if entry.awaitingCompletion || (agent.status == "done" && old?.status != "done") {
                    entry.unread = true
                    entry.viewed = false
                }
                entry.awaitingCompletion = false
                if entry.unread && agent.focused && terminalActive {
                    entry.viewed = true // Stay green until leaving this view.
                }
            default:
                // Unknown is not evidence of completion or acknowledgement.
                // Preserve a known busy/unread cycle across a transient unknown.
                break
            }
            // An unknown -> done recovery is not itself a new completion.
            if Self.knownState(agent.status) != "unknown" { entry.status = agent.status }
            next[key] = entry
            if agent.status == "idle" || agent.status == "done" {
                return entry.unread ? "done" : "idle"
            }
            return Self.knownState(agent.status)
        }
        entries = next // Prune closed panes and replaced server incarnations.
        let selected = agents.firstIndex(where: \.focused).map { states[$0] }
        return AgentLightingSnapshot(states: states, selectedState: selected)
    }

    private static func knownState(_ state: String) -> String {
        ["working", "blocked", "done", "idle"].contains(state) ? state : "unknown"
    }
}
