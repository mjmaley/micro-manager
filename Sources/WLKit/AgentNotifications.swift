import Foundation

/// Notification destinations never use a page/slot number. Socket incarnation
/// plus pane AND terminal IDs prevent an old alert targeting a reused pane.
public struct AgentNotificationTarget: Codable, Hashable, Sendable {
    public let socketPath: String
    public let socketIdentity: String
    public let paneID: String
    public let terminalID: String

    public init?(agent: HerdrAgent, socketPath: String, socketIdentity: String) {
        guard let pane = agent.paneID, !pane.isEmpty,
              let terminal = agent.terminalID, !terminal.isEmpty else { return nil }
        self.socketPath = socketPath
        self.socketIdentity = socketIdentity
        self.paneID = pane
        self.terminalID = terminal
    }

    public func matches(_ agent: HerdrAgent) -> Bool {
        agent.paneID == paneID && agent.terminalID == terminalID
    }

    public var identifier: String {
        // Length-delimited via JSON; no ambiguous concatenation or shell commands.
        let parts = [socketPath, socketIdentity, paneID, terminalID]
        let data = try! JSONEncoder().encode(parts)
        return "herdr-agent-" + data.base64EncodedString()
    }

    /// A restarted server replaces its Unix socket. Never trust pane IDs alone
    /// across that boundary. Failure to stat the socket disables targeting.
    public static func socketIdentity(at path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSocket,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        return "\(device):\(inode):\(created.timeIntervalSince1970)"
    }
}

public struct AgentNotificationEvent: Sendable {
    public enum Kind: String, Sendable { case attention, finished }
    public let target: AgentNotificationTarget
    public let agent: HerdrAgent
    public let kind: Kind
}

/// Pure transition policy, shared with tests. Startup, reconnect, sleep/wake,
/// and newly discovered panes establish a baseline rather than replaying alerts.
public struct AgentNotificationTracker {
    private var previous: [AgentNotificationTarget: HerdrAgent] = [:]

    public init() {}
    public mutating func reset() { previous.removeAll() }

    public mutating func consume(
        _ agents: [HerdrAgent], socketPath: String, socketIdentity: String,
        terminalActive: Bool
    ) -> [AgentNotificationEvent] {
        var next: [AgentNotificationTarget: HerdrAgent] = [:]
        var events: [AgentNotificationEvent] = []
        for agent in agents {
            guard let target = AgentNotificationTarget(
                agent: agent, socketPath: socketPath, socketIdentity: socketIdentity
            ) else { continue }
            next[target] = agent
            guard let old = previous[target], old.agent == agent.agent,
                  old.status != agent.status,
                  !(agent.focused && terminalActive) else { continue }
            let kind: AgentNotificationEvent.Kind
            if agent.status == "blocked" {
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
