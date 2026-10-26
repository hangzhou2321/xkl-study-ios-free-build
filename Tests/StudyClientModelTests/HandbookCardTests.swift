import Foundation
import XCTest
@testable import StudyClientModel

final class HandbookCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private func card(_ n: Int) -> HandbookCard {
        .init(id: "synthetic-knowledge-\(n)", sourceGroupIDs: ["synthetic-group-\(n)"], topicNumber: n,
            title: "Synthetic complete knowledge point \(n)", prompt: "Recall synthetic knowledge point \(n)",
            answerSummary: "Synthetic clear answer \(n)",
            blocks: [.init(title: "Synthetic comparison", kind: "keyValues", rows: [["Synthetic key", "Synthetic value"]])],
            sourcePages: [n], examples: [], sourceNotes: [], chapterID: "synthetic-chapter")
    }
    private func fixture(_ count: Int = 2, revision: String = "1.0") -> HandbookCardPackage {
        .init(id: "synthetic-handbook", subject: .computer, title: "Synthetic book only", revision: revision,
            source: .init(title: "Synthetic source", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64),
                pdfPageCount: 10, includedPages: Array(1...10)),
            chapters: [.init(id: "synthetic-chapter", title: "Synthetic chapter")], cards: (1...count).map(card))
    }
    private func changed(_ source: HandbookCardPackage, revision: String = "1.1", edit: (inout [String: Any]) -> Void) throws -> HandbookCardPackage {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        object["revision"] = revision; edit(&object)
        return try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
    }
    private func restored(_ e: HandbookRecallEngine) throws -> HandbookRecallEngine {
        try .init(package: e.package, record: JSONDecoder().decode(HandbookCardRecord.self, from: JSONEncoder().encode(e.record)))
    }
    private func rating(_ e: inout HandbookRecallEngine, remembered: Bool, at date: Date) throws -> UUID {
        let p = try XCTUnwrap(e.presentation)
        try e.reveal(token: p.id, now: date)
        try e.rate(remembered: remembered, token: p.id, now: date)
        return p.id
    }

    func testWholePackageLoadAndMobileBlockValidation() throws {
        let pack = fixture(); XCTAssertEqual(try HandbookCardPackage.load(JSONEncoder().encode(pack)), pack)
        XCTAssertEqual(pack.chapter(for: pack.cards[0])?.id, "synthetic-chapter")
        XCTAssertThrowsError(try changed(pack) { object in
            var cards = object["cards"] as! [[String: Any]]
            cards[0]["blocks"] = [["title": "too wide", "kind": "table", "columns": ["a","b","c","d"], "rows": [["1","2","3","4"]], "collapsed": false]]
            object["cards"] = cards
        })
    }
    func testRevealIsNotASelfRatingAndBackSideRestores() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); try e.start(now: now)
        let p = try XCTUnwrap(e.presentation); try e.reveal(token: p.id, now: now)
        XCTAssertTrue(try XCTUnwrap(e.presentation).revealed); XCTAssertTrue(e.record.ratings.isEmpty)
        XCTAssertTrue(e.record.progress.isEmpty)
        let reloaded = try restored(e)
        XCTAssertEqual(reloaded.record, e.record); XCTAssertEqual(reloaded.presentation?.id, p.id)
    }
    func testRatingRequiresRevealedCurrentTokenAndIsIdempotent() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); try e.start(now: now)
        let p = try XCTUnwrap(e.presentation), before = e.record
        XCTAssertThrowsError(try e.rate(remembered: true, token: p.id, now: now)); XCTAssertEqual(e.record, before)
        XCTAssertThrowsError(try e.reveal(token: UUID(), now: now)); XCTAssertEqual(e.record, before)
        _ = try rating(&e, remembered: true, at: now)
        let after = e.record; try e.rate(remembered: false, token: p.id, now: now)
        XCTAssertEqual(e.record, after); XCTAssertEqual(e.record.ratings.count, 1)
        XCTAssertNotEqual(e.presentation?.id, p.id); XCTAssertNotEqual(e.currentCard?.id, p.cardID)
    }
    func testForgottenWaitsReal24HoursAcrossMidnight() throws {
        let f = ISO8601DateFormatter(), late = try XCTUnwrap(f.date(from: "2026-10-26T23:59:00Z"))
        var e = try HandbookRecallEngine.fresh(fixture(1)); try e.start(now: late)
        _ = try rating(&e, remembered: false, at: late)
        XCTAssertNil(e.presentation); XCTAssertEqual(e.nextDueAt, late.addingTimeInterval(86_400))
        try e.start(now: late.addingTimeInterval(120)); XCTAssertNil(e.presentation)
        try e.start(now: late.addingTimeInterval(86_399)); XCTAssertNil(e.presentation)
        try e.start(now: late.addingTimeInterval(86_400)); XCTAssertNotNil(e.presentation)
        XCTAssertEqual(e.stats(on: late.addingTimeInterval(120)).due, 0)
        XCTAssertEqual(e.stats(on: late.addingTimeInterval(86_400)).due, 1)
        _ = try restored(e)
    }
    func testRememberedWaits72HoursThenSevenDays() throws {
        var e = try HandbookRecallEngine.fresh(fixture(1)); try e.start(now: now)
        _ = try rating(&e, remembered: true, at: now)
        let due = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(e.nextDueAt, due)
        try e.start(now: due.addingTimeInterval(-1)); XCTAssertNil(e.presentation)
        try e.start(now: due); XCTAssertNotNil(e.presentation)
        _ = try rating(&e, remembered: true, at: due)
        XCTAssertEqual(e.nextDueAt, due.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(e.record.progress["synthetic-knowledge-1"]?.streak, 2)
        _ = try restored(e)
    }
    func testForgottenResetsRememberedStreakWithoutDeletingHistory() throws {
        var e = try HandbookRecallEngine.fresh(fixture(1)); try e.start(now: now)
        _ = try rating(&e, remembered: true, at: now)
        let next = now.addingTimeInterval(3 * 86_400); try e.start(now: next)
        _ = try rating(&e, remembered: false, at: next)
        XCTAssertEqual(e.record.ratings.count, 2)
        let p = try XCTUnwrap(e.record.progress["synthetic-knowledge-1"])
        XCTAssertEqual(p.rememberedCount, 1); XCTAssertEqual(p.forgottenCount, 1); XCTAssertEqual(p.streak, 0)
        XCTAssertEqual(p.nextDueAt, next.addingTimeInterval(86_400)); _ = try restored(e)
    }
    func testPostponePreservesBackSideAndReturnsAfterOtherCards() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); try e.start(now: now)
        let first = try XCTUnwrap(e.presentation); try e.reveal(token: first.id, now: now)
        try e.postpone(token: first.id, now: now)
        XCTAssertEqual(e.currentCard?.id, "synthetic-knowledge-2"); XCTAssertTrue(e.record.ratings.isEmpty)
        _ = try rating(&e, remembered: true, at: now)
        XCTAssertEqual(e.presentation?.id, first.id); XCTAssertEqual(e.presentation?.revealed, true)
        XCTAssertEqual(e.record.ratings.count, 1); XCTAssertNil(e.record.progress[first.cardID])
        _ = try restored(e)
    }
    func testAllPostponedEndsRoundWithoutASelfRatingOrInfiniteLoop() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); try e.start(now: now)
        let first = try XCTUnwrap(e.presentation); try e.postpone(token: first.id, now: now)
        let second = try XCTUnwrap(e.presentation); try e.postpone(token: second.id, now: now)
        XCTAssertNil(e.presentation); XCTAssertEqual(e.record.bookmarks.count, 2)
        XCTAssertTrue(e.record.ratings.isEmpty); XCTAssertTrue(e.record.progress.isEmpty)
        XCTAssertEqual(e.stats(on: now).remainingToday, 0)
        e = try restored(e); try e.start(now: now)
        XCTAssertEqual(e.presentation?.id, first.id); XCTAssertEqual(e.record.ratings.count, 0)
    }
    func testReimportAndContentMetadataDoNotResetExistingCards() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); try e.start(now: now)
        _ = try rating(&e, remembered: true, at: now)
        let before = e.record; try e.updatePackage(e.package); XCTAssertEqual(e.record, before)
        let updated = try changed(e.package) { object in
            var source = object["source"] as! [String: Any]; source["title"] = "Updated source label"; object["source"] = source
        }
        try e.updatePackage(updated)
        XCTAssertEqual(e.record.progress, before.progress); XCTAssertEqual(e.record.ratings, before.ratings)
        XCTAssertEqual(e.presentation, before.presentation); XCTAssertEqual(e.record.events, before.events)
        XCTAssertEqual(e.record.contentVersions.count, 2); _ = try restored(e)
    }
    func testChangedCardDefinitionKeepsFrozenCurrentBackSideAndOldSelfRatings() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); try e.start(now: now)
        let old = try XCTUnwrap(e.currentCard), p = try XCTUnwrap(e.presentation)
        try e.reveal(token: p.id, now: now)
        let updated = try changed(e.package) { object in
            var cards = object["cards"] as! [[String: Any]]; cards[0]["answerSummary"] = "Corrected synthetic answer"; object["cards"] = cards
        }
        try e.updatePackage(updated)
        XCTAssertEqual(e.currentCard, old); XCTAssertEqual(e.presentation?.revealed, true)
        XCTAssertNotEqual(e.record.activeDefinitions[old.id], old.definitionID)
        _ = try rating(&e, remembered: false, at: now)
        XCTAssertEqual(e.record.ratings[0].definitionID, old.definitionID); _ = try restored(e)
    }
    func testDeletedOrOlderContentIsRejectedWithoutMutation() throws {
        var e = try HandbookRecallEngine.fresh(fixture()); let original = e.package
        try e.updatePackage(fixture(3, revision: "1.1")); let before = e.record
        XCTAssertThrowsError(try e.updatePackage(original)); XCTAssertEqual(e.record, before)
        XCTAssertThrowsError(try e.updatePackage(fixture(2, revision: "1.2"))); XCTAssertEqual(e.record, before)
    }
    func testTamperedProgressOrUnrevealedRatingFailsClosed() throws {
        var e = try HandbookRecallEngine.fresh(fixture(1)); try e.start(now: now)
        _ = try rating(&e, remembered: true, at: now)
        var saved = e.record; saved.progress["synthetic-knowledge-1"]?.nextDueAt = now
        XCTAssertThrowsError(try HandbookRecallEngine(package: e.package, record: saved))
        saved = e.record; saved.events.removeAll { $0.kind == "reveal" }
        XCTAssertThrowsError(try HandbookRecallEngine(package: e.package, record: saved))
    }
    func testClockRollbackNeverClearsSavedProgress() throws {
        var e = try HandbookRecallEngine.fresh(fixture(1)); try e.start(now: now)
        _ = try rating(&e, remembered: false, at: now)
        let before = e.record
        XCTAssertThrowsError(try e.start(now: now.addingTimeInterval(-120))); XCTAssertEqual(e.record, before)
        XCTAssertEqual(e.stats(on: now).unseen, 0); XCTAssertEqual(e.stats(on: now).forgotten, 1)
    }
    func testInitialStatsDoNotCallUnseenCardsDue() throws {
        let e = try HandbookRecallEngine.fresh(fixture())
        let stats = e.stats(on: now)
        XCTAssertEqual(stats.total, 2); XCTAssertEqual(stats.seen, 0); XCTAssertEqual(stats.unseen, 2)
        XCTAssertEqual(stats.due, 0); XCTAssertEqual(stats.remembered, 0); XCTAssertEqual(stats.forgotten, 0)
    }
}
