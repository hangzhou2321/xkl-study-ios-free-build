import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

final class ProfessionalRecallEngineTests: XCTestCase {
    private let day: UInt32 = 20_750
    private func date(_ day: UInt32) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200) }
    private func deck(_ count: Int = 60) -> RecallDeck {
        RecallDeck(subject: .computer, bankID: ConceptSubject.computer.bankID, cards: (0..<count).map {
            RecallDeck.Item(conceptID: "synthetic-\($0 / 10)", conceptTitle: "Synthetic topic \($0 / 10)",
                card: RecallCard(id: "synthetic-\($0 / 10):card-\($0)", prompt: "Recall synthetic \($0)", answer: "Synthetic answer \($0)"))
        })
    }
    @MainActor private func compare(_ actual: ProfessionalRecallEngine, _ reference: PocketEngine,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try actual.info, b = try reference.info
        XCTAssertEqual(a.word, b.word, file: file, line: line)
        XCTAssertEqual(a.stage, b.stage, file: file, line: line)
        XCTAssertEqual(a.day, b.day, file: file, line: line)
        XCTAssertEqual(a.selection_day, b.selection_day, file: file, line: line)
        XCTAssertEqual(a.new_remaining, b.new_remaining, file: file, line: line)
        XCTAssertEqual(a.review_remaining, b.review_remaining, file: file, line: line)
        XCTAssertEqual(a.total_remaining, b.total_remaining, file: file, line: line)
        XCTAssertEqual(a.completed, b.completed, file: file, line: line)
        XCTAssertEqual(a.first_known, b.first_known, file: file, line: line)
        XCTAssertEqual(a.has_task, b.has_task, file: file, line: line)
        XCTAssertEqual(a.revealed, b.revealed, file: file, line: line)
        let bytes = try reference.snapshot()
        let raw = try XCTUnwrap(bytes.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
        defer { xkl_engine_free(raw) }
        for (index, id) in actual.record.cardIDs.enumerated() {
            XCTAssertEqual(try actual.packedCard(id: id), xkl_engine_card(raw, UInt32(index)), file: file, line: line)
        }
    }

    @MainActor func testExactWordPolicyParityForCorrectWrongRepeatedWrongAndCrossDay() async throws {
        let actual = try ProfessionalRecallEngine.fresh(deck: deck(), now: date(day))
        let reference = try PocketEngine(snapshot: actual.record.snapshot)
        var policy = actual.record.analysis
        XCTAssertTrue(policy.conservativeEnabled)
        try actual.start(day: day, now: date(day))
        try reference.start(day: day, preservingRevealedAnswer: true, preservingShownStepAcrossDay: true)
        var reset = false, seen = 0
        while try actual.info.has_task != 0 {
            try compare(actual, reference)
            let info = try actual.info
            let wrong = seen == 0 || (info.word == 0 && info.stage == 3 && !reset)
            if info.word == 0 && info.stage == 3 { reset = true }
            let token = try XCTUnwrap(actual.record.presentation?.id)
            try actual.reveal(token: token, now: date(day)); try reference.reveal()
            try actual.grade(remembered: !wrong, token: token, now: date(day))
            if let decision = try reference.answer(wrong ? 1 : 0, policy: policy) { policy.reductions.append(decision) }
            seen += 1; XCTAssertLessThan(seen, 120)
        }
        try compare(actual, reference)
        XCTAssertEqual(actual.record.analysis.reductions, policy.reductions)
        XCTAssertTrue(reset)
        try actual.start(day: day + 1, now: date(day + 1))
        try reference.start(day: day + 1, preservingRevealedAnswer: true, preservingShownStepAcrossDay: true)
        try compare(actual, reference)
        XCTAssertEqual(try actual.info.review_remaining, 1)
        let token = try XCTUnwrap(actual.record.presentation?.id)
        try actual.reveal(token: token, now: date(day + 1)); try reference.reveal()
        try actual.grade(remembered: false, token: token, now: date(day + 1))
        _ = try reference.answer(1, policy: policy)
        try compare(actual, reference)
    }

    @MainActor func testFirstKnownMatchesEnglishAndDoesNotInventQuestionCorrectness() async throws {
        let engine = try ProfessionalRecallEngine.fresh(deck: deck(2), now: date(day))
        try engine.start(day: day, now: date(day))
        let id = try XCTUnwrap(engine.currentItem?.id), token = try XCTUnwrap(engine.record.presentation?.id)
        XCTAssertThrowsError(try engine.grade(remembered: true, token: token, now: date(day)))
        XCTAssertTrue(engine.record.attempts.isEmpty)
        try engine.reveal(token: token, now: date(day))
        XCTAssertTrue(engine.record.attempts.isEmpty)
        try engine.grade(remembered: true, token: token, now: date(day))
        XCTAssertEqual(try engine.packedCard(id: id), 0x10ffff)
        XCTAssertEqual(try engine.stats(on: day).firstKnown, 1)
        XCTAssertEqual(engine.record.attempts.count, 1)
        let saved = engine.record
        try engine.grade(remembered: false, token: token, now: date(day))
        try engine.reveal(token: token, now: date(day))
        XCTAssertEqual(engine.record, saved)
        XCTAssertEqual(try engine.allEvents().filter(\.graded).count, 1)
    }

    @MainActor func testColdResumeAndCrossDayPreserveVisibleStepWithoutGrade() async throws {
        let original = try ProfessionalRecallEngine.fresh(deck: deck(), now: date(day))
        try original.start(day: day, now: date(day))
        let token = try XCTUnwrap(original.record.presentation?.id)
        try original.reveal(token: token, now: date(day))
        let old = original.record, before = try original.info
        let resumed = try ProfessionalRecallEngine(deck: original.deck, record: old)
        try resumed.start(day: day + 1, now: date(day + 1))
        XCTAssertEqual(resumed.record.presentation, old.presentation)
        XCTAssertEqual(try resumed.info.word, before.word)
        XCTAssertEqual(try resumed.info.completed, before.completed)
        XCTAssertTrue(resumed.record.attempts.isEmpty)
        XCTAssertTrue(try resumed.allEvents().allSatisfy { [UInt32(1), 2, 3, 4].contains($0.kind) })
        let stable = resumed.record
        try resumed.start(day: day + 1, now: date(day + 1))
        XCTAssertEqual(resumed.record, stable)
        try resumed.grade(remembered: true, token: token, now: date(day + 1))
        XCTAssertEqual(resumed.record.attempts.count, 1)
    }

    @MainActor func testMigrationPreservesLegacyRecordsDueAndVisibleCardWithoutSyntheticGrades() async throws {
        let source = deck(4)
        var old = try RecallEngine(deck: source)
        try old.act("start", day: Int(day), newLimit: 4, now: date(day))
        let first = try XCTUnwrap(old.record.state.shown)
        try old.act("reveal", day: Int(day), token: first.id, now: date(day))
        try old.act("grade", day: Int(day), token: first.id, remembered: false, now: date(day))
        try old.act("next", day: Int(day), token: first.id, now: date(day))
        let second = try XCTUnwrap(old.record.state.shown)
        try old.act("reveal", day: Int(day), token: second.id, now: date(day))
        let legacy = old.record
        let migrated = try ProfessionalRecallEngine.fresh(deck: source, legacy: [legacy], now: date(day))
        XCTAssertEqual(migrated.record.migration.sourceRecords, [legacy])
        XCTAssertTrue(migrated.record.attempts.isEmpty)
        XCTAssertTrue(try migrated.allEvents().isEmpty)
        let packed = try XCTUnwrap(migrated.packedCard(id: first.cardID))
        XCTAssertEqual(packed & 65_535, day + 1)
        XCTAssertEqual((packed >> 16) & 15, 1)
        XCTAssertEqual(migrated.record.migration.cards.first?.prior.level, 0)
        try migrated.start(day: day, now: date(day))
        XCTAssertEqual(migrated.record.presentation?.cardID, second.cardID)
        XCTAssertEqual(migrated.record.presentation?.id, second.id)
        XCTAssertEqual(migrated.record.presentation?.revealed, true)
        XCTAssertEqual(try migrated.stats(on: day).legacyForgotten, 1)
        XCTAssertEqual(try migrated.stats(on: day).forgotten, 0)
        XCTAssertEqual(old.record, legacy)
        _ = try ProfessionalRecallEngine(deck: source, record: migrated.record)
    }

    @MainActor func testOutOfScopeLegacyShownCannotBecomeMainlineHead() async throws {
        let all = deck(4)
        var old = try RecallEngine(deck: all)
        try old.act("start", day: Int(day), newLimit: 4, now: date(day))
        let scoped = RecallDeck(subject: all.subject, bankID: all.bankID, cards: Array(all.cards.dropFirst()))
        let mainline = try ProfessionalRecallEngine.fresh(deck: scoped, legacy: [old.record], now: date(day))
        XCTAssertNil(mainline.record.migration.resumedCardID)
        try mainline.start(day: day, now: date(day))
        XCTAssertEqual(mainline.currentItem?.id, scoped.cards.first?.id)
    }

    @MainActor func testNewerLegacyResultCannotBeRegradedByResurrectingOlderShownCard() async throws {
        let source = deck(4)
        var old = try RecallEngine(deck: source)
        try old.act("start", day: Int(day), newLimit: 4, now: date(day))
        let shown = try XCTUnwrap(old.record.state.shown)
        try old.act("reveal", day: Int(day), token: shown.id, now: date(day).addingTimeInterval(30))
        let stale = old.record
        // A same-day wall-clock correction cannot make the shorter prefix win.
        try old.act("grade", day: Int(day), token: shown.id, remembered: true, now: date(day).addingTimeInterval(10))
        let migrated = try ProfessionalRecallEngine.fresh(deck: source, legacy: [old.record, stale], now: date(day))
        XCTAssertNil(migrated.record.migration.resumedCardID)
        XCTAssertTrue(migrated.record.attempts.isEmpty)
        XCTAssertEqual(migrated.record.migration.sourceRecords, [old.record, stale])
        try migrated.start(day: day, now: date(day))
        XCTAssertNotEqual(migrated.currentItem?.id, shown.cardID)
        XCTAssertTrue(migrated.record.attempts.isEmpty)
    }

    @MainActor func testLegacyPendingForgottenRepairDoesNotBecomeNewOrAdvanceSameDay() async throws {
        let source = deck(4)
        var old = try RecallEngine(deck: source)
        try old.act("start", day: Int(day), newLimit: 4, now: date(day))
        let first = try XCTUnwrap(old.record.state.shown)
        for index in 0..<4 {
            let shown = try XCTUnwrap(old.record.state.shown)
            try old.act("reveal", day: Int(day), token: shown.id, now: date(day))
            try old.act("grade", day: Int(day), token: shown.id, remembered: index != 0, now: date(day))
            try old.act("next", day: Int(day), token: shown.id, now: date(day))
        }
        XCTAssertEqual(old.record.state.shown?.cardID, first.cardID)
        let migrated = try ProfessionalRecallEngine.fresh(deck: source, legacy: [old.record], now: date(day))
        try migrated.start(day: day, now: date(day))
        let token = try XCTUnwrap(migrated.record.presentation?.id)
        try migrated.reveal(token: token, now: date(day))
        try migrated.grade(remembered: true, token: token, now: date(day))
        let packed = try XCTUnwrap(migrated.packedCard(id: first.cardID))
        XCTAssertEqual((packed >> 16) & 15, 1)
        XCTAssertEqual(packed & 65_535, day + 1)
        XCTAssertEqual(try migrated.stats(on: day).firstKnown, 0)
    }

    @MainActor func testMetadataChangesKeepStateButMappingChangesFailClosed() async throws {
        let original = try ProfessionalRecallEngine.fresh(deck: deck(4), now: date(day))
        try original.start(day: day, now: date(day))
        var cards = original.deck.cards
        cards[0] = RecallDeck.Item(conceptID: cards[0].conceptID, conceptTitle: "Updated title",
            card: RecallCard(id: cards[0].id, prompt: "Updated prompt", answer: "Updated answer"))
        let updated = RecallDeck(subject: .computer, bankID: original.deck.bankID, cards: cards)
        let reopened = try ProfessionalRecallEngine(deck: updated, record: original.record)
        XCTAssertEqual(reopened.record, original.record)
        let reordered = RecallDeck(subject: .computer, bankID: updated.bankID, cards: Array(cards.reversed()))
        XCTAssertThrowsError(try ProfessionalRecallEngine(deck: reordered, record: original.record))
        var corrupt = original.record; corrupt.snapshot[0] ^= 1
        XCTAssertThrowsError(try ProfessionalRecallEngine(deck: original.deck, record: corrupt))
    }

    @MainActor func testRotationPreservesEveryAnswerAndPolicyEvidenceAcrossRestore() async throws {
        var actual = try ProfessionalRecallEngine.fresh(deck: deck(), now: date(day))
        try actual.start(day: day, now: date(day))
        var count = 0
        while try actual.info.has_task != 0 {
            let token = try XCTUnwrap(actual.record.presentation?.id)
            try actual.reveal(token: token, now: date(day))
            try actual.grade(remembered: count != 0, token: token, now: date(day))
            if count % 4 == 0 {
                let prefix = try actual.allEvents()
                try actual.rotateLog()
                XCTAssertEqual(try actual.allEvents(), prefix)
                actual = try ProfessionalRecallEngine(deck: actual.deck, record: actual.record)
                try actual.start(day: day, now: date(day))
            }
            count += 1; XCTAssertLessThan(count, 80)
        }
        XCTAssertGreaterThan(actual.record.volumes.count, 1)
        XCTAssertEqual(try actual.allEvents().filter(\.graded).count, actual.record.attempts.count)
        XCTAssertGreaterThan(actual.record.analysis.savedRepetitions, 0)
        _ = try ProfessionalRecallEngine(deck: actual.deck, record: actual.record)
    }

    @MainActor func testLongTermReviewUsesTenLevelsAndRepeatsLevelTenAt180Days() async throws {
        let engine = try ProfessionalRecallEngine.fresh(deck: deck(1), now: date(day))
        let id = engine.deck.cards[0].id
        var currentDay = day
        try engine.start(day: currentDay, now: date(currentDay))
        let first = try XCTUnwrap(engine.record.presentation?.id)
        try engine.reveal(token: first, now: date(currentDay))
        try engine.grade(remembered: false, token: first, now: date(currentDay))
        let gaps: [UInt32] = [0, 1, 2, 3, 5, 7, 10, 15, 30, 90, 180]
        for round in 1...11 {
            while try engine.info.has_task != 0 {
                let token = try XCTUnwrap(engine.record.presentation?.id)
                try engine.reveal(token: token, now: date(currentDay))
                try engine.grade(remembered: true, token: token, now: date(currentDay))
            }
            let packed = try XCTUnwrap(engine.packedCard(id: id)), level = min(round, 10)
            XCTAssertEqual((packed >> 16) & 15, UInt32(level))
            XCTAssertEqual(packed & 65_535, currentDay + gaps[level])
            if round < 11 {
                currentDay = packed & 65_535
                try engine.start(day: currentDay, now: date(currentDay))
            }
        }
    }

    @MainActor func testDisabledVocabularyPolicyMatchesBareEngineAndPolicyChangesSurviveRestart() async throws {
        var actual = try ProfessionalRecallEngine.fresh(deck: deck(30), now: date(day))
        let reference = try PocketEngine(snapshot: actual.record.snapshot)
        try actual.setConservativeEnabled(false, now: date(day))
        XCTAssertFalse(actual.record.analysis.conservativeEnabled)
        try actual.start(day: day, now: date(day)); try reference.start(day: day)
        var count = 0, reinforcement = 0
        while try actual.info.has_task != 0 {
            let info = try actual.info
            if info.word == 0 && info.stage > 0 { reinforcement += 1 }
            let token = try XCTUnwrap(actual.record.presentation?.id)
            try actual.reveal(token: token, now: date(day)); try reference.reveal()
            try actual.grade(remembered: count != 0, token: token, now: date(day))
            try reference.answer(count == 0 ? 1 : 0)
            try compare(actual, reference)
            if count == 8 {
                actual = try ProfessionalRecallEngine(deck: actual.deck, record: actual.record)
                XCTAssertFalse(actual.record.analysis.conservativeEnabled)
                try actual.start(day: day, now: date(day)); try reference.start(day: day)
            }
            count += 1; XCTAssertLessThan(count, 50)
        }
        XCTAssertEqual(reinforcement, 7)
        XCTAssertEqual(actual.record.analysis.savedRepetitions, 0)
        let before = actual.record
        try actual.setConservativeEnabled(true, now: date(day))
        XCTAssertEqual(actual.record.snapshot, before.snapshot)
        XCTAssertEqual(actual.record.attempts, before.attempts)
        XCTAssertEqual(actual.record.analysis.conservativeFirstSequence, try actual.info.log_records + 1)
        let reopened = try ProfessionalRecallEngine(deck: actual.deck, record: actual.record)
        XCTAssertTrue(reopened.record.analysis.conservativeEnabled)
        let enabled = reopened.record
        try reopened.setConservativeEnabled(true, now: date(day))
        XCTAssertEqual(reopened.record, enabled)
    }

    @MainActor func testPromotionAndAppendInOneBoundaryPreserveLiveHeadAndDeferredSevenStages() async throws {
        let all = deck(60)
        let donorDeck = RecallDeck(subject: all.subject, bankID: all.bankID, cards: Array(all.cards.prefix(2)))
        let receiverDeck = RecallDeck(subject: all.subject, bankID: all.bankID, cards: Array(all.cards.dropFirst(2).prefix(30)))
        let donor = try ProfessionalRecallEngine.fresh(deck: donorDeck, now: date(day))
        let receiver = try ProfessionalRecallEngine.fresh(deck: receiverDeck, now: date(day))
        try donor.start(day: day, now: date(day)); try receiver.start(day: day, now: date(day))
        let bad = try XCTUnwrap(donor.record.presentation?.id)
        try donor.reveal(token: bad, now: date(day)); try donor.grade(remembered: false, token: bad, now: date(day))
        let moveID = donorDeck.cards[0].id, before = receiver.record
        let transfer = try XCTUnwrap(donor.transferState(for: moveID, sourceScope: "related"))
        XCTAssertEqual(transfer.stageMask, 254)
        let head = try XCTUnwrap(receiver.record.presentation?.id)
        try receiver.reveal(token: head, now: date(day))
        let updated = RecallDeck(subject: all.subject, bankID: all.bankID,
            cards: receiverDeck.cards + [donorDeck.cards[0], all.cards[55]])
        try receiver.reconcile(to: updated, importing: [moveID: transfer], now: date(day))
        XCTAssertEqual(Array(receiver.record.cardIDs.prefix(before.cardIDs.count)), before.cardIDs)
        XCTAssertEqual(receiver.record.presentation?.id, head)
        XCTAssertEqual(receiver.record.presentation?.revealed, true)
        XCTAssertEqual(try receiver.packedCard(id: moveID), transfer.packed)
        XCTAssertEqual(receiver.record.deferredCards?[moveID]?.stageMask, 254)
        XCTAssertTrue(receiver.record.attempts.isEmpty)
        let stable = receiver.record
        try receiver.reconcile(to: updated, now: date(day))
        XCTAssertEqual(receiver.record, stable)
        var resumed = try ProfessionalRecallEngine.restore(record: receiver.record, fallback: updated)
        try resumed.start(day: day, now: date(day))
        while try resumed.info.has_task != 0 {
            let token = try XCTUnwrap(resumed.record.presentation?.id)
            try resumed.reveal(token: token, now: date(day))
            try resumed.grade(remembered: true, token: token, now: date(day))
        }
        try resumed.start(day: day, now: date(day))
        XCTAssertEqual(resumed.currentItem?.id, moveID)
        XCTAssertEqual(try resumed.info.stage, 1)
        XCTAssertNil(resumed.record.deferredCards?[moveID])
        resumed = try ProfessionalRecallEngine.restore(record: resumed.record, fallback: updated)
        try resumed.start(day: day, now: date(day))
        var stages: [UInt32] = []
        while resumed.currentItem?.id == moveID {
            stages.append(try resumed.info.stage)
            let token = try XCTUnwrap(resumed.record.presentation?.id)
            try resumed.reveal(token: token, now: date(day))
            try resumed.grade(remembered: true, token: token, now: date(day))
        }
        XCTAssertEqual(stages, [1, 2, 3, 4, 5, 6, 7])
    }

    @MainActor func testNonlinearLegacySameScoreCannotDiscardAnotherArchivesVisibleAnswer() async throws {
        let original = deck(4)
        var modifiedCards = original.cards
        modifiedCards[3] = RecallDeck.Item(conceptID: modifiedCards[3].conceptID, conceptTitle: "Different original deck",
            card: modifiedCards[3].card)
        let modified = RecallDeck(subject: original.subject, bankID: original.bankID, cards: modifiedCards)
        var a = try RecallEngine(deck: original), b = try RecallEngine(deck: modified)
        try a.act("start", day: Int(day), newLimit: 4, now: date(day))
        try a.act("reveal", day: Int(day), token: a.record.state.shown!.id, now: date(day))
        try b.act("start", day: Int(day), newLimit: 4, now: date(day).addingTimeInterval(10))
        XCTAssertEqual(a.record.state.progress, b.record.state.progress)
        XCTAssertThrowsError(try ProfessionalRecallEngine.fresh(deck: original, legacy: [a.record, b.record], now: date(day)))
    }
}
