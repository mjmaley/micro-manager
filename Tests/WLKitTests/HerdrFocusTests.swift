import Foundation
import Testing
@testable import WLKit

struct HerdrFocusTests {
    private func agent(address: String = "rohan/t3", created: Int64? = 1_793_937_861_286) -> HerdrAgent {
        HerdrAgent(status: "idle", address: address, createdMs: created)
    }

    @Test func missingIdentityNeverBecomesADestination() {
        #expect(agent(created: nil).focusTarget == nil)
        for address in ["", " ", "t1 ", "rohan/\nt1"] {
            #expect(agent(address: address).focusTarget == nil)
        }
    }

    @Test func retainedNotificationCannotMoveToAnotherOccupant() throws {
        let target = try #require(agent().focusTarget)
        let saved = try JSONEncoder().encode(target)
        let retained = try JSONDecoder().decode(HerdrAgentTarget.self, from: saved)
        #expect(retained.matches(agent()))
        for replacement in [agent(created: 1_793_937_861_287), agent(address: "t3"), agent(address: "other/t3")] {
            #expect(!retained.matches(replacement))
            #expect(retained.identifier != replacement.focusTarget?.identifier)
        }
    }

    @Test func forkEraNotificationCannotBeDecodedAsACoreTarget() throws {
        let old = try JSONSerialization.data(withJSONObject: [
            "clientID": "c", "machineID": "local", "bootID": "b", "paneID": "w6:p3", "terminalID": "term",
        ])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HerdrAgentTarget.self, from: old) }
    }

    @Test func statusAndPlacementChangesKeepTheSameOccupant() throws {
        let before = agent()
        var after = before
        after.status = "working"
        after.paneID = "p-new"
        after.focused = true
        #expect(try #require(before.focusTarget).matches(after))
    }
}
