import Foundation

/// One terminal occupant, not a page/slot. An alert cannot migrate to a
/// different terminal at the same address or to a renamed machine's address.
public struct HerdrAgentTarget: Codable, Hashable, Sendable {
    /// `t7` or `machine/t7`, as herdr-core names it.
    public let address: String
    public let createdMs: Int64

    public init?(agent: HerdrAgent) {
        self.init(address: agent.address, createdMs: agent.createdMs)
    }

    init?(address: String, createdMs: Int64?) {
        guard let createdMs, !address.isEmpty,
              !address.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }
        self.address = address
        self.createdMs = createdMs
    }

    public func matches(_ agent: HerdrAgent) -> Bool {
        agent.focusTarget == self
    }

    public var identifier: String {
        // Length-delimited via JSON; no ambiguous concatenation.
        let data = try! JSONEncoder().encode([address, String(createdMs)])
        return "herdr-agent-" + data.base64EncodedString()
    }
}

public struct AgentNotificationEvent: Sendable {
    public enum Kind: String, Sendable { case attention, finished }
    public let target: HerdrAgentTarget
    public let agent: HerdrAgent
    public let kind: Kind
}

/// Pure transition policy, shared with tests. Startup, reconnect, sleep/wake,
/// and newly discovered panes establish a baseline rather than replaying alerts.
public struct AgentNotificationTracker {
    private var previous: [HerdrAgentTarget: HerdrAgent] = [:]

    public init() {}
    public mutating func reset() { previous.removeAll() }

    public mutating func consume(
        _ agents: [HerdrAgent], terminalActive: Bool
    ) -> [AgentNotificationEvent] {
        var next: [HerdrAgentTarget: HerdrAgent] = [:]
        var events: [AgentNotificationEvent] = []
        for agent in agents {
            guard let target = agent.focusTarget else { continue }
            next[target] = agent
            guard let old = previous[target], old.agent == agent.agent,
                  old.status != agent.status,
                  !(agent.focused && terminalActive) else { continue }
            let kind: AgentNotificationEvent.Kind
            if ["blocked", "error"].contains(agent.status) {
                kind = .attention
            } else if ["working", "blocked"].contains(old.status)
                        && ["done", "idle"].contains(agent.status) {
                kind = .finished
            } else {
                continue
            }
            events.append(AgentNotificationEvent(target: target, agent: agent, kind: kind))
        }
        previous = next
        return events
    }
}
