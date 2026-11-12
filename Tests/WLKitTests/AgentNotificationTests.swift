import Foundation
import Testing
@testable import WLKit

struct AgentNotificationTests {
    private func agent(_ state: String, address: String = "t1", created: Int64 = 1,
                       focused: Bool = false) -> HerdrAgent {
        HerdrAgent(agent: "pi", status: state, address: address, createdMs: created, focused: focused)
    }

    private func consume(_ tracker: inout AgentNotificationTracker, _ agents: [HerdrAgent], active: Bool = false) -> [AgentNotificationEvent] {
        tracker.consume(agents, terminalActive: active)
    }

    @Test func startupNewAgentsAndRepeatedPollsAreSilent() {
        var tracker = AgentNotificationTracker()
        #expect(consume(&tracker, [agent("blocked")]).isEmpty)
        #expect(consume(&tracker, [agent("blocked")]).isEmpty)
        #expect(consume(&tracker, [agent("blocked"), agent("done", address: "t2")]).isEmpty)
    }

    @Test func attentionAndCompletionAreEmittedOnce() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")])
        #expect(consume(&tracker, [agent("blocked")]).map(\.kind) == [.attention])
        #expect(consume(&tracker, [agent("blocked")]).isEmpty)
        #expect(consume(&tracker, [agent("done")]).map(\.kind) == [.finished])
        #expect(consume(&tracker, [agent("idle")]).isEmpty)
        _ = consume(&tracker, [agent("working")])
        #expect(consume(&tracker, [agent("error")]).map(\.kind) == [.attention])
    }

    @Test func focusedPaneAlertsOnlyWhenTerminalIsNotActive() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working", focused: true)], active: true)
        #expect(consume(&tracker, [agent("blocked", focused: true)], active: true).isEmpty)
        #expect(consume(&tracker, [agent("blocked", focused: true)]).isEmpty)
        _ = consume(&tracker, [agent("working", focused: true)])
        #expect(consume(&tracker, [agent("idle", focused: true)]).map(\.kind) == [.finished])
    }

    @Test func backgroundPaneStillAlertsWithTerminalActive() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")], active: true)
        #expect(consume(&tracker, [agent("blocked")], active: true).map(\.kind) == [.attention])
    }

    @Test func reconnectAndWakeRebaseline() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")])
        tracker.reset()
        #expect(consume(&tracker, [agent("done")]).isEmpty)
    }

    @Test func replacedTerminalAtTheSameAddressDoesNotInheritState() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")])
        #expect(consume(&tracker, [agent("blocked", created: 2)]).isEmpty)
        _ = consume(&tracker, [])
        #expect(consume(&tracker, [agent("blocked")]).isEmpty)
    }

    @Test func reorderingDoesNotChangeDestination() throws {
        var tracker = AgentNotificationTracker()
        let second = agent("working", address: "t2")
        _ = consume(&tracker, [agent("working"), second])
        let events = consume(&tracker, [second, agent("blocked")])
        let destination = try #require(agent("blocked").focusTarget)
        #expect(events.map(\.target) == [destination])
    }

    @Test func unknownIdleAndAgentReplacementDoNotAnnounceCompletion() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("unknown")])
        #expect(consume(&tracker, [agent("idle")]).isEmpty)
        _ = consume(&tracker, [agent("working")])
        var replacement = agent("done")
        replacement.agent = "codex"
        #expect(consume(&tracker, [replacement]).isEmpty)
    }

    @Test func sameTerminalNumberOnAnotherMachineIsAnotherAgent() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working"), agent("working", address: "rohan/t1")])
        let events = consume(&tracker, [agent("blocked"), agent("working", address: "rohan/t1")])
        #expect(events.map(\.target.address) == ["t1"])
        let finished = consume(&tracker, [agent("blocked"), agent("idle", address: "rohan/t1")])
        #expect(finished.map(\.target.address) == ["rohan/t1"])
        #expect(finished.map(\.kind) == [.finished])
    }

    @Test func missingIdentityIsNotTargetable() {
        let missing = HerdrAgent(status: "blocked", createdMs: nil)
        #expect(HerdrAgentTarget(agent: missing) == nil)
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [missing])
        var idle = missing
        idle.status = "idle"
        #expect(consume(&tracker, [idle]).isEmpty)
    }
}
