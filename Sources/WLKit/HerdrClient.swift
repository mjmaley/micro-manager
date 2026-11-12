import Foundation

/// One herdr-core terminal whose program reports an OSC 7501 status. Shells
/// and programs that never reported are not agents.
public struct HerdrAgent: Equatable, Sendable {
    /// `t7` on this computer, `machine/t7` on a connected machine.
    public var address: String
    /// With the address, identifies one occupant; herdr-core never reuses
    /// an address, but a re-added machine name could.
    public var createdMs: Int64?
    /// The Herdr app pane showing it, if any.
    public var paneID: String?
    /// The program's own name for itself (`omp`, `claude-code`, `codex`).
    public var agent: String
    /// idle, working, blocked, done, error, or unknown. `done` means finished
    /// and not yet seen in the Herdr app; once seen it reads `idle`, as in the
    /// app's own lists.
    public var status: String
    public var cwd: String?
    public var foregroundCwd: String?
    /// The focused pane of the Herdr app shows this agent.
    public var focused: Bool

    /// The core's name for the machine, or nil for this computer.
    public var machineName: String? {
        address.firstIndex(of: "/").map { String(address[..<$0]) }
    }
    public var isLocalMachine: Bool { machineName == nil }
    public var machineLabel: String { machineName ?? "This computer" }

    public var focusTarget: HerdrAgentTarget? { HerdrAgentTarget(agent: self) }

    /// Where the agent is actually working. `foreground.cwd` follows a `cd`
    /// inside the terminal; `cwd` is only where it started.
    public var workingDirectory: String? {
        [foregroundCwd, cwd].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Last path component of the working directory, which is what a person
    /// recognises the agent by.
    public var shortName: String {
        guard let directory = workingDirectory else { return agent }
        return (directory as NSString).lastPathComponent
    }

    public init(
        agent: String = "claude-code",
        status: String,
        address: String = "t1",
        createdMs: Int64? = 1,
        paneID: String? = nil,
        cwd: String? = nil,
        foregroundCwd: String? = nil,
        focused: Bool = false
    ) {
        self.agent = agent
        self.status = status
        self.address = address
        self.createdMs = createdMs
        self.paneID = paneID
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.focused = focused
    }
}

public enum HerdrError: LocalizedError {
    case timeout(String)
    case api(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let method): return "Timed out waiting for \(method)."
        case .api(let message): return message
        case .badResponse(let detail): return "Bad response: \(detail)"
        }
    }
}

/// herdr-core owns terminals, status, and input on every connected machine;
/// the Herdr app owns what is shown. Core requests go through `herdr-core
/// connect` (JSON-RPC on stdin/stdout), app requests through `herdr-app`.
/// Actions re-read the target's occupant first: a guard, not an atomic
/// compare-and-act.
public enum HerdrClient {
    private static let environment = ProcessInfo.processInfo.environment
    private static let home = NSHomeDirectory() as NSString
    static let coreBinary = environment["WL_HERDR_CORE_BINARY"].flatMap { $0.isEmpty ? nil : $0 }
        ?? home.appendingPathComponent(".local/bin/herdr-core")
    static let appBinary = environment["WL_HERDR_APP_BINARY"].flatMap { $0.isEmpty ? nil : $0 }
        ?? home.appendingPathComponent(".local/bin/herdr-app")
    private static let snapshots = HerdrSnapshotLoader()

    public static func snapshot() async throws -> HerdrSnapshot {
        try await snapshots.load()
    }

    /// Herdr app order (space → tab → terminal → sub-agents), then agents the
    /// app does not show, in core order.
    public static func listAgents() async throws -> [HerdrAgent] {
        try await snapshot().agents
    }

    public static func focusedAgent() async throws -> HerdrAgent? {
        try await snapshot().agents.first(where: \.focused)
    }

    public static func focusAgent(_ target: HerdrAgentTarget) async throws {
        try await verify(target)
        try await appCommand("agent.focus", ["terminal": target.address])
    }

    /// Named keys (`enter`, `esc`, `up`, `ctrl+alt+u`), encoded by the core
    /// for the program's current keyboard mode.
    public static func sendKeys(target: HerdrAgentTarget, keys: [String]) async throws {
        try await verify(target)
        _ = try await rpc("terminal.keys", ["terminal": target.address, "keys": keys])
    }

    /// Types text without submitting it. herdr-core has no unsubmitted paste,
    /// so this presses one key per character and refuses, before typing
    /// anything, text that named keys cannot spell.
    public static func typeText(target: HerdrAgentTarget, text: String) async throws {
        let keys = try keyNames(for: text)
        try await sendKeys(target: target, keys: keys)
    }

    /// Pastes text and presses Enter. The core waits for a person's unsent
    /// draft (up to its `draft_wait`, 60 s by default) and refuses a blocked
    /// program rather than answering its dialog.
    public static func submitText(target: HerdrAgentTarget, text: String) async throws {
        try await verify(target)
        _ = try await rpc("terminal.send", ["terminal": target.address, "text": text], timeout: 75)
    }

    /// The Herdr app's shown space moves to its next tab.
    public static func cycleTabs() async throws {
        try await appCommand("tab.next", [:])
    }

    // MARK: - Text as named keys

    /// Characters herdr-core accepts as key names in the observed 0.1.20
    /// build. Shifted punctuation (`?`, `!`, `:`) has no name and is refused.
    private static let directKeys = Set(",-./;=[\\]`'")

    static func keyNames(for text: String) throws -> [String] {
        try text.map { character -> String in
            guard character.isASCII else { throw unspellable(character) }
            if character == " " { return "space" }
            if character.isLowercase || character.isNumber || directKeys.contains(character) {
                return String(character)
            }
            if character.isUppercase { return "shift+" + character.lowercased() }
            throw unspellable(character)
        }
    }

    private static func unspellable(_ character: Character) -> HerdrError {
        .api("Herdr cannot type \"\(character)\" without submitting. Use letters, digits, spaces, and , - . / ; = [ \\ ] ` ' only.")
    }

    // MARK: - Transport

    static func loadSnapshot() async throws -> HerdrSnapshot {
        async let core = rpc("terminal.list", [:])
        async let layout = appJSON(["ls"])
        async let view = appJSON(["status"])
        let terminals = try await core
        let app: (layout: [String: Any], focusedPane: String?)?
        let appError: String?
        do {
            app = (try await layout, (try await view)["focused_pane"] as? String)
            appError = nil
        } catch {
            app = nil
            appError = "Herdr app: \(error.localizedDescription)"
        }
        return try HerdrSnapshot(core: terminals, app: app?.layout, focusedPane: app?.focusedPane, appError: appError)
    }

    /// The target's address still holds the same live occupant.
    private static func verify(_ target: HerdrAgentTarget) async throws {
        let terminal = try await rpc("terminal.get", ["terminal": target.address])
        guard terminal["address"] as? String == target.address,
              (terminal["created_ms"] as? NSNumber)?.int64Value == target.createdMs,
              terminal["state"] as? String == "live" else {
            throw HerdrError.api("That Herdr terminal has ended or been replaced.")
        }
    }

    static func rpc(_ method: String, _ params: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        var request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        request.append(0x0A)
        let data = try await HerdrCommand.run(executable: coreBinary, arguments: ["connect"],
                                              input: request, timeout: timeout)
        let line = data.split(separator: 0x0A, maxSplits: 1).first ?? data[...]
        guard let envelope = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw HerdrError.badResponse("herdr-core did not return a JSON-RPC envelope.")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw HerdrError.api(error["message"] as? String ?? "herdr-core \(method) failed.")
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw HerdrError.badResponse("herdr-core \(method) has no result.")
        }
        return result
    }

    private static func appJSON(_ arguments: [String]) async throws -> [String: Any] {
        let data = try await HerdrCommand.run(executable: appBinary, arguments: arguments, timeout: 10)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HerdrError.badResponse("herdr-app \(arguments.joined(separator: " ")) did not return JSON.")
        }
        return result
    }

    /// Arguments go as one JSON object, so an address can never be read as a flag.
    private static func appCommand(_ name: String, _ arguments: [String: String]) async throws {
        let object = try JSONSerialization.data(withJSONObject: arguments)
        let result = try await appJSON(["do", name, String(decoding: object, as: UTF8.self)])
        if let error = result["error"] as? String { throw HerdrError.api(error) }
    }
}
