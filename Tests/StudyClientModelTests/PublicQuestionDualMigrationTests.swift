import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Synthetic-only migration and replay checks; these use neither actual user
/// history nor a real question bank.
final class PublicQuestionDualMigrationTests: XCTestCase {
    private let bankHash = PublicQuestionDualFixtures.hash
    private let base = PublicQuestionDualFixtures.now

    @MainActor private func migrate(_ legacy: ExamLearningEngine, _ bank: ExamBank,
                                    at: Date, volumes: [Data] = []) throws -> (PublicQuestionDualFSRS, Data) {
        let bytes = try JSONEncoder().encode(legacy.record)
        let captured = try PublicDualLegacyCapture.read(snapshot: legacy.record.snapshot,
                                                         bankCount: bank.questions.count, now: at)
        let dual = try PublicQuestionDualFSRS(migrating: bank, hash: bankHash, record: legacy.record,
            legacyRecordBytes: bytes, priorVolumeBytes: volumes, legacyTokens: captured.tokens,
            legacyItems: captured.items, now: at)
        return (dual, bytes)
    }

    private func milliseconds(_ at: Date) -> Int64 { Int64(at.timeIntervalSince1970 * 1_000) }

    @MainActor private func withFutureDue(_ bank: ExamBank) throws -> ExamLearningEngine {
        let day = PublicQuestionDualFixtures.day
        let packed: [UInt32] = bank.questions.indices.map { i in
            if i < 25 { return 0 }
            let due = i < 292 ? day - 1 : day + 1
            return (1 << 20) | (1 << 16) | due
        }
        var stream = UUID().uuid
        let handle = try XCTUnwrap(withUnsafeBytes(of: &stream) { raw in
            packed.withUnsafeBufferPointer { cards in
                xkl_engine_import_cards(UInt32(cards.count), cards.baseAddress, day, UInt32.max,
                                        raw.bindMemory(to: UInt8.self).baseAddress)
            }
        })
        defer { xkl_engine_free(handle) }
        var snapshot = Data(count: xkl_engine_snapshot_size(handle))
        let written = snapshot.withUnsafeMutableBytes {
            xkl_engine_snapshot(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        XCTAssertEqual(written, snapshot.count)
        let pocket = try PocketEngine(snapshot: snapshot)
        var record = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base).record
        record.snapshot = snapshot; record.snapshotSHA256 = StudySHA256.hex(snapshot)
        record.analysis = StudyAnalysisSettings(streamID: try pocket.streamID, nextSequence: 1, now: base)
        let legacy = try ExamLearningEngine(bank: bank, hash: bankHash, record: record)
        try legacy.start(day: day, now: base)
        return legacy
    }

    @MainActor func testAll292PendingItemsSurvivePagingAndRestarts() async throws {
        let bank = PublicQuestionDualFixtures.bank(292)
        let old = try PublicQuestionDualFixtures.legacyWithDue(bank, dueCount: 267)
        let snapshot = old.record.snapshot, oldPresentation = old.record.presentation
        let capture = try PublicDualLegacyCapture.read(snapshot: snapshot, bankCount: 292, now: base)
        XCTAssertEqual(capture.items.count, 292)
        let ids = capture.items.map { bank.questions[Int($0.word)].id }
        XCTAssertEqual(Set(ids).count, 292)
        var (dual, bytes) = try migrate(old, bank, at: base)
        XCTAssertEqual(dual.state.legacyIDs, bank.questions.map(\.id))
        XCTAssertEqual(dual.state.legacyAnchorSHA256, StudySHA256.hex(bytes))
        XCTAssertEqual(dual.state.legacyTokens, capture.tokens)
        XCTAssertEqual(dual.state.legacyItems, capture.items)
        XCTAssertEqual(dual.state.initialCarry, ids)
        XCTAssertEqual(dual.presentation, oldPresentation)
        XCTAssertEqual(dual.state.queue, Array(ids.prefix(20)))
        XCTAssertTrue(dual.state.events.isEmpty)
        XCTAssertTrue(dual.state.daily.isEmpty)
        XCTAssertTrue(dual.state.all.isEmpty)
        let slots = try PublicQuestionDualFixtures.slots(snapshot: snapshot, count: 292)
        for (i, q) in bank.questions.enumerated() { XCTAssertEqual(dual.state.legacyPacked[q.id], slots[i].packed) }
        try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        var completed: [String] = []
        for i in 0..<292 {
            let at = base.addingTimeInterval(Double(2 * i + 1))
            if dual.presentation == nil { try dual.start(now: at) }
            XCTAssertLessThanOrEqual(dual.state.queue.count, 20)
            let p = try XCTUnwrap(dual.presentation)
            XCTAssertEqual(p.questionID, ids[i])
            completed.append(p.questionID)
            try dual.selectAndSubmit("A", presentationID: p.id, now: at)
            try dual.nextQuestion(presentationID: p.id, now: at)
            if i % 20 == 19 {
                let saved = try JSONEncoder().encode(dual.state)
                dual = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self, from: saved),
                                                  bank: bank, hash: bankHash)
                try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
            }
        }
        XCTAssertEqual(completed, ids)
        XCTAssertTrue(dual.state.carry.isEmpty)
        XCTAssertEqual(dual.state.events.filter { $0.kind == "answer" }.count, 292)
        XCTAssertEqual(old.record.snapshot, snapshot)
        XCTAssertTrue(old.record.attempts.isEmpty)
    }

    @MainActor func testPartialMultipleSelectionSurvivesAndStrictSubsetIsWrong() async throws {
        let bank = PublicQuestionDualFixtures.bank(30, kind: .multiple)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        try old.toggle("A")
        let oldPresentation = try XCTUnwrap(old.record.presentation)
        let (dual, bytes) = try migrate(old, bank, at: base.addingTimeInterval(1))
        XCTAssertEqual(dual.presentation, oldPresentation)
        XCTAssertTrue(dual.state.events.isEmpty)
        let saved = try JSONEncoder().encode(dual.state)
        let resumed = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self, from: saved),
                                                 bank: bank, hash: bankHash)
        try resumed.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        let at = base.addingTimeInterval(2)
        try resumed.submitAutomatically(presentationID: oldPresentation.id, now: at)
        let scored = try XCTUnwrap(resumed.answerReview?.attempt)
        XCTAssertEqual(scored.selectedOptions, ["A"])
        XCTAssertFalse(scored.isCorrect)
        XCTAssertEqual(scored.grade, 1)
        XCTAssertEqual(scored.gradedAt, at)
        let day = UInt32(try ConceptCalendar.studyDay(at))
        let again = try FSRS6Shadow.review(nil, day: day, rating: 1, timestampMs: milliseconds(at)).memory
        XCTAssertEqual(resumed.state.daily[scored.questionID], again)
        XCTAssertEqual(resumed.state.all[scored.questionID], again)
        let once = resumed.state
        try resumed.submitAutomatically(presentationID: oldPresentation.id, now: at)
        XCTAssertEqual(resumed.state, once)
    }

    @MainActor func testLegacyResultAndNextQuestionAndOldUndoSurvive() async throws {
        let bank = PublicQuestionDualFixtures.bank(1)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let first = try XCTUnwrap(old.presentationOrNil)
        try old.selectAndSubmit("A", presentationID: first.id, now: base.addingTimeInterval(1))
        let review = try XCTUnwrap(old.record.answerReview)
        let next = try XCTUnwrap(old.record.presentation)
        let (dual, bytes) = try migrate(old, bank, at: base.addingTimeInterval(2))
        XCTAssertEqual(dual.answerReview, review)
        XCTAssertEqual(dual.presentation, next)
        XCTAssertEqual(dual.state.legacyAttempts.count, 1)
        XCTAssertTrue(dual.state.events.isEmpty)
        let resumed = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self,
            from: JSONEncoder().encode(dual.state)), bank: bank, hash: bankHash)
        try resumed.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        try resumed.selectAndSubmit("A", presentationID: first.id, now: base.addingTimeInterval(3))
        XCTAssertTrue(resumed.state.events.isEmpty)
        try resumed.nextQuestion(presentationID: first.id, now: base.addingTimeInterval(3))
        XCTAssertNil(resumed.answerReview)
        XCTAssertEqual(resumed.presentation, next)
        XCTAssertEqual(resumed.canUndoLegacy, old.record.lastUndoableAttemptID != nil)
    }

    @MainActor func testHistoryUsesGradeTimeAndSameDayFirstVsAll() async throws {
        let bank = PublicQuestionDualFixtures.bank(1)
        let startOfDay = Calendar.current.startOfDay(for: base)
        let midnight = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: startOfDay))
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: midnight.addingTimeInterval(-5))
        let firstDay = UInt32(try ConceptCalendar.studyDay(midnight.addingTimeInterval(-5)))
        let nextDay = UInt32(try ConceptCalendar.studyDay(midnight.addingTimeInterval(1)))
        try old.start(day: firstDay, now: midnight.addingTimeInterval(-5))
        try old.toggle("B")
        try old.submit(now: midnight.addingTimeInterval(-2))
        try old.start(day: nextDay, now: midnight.addingTimeInterval(1))
        try old.confirm(1, now: midnight.addingTimeInterval(1))
        let wrong = try XCTUnwrap(old.record.attempts.last)
        let next = try XCTUnwrap(old.record.presentation)
        try old.selectAndSubmit("A", presentationID: next.id, now: midnight.addingTimeInterval(2))
        let correct = try XCTUnwrap(old.record.attempts.last)
        XCTAssertNotEqual(try ConceptCalendar.studyDay(wrong.answeredAt), try ConceptCalendar.studyDay(try XCTUnwrap(wrong.gradedAt)))
        let (dual, bytes) = try migrate(old, bank, at: midnight.addingTimeInterval(3))
        XCTAssertEqual(dual.state.legacyRatings.map(\.day), [nextDay, nextDay])
        XCTAssertEqual(dual.state.legacyRatings.map(\.at), [wrong.gradedAt!, correct.gradedAt!])
        let expectedDaily = try FSRS6Shadow.review(nil, day: nextDay, rating: 1,
            timestampMs: milliseconds(wrong.gradedAt!)).memory
        let expectedAll = try FSRS6Shadow.review(expectedDaily, day: nextDay, rating: 3,
            timestampMs: milliseconds(correct.gradedAt!)).memory
        XCTAssertEqual(dual.state.daily[wrong.questionID], expectedDaily)
        XCTAssertEqual(dual.state.all[wrong.questionID], expectedAll)
        try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
    }

    @MainActor func testNewUndoPreservesAuditTrailAndDoesNotChangeLegacy() async throws {
        let bank = PublicQuestionDualFixtures.bank(2)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let (dual, bytes) = try migrate(old, bank, at: base.addingTimeInterval(1))
        let beforeDaily = dual.state.daily, beforeAll = dual.state.all, beforeCarry = dual.state.carry
        let p = try XCTUnwrap(dual.presentation)
        try dual.selectAndSubmit("A", presentationID: p.id, now: base.addingTimeInterval(2))
        let realAttempt = try XCTUnwrap(dual.answerReview?.attempt)
        try dual.nextQuestion(presentationID: p.id, now: base.addingTimeInterval(3))
        XCTAssertTrue(dual.canUndo)
        try dual.undo(now: base.addingTimeInterval(4))
        XCTAssertEqual(dual.state.daily, beforeDaily)
        XCTAssertEqual(dual.state.all, beforeAll)
        XCTAssertEqual(dual.state.carry, beforeCarry)
        XCTAssertEqual(dual.state.events.filter { $0.kind == "answer" }.count, 1)
        XCTAssertEqual(dual.state.events.last?.attempt?.undoneAttemptID, realAttempt.id)
        XCTAssertEqual(dual.presentation?.questionID, p.questionID)
        try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        _ = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self,
            from: JSONEncoder().encode(dual.state)), bank: bank, hash: bankHash)
    }

    @MainActor func testArchivedVolumeRemainsVerifiableAndMissingOrAlteredVolumeFails() async throws {
        let bank = PublicQuestionDualFixtures.bank(2)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let p = try XCTUnwrap(old.record.presentation)
        try old.selectAndSubmit("B", presentationID: p.id, now: base.addingTimeInterval(1))
        try old.nextQuestion(presentationID: p.id, now: base.addingTimeInterval(2))
        let archive = try JSONEncoder().encode(old.record)
        let digest = StudySHA256.hex(archive)
        let info = try old.info
        try old.rotate(reference: ExamVolumeReference(filename: digest + ".json", sha256: digest,
            firstSequence: old.logBase + 1, lastSequence: info.log_records, attemptCount: old.record.attempts.count))
        let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
        let source = try canonical.encode(old.record)
        let (dual, bytes) = try migrate(old, bank, at: base.addingTimeInterval(3), volumes: [archive])
        XCTAssertEqual(dual.state.legacyAttempts.count, 1)
        XCTAssertEqual(dual.state.legacyRatings.count, 1)
        try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [archive])
        XCTAssertThrowsError(try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: []))
        var altered = archive; altered.append(0)
        XCTAssertThrowsError(try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [altered]))
        XCTAssertEqual(try canonical.encode(old.record), source)
    }

    @MainActor func testNextPageBalancesOldCarryAndNewlyDueWithoutLosingEither() async throws {
        let bank = PublicQuestionDualFixtures.bank(312)
        let old = try withFutureDue(bank)
        let (dual, bytes) = try migrate(old, bank, at: base)
        XCTAssertEqual(dual.state.carry.count, 292)
        for i in 0..<20 {
            let p = try XCTUnwrap(dual.presentation)
            let at = base.addingTimeInterval(Double(i + 1))
            try dual.selectAndSubmit("A", presentationID: p.id, now: at)
            try dual.nextQuestion(presentationID: p.id, now: at)
        }
        let carryBefore = dual.state.carry
        XCTAssertEqual(carryBefore.count, 272)
        XCTAssertNil(dual.presentation)
        let tomorrow = base.addingTimeInterval(86_400)
        try dual.start(now: tomorrow)
        XCTAssertEqual(dual.state.queue.count, 20)
        let future = Set(bank.questions[292..<312].map(\.id))
        XCTAssertEqual(dual.state.queue.filter { future.contains($0) }.count, 10)
        XCTAssertEqual(dual.state.queue.filter { carryBefore.contains($0) }.count, 10)
        XCTAssertEqual(dual.state.carry, carryBefore)
        let state = try JSONDecoder().decode(PublicQuestionDualState.self, from: JSONEncoder().encode(dual.state))
        let resumed = try PublicQuestionDualFSRS(state: state, bank: bank, hash: bankHash)
        XCTAssertEqual(resumed.state.queue, dual.state.queue)
        XCTAssertEqual(resumed.state.carry, carryBefore)
        try resumed.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        let before = resumed.state
        try resumed.start(now: tomorrow.addingTimeInterval(1))
        XCTAssertEqual(resumed.state, before)
    }

    @MainActor func testOptionalWrongRetryWaitsTenMinutesAndDoesNotTouchDailyAcrossMidnight() async throws {
        let midnight = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: base)))
        let start = midnight.addingTimeInterval(-1_220)
        let bank = PublicQuestionDualFixtures.bank(1)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: start)
        try old.start(day: UInt32(try ConceptCalendar.studyDay(start)), now: start)
        let (dual, bytes) = try migrate(old, bank, at: start.addingTimeInterval(1))
        let first = try XCTUnwrap(dual.presentation)
        let scoredAt = midnight.addingTimeInterval(-1_201)
        try dual.selectAndSubmit("B", presentationID: first.id, now: scoredAt)
        let firstState = dual.state
        try dual.startRetry(now: scoredAt.addingTimeInterval(600)) // result page still visible
        XCTAssertEqual(dual.state, firstState)
        try dual.nextQuestion(presentationID: first.id, now: scoredAt)
        let daily = dual.state.daily, all = dual.state.all
        let tooSoon = scoredAt.addingTimeInterval(599)
        try dual.startRetry(now: tooSoon)
        XCTAssertNil(dual.presentation)
        XCTAssertEqual(try dual.stats(now: tooSoon).retryAvailable, 0)
        let ready = scoredAt.addingTimeInterval(600)
        XCTAssertEqual(try dual.stats(now: ready).retryAvailable, 1)
        try dual.startRetry(now: ready)
        XCTAssertEqual(dual.state.roundKind, "retry")
        let retry = try XCTUnwrap(dual.presentation)
        XCTAssertEqual(retry.questionID, first.questionID)
        let active = dual.state
        try dual.startRetry(now: ready)
        XCTAssertEqual(dual.state, active)
        let answeredAfterMidnight = midnight.addingTimeInterval(1)
        XCTAssertNotEqual(try ConceptCalendar.studyDay(scoredAt), try ConceptCalendar.studyDay(answeredAfterMidnight))
        try dual.selectAndSubmit("A", presentationID: retry.id, now: answeredAfterMidnight)
        XCTAssertEqual(dual.state.daily, daily)
        XCTAssertNotEqual(dual.state.all, all)
        XCTAssertEqual(dual.state.events.filter { $0.kind == "answer" }.count, 2)
        try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        let restored = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self,
            from: JSONEncoder().encode(dual.state)), bank: bank, hash: bankHash)
        XCTAssertEqual(restored.state.daily, daily)
        XCTAssertEqual(restored.state.all, dual.state.all)
    }

    @MainActor func testTimeZoneChangeReplaysOldAndNewEventsAndRejectsTampering() async throws {
        func day(_ at: Date, zone: TimeZone) throws -> UInt32 {
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let midnight = try XCTUnwrap(utc.date(from: local.dateComponents([.year, .month, .day], from: at)))
            return UInt32(midnight.timeIntervalSince1970 / 86_400)
        }
        let bank = PublicQuestionDualFixtures.bank(2)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: UInt32(try ConceptCalendar.studyDay(base)), now: base)
        let oldP = try XCTUnwrap(old.record.presentation)
        try old.selectAndSubmit("B", presentationID: oldP.id, now: base.addingTimeInterval(1))
        try old.nextQuestion(presentationID: oldP.id, now: base.addingTimeInterval(2))
        let (dual, bytes) = try migrate(old, bank, at: base.addingTimeInterval(3))
        let before = dual.state
        let p = try XCTUnwrap(dual.presentation)
        let ratedAt = base.addingTimeInterval(2 * 86_400 + 8 * 3_600)
        try dual.selectAndSubmit("A", presentationID: p.id, now: ratedAt)
        var expected = dual.state
        let e = try XCTUnwrap(expected.events.last)
        let candidates = [TimeZone(identifier: "Asia/Shanghai")!, TimeZone(identifier: "America/Los_Angeles")!]
        let savedZone = try XCTUnwrap(candidates.first { (try? day(ratedAt, zone: $0)) != e.day })
        let savedDay = try day(ratedAt, zone: savedZone)
        XCTAssertNotEqual(savedDay, e.day)
        expected.events[expected.events.count - 1] = PublicDualEvent(sequence: e.sequence, kind: e.kind,
            at: e.at, day: savedDay, timeZoneID: savedZone.identifier, round: e.round, attempt: e.attempt)
        expected.daily[p.questionID] = try FSRS6Shadow.review(before.daily[p.questionID], day: savedDay,
            rating: 3, timestampMs: milliseconds(ratedAt)).memory
        expected.all[p.questionID] = try FSRS6Shadow.review(before.all[p.questionID], day: savedDay,
            rating: 3, timestampMs: milliseconds(ratedAt)).memory
        expected.lastRating[p.questionID] = PublicDualLastRating(day: savedDay, at: ratedAt, remembered: true)
        let saved = try JSONEncoder().encode(expected)
        let resumed = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self, from: saved),
                                                 bank: bank, hash: bankHash)
        XCTAssertEqual(resumed.state.daily, expected.daily)
        XCTAssertEqual(resumed.state.all, expected.all)
        try resumed.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var events = try XCTUnwrap(obj["events"] as? [[String: Any]])
        var event = try XCTUnwrap(events.last)
        event["day"] = (event["day"] as! Int) + 1
        events[events.count - 1] = event; obj["events"] = events
        let badDay = try JSONSerialization.data(withJSONObject: obj)
        let bad = try JSONDecoder().decode(PublicQuestionDualState.self, from: badDay)
        XCTAssertThrowsError(try PublicQuestionDualFSRS(state: bad, bank: bank, hash: bankHash))
        event["timeZoneID"] = "Not/A_Real_Time_Zone"
        events[events.count - 1] = event; obj["events"] = events
        let badZone = try JSONDecoder().decode(PublicQuestionDualState.self,
            from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertThrowsError(try PublicQuestionDualFSRS(state: badZone, bank: bank, hash: bankHash))
    }

    @MainActor func testImportedKnownWithoutScoresIsReviewableButFutureDueIsNotEarly() async throws {
        let bank = PublicQuestionDualFixtures.bank(2)
        let day = PublicQuestionDualFixtures.day
        let packed: [UInt32] = [(1 << 20) | UInt32(UInt16.max), (1 << 20) | (1 << 16) | (day + 1)]
        var stream = UUID().uuid
        let handle = try XCTUnwrap(withUnsafeBytes(of: &stream) { raw in
            packed.withUnsafeBufferPointer { cards in
                xkl_engine_import_cards(UInt32(cards.count), cards.baseAddress, day, UInt32.max,
                                        raw.bindMemory(to: UInt8.self).baseAddress)
            }
        })
        defer { xkl_engine_free(handle) }
        var snapshot = Data(count: xkl_engine_snapshot_size(handle))
        let written = snapshot.withUnsafeMutableBytes {
            xkl_engine_snapshot(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        XCTAssertEqual(written, snapshot.count)
        let pocket = try PocketEngine(snapshot: snapshot)
        var record = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base).record
        record.snapshot = snapshot; record.snapshotSHA256 = StudySHA256.hex(snapshot)
        record.analysis = StudyAnalysisSettings(streamID: try pocket.streamID, nextSequence: 1, now: base)
        let old = try ExamLearningEngine(bank: bank, hash: bankHash, record: record)
        let (dual, bytes) = try migrate(old, bank, at: base)
        XCTAssertTrue(dual.state.legacyRatings.isEmpty)
        XCTAssertTrue(dual.state.legacyAttempts.isEmpty)
        XCTAssertTrue(dual.state.daily.isEmpty)
        XCTAssertTrue(dual.state.all.isEmpty)
        try dual.start(now: base.addingTimeInterval(1))
        XCTAssertEqual(dual.state.queue, [bank.questions[0].id])
        XCTAssertFalse(dual.state.queue.contains(bank.questions[1].id))
        XCTAssertTrue(dual.state.daily.isEmpty) // opening a review does not create a score
        XCTAssertTrue(dual.state.all.isEmpty)
        try dual.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
    }

    @MainActor func testActualTimeZoneChangeDoesNotRewriteMigratedHistory() async throws {
        let oldEnv = getenv("TZ").map { String(cString: $0) }
        defer {
            if let oldEnv { setenv("TZ", oldEnv, 1) } else { unsetenv("TZ") }
            tzset(); NSTimeZone.resetSystemTimeZone()
        }
        setenv("TZ", "Asia/Shanghai", 1); tzset(); NSTimeZone.resetSystemTimeZone()
        XCTAssertEqual(TimeZone.current.identifier, "Asia/Shanghai")
        let at = base.addingTimeInterval(8 * 3_600) // This instant is on different dates in the two zones.
        let bank = PublicQuestionDualFixtures.bank(2)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: at)
        try old.start(day: UInt32(try ConceptCalendar.studyDay(at)), now: at)
        let p = try XCTUnwrap(old.record.presentation)
        try old.selectAndSubmit("B", presentationID: p.id, now: at.addingTimeInterval(1))
        try old.nextQuestion(presentationID: p.id, now: at.addingTimeInterval(2))
        let (dual, bytes) = try migrate(old, bank, at: at.addingTimeInterval(3))
        let original = dual.state
        setenv("TZ", "America/Los_Angeles", 1); tzset(); NSTimeZone.resetSystemTimeZone()
        XCTAssertEqual(TimeZone.current.identifier, "America/Los_Angeles")
        XCTAssertNotEqual(UInt32(try ConceptCalendar.studyDay(at)), original.migratedDay)
        let restored = try PublicQuestionDualFSRS(state: JSONDecoder().decode(PublicQuestionDualState.self,
            from: JSONEncoder().encode(original)), bank: bank, hash: bankHash)
        try restored.validateLegacy(recordBytes: bytes, priorVolumeBytes: [])
        XCTAssertEqual(restored.state.legacyRatings, original.legacyRatings)
        XCTAssertEqual(restored.state.daily, original.daily)
        XCTAssertEqual(restored.state.all, original.all)
    }

    @MainActor func testRetryDoesNotStartForYesterdayWrongAnswer() async throws {
        let midnight = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: base)))
        let scoredAt = midnight.addingTimeInterval(-601)
        let bank = PublicQuestionDualFixtures.bank(1)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: scoredAt.addingTimeInterval(-2))
        try old.start(day: UInt32(try ConceptCalendar.studyDay(scoredAt)), now: scoredAt.addingTimeInterval(-2))
        let (dual, _) = try migrate(old, bank, at: scoredAt.addingTimeInterval(-1))
        let first = try XCTUnwrap(dual.presentation)
        try dual.selectAndSubmit("B", presentationID: first.id, now: scoredAt)
        try dual.nextQuestion(presentationID: first.id, now: scoredAt)
        let tomorrow = midnight.addingTimeInterval(1)
        XCTAssertEqual(try dual.stats(now: tomorrow).retryAvailable, 0)
        try dual.startRetry(now: tomorrow)
        XCTAssertNil(dual.presentation)
        XCTAssertEqual(dual.state.events.filter { $0.kind == "startRetry" }.count, 0)
    }
}

private extension ExamLearningEngine {
    var presentationOrNil: ExamPresentation? { record.presentation }
}
