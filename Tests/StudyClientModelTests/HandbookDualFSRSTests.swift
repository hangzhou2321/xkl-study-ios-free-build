import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

final class HandbookDualFSRSTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func package(_ count: Int, subject: ConceptSubject = .power) -> HandbookCardPackage {
        var p = HandbookCardPackage(id: "synthetic-\(subject.rawValue)", subject: subject, title: "Synthetic",
            revision: "1.0", source: .init(title: "Synthetic", fileName: "synthetic.pdf",
                sha256: String(repeating: "a", count: 64), pdfPageCount: 2, includedPages: [1]),
            chapters: [.init(id: "chapter", title: "Synthetic")], cards: (0..<count).map {
                .init(id: "original-id-\($0)", sourceGroupIDs: ["group-\($0)"], topicNumber: 1,
                    title: "Synthetic \($0)", prompt: "Recall", answerSummary: "Synthetic answer",
                    blocks: [], sourcePages: [1], examples: [], sourceNotes: [], chapterID: "chapter")
            })
        p.memoryGuides = p.cards.map { .init(cardID: $0.id, explanation: nil,
            rows: [.init(cue: "Synthetic", answer: "Synthetic answer")], mnemonic: nil) }
        return p
    }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
    private func catalog(_ p: HandbookCardPackage) -> RecallDeck {
        .init(subject: p.subject, bankID: p.subject.bankID, cards: p.cards.indices.map { index in
            .init(conceptID: "handbook", conceptTitle: "Handbook slot",
                  card: .init(id: "handbook:\(index)", prompt: "slot \(index)", answer: "slot \(index)"))
        })
    }

    @MainActor func testNewGoodAndAgainUseActualFSRSWithoutSevenRepeats() async throws {
        let p = package(2), old = try HandbookWordEngine(package: p, now: now).state
        let engine = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        XCTAssertTrue(engine.state.legacyRatings.isEmpty)
        try engine.start(now: now.addingTimeInterval(2)); XCTAssertEqual(engine.state.queue.count, 2)
        let first = try XCTUnwrap(engine.presentation), firstAt = now.addingTimeInterval(4)
        XCTAssertThrowsError(try engine.rate(remembered: true, token: first.id, now: firstAt))
        try engine.reveal(token: first.id, now: now.addingTimeInterval(3))
        XCTAssertTrue(engine.state.daily.isEmpty)
        try engine.rate(remembered: true, token: first.id, now: firstAt)
        let day = UInt32(try ConceptCalendar.studyDay(firstAt))
        let good = try FSRS6Shadow.review(nil, day: day, rating: 3, timestampMs: ms(firstAt)).memory
        XCTAssertEqual(engine.state.daily[first.cardID], good); XCTAssertEqual(engine.state.all[first.cardID], good)
        XCTAssertEqual(good.dueDay, day + 2)
        let afterFirst = engine.state
        try engine.rate(remembered: false, token: first.id, now: firstAt)
        XCTAssertEqual(engine.state, afterFirst)
        let second = try XCTUnwrap(engine.presentation), secondAt = now.addingTimeInterval(6)
        try engine.reveal(token: second.id, now: now.addingTimeInterval(5))
        try engine.rate(remembered: false, token: second.id, now: secondAt)
        let again = try FSRS6Shadow.review(nil, day: day, rating: 1, timestampMs: ms(secondAt)).memory
        XCTAssertEqual(engine.state.daily[second.cardID], again); XCTAssertEqual(again.dueDay, day + 1)
        XCTAssertNil(engine.presentation); XCTAssertTrue(engine.state.queue.isEmpty)
        XCTAssertEqual(engine.state.events.filter { $0.kind == "grade" }.count, 2)
        try engine.start(now: now.addingTimeInterval(7)); XCTAssertNil(engine.presentation)
        try engine.start(now: now.addingTimeInterval(86_400 + 7))
        XCTAssertEqual(engine.presentation?.cardID, second.cardID)
        XCTAssertEqual(engine.state.queue.count, 1)
        try engine.validateLegacy(old)
    }

    @MainActor func testCarriedOldRevealedCardAndBoundedQueueSurviveRestart() async throws {
        let p = package(6), oldEngine = try HandbookWordEngine(package: p, now: now)
        try oldEngine.start(now: now); let oldToken = try XCTUnwrap(oldEngine.presentation?.id)
        try oldEngine.reveal(token: oldToken, now: now.addingTimeInterval(1))
        let old = oldEngine.state, before = old.word.snapshot
        let migratedAt = now.addingTimeInterval(2), dual = try HandbookDualFSRS(legacy: old, now: migratedAt)
        XCTAssertEqual(dual.presentation?.id, oldToken); XCTAssertEqual(dual.presentation?.revealed, true)
        XCTAssertEqual(dual.currentCard, old.frozenCard); XCTAssertEqual(dual.currentMemoryGuide, old.frozenGuide)
        XCTAssertEqual(dual.presentation?.shownAt, migratedAt) // transfer timestamp, not a fabricated old view
        XCTAssertEqual(dual.state.initialQueue.count, 6)
        XCTAssertTrue(dual.state.events.isEmpty); XCTAssertTrue(dual.state.daily.isEmpty)
        XCTAssertEqual(old.word.snapshot, before)
        let state = try JSONDecoder().decode(HandbookDualFSRSState.self, from: JSONEncoder().encode(dual.state))
        let resumed = try HandbookDualFSRS(state: state, package: p, ids: p.cards.map(\.id))
        try resumed.validateLegacy(old)
        XCTAssertEqual(resumed.presentation, dual.presentation); XCTAssertEqual(resumed.currentCard, dual.currentCard)
        try resumed.rate(remembered: true, token: oldToken, now: now.addingTimeInterval(3))
        XCTAssertNotNil(resumed.presentation); XCTAssertNotEqual(resumed.presentation?.id, oldToken)
        XCTAssertEqual(resumed.state.queue.count, 5)
    }

    @MainActor func testTwentyCardRoundsBalanceDueAndNewAndRetainOverflow() async throws {
        let p = package(35), old = try HandbookWordEngine(package: p, now: now).state
        let engine = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        try engine.start(now: now.addingTimeInterval(2)); XCTAssertEqual(engine.state.queue.count, 20)
        for i in 0..<20 {
            let p = try XCTUnwrap(engine.presentation), at = now.addingTimeInterval(Double(10 + i * 2))
            try engine.reveal(token: p.id, now: at)
            try engine.rate(remembered: true, token: p.id, now: at.addingTimeInterval(1))
        }
        XCTAssertNil(engine.presentation); XCTAssertEqual(engine.state.daily.count, 20)
        let nextDay = now.addingTimeInterval(3 * 86_400)
        try engine.start(now: nextDay)
        XCTAssertEqual(engine.state.queue.count, 20)
        XCTAssertEqual(Array(engine.state.queue.prefix(10)), (0..<10).map { "original-id-\($0)" })
        XCTAssertEqual(Array(engine.state.queue.suffix(10)), (20..<30).map { "original-id-\($0)" })
        XCTAssertEqual(engine.stats(on: nextDay).remainingToday, 20)
        XCTAssertEqual(engine.stats(on: nextDay).due, 20) // all obligations remain, not only selected
    }

    @MainActor func testOldSameDayRatingsFeedTwoDifferentTracksAndPendingCurrent() async throws {
        let p = package(1), legacy = try HandbookWordEngine(package: p, now: now)
        try legacy.start(now: now); var t = try XCTUnwrap(legacy.presentation?.id)
        try legacy.reveal(token: t, now: now.addingTimeInterval(1))
        try legacy.rate(remembered: false, token: t, now: now.addingTimeInterval(2))
        t = try XCTUnwrap(legacy.presentation?.id)
        try legacy.reveal(token: t, now: now.addingTimeInterval(3))
        try legacy.rate(remembered: true, token: t, now: now.addingTimeInterval(4))
        let old = legacy.state, migrated = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(5))
        let first = try XCTUnwrap(old.word.attempts.first), id = "original-id-0"
        let daily = try FSRS6Shadow.review(nil, day: first.day, rating: 1, timestampMs: ms(first.at)).memory
        let second = old.word.attempts[1]
        let all = try FSRS6Shadow.review(daily, day: second.day, rating: 3, timestampMs: ms(second.at)).memory
        XCTAssertEqual(migrated.state.legacyRatings.count, 2)
        XCTAssertEqual(migrated.state.daily[id], daily); XCTAssertEqual(migrated.state.all[id], all)
        XCTAssertNotEqual(daily, all)
        let pending = try XCTUnwrap(migrated.presentation?.id)
        try migrated.reveal(token: pending, now: now.addingTimeInterval(6))
        try migrated.rate(remembered: true, token: pending, now: now.addingTimeInterval(7))
        XCTAssertEqual(migrated.state.daily[id], daily)
        XCTAssertNotEqual(migrated.state.all[id], all)
        XCTAssertEqual(migrated.state.legacyRatings.count, 2)
        XCTAssertEqual(migrated.state.events.filter { $0.kind == "grade" }.count, 1)
        try migrated.validateLegacy(old)
    }

    @MainActor func testFamiliarPostponeAndStaleTokensDoNotInventGrades() async throws {
        let p = package(3), legacy = try HandbookWordEngine(package: p, now: now)
        try legacy.start(now: now); let first = try XCTUnwrap(legacy.presentation)
        try legacy.markFamiliar(token: first.id, now: now.addingTimeInterval(1))
        let old = legacy.state, dual = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(2))
        XCTAssertTrue(dual.state.familiar.contains(first.cardID)); XCTAssertNil(dual.state.daily[first.cardID])
        let current = try XCTUnwrap(dual.presentation), before = dual.state.daily
        XCTAssertTrue(try dual.postpone(token: current.id, now: now.addingTimeInterval(3)))
        XCTAssertEqual(dual.state.daily, before)
        XCTAssertFalse(try dual.postpone(token: current.id, now: now.addingTimeInterval(4)))
        let new = try XCTUnwrap(dual.presentation)
        try dual.markFamiliar(token: new.id, now: now.addingTimeInterval(4))
        XCTAssertTrue(dual.state.familiar.contains(new.cardID)); XCTAssertTrue(dual.state.daily.isEmpty)
        XCTAssertTrue(dual.state.events.filter { $0.kind == "grade" }.isEmpty)
        let reopened = try HandbookDualFSRS(state: dual.state, package: p, ids: p.cards.map(\.id))
        try reopened.validateLegacy(old)
        XCTAssertEqual(reopened.state.familiar, dual.state.familiar)
    }

    @MainActor func testReimportAndAppendKeepOldSlotsFrozenAndModelState() async throws {
        let p = package(2), old = try HandbookWordEngine(package: p, now: now).state
        let dual = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        try dual.start(now: now.addingTimeInterval(2)); let shown = try XCTUnwrap(dual.presentation)
        try dual.reveal(token: shown.id, now: now.addingTimeInterval(3))
        let before = dual.state, frozen = dual.currentCard
        try dual.updatePackage(p, ids: p.cards.map(\.id), now: now.addingTimeInterval(4))
        XCTAssertEqual(dual.state, before)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        var cards = try XCTUnwrap(obj["cards"] as? [[String: Any]])
        var extra = try XCTUnwrap(cards.first); extra["id"] = "new-card"; extra["sourceGroupIDs"] = ["new-group"]
        cards.insert(extra, at: 0); obj["cards"] = cards; obj["revision"] = "1.1"
        let newer = try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: obj))
        let ids = p.cards.map(\.id) + ["new-card"]
        try dual.updatePackage(newer, ids: ids, now: now.addingTimeInterval(5))
        XCTAssertEqual(dual.state.legacyIDs, p.cards.map(\.id)); XCTAssertEqual(dual.state.ids, ids)
        XCTAssertEqual(dual.currentCard, frozen); XCTAssertEqual(dual.presentation?.id, shown.id)
        XCTAssertTrue(dual.state.daily.isEmpty); XCTAssertEqual(dual.state.events, before.events)
        try dual.validateLegacy(old)
        let reloaded = try HandbookDualFSRS(state: dual.state, package: newer, ids: ids)
        XCTAssertEqual(reloaded.presentation, dual.presentation); try reloaded.validateLegacy(old)
        XCTAssertThrowsError(try dual.updatePackage(newer, ids: Array(ids.reversed()), now: now.addingTimeInterval(6)))
    }

    @MainActor func testClockRollbackSubjectAndTamperedStateFailClosed() async throws {
        let p = package(1), old = try HandbookWordEngine(package: p, now: now).state
        XCTAssertThrowsError(try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(-1)))
        let dual = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        try dual.start(now: now.addingTimeInterval(2)); let p0 = try XCTUnwrap(dual.presentation)
        let before = dual.state
        XCTAssertThrowsError(try dual.reveal(token: p0.id, now: now.addingTimeInterval(1)))
        XCTAssertEqual(dual.state, before)
        var bad = before; bad.familiar = [p0.cardID]
        XCTAssertThrowsError(try HandbookDualFSRS(state: bad, package: p, ids: p.cards.map(\.id)))
        bad = before; bad.seen = []
        XCTAssertThrowsError(try HandbookDualFSRS(state: bad, package: p, ids: p.cards.map(\.id)))
        bad = before; bad.lastRating[p0.cardID] = .init(day: UInt32(try ConceptCalendar.studyDay(now)), at: now, remembered: false)
        XCTAssertThrowsError(try HandbookDualFSRS(state: bad, package: p, ids: p.cards.map(\.id)))
        XCTAssertThrowsError(try HandbookDualFSRS(state: before, package: package(1, subject: .computer), ids: p.cards.map(\.id)))
        var oldChanged = old; oldChanged.word.attempts.removeAll()
        oldChanged.word.snapshotSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try dual.validateLegacy(oldChanged))
    }

    @MainActor func testActualPocketUndoDoesNotSeedFSRSWithRetractedGrade() async throws {
        let p = package(1), original = try HandbookWordEngine(package: p, now: now)
        try original.start(now: now)
        let first = try XCTUnwrap(original.presentation?.id)
        try original.reveal(token: first, now: now.addingTimeInterval(1))
        try original.rate(remembered: true, token: first, now: now.addingTimeInterval(2))
        var old = original.state
        let pocket = try PocketEngine(snapshot: old.word.snapshot)
        try pocket.undo()
        let info = try pocket.info
        XCTAssertNotEqual(info.has_task, 0)
        let undoEvent = try XCTUnwrap(pocket.events(from: pocket.logBase + 1).last { $0.kind == 8 })
        XCTAssertNotEqual(undoEvent.undoRevision, UInt32.max)
        old.word.snapshot = try pocket.snapshot()
        old.word.snapshotSHA256 = StudySHA256.hex(old.word.snapshot)
        let token = UUID(), index = Int(info.word)
        let card = try XCTUnwrap(p.cards.first { $0.id == old.originalCardIDs[index] })
        old.word.presentation = .init(id: token, cardID: old.word.cardIDs[index], revealed: info.revealed != 0)
        old.frozenCard = card; old.frozenToken = token; old.frozenGuide = p.memoryGuide(for: card)
        let migrated = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(3))
        XCTAssertEqual(migrated.state.legacyRatings.count, 1)
        XCTAssertTrue(try XCTUnwrap(migrated.state.legacyRatings.first).retracted)
        XCTAssertTrue(migrated.state.daily.isEmpty)
        XCTAssertTrue(migrated.state.all.isEmpty)
        XCTAssertEqual(migrated.presentation?.id, token)
        XCTAssertEqual(old.word.attempts.count, 1, "The real historical attempt remains archived.")
        try migrated.validateLegacy(old)
    }

    @MainActor func testImportedLearnedSlotWithoutWordAttemptStaysSeenAndKeepsDue() async throws {
        let p = package(1)
        let deck = RecallDeck(subject: p.subject, bankID: p.subject.bankID, cards: p.cards.indices.map { index in
            .init(conceptID: "handbook", conceptTitle: "Handbook slot",
                  card: .init(id: "handbook:\(index)", prompt: "slot \(index)", answer: "slot \(index)"))
        })
        let day = try ConceptCalendar.studyDay(now)
        var legacyRecall = try RecallEngine(deck: deck)
        try legacyRecall.act("start", day: day, newLimit: 1, now: now)
        let token = try XCTUnwrap(legacyRecall.record.state.shown?.id)
        try legacyRecall.act("reveal", day: day, token: token, now: now.addingTimeInterval(1))
        try legacyRecall.act("grade", day: day, token: token, remembered: true, now: now.addingTimeInterval(2))
        try legacyRecall.act("next", day: day, token: token, now: now.addingTimeInterval(3))
        let imported = try ProfessionalRecallEngine.fresh(deck: deck, legacy: [legacyRecall.record], now: now.addingTimeInterval(4))
        XCTAssertTrue(imported.record.attempts.isEmpty)
        XCTAssertNil(imported.record.presentation)
        let old = HandbookWordState(package: p, originalCardIDs: p.cards.map(\.id), word: imported.record,
                                    frozenCard: nil, frozenToken: nil, frozenGuide: nil)
        let dual = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(5))
        let id = try XCTUnwrap(p.cards.first?.id), packed = try XCTUnwrap(dual.state.legacyPacked[id])
        XCTAssertNotEqual(packed & (1 << 20), 0)
        XCTAssertEqual(dual.stats(on: now).seen, 1); XCTAssertEqual(dual.stats(on: now).unseen, 0)
        XCTAssertTrue(dual.state.legacyRatings.isEmpty); XCTAssertTrue(dual.state.daily.isEmpty)
        XCTAssertTrue(dual.state.all.isEmpty); XCTAssertTrue(dual.state.events.isEmpty)
        XCTAssertNotNil(dual.nextDueAt)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        let parts = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(packed & 65_535) * 86_400))
        XCTAssertEqual(dual.nextDueAt, local.date(from: parts)) // old packed-only day has no fabricated time
        let restored = try HandbookDualFSRS(state: dual.state, package: p, ids: p.cards.map(\.id))
        try restored.validateLegacy(old)
        XCTAssertEqual(restored.state.legacyPacked[id], packed)
        try restored.start(now: now.addingTimeInterval(181 * 86_400))
        XCTAssertEqual(restored.presentation?.cardID, id)
    }

    @MainActor func testOptionalRetryAfterTenMinutesKeepsDailyAndUpdatesAll() async throws {
        let p = package(1), old = try HandbookWordEngine(package: p, now: now).state
        let e = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        try e.start(now: now.addingTimeInterval(2))
        let first = try XCTUnwrap(e.presentation)
        try e.reveal(token: first.id, now: now.addingTimeInterval(3))
        let failedAt = now.addingTimeInterval(4)
        try e.rate(remembered: false, token: first.id, now: failedAt)
        let daily = try XCTUnwrap(e.state.daily[first.cardID]), allBefore = try XCTUnwrap(e.state.all[first.cardID])
        XCTAssertEqual(daily, allBefore); XCTAssertNil(e.presentation)

        let early = failedAt.addingTimeInterval(599)
        XCTAssertEqual(e.retryCount(on: early), 0)
        let beforeEarly = e.state
        try e.startRetry(now: early)
        XCTAssertEqual(e.state, beforeEarly)
        let eligible = failedAt.addingTimeInterval(600)
        XCTAssertEqual(e.retryCount(on: eligible), 1)
        try e.start(now: eligible) // normal queue never inserts an optional retry
        XCTAssertEqual(e.state, beforeEarly); XCTAssertNil(e.presentation)
        try e.startRetry(now: eligible)
        XCTAssertEqual(e.presentation?.cardID, first.cardID)
        XCTAssertEqual(e.state.events.last?.kind, "retry")
        XCTAssertEqual(e.state.events.filter { $0.kind == "grade" }.count, 1)
        let retry = try XCTUnwrap(e.presentation)
        let reopened = try HandbookDualFSRS(state: JSONDecoder().decode(HandbookDualFSRSState.self,
            from: JSONEncoder().encode(e.state)), package: p, ids: p.cards.map(\.id))
        try reopened.validateLegacy(old)
        XCTAssertEqual(reopened.presentation, retry); XCTAssertEqual(reopened.state.daily[first.cardID], daily)
        XCTAssertThrowsError(try reopened.rate(remembered: true, token: retry.id, now: eligible))
        try reopened.reveal(token: retry.id, now: eligible.addingTimeInterval(1))
        let successAt = eligible.addingTimeInterval(2)
        try reopened.rate(remembered: true, token: retry.id, now: successAt)
        let expected = try FSRS6Shadow.review(allBefore, day: daily.lastDay, rating: 3, timestampMs: ms(successAt)).memory
        XCTAssertEqual(reopened.state.daily[first.cardID], daily)
        XCTAssertEqual(reopened.state.all[first.cardID], expected)
        XCTAssertNotEqual(reopened.state.daily[first.cardID], reopened.state.all[first.cardID])
        XCTAssertNil(reopened.presentation); XCTAssertEqual(reopened.retryCount(on: successAt.addingTimeInterval(601)), 0)
        let final = try HandbookDualFSRS(state: reopened.state, package: p, ids: p.cards.map(\.id))
        try final.validateLegacy(old); XCTAssertEqual(final.state, reopened.state)
    }

    @MainActor func testAgainDuringRetryRestartsTenMinuteWaitAndFamiliarExcludesIt() async throws {
        let p = package(1), old = try HandbookWordEngine(package: p, now: now).state
        let e = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        try e.start(now: now.addingTimeInterval(2))
        let first = try XCTUnwrap(e.presentation)
        try e.reveal(token: first.id, now: now.addingTimeInterval(3))
        try e.rate(remembered: false, token: first.id, now: now.addingTimeInterval(4))
        let retryStart = now.addingTimeInterval(604)
        try e.startRetry(now: retryStart)
        let retry = try XCTUnwrap(e.presentation), active = e.state
        try e.startRetry(now: retryStart.addingTimeInterval(1)) // already in a round: no displacement
        XCTAssertEqual(e.state, active)
        try e.reveal(token: retry.id, now: retryStart.addingTimeInterval(2))
        let failedAgain = retryStart.addingTimeInterval(3)
        try e.rate(remembered: false, token: retry.id, now: failedAgain)
        XCTAssertEqual(e.retryCount(on: failedAgain.addingTimeInterval(599)), 0)
        XCTAssertEqual(e.retryCount(on: failedAgain.addingTimeInterval(600)), 1)
        let restored = try HandbookDualFSRS(state: e.state, package: p, ids: p.cards.map(\.id))
        try restored.validateLegacy(old)
        try restored.startRetry(now: failedAgain.addingTimeInterval(600))
        let toMark = try XCTUnwrap(restored.presentation)
        let beforeFamiliar = restored.state.daily
        try restored.markFamiliar(token: toMark.id, now: failedAgain.addingTimeInterval(601))
        XCTAssertEqual(restored.state.daily, beforeFamiliar)
        XCTAssertEqual(restored.retryCount(on: failedAgain.addingTimeInterval(1_201)), 0)
        XCTAssertEqual(restored.state.events.filter { $0.kind == "grade" }.count, 2)
    }

    @MainActor func testRetryEventWithEarlyTimestampFailsReplay() async throws {
        let p = package(1), old = try HandbookWordEngine(package: p, now: now).state
        let e = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        try e.start(now: now.addingTimeInterval(2))
        let first = try XCTUnwrap(e.presentation)
        try e.reveal(token: first.id, now: now.addingTimeInterval(3))
        let failedAt = now.addingTimeInterval(4)
        try e.rate(remembered: false, token: first.id, now: failedAt)
        try e.startRetry(now: failedAt.addingTimeInterval(600))
        var bad = e.state
        let last = try XCTUnwrap(bad.events.last)
        var frozen = try XCTUnwrap(last.next)
        let earlier = failedAt.addingTimeInterval(599), oldPresentation = frozen.presentation
        frozen.presentation = .init(id: oldPresentation.id, cardID: oldPresentation.cardID,
            definitionID: oldPresentation.definitionID, revealed: false, shownAt: earlier)
        bad.events[bad.events.count - 1] = .init(id: last.id, sequence: last.sequence, kind: last.kind,
            at: earlier, day: last.day, utcOffsetSeconds: last.utcOffsetSeconds, cardID: last.cardID,
            presentationID: last.presentationID, remembered: last.remembered, round: last.round, next: frozen)
        XCTAssertThrowsError(try HandbookDualFSRS(state: bad, package: p, ids: p.cards.map(\.id)))
        XCTAssertEqual(e.state.events.last?.kind, "retry") // rejected copy leaves original untouched
    }

    @MainActor func testOptionalRetryLimitAndOverflowAreNeverAutomatic() async throws {
        let p = package(25), old = try HandbookWordEngine(package: p, now: now).state
        let e = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(1))
        for batch in 0..<2 {
            try e.start(now: now.addingTimeInterval(Double(2 + batch * 100)))
            while let current = e.presentation {
                let sequence = e.state.events.count
                let at = now.addingTimeInterval(Double(10 + batch * 100 + sequence * 2))
                try e.reveal(token: current.id, now: at)
                try e.rate(remembered: false, token: current.id, now: at.addingTimeInterval(1))
            }
        }
        XCTAssertEqual(e.state.events.filter { $0.kind == "grade" }.count, 25)
        let eligible = now.addingTimeInterval(1_000)
        XCTAssertEqual(e.retryCount(on: eligible), 25); XCTAssertNil(e.presentation)
        try e.startRetry(now: eligible)
        XCTAssertEqual(e.state.queue.count, 20)
        XCTAssertEqual(e.retryCount(on: eligible), 5)
        while let current = e.presentation {
            let at = eligible.addingTimeInterval(Double(e.state.events.count * 2 + 1))
            try e.reveal(token: current.id, now: at)
            try e.rate(remembered: true, token: current.id, now: at.addingTimeInterval(1))
        }
        XCTAssertNil(e.presentation) // remaining five never start without a separate tap
        XCTAssertEqual(e.retryCount(on: eligible.addingTimeInterval(500)), 5)
        try e.startRetry(now: eligible.addingTimeInterval(500))
        XCTAssertEqual(e.state.queue.count, 5)
    }

    @MainActor func testReviewRequiresBothDueDayAndFullElapsedFSRSInterval() async throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        let nearMidnight = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23, minute: 59)))
        for remembered in [false, true] {
            let p = package(1), old = try HandbookWordEngine(package: p, now: nearMidnight.addingTimeInterval(-4)).state
            let e = try HandbookDualFSRS(legacy: old, now: nearMidnight.addingTimeInterval(-3))
            try e.start(now: nearMidnight.addingTimeInterval(-2))
            let first = try XCTUnwrap(e.presentation)
            try e.reveal(token: first.id, now: nearMidnight.addingTimeInterval(-1))
            try e.rate(remembered: remembered, token: first.id, now: nearMidnight)
            let due = nearMidnight.addingTimeInterval((remembered ? 2 : 1) * 86_400)
            XCTAssertEqual(e.nextDueAt, due)
            let afterMidnight = nearMidnight.addingTimeInterval(120)
            XCTAssertEqual(e.stats(on: afterMidnight).due, 0)
            let finished = e.state
            try e.start(now: afterMidnight); XCTAssertEqual(e.state, finished)
            let beforeDue = due.addingTimeInterval(-1)
            XCTAssertEqual(e.stats(on: beforeDue).due, 0)
            try e.start(now: beforeDue); XCTAssertEqual(e.state, finished)
            XCTAssertEqual(e.stats(on: due).due, 1)
            try e.start(now: due); XCTAssertEqual(e.presentation?.cardID, first.cardID)

            // A forged start at 00:01 with otherwise matching frozen head is
            // rejected during replay, even when the calendar dueDay has arrived.
            var bad = e.state
            let last = try XCTUnwrap(bad.events.last)
            var shown = try XCTUnwrap(last.next)
            let oldShown = shown.presentation
            shown.presentation = .init(id: oldShown.id, cardID: oldShown.cardID,
                definitionID: oldShown.definitionID, revealed: false, shownAt: afterMidnight)
            bad.events[bad.events.count - 1] = .init(id: last.id, sequence: last.sequence,
                kind: last.kind, at: afterMidnight, day: UInt32(try ConceptCalendar.studyDay(afterMidnight)),
                utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: afterMidnight),
                cardID: last.cardID, presentationID: last.presentationID, remembered: last.remembered,
                round: last.round, next: shown)
            XCTAssertThrowsError(try HandbookDualFSRS(state: bad, package: p, ids: p.cards.map(\.id)))
        }
    }

    @MainActor func testRetryRoundCrossesMidnightAndStillUpdatesOnlyAllTrack() async throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        let failedAt = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23, minute: 45)))
        let p = package(1), old = try HandbookWordEngine(package: p, now: failedAt.addingTimeInterval(-4)).state
        let e = try HandbookDualFSRS(legacy: old, now: failedAt.addingTimeInterval(-3))
        try e.start(now: failedAt.addingTimeInterval(-2)); XCTAssertEqual(e.state.roundKind, "main")
        let first = try XCTUnwrap(e.presentation)
        try e.reveal(token: first.id, now: failedAt.addingTimeInterval(-1))
        try e.rate(remembered: false, token: first.id, now: failedAt)
        let daily = try XCTUnwrap(e.state.daily[first.cardID]), all = try XCTUnwrap(e.state.all[first.cardID])
        let retryAt = failedAt.addingTimeInterval(600) // 23:55, same local day
        XCTAssertEqual(e.retryCount(on: retryAt), 1)
        try e.startRetry(now: retryAt); XCTAssertEqual(e.state.roundKind, "retry")
        let pending = try XCTUnwrap(e.presentation)
        try e.reveal(token: pending.id, now: retryAt.addingTimeInterval(1))
        let resumed = try HandbookDualFSRS(state: JSONDecoder().decode(HandbookDualFSRSState.self,
            from: JSONEncoder().encode(e.state)), package: p, ids: p.cards.map(\.id))
        try resumed.validateLegacy(old)
        XCTAssertEqual(resumed.state.roundKind, "retry"); XCTAssertEqual(resumed.presentation?.id, pending.id)
        XCTAssertEqual(resumed.presentation?.revealed, true)
        let gradedAt = failedAt.addingTimeInterval(16 * 60) // 00:01 the next day
        XCTAssertNotEqual(try ConceptCalendar.studyDay(failedAt), try ConceptCalendar.studyDay(gradedAt))
        try resumed.rate(remembered: true, token: pending.id, now: gradedAt)
        let newDay = UInt32(try ConceptCalendar.studyDay(gradedAt))
        let expectedAll = try FSRS6Shadow.review(all, day: newDay, rating: 3, timestampMs: ms(gradedAt)).memory
        XCTAssertEqual(resumed.state.daily[first.cardID], daily)
        XCTAssertEqual(resumed.state.all[first.cardID], expectedAll)
        XCTAssertNil(resumed.state.roundKind); XCTAssertNil(resumed.presentation)
        XCTAssertEqual(resumed.nextDueAt, failedAt.addingTimeInterval(86_400))
        let again = try HandbookDualFSRS(state: resumed.state, package: p, ids: p.cards.map(\.id))
        try again.validateLegacy(old); XCTAssertEqual(again.state, resumed.state)
        var bad = e.state; bad.roundKind = "main"
        XCTAssertThrowsError(try HandbookDualFSRS(state: bad, package: p, ids: p.cards.map(\.id)))
    }

    @MainActor func testOptionalRetryDoesNotStartAfterSameDayHasEnded() async throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        let failedAt = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23, minute: 55)))
        let p = package(1), old = try HandbookWordEngine(package: p, now: failedAt.addingTimeInterval(-4)).state
        let e = try HandbookDualFSRS(legacy: old, now: failedAt.addingTimeInterval(-3))
        try e.start(now: failedAt.addingTimeInterval(-2)); let first = try XCTUnwrap(e.presentation)
        try e.reveal(token: first.id, now: failedAt.addingTimeInterval(-1))
        try e.rate(remembered: false, token: first.id, now: failedAt)
        let tomorrow = failedAt.addingTimeInterval(600)
        XCTAssertNotEqual(try ConceptCalendar.studyDay(failedAt), try ConceptCalendar.studyDay(tomorrow))
        XCTAssertEqual(e.retryCount(on: tomorrow), 0)
        let before = e.state; try e.startRetry(now: tomorrow); XCTAssertEqual(e.state, before)
    }

    @MainActor func testNormalRoundAcrossMidnightStillRecordsNewDailyGrade() async throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        let shownAt = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23, minute: 59)))
        let p = package(1), old = try HandbookWordEngine(package: p, now: shownAt.addingTimeInterval(-2)).state
        let e = try HandbookDualFSRS(legacy: old, now: shownAt.addingTimeInterval(-1))
        try e.start(now: shownAt); let current = try XCTUnwrap(e.presentation)
        try e.reveal(token: current.id, now: shownAt.addingTimeInterval(1))
        let gradedAt = shownAt.addingTimeInterval(120)
        try e.rate(remembered: true, token: current.id, now: gradedAt)
        XCTAssertEqual(e.state.daily[current.cardID]?.lastDay, UInt32(try ConceptCalendar.studyDay(gradedAt)))
        XCTAssertEqual(e.state.daily[current.cardID], e.state.all[current.cardID])
    }

    @MainActor func testInactiveLegacySlotsStayParkedButNewlyAppendedCardsAreActive() async throws {
        let p = package(3), deck = catalog(p), source = try ProfessionalRecallEngine.fresh(deck: deck, now: now)
        let subset = RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: Array(deck.cards.dropFirst()))
        try source.reconcile(to: subset, now: now.addingTimeInterval(1))
        XCTAssertEqual(source.activeCardIDs, ["handbook:1", "handbook:2"])
        XCTAssertNotNil(source.record.parkedCards?["handbook:0"])
        XCTAssertNil(source.record.presentation)
        let original = source.record
        let old = HandbookWordState(package: p, originalCardIDs: p.cards.map(\.id), word: original,
                                    frozenCard: nil, frozenToken: nil, frozenGuide: nil)
        let wrapped = try HandbookWordEngine(state: old)
        try wrapped.enableDualFSRS(now: now.addingTimeInterval(2))
        XCTAssertNil(wrapped.activePosition(of: "original-id-0"))
        XCTAssertEqual(wrapped.activePosition(of: "original-id-1"), 1)
        XCTAssertEqual(wrapped.activePosition(of: "original-id-2"), 2)
        let e = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(2))
        XCTAssertEqual(e.state.legacyIDs, p.cards.map(\.id))
        XCTAssertEqual(e.state.legacyActiveIDs, ["original-id-1", "original-id-2"])
        XCTAssertEqual(e.inactiveCount, 1); XCTAssertEqual(e.stats(on: now).total, 2)
        XCTAssertEqual(e.stats(on: now).unseen, 2)
        XCTAssertEqual(e.state.legacyPacked["original-id-0"], try source.packedCard(id: "handbook:0"))
        XCTAssertEqual(source.record, original)
        try e.validateLegacy(old)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        var cards = try XCTUnwrap(object["cards"] as? [[String: Any]])
        var extra = try XCTUnwrap(cards.first); extra["id"] = "new-card"; extra["sourceGroupIDs"] = ["new-group"]
        cards.append(extra); object["cards"] = cards; object["revision"] = "1.1"
        let updated = try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
        let ids = p.cards.map(\.id) + ["new-card"]
        try e.updatePackage(updated, ids: ids, now: now.addingTimeInterval(3))
        XCTAssertEqual(e.stats(on: now).total, 3); XCTAssertEqual(e.stats(on: now).unseen, 3)
        try e.start(now: now.addingTimeInterval(4))
        XCTAssertEqual(e.state.queue, ["original-id-1", "original-id-2", "new-card"])
        XCTAssertFalse(e.state.queue.contains("original-id-0"))
        let restored = try HandbookDualFSRS(state: e.state, package: updated, ids: ids)
        try restored.validateLegacy(old)
        XCTAssertEqual(restored.state.legacyActiveIDs, e.state.legacyActiveIDs)
    }

    @MainActor func testActiveSlotWithHistoricalParkedArchiveIsNotRejected() async throws {
        let p = package(3), deck = catalog(p), source = try ProfessionalRecallEngine.fresh(deck: deck, now: now)
        let subset = RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: Array(deck.cards.dropFirst()))
        try source.reconcile(to: subset, now: now.addingTimeInterval(1))
        try source.reconcile(to: deck, now: now.addingTimeInterval(2))
        XCTAssertNotNil(source.record.parkedCards?["handbook:0"])
        XCTAssertEqual(source.activeCardIDs.count, 3)
        let old = HandbookWordState(package: p, originalCardIDs: p.cards.map(\.id), word: source.record,
                                    frozenCard: nil, frozenToken: nil, frozenGuide: nil)
        let e = try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(3))
        XCTAssertEqual(e.inactiveCount, 0); XCTAssertEqual(e.stats(on: now).total, 3)
        try e.validateLegacy(old)
    }

    @MainActor func testDeferredLegacyCardFailsClosedWithoutChangingOldArchive() async throws {
        let p = package(3), deck = catalog(p), day = UInt32(try ConceptCalendar.studyDay(now))
        let donor = try ProfessionalRecallEngine.fresh(deck: deck, now: now)
        try donor.start(day: day, now: now)
        let bad = try XCTUnwrap(donor.record.presentation?.id)
        try donor.reveal(token: bad, now: now.addingTimeInterval(1))
        try donor.grade(remembered: false, token: bad, now: now.addingTimeInterval(2))
        let transfer = try XCTUnwrap(donor.transferState(for: "handbook:0", sourceScope: "synthetic"))
        XCTAssertNotEqual(transfer.stageMask, 0)

        let receiver = try ProfessionalRecallEngine.fresh(deck: deck, now: now, initiallyActive: false)
        let one = RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: [deck.cards[1]])
        try receiver.reconcile(to: one, now: now.addingTimeInterval(3))
        try receiver.start(day: day, now: now.addingTimeInterval(4))
        let both = RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: [deck.cards[0], deck.cards[1]])
        try receiver.reconcile(to: both, importing: ["handbook:0": transfer], now: now.addingTimeInterval(5))
        XCTAssertNotNil(receiver.record.deferredCards?["handbook:0"])
        let shown = try XCTUnwrap(receiver.record.presentation), index = try XCTUnwrap(receiver.record.cardIDs.firstIndex(of: shown.cardID))
        let card = p.cards[index], before = receiver.record
        let old = HandbookWordState(package: p, originalCardIDs: p.cards.map(\.id), word: before,
                                    frozenCard: card, frozenToken: shown.id, frozenGuide: p.memoryGuide(for: card))
        XCTAssertThrowsError(try HandbookDualFSRS(legacy: old, now: now.addingTimeInterval(6)))
        XCTAssertEqual(receiver.record, before)
        XCTAssertNotNil(receiver.record.deferredCards?["handbook:0"])
    }
}
