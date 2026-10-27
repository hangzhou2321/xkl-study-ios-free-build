import Foundation
import XCTest
import CPocket
@testable import StudyClientModel

final class HandbookDiagramTests: XCTestCase {
    // Independent pre-diagram canonical JSON and SHA-256 values.
    private let legacyJSON = #"{"cards":[{"answerSummary":"Synthetic answer","blocks":[],"chapterID":"chapter","examples":[],"id":"synthetic-card","prompt":"Recall a synthetic fact","sourceGroupIDs":["synthetic-group"],"sourceNotes":[],"sourcePages":[1],"title":"Synthetic card","topicNumber":1}],"chapters":[{"id":"chapter","title":"Synthetic chapter"}],"format":"xkl-handbook-cards-v1","id":"synthetic-book","revision":"1.0","source":{"fileName":"original.pdf","includedPages":[1,2],"pdfPageCount":2,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Synthetic original source"},"subject":"computer","title":"Synthetic book"}"#
    private func pack(_ block: [String: Any]) throws -> HandbookCardPackage {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any])
        var cards = try XCTUnwrap(object["cards"] as? [[String: Any]])
        cards[0]["blocks"] = [block]; object["cards"] = cards
        return try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
    }
    private func diagram(_ mode: String, _ items: [String], collapsed: Bool = true) -> [String: Any] {
        ["title": "Synthetic diagram", "kind": "diagram", "text": mode, "items": items, "collapsed": collapsed]
    }
    func testLegacyHashesAndEncodingRemainUnchanged() throws {
        let old = try HandbookCardPackage.load(Data(legacyJSON.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(old), Data(legacyJSON.utf8))
        XCTAssertEqual(old.cards[0].definitionID, "d15eeee61af5117bf546fb1fb292c05e884fba142a53d0adcaefb7d7929a961b")
        XCTAssertEqual(old.hash, "fc159af9cf87655672fa94eb447b06c9c24e45574b4993d068ed3efdc2e10084")
    }
    func testDiagramModeCountsContentAndCollapsedValidation() throws {
        XCTAssertNoThrow(try pack(diagram("branch", ["root", "left", "right"])))
        for count in 2...6 { XCTAssertNoThrow(try pack(diagram("flow", Array(repeating: "node", count: count)))) }
        XCTAssertNoThrow(try pack(diagram("flow", [String(repeating: "字", count: 100), "node"])))
        let invalid: [[String: Any]] = [diagram("branch", []), diagram("branch", ["root", "left"]),
            diagram("branch", ["root", "left", "right", "extra"]), diagram("flow", ["node"]),
            diagram("flow", Array(repeating: "node", count: 7)), diagram("other", ["a", "b"]),
            diagram("flow", [" ", "b"]), diagram("flow", [String(repeating: "字", count: 101), "b"]),
            diagram("flow", ["a", "b"], collapsed: false),
            ["title": "bad", "kind": "diagram", "items": ["a", "b"], "collapsed": true],
            ["title": "bad", "kind": "diagram", "text": "flow", "items": ["a", "b"], "rows": [["unused"]], "collapsed": true]]
        for value in invalid { XCTAssertThrowsError(try pack(value), "Unexpectedly accepted: \(value)") }
    }
    @MainActor func testRevealDoesNotCreateRatingOrChangeSchedule() async throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let engine = try HandbookWordEngine(package: pack(diagram("branch", ["root", "left", "right"])), now: now)
        try engine.start(now: now)
        let token = try XCTUnwrap(engine.presentation?.id), before = engine.record
        try engine.reveal(token: token, now: now)
        XCTAssertTrue(engine.record.attempts.isEmpty)
        func packedCard(_ snapshot: Data) throws -> UInt32 {
            let pointer = try XCTUnwrap(snapshot.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
            defer { xkl_engine_free(pointer) }
            return xkl_engine_card(pointer, 0)
        }
        XCTAssertEqual(try packedCard(engine.record.snapshot), try packedCard(before.snapshot))
        XCTAssertEqual(engine.record.attempts, before.attempts)
        XCTAssertEqual(engine.presentation?.revealed, true)
        // Expansion is local SwiftUI state; native preview checks the complete record before and after toggling.
    }
}
