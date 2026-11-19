import Foundation
import XCTest
@testable import StudyClientModel

final class CompactComputerRangeTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_793_000_000)
    private func fixture(_ revision: String = "1.35.10") -> HandbookCardPackage {
        let src = HandbookCardPackage.Source(title: "Synthetic", fileName: "test.pdf",
            sha256: String(repeating: "b", count: 64), pdfPageCount: 1, includedPages: [1])
        let ids = ["sf2-computer-duplicate", "main", "sf2-computer-unique"]
        var p = HandbookCardPackage(id: "synthetic-range", subject: .computer, title: "Synthetic",
            revision: revision, source: src, chapters: [.init(id: "a", title: "Synthetic")],
            cards: ids.map {
                .init(id: $0, sourceGroupIDs: [$0], topicNumber: 1, title: "Synthetic", prompt: "Recall?",
                    answerSummary: "Synthetic", blocks: [], sourcePages: [1], examples: [],
                    sourceNotes: [], chapterID: "a", sourceReferences: $0.hasPrefix("sf2-") ?
                        [.init(sourceID: "BAODIAN2", page: 1)] : nil)
            })
        p.additionalSources = [.init(id: "BAODIAN2", source: src)]
        return p
    }
    private func compact(_ p: HandbookCardPackage) -> HandbookCardPackage {
        var v = fixture("1.35.11")
        v.format = "xkl-handbook-cards-v6-computer-compact"
        v.requiredBasePackageHash = p.hash

        v.mainCardIDs = ["main", "sf2-computer-unique"]
        return v
    }

    @MainActor func testParkRatedDuplicateThenRestoreItsMemoryWithoutNewGrade() async throws {
        let p = fixture(), next = compact(p)
        let e = try HandbookWordEngine(package: p, now: day)
        try e.start(now: day)
        let shown = try XCTUnwrap(e.presentation)
        let duplicate = "sf2-computer-duplicate"
        XCTAssertEqual(shown.cardID, duplicate)
        try e.reveal(token: shown.id, now: day)
        try e.rate(remembered: false, token: shown.id, now: day)
        let history = e.record.attempts
        XCTAssertEqual(history.count, 1)
        let before = try e.storageForTest()
        let alias = e.record.cardIDs[try XCTUnwrap(e.state.originalCardIDs.firstIndex(of: duplicate))]
        let remembered = try XCTUnwrap(before.packedCard(id: alias))
        try e.updatePackage(next, now: day)
        XCTAssertEqual(e.record.attempts, history)
        XCTAssertFalse(e.isInMainScope(duplicate))
        XCTAssertEqual(e.record.parkedCards?[alias]?.packed, remembered)
        XCTAssertEqual(e.firstPassRemaining(includingShortBook: true), 2)
        try e.setCompactComputerRange(includeAll: true, now: day)
        let reopened = try HandbookWordEngine(state: e.state)
        XCTAssertTrue(reopened.compactComputerRange?.includesAll == true)
        XCTAssertTrue(reopened.isInMainScope(duplicate)); XCTAssertFalse(reopened.isFirstPass(duplicate))
        XCTAssertEqual(try reopened.storageForTest().packedCard(id: alias), remembered)
        XCTAssertEqual(reopened.record.attempts, history)
        try reopened.setCompactComputerRange(includeAll: false, now: day)
        XCTAssertFalse(reopened.isInMainScope(duplicate))
        XCTAssertEqual(reopened.record.attempts, history)
    }

    @MainActor func testRemovingAnOnScreenDuplicatePreservesCheckpointWithoutGrading() async throws {
        let p = fixture(), e = try HandbookWordEngine(package: p, now: day)
        try e.start(now: day);let shown = try XCTUnwrap(e.presentation)
        XCTAssertEqual(shown.cardID,"sf2-computer-duplicate")
        try e.reveal(token: shown.id, now: day)
        let before = try XCTUnwrap(e.record.presentation)
        try e.updatePackage(compact(p), now: day)
        XCTAssertEqual(e.record.parkedCards?[before.cardID]?.presentation, before)
        XCTAssertNotEqual(e.presentation?.id,shown.id)
        XCTAssertTrue(e.record.attempts.isEmpty)
        let resumed = try HandbookWordEngine(state:e.state)
        try resumed.start(now:day)
        XCTAssertEqual(resumed.stats(on:day).total,2)
        XCTAssertNotEqual(resumed.presentation?.cardID,"sf2-computer-duplicate")
    }
}
// Inspect the existing durable packed state through the production decoder; no test-only model API.
private extension HandbookWordEngine {
    @MainActor func storageForTest() throws -> ProfessionalRecallEngine {
        let ids = record.cardIDs
        let deck = RecallDeck(subject: .computer, bankID: ConceptSubject.computer.bankID,
                              cards: ids.enumerated().map { i, id in
            .init(conceptID: "handbook", conceptTitle: "Handbook slot",
                  card: .init(id:id,prompt:"slot \(i)",answer:"slot \(i)"))
        })
        return try ProfessionalRecallEngine(deck:deck, record:record)
    }
}
