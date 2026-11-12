import Foundation

/// Agents from herdr-core's `terminal.list`, placed and focused by the Herdr
/// app. The core is required; without the app, agents keep core order and
/// none is focused.
public struct HerdrSnapshot: Equatable, Sendable {
    public let agents: [HerdrAgent]
    /// A disconnected machine or an unavailable app: partial, not failed.
    public let warning: String?

    init(core: [String: Any], app: [String: Any]?, focusedPane: String?, appError: String?) throws {
        guard let terminals = core["terminals"] as? [[String: Any]] else {
            throw HerdrError.badResponse("herdr-core terminal.list has no terminals.")
        }
        var agents: [HerdrAgent] = []
        var addresses = Set<String>()
        for terminal in terminals {
            guard let address = terminal["address"] as? String, addresses.insert(address).inserted else {
                throw HerdrError.badResponse("herdr-core listed a terminal without a unique address.")
            }
            if let agent = Self.agent(terminal, address: address) { agents.append(agent) }
        }

        // Place agents where the app shows them; a terminal shown twice keeps
        // its first place and pane.
        var places: [String: (rank: Int, pane: String?)] = [:]
        func visit(_ shown: [String: Any]) {
            if let address = shown["terminal"] as? String, places[address] == nil {
                places[address] = (places.count, shown["pane"] as? String)
            }
            for child in shown["sub_agents"] as? [[String: Any]] ?? [] { visit(child) }
        }
        for space in app?["spaces"] as? [[String: Any]] ?? [] {
            for tab in space["tabs"] as? [[String: Any]] ?? [] {
                for shown in tab["terminals"] as? [[String: Any]] ?? [] { visit(shown) }
            }
        }
        for index in agents.indices {
            guard let pane = places[agents[index].address]?.pane else { continue }
            agents[index].paneID = pane
            agents[index].focused = pane == focusedPane
        }
        let coreOrder = Dictionary(uniqueKeysWithValues: agents.enumerated().map { ($1.address, $0) })
        self.agents = agents.sorted { lhs, rhs in
            switch (places[lhs.address]?.rank, places[rhs.address]?.rank) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return coreOrder[lhs.address]! < coreOrder[rhs.address]!
            }
        }

        let offline = (core["machines"] as? [[String: Any]] ?? []).first { $0["state"] as? String != "connected" }
        let machineWarning = offline.map { machine in
            let name = machine["name"] as? String ?? "A machine"
            let state = (machine["state"] as? String ?? "unknown").replacingOccurrences(of: "_", with: " ")
            return "\(name) is \(state); its agents are not shown."
        }
        warning = appError ?? machineWarning
    }

    private static let knownStates: Set = ["idle", "working", "blocked", "done", "error"]

    private static func agent(_ terminal: [String: Any], address: String) -> HerdrAgent? {
        // A terminal is an agent while its program reports an OSC 7501 status.
        guard terminal["state"] as? String == "live",
              let status = terminal["status"] as? [String: Any],
              let state = status["state"] as? String else { return nil }
        let foreground = terminal["foreground"] as? [String: Any]
        let name = (status["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (foreground?["name"] as? String) ?? "agent"
        var display = knownStates.contains(state) ? state : "unknown"
        // The app records the last turn a person has seen. A finished turn
        // they have looked at is idle, exactly as the app's lists show it.
        if display == "done",
           let turn = (terminal["turn"] as? NSNumber)?.intValue,
           let seen = ((terminal["labels"] as? [String: Any])?["herdr.seen"] as? String).flatMap(Int.init),
           seen >= turn {
            display = "idle"
        }
        return HerdrAgent(
            agent: name,
            status: display,
            address: address,
            createdMs: (terminal["created_ms"] as? NSNumber)?.int64Value,
            cwd: terminal["cwd"] as? String,
            foregroundCwd: foreground?["cwd"] as? String
        )
    }
}

/// Coalesce overlapping reads; sequential polls and actions still read fresh.
actor HerdrSnapshotLoader {
    private var pending: Task<HerdrSnapshot, Error>?

    func load() async throws -> HerdrSnapshot {
        if let pending { return try await pending.value }
        let task = Task { try await HerdrClient.loadSnapshot() }
        pending = task
        defer { pending = nil }
        return try await task.value
    }
}
