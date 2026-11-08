import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

/// All questions and scores in this fixture are synthetic. No phone files,
/// user content, account information, or public question banks are used.
enum PublicQuestionDualFixtures {
    static let hash = String(repeating: "a", count: 64)
    static let day: UInt32 = 21_000
    static let now = Date(timeIntervalSince1970: Double(day) * 86_400 + 12 * 3_600)

    static func bank(_ count: Int, kind: ExamQuestionType = .single) -> ExamBank {
        let options: [ExamOption]
        let answers: [String]
        switch kind {
        case .single:
            options = [ExamOption(id: "A", text: "合成甲"), ExamOption(id: "B", text: "合成乙"),
                       ExamOption(id: "C", text: "合成丙")]; answers = ["A"]
        case .multiple:
            options = [ExamOption(id: "A", text: "合成甲"), ExamOption(id: "B", text: "合成乙"),
                       ExamOption(id: "C", text: "合成丙")]; answers = ["A", "B"]
        case .judgment:
            options = [ExamOption(id: "T", text: "正确"), ExamOption(id: "F", text: "错误")]; answers = ["T"]
        }
        return ExamBank(id: "synthetic-public-bank", title: "纯合成公共题库", sourceName: "synthetic.pdf",
            sourceSHA256: hash, totalPages: 1, questions: (0..<count).map { index in
                ExamQuestion(id: "synthetic-public-\(index)", number: index + 1, type: kind,
                    section: "合成章节", prompt: "仅用于本地测试的虚构题目 \(index)",
                    options: options, answer: answers, pageStart: 1, pageEnd: 1)
            })
    }

    /// Creates synthetic prior learned slots without inventing answers. The
    /// Pocket import API explicitly supports packed-only old state and zero
    /// prior events. 267 due plus 25 new resembles a 292-item active task.
    @MainActor static func legacyWithDue(_ b: ExamBank, dueCount: Int) throws -> ExamLearningEngine {
        precondition(dueCount >= 0 && dueCount <= b.questions.count)
        let newCount = b.questions.count - dueCount
        let packed = b.questions.indices.map { index -> UInt32 in
            index < newCount ? 0 : ((1 << 20) | (1 << 16) | (day - 1))
        }
        var stream = UUID().uuid
        let pointer = try XCTUnwrap(withUnsafeBytes(of: &stream) { streamRaw in
            packed.withUnsafeBufferPointer { cards in
                xkl_engine_import_cards(UInt32(cards.count), cards.baseAddress, day, UInt32.max,
                                        streamRaw.bindMemory(to: UInt8.self).baseAddress)
            }
        })
        defer { xkl_engine_free(pointer) }
        var snapshot = Data(count: xkl_engine_snapshot_size(pointer))
        let written = snapshot.withUnsafeMutableBytes { raw in
            xkl_engine_snapshot(pointer, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        XCTAssertEqual(written, snapshot.count)
        let pocket = try PocketEngine(snapshot: snapshot)
        var record = try ExamLearningEngine.fresh(bank: b, hash: hash, now: now).record
        record.snapshot = snapshot
        record.snapshotSHA256 = StudySHA256.hex(snapshot)
        record.analysis = StudyAnalysisSettings(streamID: try pocket.streamID, nextSequence: 1, now: now)
        let engine = try ExamLearningEngine(bank: b, hash: hash, record: record)
        try engine.start(day: day, now: now)
        return engine
    }

    struct Slot: Equatable {
        let packed: UInt32
        let pendingStageMask: UInt32
        let failedRound: UInt32
    }

    /// Read-only C API: stage masks report obligations, not queue order.
    static func slots(snapshot: Data, count: Int) throws -> [Slot] {
        let pointer = try XCTUnwrap(snapshot.withUnsafeBytes { raw in
            xkl_engine_restore(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        })
        defer { xkl_engine_free(pointer) }
        return (0..<count).map { index in
            var failed: UInt32 = 0
            let stages = xkl_engine_pending_stages(pointer, UInt32(index), &failed)
            return Slot(packed: xkl_engine_card(pointer, UInt32(index)), pendingStageMask: stages, failedRound: failed)
        }
    }
}

final class PublicQuestionDualFixturesTests: XCTestCase {
    @MainActor func testUnsubmittedMultipleChoiceRestoresSelectionAndPocketObligations() async throws {
        let b = PublicQuestionDualFixtures.bank(30, kind: .multiple)
        let legacy = try ExamLearningEngine.fresh(bank: b, hash: PublicQuestionDualFixtures.hash,
                                                   now: PublicQuestionDualFixtures.now)
        try legacy.start(day: PublicQuestionDualFixtures.day, now: PublicQuestionDualFixtures.now)
        let original = try XCTUnwrap(legacy.record.presentation)
        try legacy.toggle("A") // Only one of two correct options; no submit and no grade.
        let selected = try XCTUnwrap(legacy.record.presentation)
        XCTAssertEqual(selected.selectedOptionIDs, ["A"])
        XCTAssertEqual(selected.optionOrder, original.optionOrder)
        XCTAssertTrue(legacy.record.attempts.isEmpty)
        let bytes = try JSONEncoder().encode(legacy.record)
        let restored = try ExamLearningEngine(bank: b, hash: PublicQuestionDualFixtures.hash,
            record: JSONDecoder().decode(ExamDiskRecord.self, from: bytes))
        XCTAssertEqual(restored.record.presentation, selected)
        XCTAssertEqual(restored.record.snapshot, legacy.record.snapshot)
        XCTAssertEqual(try PublicQuestionDualFixtures.slots(snapshot: restored.record.snapshot, count: b.questions.count),
                       try PublicQuestionDualFixtures.slots(snapshot: legacy.record.snapshot, count: b.questions.count))
        XCTAssertTrue(restored.record.attempts.isEmpty)
    }

    @MainActor func testResultPageAndNextFrozenQuestionCoexistWithoutDoubleGrade() async throws {
        let b = PublicQuestionDualFixtures.bank(1)
        let legacy = try ExamLearningEngine.fresh(bank: b, hash: PublicQuestionDualFixtures.hash,
                                                   now: PublicQuestionDualFixtures.now)
        try legacy.start(day: PublicQuestionDualFixtures.day, now: PublicQuestionDualFixtures.now)
        let first = try XCTUnwrap(legacy.record.presentation)
        try legacy.selectAndSubmit("A", presentationID: first.id,
                                   now: PublicQuestionDualFixtures.now.addingTimeInterval(1))
        let result = try XCTUnwrap(legacy.record.answerReview)
        let next = try XCTUnwrap(legacy.record.presentation)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertEqual(result.presentation.id, first.id)
        XCTAssertEqual(legacy.record.attempts.count, 1)
        let saved = try JSONEncoder().encode(legacy.record)
        let restored = try ExamLearningEngine(bank: b, hash: PublicQuestionDualFixtures.hash,
            record: JSONDecoder().decode(ExamDiskRecord.self, from: saved))
        XCTAssertEqual(restored.record.answerReview, result)
        XCTAssertEqual(restored.record.presentation, next)
        try restored.selectAndSubmit("A", presentationID: first.id,
                                     now: PublicQuestionDualFixtures.now.addingTimeInterval(2))
        XCTAssertEqual(restored.record.attempts.count, 1)
    }

    @MainActor func testLegacyFamiliarUndoIsActualRetractionNotFabricatedAnswer() async throws {
        let b = PublicQuestionDualFixtures.bank(1)
        let legacy = try ExamLearningEngine.fresh(bank: b, hash: PublicQuestionDualFixtures.hash,
                                                   now: PublicQuestionDualFixtures.now)
        try legacy.start(day: PublicQuestionDualFixtures.day, now: PublicQuestionDualFixtures.now)
        try legacy.familiar(now: PublicQuestionDualFixtures.now.addingTimeInterval(1))
        let familiar = try XCTUnwrap(legacy.record.attempts.last)
        XCTAssertEqual(familiar.mode, "familiar")
        XCTAssertEqual(try legacy.info.can_undo, 1)
        try legacy.undo(now: PublicQuestionDualFixtures.now.addingTimeInterval(2))
        let undo = try XCTUnwrap(legacy.record.attempts.last)
        XCTAssertEqual(undo.mode, "undo")
        XCTAssertEqual(undo.undoneAttemptID, familiar.id)
        XCTAssertEqual(legacy.record.attempts.filter { $0.mode == "answer" }.count, 0)
    }

    @MainActor func testLegacyAnswerCanBeGradedAfterMidnightWithoutChangingItsTrueTimes() async throws {
        let b = PublicQuestionDualFixtures.bank(2)
        let dayStart = Calendar.current.startOfDay(for: PublicQuestionDualFixtures.now)
        let midnight = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: dayStart))
        let selectedAt = midnight.addingTimeInterval(-2)
        let gradedAt = midnight.addingTimeInterval(2)
        let firstDay = UInt32(try ConceptCalendar.studyDay(selectedAt))
        let nextDay = UInt32(try ConceptCalendar.studyDay(gradedAt))
        XCTAssertEqual(nextDay, firstDay + 1)
        let legacy = try ExamLearningEngine.fresh(bank: b, hash: PublicQuestionDualFixtures.hash, now: selectedAt)
        try legacy.start(day: firstDay, now: selectedAt)
        try legacy.toggle("A")
        try legacy.submit(now: selectedAt)
        let pending = try XCTUnwrap(legacy.record.presentation?.pending)
        XCTAssertEqual(pending.answeredAt, selectedAt)
        XCTAssertNil(pending.gradedAt)
        try legacy.start(day: nextDay, now: gradedAt)
        try legacy.confirm(0, now: gradedAt)
        let scored = try XCTUnwrap(legacy.record.attempts.last)
        XCTAssertEqual(scored.answeredAt, selectedAt)
        XCTAssertEqual(scored.gradedAt, gradedAt)
        XCTAssertEqual(try ConceptCalendar.studyDay(try XCTUnwrap(scored.gradedAt)), Int(nextDay))
        XCTAssertEqual(try ConceptCalendar.studyDay(scored.answeredAt), Int(firstDay))
    }

    @MainActor func testSyntheticLegacyTaskHasHundredsOfDistinctObligationsWithoutFabricatedGrades() async throws {
        let bank = PublicQuestionDualFixtures.bank(292)
        let legacy = try PublicQuestionDualFixtures.legacyWithDue(bank, dueCount: 267)
        let info = try legacy.info
        XCTAssertEqual(info.review_remaining, 267)
        XCTAssertEqual(info.new_remaining, 25)
        XCTAssertEqual(info.review_remaining + info.new_remaining, 292)
        XCTAssertTrue(legacy.record.attempts.isEmpty)
        let slots = try PublicQuestionDualFixtures.slots(snapshot: legacy.record.snapshot, count: bank.questions.count)
        XCTAssertEqual(slots.prefix(25).filter { $0.packed == 0 }.count, 25)
        XCTAssertEqual(slots.dropFirst(25).filter { ($0.packed & (1 << 20)) != 0 }.count, 267)
        let saved = try JSONEncoder().encode(legacy.record)
        let restored = try ExamLearningEngine(bank: bank, hash: PublicQuestionDualFixtures.hash,
            record: JSONDecoder().decode(ExamDiskRecord.self, from: saved))
        XCTAssertEqual(restored.record.presentation, legacy.record.presentation)
        XCTAssertEqual(restored.record.snapshot, legacy.record.snapshot)
        XCTAssertEqual(try restored.info.review_remaining + restored.info.new_remaining, 292)
        XCTAssertTrue(restored.record.attempts.isEmpty)
    }
}
