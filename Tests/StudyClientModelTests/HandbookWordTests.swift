import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

final class HandbookWordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private func package(_ n: Int = 3) -> HandbookCardPackage {
        .init(id: "synthetic-handbook-word", subject: .computer, title: "Synthetic", revision: "1.0",
              source: .init(title: "Synthetic", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64), pdfPageCount: 2, includedPages: [1]),
              chapters: [.init(id: "chapter", title: "Synthetic")], cards: (0..<n).map {
                  .init(id: "original-id-\($0)", sourceGroupIDs: ["group-\($0)"], topicNumber: 1, title: "Synthetic \($0)", prompt: "Recall",
                        answerSummary: "Source;value", blocks: [], sourcePages: [1], examples: [], sourceNotes: [], chapterID: "chapter")
              })
    }
    @MainActor private func english(_ n: Int) throws -> PocketEngine {
        var stream = UUID().uuid
        let values = [UInt32](repeating: 0, count: n)
        let pointer = withUnsafeBytes(of: &stream) { bytes in values.withUnsafeBufferPointer {
            xkl_engine_import_cards(UInt32(n), $0.baseAddress, UInt32(try! ConceptCalendar.studyDay(now)), UInt32.max,
                                    bytes.bindMemory(to: UInt8.self).baseAddress)
        } }!
        defer { xkl_engine_free(pointer) }
        var data = Data(count: xkl_engine_snapshot_size(pointer))
        _ = data.withUnsafeMutableBytes { xkl_engine_snapshot(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        return try PocketEngine(snapshot: data)
    }
    private func cards(_ data: Data, _ count: Int) -> [UInt32] {
        let p = data.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }!
        defer { xkl_engine_free(p) };return (0..<count).map { xkl_engine_card(p, UInt32($0)) }
    }
    @MainActor func testExactEnglishAnswerPathRepeatsLevelsAndDueDays() async throws {
        let book = try HandbookWordEngine(package: package(), now: now), direct = try english(3)
        let day = UInt32(try ConceptCalendar.studyDay(now))
        try book.start(now: now);try direct.start(day: day)
        var policy = StudyAnalysisSettings(streamID: try direct.streamID, nextSequence: 1, now: now)
        var count = 0, stages: [UInt32] = []
        while let shown = book.presentation {
            let expected = try direct.info
            XCTAssertEqual(book.currentCard?.id, "original-id-\(expected.word)")
            stages.append(expected.stage)
            try book.reveal(token: shown.id, now: now);try direct.reveal()
            let remembered = count != 0
            try book.rate(remembered: remembered, token: shown.id, now: now)
            if let decision = try direct.answer(remembered ? 0 : 1, policy: policy) { policy.reductions.append(decision) }
            XCTAssertEqual(cards(book.record.snapshot, 3), cards(try direct.snapshot(), 3))
            XCTAssertEqual(try direct.info.has_task != 0, book.presentation != nil)
            count += 1;XCTAssertLessThan(count, 40)
            if count >= 40 { break }
        }
        XCTAssertTrue(Set(1...7).isSubset(of: Set(stages)))
        XCTAssertEqual(book.record.attempts.count, count)
        XCTAssertTrue(book.record.migration.sourceRecords.isEmpty)
        XCTAssertNotNil(book.nextDueAt)
        let next = now.addingTimeInterval(86_400)
        try book.start(now: next);try direct.start(day: UInt32(ConceptCalendar.studyDay(next)))
        XCTAssertEqual(book.currentCard?.id, "original-id-\(try direct.info.word)")
        XCTAssertEqual(cards(book.record.snapshot, 3), cards(try direct.snapshot(), 3))
    }
    @MainActor func testOriginalFirstKnownGraduationAndNoRevealGrade() async throws {
        let book = try HandbookWordEngine(package: package(1), now: now)
        try book.start(now: now);let token = try XCTUnwrap(book.presentation?.id)
        try book.reveal(token: token, now: now);XCTAssertTrue(book.record.attempts.isEmpty)
        try book.rate(remembered: true, token: token, now: now)
        XCTAssertNil(book.presentation);XCTAssertNil(book.nextDueAt)
        let before = book.state;try book.rate(remembered: false, token: token, now: now)
        XCTAssertEqual(book.state, before)
    }
    @MainActor func testResumeAcrossDaysAndContentUpdateKeepOriginalIDsAndFrozenFace() async throws {
        let original = package(),book = try HandbookWordEngine(package: original, now: now)
        try book.start(now: now);let token = try XCTUnwrap(book.presentation?.id);try book.reveal(token: token, now: now)
        let restored = try HandbookWordEngine(state: JSONDecoder().decode(HandbookWordState.self, from: JSONEncoder().encode(book.state)))
        try restored.start(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(restored.presentation?.id, token);XCTAssertEqual(restored.presentation?.revealed, true)
        let frozen = restored.currentCard, before = restored.record
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object["revision"] = "1.1";var rows = object["cards"] as! [[String: Any]];rows[0]["answerSummary"] = "Updated source";object["cards"] = rows
        let updated = try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
        try restored.updatePackage(updated, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(restored.record, before);XCTAssertEqual(restored.currentCard, frozen)
        XCTAssertEqual(restored.state.originalCardIDs, original.cards.map(\.id))
        XCTAssertEqual(restored.package.cards[0].answerSummary, "Updated source")
    }
    #if canImport(Combine)
    @MainActor func testStoreArchivesOldSelfRatingsWithoutReplayingAndReimportDoesNotReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-book-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try JSONEncoder().encode(package())
        let old = HandbookCardStore(subject: .computer, baseDirectory: root, documentsDirectory: root)
        old.importData(raw);old.start(now: now);let oldToken = try XCTUnwrap(old.engine?.presentation?.id)
        old.reveal(token: oldToken, now: now);old.rate(remembered: true, token: oldToken, now: now)
        let oldURL = root.appendingPathComponent("HandbookCards/computer/current.json"), oldBytes = try Data(contentsOf: oldURL)
        let migrated = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(migrated.blocked, migrated.error ?? "");XCTAssertTrue(try XCTUnwrap(migrated.engine).record.attempts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        let currentURL = root.appendingPathComponent("HandbookWordRecall/computer/current.json"), initialBytes = try Data(contentsOf: currentURL)
        migrated.importData(raw);XCTAssertEqual(try Data(contentsOf: currentURL), initialBytes)
        migrated.start(now: now);let p = try XCTUnwrap(migrated.engine?.presentation)
        migrated.reveal(token: p.id, now: now)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertEqual(reopened.engine?.presentation?.id, p.id);XCTAssertEqual(reopened.engine?.presentation?.revealed, true)
        reopened.rate(remembered: false, token: p.id, now: now)
        let once = try Data(contentsOf: currentURL)
        reopened.rate(remembered: true, token: p.id, now: now);reopened.importData(raw)
        XCTAssertEqual(try Data(contentsOf: currentURL), once);XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertFalse(try reopened.exportRecords().isEmpty)
    }
    @MainActor func testCommittedWriteFailureKeepsNewAnswerAndNeverReplaysIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var failAfterCommit = false
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now, writer: { data,url in
            try data.write(to: url, options: .atomic)
            if failAfterCommit { throw NSError(domain: "SyntheticPostCommit", code: 1) }
        })
        store.importData(try JSONEncoder().encode(package()));store.start(now: now)
        let token = try XCTUnwrap(store.engine?.presentation?.id);store.reveal(token: token, now: now)
        failAfterCommit = true;store.rate(remembered: false, token: token, now: now)
        XCTAssertTrue(store.blocked)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "");XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        let path = root.appendingPathComponent("HandbookWordRecall/computer/current.json"),before = try Data(contentsOf: path)
        reopened.rate(remembered: true, token: token, now: now)
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
    #endif
}
