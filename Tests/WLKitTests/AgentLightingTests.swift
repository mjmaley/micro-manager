import Testing
@testable import WLKit

struct AgentLightingTests {
    func agent(_ status: String, pane: String = "p1", focused: Bool = false,
               terminal: String? = nil, kind: String = "pi") -> HerdrAgent {
        HerdrAgent(agent: kind, status: status, paneID: pane,
                   terminalID: terminal ?? "term-\(pane)", focused: focused)
    }

    func consume(_ tracker: inout AgentLightingTracker, _ agents: [HerdrAgent],
                 active: Bool = false, server: String? = "server-1") -> AgentLightingSnapshot {
        tracker.consume(agents, socketPath: "/herdr.sock", socketIdentity: server, terminalActive: active)
    }

    @Test func startupDoesNotInventUnreadIdleCompletions() {
        var tracker = AgentLightingTracker()
        let result = consume(&tracker, [agent("idle"), agent("done", pane: "p2"), agent("unknown", pane: "p3")])
        #expect(result.states == ["idle", "done", "unknown"])
    }

    @Test func backgroundIdleCompletionRemainsGreenUntilVisitedAndLeft() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working")])
        #expect(consume(&tracker, [agent("idle")]).states == ["done"])
        for _ in 0..<10 {
            #expect(consume(&tracker, [agent("idle")]).states == ["done"])
        }
        #expect(consume(&tracker, [agent("idle", focused: true)], active: true).states == ["done"])
        #expect(consume(&tracker, [agent("idle")], active: true).states == ["idle"])
    }

    @Test func activeCompletionStaysGreenWithoutATimerUntilPaneLosesFocus() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working", focused: true)], active: true)
        for _ in 0..<20 {
            #expect(consume(&tracker, [agent("idle", focused: true)], active: true).states == ["done"])
        }
        #expect(consume(&tracker, [agent("idle")], active: true).states == ["idle"])
        #expect(consume(&tracker, [agent("idle", focused: true)], active: true).states == ["idle"])
    }

    @Test func switchingToAnotherAppAcknowledgesViewedCompletion() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working", focused: true)], active: true)
        _ = consume(&tracker, [agent("idle", focused: true)], active: true)
        let background = consume(&tracker, [agent("idle", focused: true)])
        #expect(background.states == ["idle"])
        #expect(background.selectedState == "idle")
    }

    @Test func selectedBehindBrowserIsNotViewed() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working", focused: true)])
        #expect(consume(&tracker, [agent("idle", focused: true)]).states == ["done"])
        #expect(consume(&tracker, [agent("idle")]).states == ["done"])
    }

    @Test func viewingWorkingPaneDoesNotAcknowledgeLaterBackgroundResult() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working", focused: true)], active: true)
        _ = consume(&tracker, [agent("working")], active: true)
        #expect(consume(&tracker, [agent("idle")], active: true).states == ["done"])
    }

    @Test func rawDoneToIdleOnFocusDoesNotEraseGreenHold() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("done")])
        #expect(consume(&tracker, [agent("idle", focused: true)], active: true).states == ["done"])
        #expect(consume(&tracker, [agent("idle")], active: true).states == ["idle"])
    }

    @Test func repeatedDoneAfterAcknowledgementDoesNotRelightGreen() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("done", focused: true)], active: true)
        #expect(consume(&tracker, [agent("done")], active: true).states == ["idle"])
        #expect(consume(&tracker, [agent("done")], active: true).states == ["idle"])
    }

    @Test func newWorkResetsTheReadCycle() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("done", focused: true)], active: true)
        _ = consume(&tracker, [agent("idle")], active: true)
        #expect(consume(&tracker, [agent("working")]).states == ["working"])
        #expect(consume(&tracker, [agent("idle")]).states == ["done"])
    }

    @Test func explicitNewDoneIsRecognizedWithoutObservedWorking() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("idle")])
        #expect(consume(&tracker, [agent("done")]).states == ["done"])
    }

    @Test func blockedAndWorkingOverrideUnread() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("done")])
        #expect(consume(&tracker, [agent("blocked")]).states == ["blocked"])
        #expect(consume(&tracker, [agent("working")]).states == ["working"])
        #expect(consume(&tracker, [agent("idle")]).states == ["done"])
    }

    @Test func unknownIsNotCompletionButDoesNotLoseKnownBusyCycle() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working")])
        #expect(consume(&tracker, [agent("unknown")]).states == ["unknown"])
        #expect(consume(&tracker, [agent("idle")]).states == ["done"])
    }

    @Test func leavingDuringUnknownAcknowledgesOnlyThePreviouslyViewedResult() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("done", focused: true)], active: true)
        #expect(consume(&tracker, [agent("unknown")], active: true).states == ["unknown"])
        #expect(consume(&tracker, [agent("done")], active: true).states == ["idle"])
    }

    @Test func unrecognizedStatusIsNeutralRatherThanFinishedOrSeen() {
        var tracker = AgentLightingTracker()
        #expect(consume(&tracker, [agent("unexpected")]).states == ["unknown"])
    }

    @Test func ringFollowsSelectedAgentRatherThanWorstState() {
        var tracker = AgentLightingTracker()
        let agents = [agent("blocked"), agent("idle", pane: "p2", focused: true)]
        let result = consume(&tracker, agents)
        #expect(result.selectedState == "idle")
        #expect(StatusMapper.aggregate(agents) == "blocked")
        #expect(StatusMapper.zone(for: result.selectedState)?.color == 0xFFFFFF)
    }

    @Test func ringFollowsSelectedBackgroundCompletion() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working", focused: true)])
        let result = consume(&tracker, [agent("idle", focused: true)])
        #expect(result.selectedState == "done")
        #expect(StatusMapper.zone(for: result.selectedState)?.color == 0x00C853)
    }

    @Test func selectedAgentCanBeOutsideTheVisibleBank() {
        var tracker = AgentLightingTracker()
        let agents = (0..<8).map { agent($0 == 7 ? "working" : "idle", pane: "p\($0)", focused: $0 == 7) }
        let result = consume(&tracker, agents)
        #expect(result.selectedState == "working")
        #expect(result.states.prefix(6).allSatisfy { $0 == "idle" })
    }

    @Test func noSelectedAgentMeansDarkRing() {
        var tracker = AgentLightingTracker()
        #expect(consume(&tracker, [agent("working")]).selectedState == nil)
        #expect(consume(&tracker, []).selectedState == nil)
    }

    @Test func historyFollowsPaneNotSlotOrdering() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working", pane: "a"), agent("idle", pane: "b")])
        let result = consume(&tracker, [agent("idle", pane: "b"), agent("idle", pane: "a")])
        #expect(result.states == ["idle", "done"])
    }

    @Test func serverTerminalAndAgentReplacementCannotInheritUnreadHistory() {
        for replacement in ["server", "terminal", "kind"] {
            var tracker = AgentLightingTracker()
            _ = consume(&tracker, [agent("working")])
            let next = agent("idle", terminal: replacement == "terminal" ? "new-term" : nil,
                             kind: replacement == "kind" ? "codex" : "pi")
            #expect(consume(&tracker, [next], server: replacement == "server" ? "server-2" : "server-1").states == ["idle"])
        }
    }

    @Test func closedPanesAndResetLoseOldHistory() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working")])
        _ = consume(&tracker, [])
        #expect(consume(&tracker, [agent("idle")]).states == ["idle"])
        _ = consume(&tracker, [agent("working")])
        tracker.reset()
        #expect(consume(&tracker, [agent("idle")]).states == ["idle"])
    }

    @Test func missingIdentityFallsBackWithoutFabricatedReadState() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working")])
        #expect(consume(&tracker, [agent("idle")], server: nil).states == ["idle"])
        #expect(consume(&tracker, [agent("done")], active: true, server: nil).states == ["done"])
    }

    @Test func sleepAcknowledgesOnlyPreviouslyViewedResults() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("done", focused: true), agent("done", pane: "p2")], active: true)
        tracker.endViewing()
        let result = consume(&tracker, [agent("done", focused: true), agent("done", pane: "p2")], active: true)
        #expect(result.states == ["idle", "done"])
    }

    @Test func renderingOverridesDoNotChangeRawAgentStatus() {
        var tracker = AgentLightingTracker()
        _ = consume(&tracker, [agent("working")])
        let agents = [agent("idle")]
        let lights = consume(&tracker, agents)
        let threads = StatusMapper.threads(for: agents, agentKeyIDs: [0, 1], lightingStates: lights.states)
        #expect(threads[0].color == 0x00C853)
        #expect(threads[1].effect == .off)
        #expect(agents[0].status == "idle")
    }

    @Test func defaultPaletteAndEffectsMatchTheNewMeaning() {
        let config = BridgeConfig()
        #expect(config.color(for: "done") == 0x00C853)
        #expect(config.color(for: "idle") == 0xFFFFFF)
        #expect(config.color(for: "unknown") == 0x90A4AE)
        #expect(config.color(for: "working") == 0xFFA000)
        #expect(config.color(for: "blocked") == 0xFF2D2D)
        #expect(config.effect(for: "blocked") == .breath)
        #expect(config.effect(for: "working") == .solid)
    }
}
