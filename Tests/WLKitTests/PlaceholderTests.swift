import XCTest
@testable import WLKit

final class PlaceholderTests: XCTestCase {
    func testPadGeometry() {
        XCTAssertEqual(Pad.rows.flatMap { $0 }.count, Pad.keyCount)
        // Reading order: the top row is wired right to left.
        XCTAssertEqual(Pad.agentKeyIDs, [1, 0, 2, 3, 4, 5])
        XCTAssertEqual(Pad.displayRows.flatMap { $0 }.sorted(), Pad.rows.flatMap { $0 }.sorted())
        XCTAssertEqual(Pad.codexMicro.agentKeyIDs, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(Pad.codexMicro.herdrLayerNumber, 2)
        XCTAssertEqual(Pad.configuration(productID: 0x8360, product: "Codex Micro"), Pad.codexMicro)
    }
}
