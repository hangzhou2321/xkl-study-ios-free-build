import Foundation
import XCTest
@testable import StudyClientModel

final class HandbookSourceScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func package() -> HandbookCardPackage {
        .init(id: "synthetic-source-scope", subject: .power, title: "Synthetic", revision: "1.0",
              source: .init(title: "Synthetic 宝典", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64),
                            pdfPageCount: 2, includedPages: [1]),
              chapters: [.init(id: "chapter", title: "Synthetic")], cards: (0..<3).map {
                  .init(id: "old-\($0)", sourceGroupIDs: ["group-\($0)"], topicNumber: 1,
                        title: "Title \($0)", prompt: "Recall", answerSummary: "Answer \($0)",
                        blocks: [], sourcePages: [1], examples: [], sourceNotes: [], chapterID: "chapter")
              })
    }

    private func scopePackage() throws -> HandbookCardPackage {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(package())) as! [String: Any]
        object["revision"] = "1.1"
        var cards = object["cards"] as! [[String: Any]]
        var added = cards[0]; added["id"] = "new-0"; added["sourceGroupIDs"] = ["new-group"]
        cards.append(added); object["cards"] = cards
        object["mainCardIDs"] = ["old-0", "new-0"]
        return try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
    }

    @MainActor func testScopeKeepsOldAttemptsAndIDsAcrossReimportAndRestart() async throws {
        let engine = try HandbookWordEngine(package: package(), now: now)
        try engine.start(now: now)
        let shown = try XCTUnwrap(engine.presentation)
        try engine.reveal(token: shown.id, now: now)
        try engine.rate(remembered: true, token: shown.id, now: now)
        let before = engine.state
        try engine.updatePackage(scopePackage(), now: now)
        XCTAssertEqual(Array(engine.state.originalCardIDs.prefix(3)), before.originalCardIDs)
        XCTAssertEqual(Array(engine.record.attempts.prefix(before.word.attempts.count)), before.word.attempts)
        XCTAssertEqual(engine.stats(on: now).total, 2)
        XCTAssertTrue(engine.isInMainScope("old-0"))
        XCTAssertFalse(engine.isInMainScope("old-1"))
        XCTAssertTrue(engine.isInMainScope("new-0"))
        let after = engine.state
        try engine.updatePackage(scopePackage(), now: now)
        XCTAssertEqual(engine.state, after)
        let restored = try HandbookWordEngine(state: engine.state)
        XCTAssertEqual(restored.state, after)
        XCTAssertEqual(restored.stats(on: now).total, 2)
    }

    @MainActor func testManualRequeueDoesNotInventAnswersAndSurvivesRestart() async throws {
        let engine = try HandbookWordEngine(package: package(), now: now)
        try engine.start(now: now)
        let first = try XCTUnwrap(engine.presentation)
        let id = try XCTUnwrap(engine.currentCard?.id)
        try engine.reveal(token: first.id, now: now)
        try engine.rate(remembered: true, token: first.id, now: now)
        let attempts = engine.record.attempts
        let head = engine.presentation
        XCTAssertTrue(try engine.requeue(cardID: id, now: now))
        XCTAssertEqual(engine.record.attempts, attempts)
        XCTAssertEqual(engine.presentation, head)
        XCTAssertFalse(try engine.requeue(cardID: id, now: now))
        let restored = try HandbookWordEngine(state: engine.state)
        XCTAssertEqual(restored.record.attempts, attempts)
        XCTAssertEqual(restored.presentation, head)
        for _ in 0..<15 {
            if restored.currentCard?.id == id { break }
            if let p = restored.presentation {
                try restored.reveal(token: p.id, now: now)
                try restored.rate(remembered: true, token: p.id, now: now)
            } else { try restored.start(now: now) }
        }
        XCTAssertEqual(restored.currentCard?.id, id)
        let resumed = try XCTUnwrap(restored.presentation)
        try restored.reveal(token: resumed.id, now: now)
        try restored.rate(remembered: false, token: resumed.id, now: now)
        XCTAssertEqual(restored.record.attempts.filter { $0.cardID == restored.record.cardIDs[0] }.count, 2)
        _ = try HandbookWordEngine(state: restored.state)
    }

    func testSourceColourOverlapsPersonalColourAndHonoursMask() {
        let text = "甲乙丙丁", hash = HandbookHighlightState.hash(text)
        func span(_ location: Int, _ length: Int) -> HandbookHighlightSpan {
            .init(cardID: "card", fieldID: "field", textSHA256: hash, location: location, length: length)
        }
        let state = HandbookHighlightState(subject: .power, spans: [span(1, 1)])
        let runs = state.runs(cardID: "card", fieldID: "field", text: text,
                              sourceSpans: [span(2, 1)], sourceYellowSpans: [span(1, 2)])
        XCTAssertEqual(runs, [.init(text: "甲", red: false), .init(text: "乙丙", red: true, yellow: true),
                              .init(text: "丁", red: false)])
        let visible = state.runs(cardID: "card", fieldID: "field", text: text, visible: NSRange(location: 0, length: 2),
                                 sourceSpans: [span(2, 1)], sourceYellowSpans: [span(1, 2)])
        XCTAssertEqual(visible.map(\.text).joined(), "甲乙")
        XCTAssertEqual(state.spans, [span(1, 1)])
    }
}
