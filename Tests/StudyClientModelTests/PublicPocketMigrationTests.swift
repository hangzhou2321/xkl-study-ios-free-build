import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

/// Purely synthetic migration checks: no private bank or phone records.
final class PublicPocketMigrationTests: XCTestCase {
    private let bankHash = PublicQuestionDualFixtures.hash
    private let base = PublicQuestionDualFixtures.now

    private struct Envelope: Codable {
        var format = "xkl-ios-public-dual-store-v1"
        let bankSHA256: String
        let state: PublicQuestionDualState
    }

    @MainActor private func dual(_ old: ExamLearningEngine, bank: ExamBank,
                                 now: Date) throws -> (PublicQuestionDualFSRS, Data) {
        let anchor = try JSONEncoder().encode(old.record)
        let capture = try PublicDualLegacyCapture.read(snapshot: old.record.snapshot,
                                                        bankCount: bank.questions.count, now: now)
        return (try PublicQuestionDualFSRS(migrating: bank, hash: bankHash, record: old.record,
            legacyRecordBytes: anchor, priorVolumeBytes: [], legacyTokens: capture.tokens,
            legacyItems: capture.items, now: now), anchor)
    }

    @MainActor private func migrate(_ source: PublicQuestionDualFSRS, bank: ExamBank,
                                    anchor: Data, now: Date) throws -> PublicPocketMigrationPlan {
        let raw = try JSONEncoder().encode(Envelope(bankSHA256: bankHash, state: source.state))
        return try PublicPocketMigration.prepare(bank: bank, hash: bankHash, source: source.state,
            sourceDualBytes: raw, anchorBytes: anchor, priorVolumeBytes: [], now: now)
    }

    @MainActor func testLargeUnfinishedTaskAndCurrentQuestionArePreserved() async throws {
        let bank = PublicQuestionDualFixtures.bank(292)
        let old = try PublicQuestionDualFixtures.legacyWithDue(bank, dueCount: 267)
        let (source, anchor) = try dual(old, bank: bank, now: base)
        let oldState = source.state, oldSnapshot = old.record.snapshot
        let migrated = try migrate(source, bank: bank, anchor: anchor, now: base.addingTimeInterval(1))
        XCTAssertEqual(migrated.questionIDs, bank.questions.map(\.id))
        XCTAssertEqual(migrated.initialObligations.count, 292)
        XCTAssertEqual(migrated.parkedObligations.count, 272)
        XCTAssertEqual(migrated.record.presentation, oldState.presentation)
        XCTAssertTrue(migrated.record.attempts.isEmpty)
        let pocket = try PocketEngine(snapshot: migrated.record.snapshot)
        let events = try pocket.events(from: 1)
        XCTAssertFalse(events.contains { [UInt32(5), 6, 7, 8, 10].contains($0.kind) })
        XCTAssertEqual(source.state, oldState)
        XCTAssertEqual(old.record.snapshot, oldSnapshot)
        let slots = try PublicQuestionDualFixtures.slots(snapshot: migrated.record.snapshot, count: 292)
        for item in migrated.parkedObligations { XCTAssertEqual(slots[Int(item.word)].packed, 0x50ffff) }
        let engine = try ExamLearningEngine(bank: bank, hash: bankHash, record: migrated.record)
        XCTAssertEqual(engine.currentQuestion?.id, source.currentQuestion?.id)
    }

    @MainActor func testRealDualAnswersStayInSourceAndAreNotFabricatedInPocket() async throws {
        let bank = PublicQuestionDualFixtures.bank(5)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let (source, anchor) = try dual(old, bank: bank, now: base.addingTimeInterval(1))
        let first = try XCTUnwrap(source.presentation)
        try source.selectAndSubmit("A", presentationID: first.id, now: base.addingTimeInterval(2))
        try source.nextQuestion(presentationID: first.id, now: base.addingTimeInterval(3))
        let second = try XCTUnwrap(source.presentation)
        try source.selectAndSubmit("B", presentationID: second.id, now: base.addingTimeInterval(4))
        let result = try XCTUnwrap(source.answerReview)
        let current = try XCTUnwrap(source.presentation)
        let before = source.state
        let migrated = try migrate(source, bank: bank, anchor: anchor, now: base.addingTimeInterval(5))
        XCTAssertEqual(migrated.bridgeReview, result)
        XCTAssertEqual(migrated.record.presentation, current)
        XCTAssertEqual(migrated.record.taskID, source.state.taskID)
        XCTAssertTrue(migrated.record.attempts.isEmpty)
        XCTAssertEqual(source.state.events.filter { $0.kind == "answer" }.count, 2)
        XCTAssertEqual(source.state, before)
        let firstWord = try XCTUnwrap(bank.questions.firstIndex { $0.id == first.questionID })
        let secondWord = try XCTUnwrap(bank.questions.firstIndex { $0.id == second.questionID })
        XCTAssertNotEqual(migrated.mappedCards[firstWord] & (1 << 20), 0)
        XCTAssertEqual((migrated.mappedCards[secondWord] >> 16) & 15, 1)
        let restored = try ExamLearningEngine(bank: bank, hash: bankHash, record: migrated.record)
        XCTAssertEqual(restored.currentQuestion?.id, current.questionID)
    }

    @MainActor func testOriginalWrongStagesAreCarriedWithoutNewScores() async throws {
        let bank = PublicQuestionDualFixtures.bank(8)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let first = try XCTUnwrap(old.record.presentation)
        try old.selectAndSubmit("B", presentationID: first.id, now: base.addingTimeInterval(1))
        try old.nextQuestion(presentationID: first.id, now: base.addingTimeInterval(2))
        let (source, anchor) = try dual(old, bank: bank, now: base.addingTimeInterval(3))
        let migrated = try migrate(source, bank: bank, anchor: anchor, now: base.addingTimeInterval(4))
        let oldItem = try XCTUnwrap(source.state.legacyItems.first { bank.questions[Int($0.word)].id == first.questionID })
        let transferred = try XCTUnwrap(migrated.initialObligations.first { $0.questionID == first.questionID })
        XCTAssertEqual(UInt32(transferred.stages), oldItem.stageMask)
        XCTAssertEqual(UInt32(transferred.failedRound), oldItem.failedRound)
        let slots = try PublicQuestionDualFixtures.slots(snapshot: migrated.record.snapshot, count: 8)
        XCTAssertEqual(slots[Int(transferred.word)].pendingStageMask, oldItem.stageMask)
        let captured = try PublicDualLegacyCapture.read(snapshot: migrated.record.snapshot,
            bankCount: bank.questions.count, now: base.addingTimeInterval(4))
        let firstRound = Array(captured.tokens.prefix(source.state.queue.count)).map(\.word)
        XCTAssertEqual(Set(firstRound).count, source.state.queue.count)
        XCTAssertEqual(firstRound.first, source.state.queue.first.flatMap { id in
            bank.questions.firstIndex(where: { $0.id == id }).map(UInt32.init)
        })
        XCTAssertTrue(migrated.record.attempts.isEmpty)
        XCTAssertEqual(source.state.legacyAttempts.count, 1)
    }

    @MainActor func testQueueReorderRejectsInvalidPermutationsAtomically() async throws {
        let bank = PublicQuestionDualFixtures.bank(5)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: bankHash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let (source, anchor) = try dual(old, bank: bank, now: base.addingTimeInterval(1))
        let migrated = try migrate(source, bank: bank, anchor: anchor, now: base.addingTimeInterval(2))
        let pointer = try XCTUnwrap(migrated.record.snapshot.withUnsafeBytes {
            xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        })
        defer { xkl_engine_free(pointer) }
        func snapshot() throws -> Data {
            var data = Data(count: xkl_engine_snapshot_size(pointer))
            let count = data.withUnsafeMutableBytes { xkl_engine_snapshot(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            XCTAssertEqual(count, data.count); return data
        }
        var order = try PublicPocketMigration.interleavedTokens(migrated.initialObligations,
                                                                 legacyTokens: source.state.legacyTokens)
        XCTAssertGreaterThanOrEqual(order.count, 3)
        let original = try snapshot(), clock = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000) + 1_000_000
        var duplicate = order; duplicate[1] = duplicate[0]
        XCTAssertFalse(duplicate.withUnsafeBufferPointer {
            xkl_engine_reorder_question_migration(pointer, $0.baseAddress, UInt32($0.count), clock)
        })
        XCTAssertEqual(try snapshot(), original)
        XCTAssertTrue(xkl_engine_reveal(pointer, clock + 1))
        let revealed = try snapshot()
        order.swapAt(0, 1)
        XCTAssertFalse(order.withUnsafeBufferPointer {
            xkl_engine_reorder_question_migration(pointer, $0.baseAddress, UInt32($0.count), clock + 2)
        })
        XCTAssertEqual(try snapshot(), revealed)
        order.swapAt(0, 1); order.swapAt(1, 2)
        XCTAssertTrue(order.withUnsafeBufferPointer {
            xkl_engine_reorder_question_migration(pointer, $0.baseAddress, UInt32($0.count), clock + 3)
        })
        var info = xkl_info_t(); XCTAssertTrue(xkl_engine_info(pointer, &info)); XCTAssertEqual(info.revealed, 1)
        let pocket = try PocketEngine(snapshot: snapshot())
        XCTAssertFalse(try pocket.events(from: 1).contains { [UInt32(5), 6, 7, 8, 10].contains($0.kind) })
    }

    @MainActor func testParkedTasksCanContinueWithoutFabricatedGrades() async throws {
        let bank = PublicQuestionDualFixtures.bank(292)
        let old = try PublicQuestionDualFixtures.legacyWithDue(bank, dueCount: 267)
        let (source, anchor) = try dual(old, bank: bank, now: base)
        let migration = try migrate(source, bank: bank, anchor: anchor, now: base.addingTimeInterval(1))
        let engine = try ExamLearningEngine(bank: bank, hash: bankHash, record: migration.record)
        var completed = 0
        while try engine.info.has_task != 0 {
            let p = try XCTUnwrap(engine.record.presentation)
            try engine.selectAndSubmit("A", presentationID: p.id, now: base.addingTimeInterval(Double(completed + 2)))
            try engine.nextQuestion(presentationID: p.id, now: base.addingTimeInterval(Double(completed + 2)))
            completed += 1
            XCTAssertLessThan(completed, 50)
        }
        XCTAssertEqual(completed, 20)
        let before = engine.record.attempts
        let next = Array(migration.parkedObligations.prefix(20))
        try engine.admitParked(next, mappedCards: migration.mappedCards,
                               legacyTokens: source.state.legacyTokens, now: base.addingTimeInterval(86_500))
        XCTAssertEqual(engine.record.attempts, before)
        XCTAssertEqual(try engine.info.day, PublicQuestionDualFixtures.day + 1)
        XCTAssertEqual(try engine.info.selection_day, PublicQuestionDualFixtures.day + 1)
        XCTAssertEqual(engine.currentQuestion?.id, next.first?.questionID)
        let slots = try PublicQuestionDualFixtures.slots(snapshot: engine.record.snapshot, count: 292)
        for item in migration.parkedObligations.dropFirst(20) {
            XCTAssertEqual(slots[Int(item.word)].packed, 0x50ffff)
        }
        let restored = try ExamLearningEngine(bank: bank, hash: bankHash, record: engine.record)
        XCTAssertEqual(restored.record.presentation, engine.record.presentation)
        XCTAssertEqual(restored.record.attempts, before)
    }
}
