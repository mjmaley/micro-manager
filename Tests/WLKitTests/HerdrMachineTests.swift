import Foundation
import Testing
@testable import WLKit

/// Shapes recorded from herdr-core 0.1.20 `terminal.list` and herdr-app 0.1.15 `ls`.
struct HerdrMachineTests {
    private func terminal(_ address: String, state: String? = "working", app: String = "omp",
                          turn: Int = 1, seen: String? = nil, created: Int64 = 100,
                          live: Bool = true) -> [String: Any] {
        var terminal: [String: Any] = [
            "address": address, "created_ms": created, "state": live ? "live" : "finished",
            "turn": turn, "cwd": "/start/\(address)",
            "foreground": ["name": app, "cwd": "/work/\(address)"],
            "labels": seen.map { ["herdr.seen": $0] } ?? [:],
        ]
        terminal["status"] = state.map { ["app": app, "state": $0] } ?? NSNull()
        return terminal
    }

    private func core(_ terminals: [[String: Any]], machines: [[String: Any]] = []) -> [String: Any] {
        ["terminals": terminals, "machines": machines, "hidden_finished": 0]
    }

    private func app(_ spaces: [[[String: Any]]]) -> [String: Any] {
        ["spaces": spaces.map { tabs in
            ["id": "s", "machine": NSNull(), "tabs": tabs.map { shown in ["id": "tb", "terminals": [shown]] }]
        }]
    }

    private func shown(_ address: String, pane: String?, sub: [[String: Any]] = []) -> [String: Any] {
        ["terminal": address, "pane": pane as Any, "sub_agents": sub]
    }

    @Test func onlyLiveReportingProgramsAreAgents() throws {
        let snapshot = try HerdrSnapshot(core: core([
            terminal("t1"), terminal("t2", state: nil, app: "zsh"), terminal("t3", live: false),
        ]), app: nil, focusedPane: nil, appError: nil)
        #expect(snapshot.agents.map(\.address) == ["t1"])
        #expect(snapshot.agents[0].workingDirectory == "/work/t1")
    }

    @Test func doneReadsIdleOnlyOnceTheAppHasSeenThatTurn() throws {
        let snapshot = try HerdrSnapshot(core: core([
            terminal("t1", state: "done", turn: 3, seen: "2"),
            terminal("t2", state: "done", turn: 3, seen: "3"),
            terminal("t3", state: "done", turn: 3),
            terminal("t4", state: "error"),
            terminal("t5", state: "thinking"),
        ]), app: nil, focusedPane: nil, appError: nil)
        #expect(snapshot.agents.map(\.status) == ["done", "idle", "done", "error", "unknown"])
    }

    @Test func appOrderAndFocusDecideKeysThenUnshownAgentsFollowInCoreOrder() throws {
        let snapshot = try HerdrSnapshot(
            core: core([terminal("t1"), terminal("t2"), terminal("rohan/t1"), terminal("t9")]),
            app: app([[shown("rohan/t1", pane: "p-remote", sub: [shown("t2", pane: nil)])],
                      [shown("t1", pane: "p-local")]]),
            focusedPane: "p-local", appError: nil
        )
        #expect(snapshot.agents.map(\.address) == ["rohan/t1", "t2", "t1", "t9"])
        #expect(snapshot.agents.filter(\.focused).map(\.address) == ["t1"])
        #expect(snapshot.agents.map(\.paneID) == ["p-remote", nil, "p-local", nil])
        #expect(snapshot.agents[0].machineName == "rohan")
        #expect(!snapshot.agents[0].isLocalMachine)
        #expect(snapshot.agents[2].isLocalMachine)
    }

    @Test func paneWithoutAnAgentFocusesNothing() throws {
        let snapshot = try HerdrSnapshot(
            core: core([terminal("t1"), terminal("t2", state: nil, app: "zsh")]),
            app: app([[shown("t1", pane: "p1")], [shown("t2", pane: "p2")]]),
            focusedPane: "p2", appError: nil
        )
        #expect(snapshot.agents.filter(\.focused).isEmpty)
    }

    @Test func missingAppKeepsAgentsButNothingIsFocused() throws {
        let snapshot = try HerdrSnapshot(core: core([terminal("t2"), terminal("t1")]), app: nil,
                                         focusedPane: nil, appError: "Herdr app: no Herdr window")
        #expect(snapshot.agents.map(\.address) == ["t2", "t1"])
        #expect(snapshot.agents.allSatisfy { !$0.focused && $0.paneID == nil })
        #expect(snapshot.warning == "Herdr app: no Herdr window")
    }

    @Test func disconnectedMachineIsReportedNotHidden() throws {
        let snapshot = try HerdrSnapshot(core: core([terminal("t1")], machines: [
            ["name": "rohan", "state": "connected"], ["name": "vps", "state": "needs_login"],
        ]), app: nil, focusedPane: nil, appError: nil)
        #expect(snapshot.warning == "vps is needs login; its agents are not shown.")
    }

    @Test func malformedOrAmbiguousCoreListsAreRejected() {
        #expect(throws: HerdrError.self) {
            try HerdrSnapshot(core: [:], app: nil, focusedPane: nil, appError: nil)
        }
        #expect(throws: HerdrError.self) {
            try HerdrSnapshot(core: core([terminal("t1"), terminal("t1")]), app: nil, focusedPane: nil, appError: nil)
        }
    }

    @Test func typedTextUsesOnlyKeysHerdrCanSpell() throws {
        #expect(try HerdrClient.keyNames(for: "Fix x/y-1, ok") ==
                ["shift+f", "i", "x", "space", "x", "/", "y", "-", "1", ",", "space", "o", "k"])
        for text in ["why?", "a\nb", "café", "tab\there"] {
            #expect(throws: HerdrError.self) { try HerdrClient.keyNames(for: text) }
        }
    }
}
