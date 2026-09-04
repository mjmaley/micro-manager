import XCTest
@testable import WLKit

final class AgentNotificationTests: XCTestCase {
    private func agent(_ state: String, pane: String = "p1", terminal: String = "t1", focused: Bool = false) -> HerdrAgent {
        HerdrAgent(agent: "pi", status: state, paneID: pane, terminalID: terminal, focused: focused)
    }

    private func consume(_ tracker: inout AgentNotificationTracker, _ agents: [HerdrAgent], identity: String = "server1", active: Bool = false) -> [AgentNotificationEvent] {
        tracker.consume(agents, socketPath: "/tmp/herdr.sock", socketIdentity: identity, terminalActive: active)
    }

    func testStartupNewAgentsAndRepeatedPollsAreSilent() {
        var tracker = AgentNotificationTracker()
        XCTAssertTrue(consume(&tracker, [agent("blocked")]).isEmpty)
        XCTAssertTrue(consume(&tracker, [agent("blocked")]).isEmpty)
        XCTAssertTrue(consume(&tracker, [agent("blocked"), agent("done", pane: "p2", terminal: "t2")]).isEmpty)
    }

    func testAttentionAndCompletionAreEmittedOnce() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")])
        XCTAssertEqual(consume(&tracker, [agent("blocked")]).map(\.kind), [.attention])
        XCTAssertTrue(consume(&tracker, [agent("blocked")]).isEmpty)
        XCTAssertEqual(consume(&tracker, [agent("done")]).map(\.kind), [.finished])
        XCTAssertTrue(consume(&tracker, [agent("idle")]).isEmpty)
    }

    func testFocusedPaneAlertsOnlyWhenTerminalIsNotActive() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working", focused: true)], active: true)
        XCTAssertTrue(consume(&tracker, [agent("blocked", focused: true)], active: true).isEmpty)
        XCTAssertTrue(consume(&tracker, [agent("blocked", focused: true)], active: false).isEmpty)
        _ = consume(&tracker, [agent("working", focused: true)])
        XCTAssertEqual(consume(&tracker, [agent("idle", focused: true)]).map(\.kind), [.finished])
    }

    func testBackgroundPaneStillAlertsWithTerminalActive() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")], active: true)
        XCTAssertEqual(consume(&tracker, [agent("blocked")], active: true).map(\.kind), [.attention])
    }

    func testReconnectWakeAndServerReplacementRebaseline() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")])
        tracker.reset()
        XCTAssertTrue(consume(&tracker, [agent("done")]).isEmpty)
        _ = consume(&tracker, [agent("working")])
        XCTAssertTrue(consume(&tracker, [agent("blocked")], identity: "server2").isEmpty)
    }

    func testRemovedAndReusedPaneDoesNotInheritState() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("working")])
        XCTAssertTrue(consume(&tracker, [agent("blocked", terminal: "replacement")]).isEmpty)
        _ = consume(&tracker, [])
        XCTAssertTrue(consume(&tracker, [agent("blocked")]).isEmpty)
    }

    func testReorderingDoesNotChangeDestination() {
        var tracker = AgentNotificationTracker()
        let second = agent("working", pane: "p2", terminal: "t2")
        _ = consume(&tracker, [agent("working"), second])
        let events = consume(&tracker, [second, agent("blocked")])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.target.paneID, "p1")
        XCTAssertEqual(events.first?.target.terminalID, "t1")
    }

    func testUnknownIdleAndAgentReplacementDoNotAnnounceCompletion() {
        var tracker = AgentNotificationTracker()
        _ = consume(&tracker, [agent("unknown")])
        XCTAssertTrue(consume(&tracker, [agent("idle")]).isEmpty)
        _ = consume(&tracker, [agent("working")])
        var replacement = agent("done")
        replacement.agent = "codex"
        XCTAssertTrue(consume(&tracker, [replacement]).isEmpty)
    }

    func testMissingIdentityIsNotTargetable() {
        let missing = HerdrAgent(status: "blocked", paneID: "p1")
        XCTAssertNil(AgentNotificationTarget(agent: missing, socketPath: "/tmp/h.sock", socketIdentity: "server"))
        XCTAssertNil(AgentNotificationTarget.socketIdentity(at: "/no-such-herdr-socket"))
    }

    func testDestinationRoundTripAndStalePaneValidation() throws {
        let target = try XCTUnwrap(AgentNotificationTarget(agent: agent("working"), socketPath: "/tmp/herdr.sock", socketIdentity: "server1"))
        let decoded = try JSONDecoder().decode(AgentNotificationTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded, target)
        XCTAssertTrue(target.matches(agent("done")))
        XCTAssertFalse(target.matches(agent("done", terminal: "replacement")))
        XCTAssertFalse(target.matches(agent("done", pane: "replacement")))
        let other = try XCTUnwrap(AgentNotificationTarget(agent: agent("working"), socketPath: "/tmp/other.sock", socketIdentity: "server1"))
        XCTAssertNotEqual(target.identifier, other.identifier)
    }
}
