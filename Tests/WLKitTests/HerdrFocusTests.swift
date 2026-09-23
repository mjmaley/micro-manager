import Foundation
import Testing
@testable import WLKit

struct HerdrFocusTests {
    @Test func visibleNavigationUsesPaneFocusAndPaneID() async throws {
        var calls = 0
        try await HerdrClient.focusAgent("w6:p3", send: { method, params in
            calls += 1
            #expect(method == "pane.focus")
            #expect(params.count == 1)
            #expect(params["pane_id"] as? String == "w6:p3")
            #expect(params["target"] == nil)
            return ["type": "pane_info", "pane": ["pane_id": "w6:p3", "focused": true]]
        })
        #expect(calls == 1)
    }

    @Test func agentIdentityUsesPaneNotTerminalOrTab() {
        let agent = HerdrAgent(status: "idle", paneID: "w6:p3", tabID: "w6:t3", terminalID: "term_123")
        #expect(agent.focusTarget == "w6:p3")
    }

    @Test func missingOrBlankPaneDoesNotFallBackToTerminal() {
        for pane: String? in [nil, "", "  "] {
            let agent = HerdrAgent(status: "idle", paneID: pane, terminalID: "term_123")
            #expect(agent.focusTarget == nil)
        }
    }

    @Test func blankTargetNeverSendsARequest() async {
        var sent = false
        do {
            try await HerdrClient.focusAgent(" ", send: { _, _ in sent = true; return [:] })
            Issue.record("Expected a missing-pane error")
        } catch {}
        #expect(!sent)
    }

    @Test func serverFailureIsNotRetriedWithAgentFocusOrKeys() async {
        var calls = 0
        do {
            try await HerdrClient.focusAgent("w6:p3", send: { _, _ in
                calls += 1
                throw HerdrError.api("pane not found")
            })
            Issue.record("Expected the server error")
        } catch {
            #expect(error.localizedDescription == "pane not found")
        }
        #expect(calls == 1)
    }

    @Test func missingOrWrongAcknowledgementCannotReportSuccess() async {
        let replies: [[String: Any]] = [[:], ["pane": ["pane_id": "w2:p1"]], ["agent": ["pane_id": "w6:p3"]]]
        for reply in replies {
            do {
                try await HerdrClient.focusAgent("w6:p3", send: { _, _ in reply })
                Issue.record("Expected a bad-response error")
            } catch {
                #expect(error.localizedDescription.contains("did not acknowledge"))
            }
        }
    }
}
