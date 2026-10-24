import XCTest
import Foundation
import StudyCore
@testable import StudyClientModel

final class ExamTests: XCTestCase {
    @MainActor private func secondLessonWithTomorrowReviews() throws -> ExamLearningEngine {
        let engine = try ExamLearningEngine.fresh(bank: bank(60, multiple: true), hash: fixtureHash)
        try engine.start(day: 21_000)
        var count = 0
        while try engine.info.has_task != 0 {
            guard count < 500 else { throw ExamError.invalid("Synthetic lesson failed to finish") }
            try answer(engine, selection: ["A", "B"], grade: 0)
            count += 1
        }
        try engine.start(day: 21_000)
        XCTAssertEqual(try engine.info.new_remaining, 25)
        XCTAssertEqual(try engine.info.review_remaining, 0)
        return engine
    }

    @MainActor func testMidnightAddsReviewsWithoutLosingPartialSelectionOrChangingNewQuota() async throws {
        let engine = try secondLessonWithTomorrowReviews()
        let unchanged = engine.record.snapshot
        XCTAssertEqual(engine.dueCount(on: 21_001), 25)
        XCTAssertEqual(engine.record.snapshot, unchanged)
        try engine.toggle("A")
        let pending = engine.record.presentation, attempts = engine.record.attempts
        let task = engine.record.taskID
        try engine.start(day: 21_001)
        XCTAssertEqual(engine.record.presentation, pending)
        XCTAssertEqual(engine.record.attempts, attempts)
        XCTAssertEqual(engine.record.taskID, task)
        XCTAssertEqual(try engine.info.new_remaining, 25)
        XCTAssertEqual(try engine.info.review_remaining, 25)
        XCTAssertEqual(try engine.info.selection_day, 21_001)
        try engine.start(day: 21_001)
        XCTAssertEqual(try engine.info.review_remaining, 25)
        XCTAssertEqual(engine.record.presentation, pending)
    }

    @MainActor func testMidnightPreservesShownResultAndTheSeparateNextPresentation() async throws {
        let engine = try secondLessonWithTomorrowReviews()
        try engine.toggle("A"); try engine.toggle("B")
        try engine.submitAutomatically(presentationID: engine.record.presentation?.id)
        let review = engine.record.answerReview
        let next = engine.record.presentation, attempts = engine.record.attempts
        XCTAssertNotNil(review)
        try engine.start(day: 21_001)
        XCTAssertEqual(engine.record.answerReview, review)
        XCTAssertEqual(engine.record.presentation, next)
        XCTAssertEqual(engine.record.attempts, attempts)
        XCTAssertEqual(try engine.info.review_remaining, 25)
        let restored = try ExamLearningEngine(bank: engine.bank, hash: fixtureHash, record: engine.record)
        XCTAssertEqual(restored.record.answerReview, review)
        XCTAssertEqual(restored.record.presentation, next)
    }

    private let fixtureHash = String(repeating: "a", count: 64)
    private func bank(_ count: Int = 3, multiple: Bool = false) -> ExamBank {
        ExamBank(id: "fictional-test-bank", title: "虚构测试题库", sourceName: "fictional.pdf",
            sourceSHA256: fixtureHash, totalPages: 2, questions: (1...count).map {
                ExamQuestion(id: "fiction-\($0)", number: $0, type: multiple ? .multiple : .single,
                    section: "虚构章节", prompt: "虚构测试题 \($0)",
                    options: [ExamOption(id: "A", text: "虚构甲"), ExamOption(id: "B", text: "虚构乙"),
                              ExamOption(id: "C", text: "虚构丙")],
                    answer: multiple ? ["A", "B"] : ["A"], pageStart: 1, pageEnd: 1)
            })
    }

    @MainActor private func answer(_ engine: ExamLearningEngine, selection: [String], grade: Int32) throws {
        for id in selection { try engine.toggle(id) }
        try engine.submit()
        try engine.confirm(grade)
    }

    /// Build an actual old finalized first-known entry through the unchanged
    /// vocabulary/original C route, instead of pretending a new-rule entry is old.
    @MainActor private func legacyCorrect(_ record: inout ExamDiskRecord, bank: ExamBank) throws {
        let p = try XCTUnwrap(record.presentation)
        let q = try XCTUnwrap(bank.questions.first { $0.id == p.questionID })
        let engine = try PocketEngine(snapshot: record.snapshot)
        let before = try engine.info
        try engine.reveal(); try engine.answer(0)
        let after = try engine.info
        let event = try XCTUnwrap(engine.events(from: before.log_records + 1).first { $0.kind == 5 })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var entry = ExamAttempt(id: UUID(), bankID: bank.id, bankSHA256: record.bankSHA256,
            questionID: q.id, number: q.number, selectedOptions: q.answer.sorted(),
            correctOptions: q.answer.sorted(), optionOrder: p.optionOrder, isCorrect: true,
            answeredAt: date, sessionID: record.taskID, presentationID: p.id, mode: "answer")
        entry.grade = 0; entry.gradedAt = date; entry.engineSequence = event.sequence
        entry.beforeRevision = before.revision; entry.afterRevision = after.revision
        entry.examPlan = 0; entry.shortenedRepeats = 0; entry.tailRemoved = 0
        entry.tailDeferred = false; entry.failureCountInTask = 0
        record.attempts.append(entry); record.lastUndoableAttemptID = entry.id
        if after.has_task != 0 {
            let next = bank.questions[Int(after.word)]
            let order = ExamPresentation.order(for: next, avoiding: record.previousOrders[next.id])
            record.previousOrders[next.id] = order
            record.presentation = ExamPresentation(id: UUID(), questionID: next.id, optionOrder: order,
                selectedOptionIDs: [], pending: nil, supplementVisible: false, presentedAt: date)
        } else { record.presentation = nil }
        record.snapshot = try engine.snapshot()
        record.snapshotSHA256 = StudySHA256.hex(record.snapshot)
    }

    func testPackageHashAndInvalidAnswerRejected() throws {
        let original = bank()
        let bytes = try JSONEncoder().encode(original)
        let valid = ExamContent(format: ExamContent.formatName, bankBytes: bytes, bankSHA256: StudySHA256.hex(bytes))
        XCTAssertEqual(try ExamContent.load(JSONEncoder().encode(valid)).1.questions.count, 3)
        XCTAssertThrowsError(try ExamContent.load(JSONEncoder().encode(
            ExamContent(format: ExamContent.formatName, bankBytes: bytes, bankSHA256: fixtureHash))))
        let duplicate = ExamBank(id: original.id, title: original.title, sourceName: original.sourceName,
            sourceSHA256: fixtureHash, totalPages: 2, questions: [original.questions[0], original.questions[0]])
        XCTAssertThrowsError(try duplicate.validate())
        let q = original.questions[0]
        let invalid = ExamQuestion(id: q.id, number: 1, type: .single, section: q.section,
            prompt: q.prompt, options: q.options, answer: ["A", "B"], pageStart: 1, pageEnd: 1)
        XCTAssertFalse(invalid.accepts(Set(invalid.answer)))
    }

    func testStrictSetGradingIncludingMissingAndExtraOptions() {
        let q = bank(1, multiple: true).questions[0]
        XCTAssertTrue(q.isCorrect(["B", "A"]))
        XCTAssertFalse(q.isCorrect(["A"]))
        XCTAssertFalse(q.isCorrect(["A", "B", "C"]))
        XCTAssertFalse(q.isCorrect(["A", "C"]))
        XCTAssertFalse(q.isCorrect([]))
        let judgement = ExamQuestion(id: "judge", number: 1, type: .judgment, section: "虚构",
            prompt: "虚构判断", options: [ExamOption(id: "T", text: "正确"), ExamOption(id: "F", text: "错误")],
            answer: ["F"], pageStart: 1, pageEnd: 1)
        XCTAssertTrue(judgement.isCorrect(["F"]))
        XCTAssertFalse(judgement.isCorrect(["T", "F"]))
    }

    func testShuffleAlwaysChangesNextPresentationButKeepsStableIDs() {
        let q = bank().questions[0]
        var previous = q.options.map(\.id)
        for _ in 0..<100 {
            let order = ExamPresentation.order(for: q, avoiding: previous)
            XCTAssertEqual(Set(order), Set(previous)); XCTAssertNotEqual(order, previous)
            XCTAssertEqual(ExamPresentation.label(order[0], in: order), "A")
            XCTAssertEqual(ExamPresentation.label(order[1], in: order), "B")
            previous = order
        }
    }

    func testSubmittedAnswerRestoresWithoutReshuffleOrDuplicateGrade() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(), hash: fixtureHash)
            try engine.start(day: 21_000)
            let original = try XCTUnwrap(engine.record.presentation)
            try engine.toggle("A"); try engine.submit()
            XCTAssertEqual(engine.record.attempts.count, 0)
            XCTAssertEqual(engine.record.presentation?.optionOrder, original.optionOrder)
            let bytes = try JSONEncoder().encode(engine.record)
            let restored = try ExamLearningEngine(bank: bank(), hash: fixtureHash,
                record: JSONDecoder().decode(ExamDiskRecord.self, from: bytes))
            try restored.start(day: 21_000)
            XCTAssertEqual(restored.record.presentation?.id, original.id)
            XCTAssertEqual(restored.record.presentation?.optionOrder, original.optionOrder)
            XCTAssertEqual(restored.pendingGrade, 0)
            try restored.submit()
            XCTAssertEqual(restored.record.attempts.count, 0)
            try restored.confirm(0); try restored.confirm(0)
            XCTAssertEqual(restored.record.attempts.count, 1)
            XCTAssertEqual(restored.currentQuestion?.id, "fiction-2")
            XCTAssertEqual(try restored.info.first_known, 0)
            XCTAssertEqual(restored.record.attempts[0].learningInitialization, "correct-short")
            XCTAssertTrue(restored.record.failureCounts.isEmpty)
            _ = try ExamLearningEngine(bank: bank(), hash: fixtureHash, record: restored.record)
        }
    }

    func testMissingMultipleOptionIsWrongAndRepeatedWrongRestoresSeven() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1, multiple: true), hash: fixtureHash)
            try engine.start(day: 21_000)
            try engine.toggle("A"); try engine.submit()
            XCTAssertEqual(engine.pendingGrade, 1)
            XCTAssertThrowsError(try engine.confirm(3))
            XCTAssertFalse(engine.record.presentation?.supplementVisible ?? true)
            try engine.confirm(1)
            XCTAssertEqual(try engine.reinforcementRemaining, 3)
            XCTAssertEqual(engine.record.attempts.last?.grade, 1)
            XCTAssertEqual(engine.record.attempts.last?.examPlan, 1)
            let recovered = try ExamLearningEngine(bank: bank(1, multiple: true), hash: fixtureHash, record: engine.record)
            try recovered.start(day: 21_000)
            try answer(recovered, selection: ["A"], grade: 1)
            XCTAssertEqual(try recovered.reinforcementRemaining, 7)
            XCTAssertEqual(recovered.record.failureCounts["fiction-1"], 2)
            XCTAssertEqual(recovered.record.attempts.last?.examPlan, 0)
            XCTAssertTrue(recovered.record.shortPlanQuestionIDs.isEmpty)
        }
    }

    func testDisabledExperimentUsesOriginalSevenAndShortTailWaitsUntilTomorrow() async throws {
        try await MainActor.run {
            let original = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            original.setExamReduction(false)
            try original.start(day: 21_000)
            try answer(original, selection: ["B"], grade: 1)
            XCTAssertEqual(try original.reinforcementRemaining, 7)
            let short = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try short.start(day: 21_000)
            try answer(short, selection: ["B"], grade: 1)
            let oldOrder = short.record.presentation?.optionOrder
            try answer(short, selection: ["A"], grade: 0)
            XCTAssertEqual(try short.info.has_task, 0)
            XCTAssertTrue(short.record.attempts.last?.tailDeferred == true)
            XCTAssertEqual(short.record.attempts.last?.tailRemoved, 2)
            try short.start(day: 21_000)
            XCTAssertEqual(try short.info.has_task, 0)
            try short.start(day: 21_001)
            XCTAssertEqual(try short.info.review_remaining, 1)
            XCTAssertNotEqual(short.record.presentation?.optionOrder, oldOrder)
            XCTAssertTrue(short.record.failureCounts.isEmpty)
        }
    }

    func testCorrectSelfReportedPartialNeedsSupplementButNotWrongChoice() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(), hash: fixtureHash)
            try engine.start(day: 21_000)
            try engine.toggle("A"); try engine.submit(); try engine.confirm(3)
            XCTAssertTrue(engine.record.presentation?.supplementVisible == true)
            XCTAssertEqual(engine.record.attempts.count, 0)
            let saved = try ExamLearningEngine(bank: bank(), hash: fixtureHash, record: engine.record)
            try saved.start(day: 21_000)
            XCTAssertTrue(saved.record.presentation?.supplementVisible == true)
            try saved.confirm(3)
            XCTAssertEqual(saved.record.attempts.count, 1)
            XCTAssertEqual(saved.record.attempts[0].grade, 3)
            XCTAssertNil(saved.pendingGrade)
        }
    }

    func testAllTwentyFiveNewCorrectAnswersTrainAndReturnTomorrowWithoutInventedErrors() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(25), hash: fixtureHash)
            try engine.start(day: 21_000)
            XCTAssertEqual(try engine.info.new_remaining, 25)
            var steps = 0
            while try engine.info.has_task != 0, steps < 150 {
                try answer(engine, selection: ["A"], grade: 0); steps += 1
            }
            XCTAssertEqual(try engine.info.has_task, 0)
            XCTAssertLessThan(steps, 150)
            XCTAssertEqual(engine.record.attempts.filter { $0.learningInitialization == "correct-short" }.count, 25)
            XCTAssertTrue(engine.record.attempts.allSatisfy { $0.isCorrect && $0.grade == 0 && $0.failureCountInTask == 0 })
            XCTAssertTrue(engine.record.failureCounts.isEmpty)
            XCTAssertTrue(Dictionary(grouping: engine.record.attempts, by: \.questionID).values.allSatisfy { $0.count >= 2 })
            XCTAssertEqual(try engine.info.first_known, 0)
            XCTAssertEqual(try engine.info.familiar, 0)
            let log = try PocketEngine(snapshot: engine.record.snapshot).events(from: 1)
            XCTAssertFalse(log.contains { $0.kind == 6 })
            try engine.start(day: 21_000)
            XCTAssertEqual(try engine.info.has_task, 0)
            try engine.start(day: 21_001)
            XCTAssertEqual(try engine.info.review_remaining, 25)
            XCTAssertEqual(try engine.info.new_remaining, 0)
            XCTAssertEqual(try engine.info.first_known, 0)
            XCTAssertEqual(try engine.info.familiar, 0)
        }
    }

    func testFamiliarUndoAndVersionMismatchDoNotOverwriteHistory() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(), hash: fixtureHash)
            try engine.start(day: 21_000)
            try engine.familiar()
            let skipped = try XCTUnwrap(engine.record.attempts.last)
            XCTAssertEqual(skipped.grade, 2)
            try engine.undo()
            XCTAssertEqual(engine.currentQuestion?.id, "fiction-1")
            XCTAssertEqual(engine.record.attempts.count, 2)
            XCTAssertEqual(engine.record.attempts.last?.undoneAttemptID, skipped.id)
            XCTAssertThrowsError(try ExamLearningEngine(bank: bank(), hash: String(repeating: "b", count: 64),
                                                       record: engine.record))
            var damaged = engine.record; damaged.snapshot[0] ^= 1
            XCTAssertThrowsError(try ExamLearningEngine(bank: bank(), hash: fixtureHash, record: damaged))
            _ = try ExamLearningEngine(bank: bank(), hash: fixtureHash, record: engine.record)
        }
    }

    func testRotationPreservesQuestionOrderPendingAnswerAndRepeatPlan() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            try answer(engine, selection: ["B"], grade: 1)
            try engine.toggle("A"); try engine.submit()
            let old = engine.record
            let bytes = try JSONEncoder().encode(old)
            let digest = StudySHA256.hex(bytes)
            let end = try engine.info.log_records
            try engine.rotate(reference: ExamVolumeReference(filename: digest + ".json", sha256: digest,
                firstSequence: 1, lastSequence: end, attemptCount: old.attempts.count))
            XCTAssertEqual(engine.record.presentation, old.presentation)
            XCTAssertEqual(engine.record.failureCounts, old.failureCounts)
            XCTAssertEqual(engine.record.shortPlanQuestionIDs, old.shortPlanQuestionIDs)
            XCTAssertTrue(engine.record.attempts.isEmpty)
            let restored = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: engine.record)
            try restored.start(day: 21_000)
            try restored.confirm(0)
            XCTAssertTrue(restored.record.attempts.last?.tailDeferred == true)
            XCTAssertEqual(try restored.info.has_task, 0)
            XCTAssertEqual(restored.record.volumes.count, 1)
        }
    }

    func testSingleChoiceAutomaticallyGradesAndKeepsLastResultUntilNext() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            let old = try XCTUnwrap(engine.record.presentation)
            try engine.selectAndSubmit("A", presentationID: old.id)
            XCTAssertEqual(engine.record.attempts.count, 1)
            XCTAssertEqual(engine.record.attempts[0].grade, 0)
            XCTAssertEqual(engine.record.attempts[0].gradingSource, "automatic-choice")
            XCTAssertEqual(try engine.info.has_task, 1)
            XCTAssertEqual(try engine.reinforcementRemaining, 3)
            XCTAssertTrue(engine.isShowingResult)
            XCTAssertEqual(engine.displayQuestion?.id, old.questionID)
            XCTAssertEqual(engine.displayPresentation?.optionOrder, old.optionOrder)
            try engine.selectAndSubmit("B", presentationID: old.id)
            try engine.submitAutomatically(presentationID: old.id)
            try engine.familiar()
            XCTAssertEqual(engine.record.attempts.count, 1)
            let restored = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: engine.record)
            try restored.start(day: 21_001)
            XCTAssertTrue(restored.isShowingResult)
            XCTAssertEqual(restored.record.attempts.count, 1)
            XCTAssertEqual(restored.displayPresentation, engine.displayPresentation)
            try restored.nextQuestion(presentationID: old.id)
            XCTAssertFalse(restored.isShowingResult)
            XCTAssertEqual(restored.displayQuestion?.id, old.questionID)
            XCTAssertNotEqual(restored.displayPresentation?.id, old.id)
            XCTAssertEqual(restored.record.attempts.count, 1)
            _ = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: restored.record)
        }
    }

    func testSameQuestionReviewPreservesOldOrderAndRejectsOldTapToken() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            let old = try XCTUnwrap(engine.record.presentation)
            try engine.selectAndSubmit("B", presentationID: old.id)
            let queued = try XCTUnwrap(engine.record.presentation)
            XCTAssertEqual(queued.questionID, old.questionID)
            XCTAssertNotEqual(queued.id, old.id)
            XCTAssertNotEqual(queued.optionOrder, old.optionOrder)
            XCTAssertEqual(engine.displayPresentation?.id, old.id)
            XCTAssertEqual(engine.displayPresentation?.optionOrder, old.optionOrder)
            _ = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: engine.record)
            try engine.nextQuestion(presentationID: old.id)
            XCTAssertEqual(engine.displayPresentation?.id, queued.id)
            try engine.selectAndSubmit("A", presentationID: old.id)
            try engine.submitAutomatically(presentationID: old.id)
            try engine.nextQuestion(presentationID: old.id)
            XCTAssertEqual(engine.record.attempts.count, 1)
            XCTAssertFalse(engine.isShowingResult)
            XCTAssertEqual(engine.displayPresentation?.optionOrder, queued.optionOrder)
            try engine.selectAndSubmit("A", presentationID: queued.id)
            XCTAssertEqual(engine.record.attempts.count, 2)
            XCTAssertTrue(engine.record.attempts.last?.tailDeferred == true)
            XCTAssertTrue(engine.isShowingResult)
        }
    }

    func testMultipleChoiceHasOneSubmissionAndStrictAutomaticWrong() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1, multiple: true), hash: fixtureHash)
            try engine.start(day: 21_000)
            let token = try XCTUnwrap(engine.record.presentation?.id)
            try engine.toggle("A")
            XCTAssertTrue(engine.record.attempts.isEmpty)
            try engine.submitAutomatically(presentationID: token)
            XCTAssertEqual(engine.record.attempts.count, 1)
            XCTAssertEqual(engine.record.attempts[0].grade, 1)
            XCTAssertFalse(engine.record.attempts[0].isCorrect)
            XCTAssertEqual(engine.record.attempts[0].gradingSource, "automatic-choice")
            XCTAssertEqual(engine.displayAttempt?.selectedOptions, ["A"])
            try engine.toggle("B"); try engine.confirm(0)
            XCTAssertEqual(engine.record.attempts.count, 1)
            XCTAssertEqual(engine.displayAttempt?.selectedOptions, ["A"])
            try engine.nextQuestion(presentationID: token)
            XCTAssertFalse(engine.isShowingResult)
            XCTAssertEqual(try engine.reinforcementRemaining, 3)
        }
    }

    func testJudgmentTapAutomaticallyGrades() async throws {
        try await MainActor.run {
            let q = ExamQuestion(id: "judge", number: 1, type: .judgment, section: "虚构",
                prompt: "虚构判断", options: [ExamOption(id: "T", text: "正确"), ExamOption(id: "F", text: "错误")],
                answer: ["F"], pageStart: 1, pageEnd: 1)
            let fixture = ExamBank(id: "judge-fixture", title: "虚构判断", sourceName: "fiction.pdf",
                sourceSHA256: fixtureHash, totalPages: 1, questions: [q])
            let engine = try ExamLearningEngine.fresh(bank: fixture, hash: fixtureHash)
            try engine.start(day: 21_000)
            try engine.selectAndSubmit("F", presentationID: engine.record.presentation?.id)
            XCTAssertEqual(engine.record.attempts.count, 1)
            XCTAssertEqual(engine.record.attempts[0].grade, 0)
            XCTAssertTrue(engine.isShowingResult)
        }
    }

    func testLegacyTwoGradesAndPendingLoadUnchangedThenGradeExactlyOnce() async throws {
        try await MainActor.run {
            let fixture = bank(3)
            let seed = try ExamLearningEngine.fresh(bank: fixture, hash: fixtureHash)
            try seed.start(day: 21_000)
            var legacy = seed.record
            try legacyCorrect(&legacy, bank: fixture); try legacyCorrect(&legacy, bank: fixture)
            let engine = try ExamLearningEngine(bank: fixture, hash: fixtureHash, record: legacy)
            try engine.toggle("A"); try engine.submit()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let oldAttempts = engine.record.attempts
            let originalPrefixBytes = try encoder.encode(oldAttempts)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(engine.record)) as? [String: Any])
            object.removeValue(forKey: "answerReview") // Exact older schema shape.
            let olderBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let restored = try ExamLearningEngine(bank: bank(3), hash: fixtureHash,
                record: JSONDecoder().decode(ExamDiskRecord.self, from: olderBytes))
            XCTAssertEqual(try encoder.encode(restored.record.attempts), originalPrefixBytes)
            XCTAssertEqual(restored.record.attempts.count, 2)
            XCTAssertTrue(restored.isShowingResult)
            XCTAssertEqual(restored.record.presentation, engine.record.presentation)
            try restored.start(day: 21_000)
            XCTAssertEqual(restored.record.attempts.count, 2)
            let token = try XCTUnwrap(restored.displayPresentation?.id)
            try restored.nextQuestion(presentationID: token)
            XCTAssertEqual(restored.record.attempts.count, 3)
            XCTAssertEqual(restored.record.attempts.last?.grade, 0)
            XCTAssertEqual(restored.record.attempts.last?.learningInitialization, "correct-short")
            XCTAssertEqual(restored.record.attempts.last?.gradingSource, "legacy-pending-auto")
            XCTAssertEqual(try encoder.encode(Array(restored.record.attempts.prefix(2))), originalPrefixBytes)
            XCTAssertTrue(restored.record.attempts.prefix(2).allSatisfy { $0.gradingSource == nil })
            XCTAssertTrue(restored.record.attempts.prefix(2).allSatisfy { $0.learningInitialization == nil })
            XCTAssertEqual(try restored.info.first_known, 2)
            XCTAssertEqual(restored.currentQuestion?.id, "fiction-3")
            XCTAssertTrue(restored.record.failureCounts.isEmpty)
            try restored.nextQuestion(presentationID: token)
            XCTAssertEqual(restored.record.attempts.count, 3)
            XCTAssertFalse(restored.isShowingResult)
        }
    }

    func testLegacyExplicitPartialIsPreservedWhenNextCompletesPending() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(3), hash: fixtureHash)
            try engine.start(day: 21_000)
            try engine.toggle("A"); try engine.submit(); try engine.confirm(3)
            XCTAssertTrue(engine.record.presentation?.supplementVisible == true)
            let restored = try ExamLearningEngine(bank: bank(3), hash: fixtureHash, record: engine.record)
            let token = try XCTUnwrap(restored.displayPresentation?.id)
            try restored.start(day: 21_000)
            XCTAssertTrue(restored.record.attempts.isEmpty)
            try restored.nextQuestion(presentationID: token)
            XCTAssertEqual(restored.record.attempts.count, 1)
            XCTAssertEqual(restored.record.attempts[0].grade, 3)
            XCTAssertEqual(restored.record.attempts[0].gradingSource, "legacy-explicit-partial")
            XCTAssertTrue(restored.record.attempts[0].isCorrect)
            try restored.nextQuestion(presentationID: token)
            XCTAssertEqual(restored.record.attempts.count, 1)
            _ = try ExamLearningEngine(bank: bank(3), hash: fixtureHash, record: restored.record)
        }
    }

    func testScoredReviewSurvivesVolumeRotationWithoutSecondGrade() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            let token = try XCTUnwrap(engine.record.presentation?.id)
            try engine.selectAndSubmit("B", presentationID: token)
            let review = try XCTUnwrap(engine.record.answerReview)
            let old = engine.record, bytes = try JSONEncoder().encode(engine.record)
            let digest = StudySHA256.hex(bytes), end = try engine.info.log_records
            try engine.rotate(reference: ExamVolumeReference(filename: digest + ".json", sha256: digest,
                firstSequence: 1, lastSequence: end, attemptCount: old.attempts.count))
            XCTAssertTrue(engine.record.attempts.isEmpty)
            XCTAssertEqual(engine.record.answerReview, review)
            let restored = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: engine.record)
            try restored.start(day: 21_000)
            XCTAssertEqual(restored.record.answerReview, review)
            try restored.nextQuestion(presentationID: token)
            XCTAssertNil(restored.record.answerReview)
            XCTAssertTrue(restored.record.attempts.isEmpty)
            XCTAssertEqual(restored.record.volumes[0].attemptCount, 1)
        }
    }

    func testInitialCorrectDoesNotConsumeFirstWrongAndSecondWrongRestoresSeven() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            try answer(engine, selection: ["A"], grade: 0)
            XCTAssertEqual(engine.record.attempts.last?.examPlan, 3)
            XCTAssertEqual(engine.record.attempts.last?.initializedRepeats, 3)
            XCTAssertEqual(try engine.reinforcementRemaining, 3)
            XCTAssertTrue(engine.record.failureCounts.isEmpty)
            try answer(engine, selection: ["B"], grade: 1)
            XCTAssertEqual(engine.record.failureCounts["fiction-1"], 1)
            XCTAssertEqual(engine.record.attempts.last?.examPlan, 1)
            XCTAssertNil(engine.record.attempts.last?.learningInitialization)
            XCTAssertEqual(try engine.reinforcementRemaining, 3)
            try answer(engine, selection: ["B"], grade: 1)
            XCTAssertEqual(engine.record.failureCounts["fiction-1"], 2)
            XCTAssertEqual(engine.record.attempts.last?.examPlan, 0)
            XCTAssertEqual(try engine.reinforcementRemaining, 7)
            let events = try PocketEngine(snapshot: engine.record.snapshot).events(from: 1)
            XCTAssertEqual(events.filter { $0.kind == 5 }.count, 1)
            XCTAssertEqual(events.filter { $0.kind == 6 }.count, 2)
            _ = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: engine.record)
        }
    }

    func testDisabledReductionStillTrainsInitiallyCorrectQuestionAndSchedulesLongTermReview() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            engine.setExamReduction(false)
            try engine.setPolicy(false)
            try engine.start(day: 21_000)
            try answer(engine, selection: ["A"], grade: 0)
            XCTAssertEqual(engine.record.attempts.last?.learningInitialization, "correct-full")
            XCTAssertEqual(engine.record.attempts.last?.examPlan, 4)
            XCTAssertEqual(try engine.reinforcementRemaining, 7)
            XCTAssertTrue(engine.record.shortPlanQuestionIDs.isEmpty)
            for _ in 0..<7 { try answer(engine, selection: ["A"], grade: 0) }
            XCTAssertEqual(engine.record.attempts.count, 8)
            XCTAssertEqual(try engine.info.has_task, 0)
            XCTAssertTrue(engine.record.failureCounts.isEmpty)
            XCTAssertEqual(try engine.info.first_known, 0)
            try engine.start(day: 21_001)
            XCTAssertEqual(try engine.info.review_remaining, 1)
            try answer(engine, selection: ["A"], grade: 0)
            XCTAssertNil(engine.record.attempts.last?.learningInitialization)
            XCTAssertEqual(engine.record.attempts.last?.examPlan, 0)
            XCTAssertEqual(try engine.info.has_task, 0)
            try engine.start(day: 21_002)
            XCTAssertEqual(try engine.info.has_task, 0)
            try engine.start(day: 21_003)
            XCTAssertEqual(try engine.info.review_remaining, 1)
        }
    }

    func testInitialCorrectShortPlanSurvivesRotationReloadAndFamiliarUndo() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            try answer(engine, selection: ["A"], grade: 0)
            XCTAssertEqual(engine.record.shortPlanQuestionIDs, ["fiction-1"])
            XCTAssertTrue(engine.record.failureCounts.isEmpty)
            let oldBytes = try JSONEncoder().encode(engine.record)
            let digest = StudySHA256.hex(oldBytes), end = try engine.info.log_records
            try engine.rotate(reference: ExamVolumeReference(filename: digest + ".json", sha256: digest,
                firstSequence: 1, lastSequence: end, attemptCount: 1))
            let restored = try ExamLearningEngine(bank: bank(1), hash: fixtureHash,
                record: JSONDecoder().decode(ExamDiskRecord.self, from: JSONEncoder().encode(engine.record)))
            try restored.start(day: 21_000)
            XCTAssertTrue(restored.record.attempts.isEmpty)
            XCTAssertEqual(try restored.reinforcementRemaining, 3)
            try restored.familiar()
            XCTAssertEqual(try restored.info.has_task, 0)
            let familiar = try XCTUnwrap(restored.record.attempts.last)
            let volume = try JSONEncoder().encode(restored.record), hash = StudySHA256.hex(volume)
            try restored.rotate(reference: ExamVolumeReference(filename: hash + ".json", sha256: hash,
                firstSequence: end + 1, lastSequence: try restored.info.log_records, attemptCount: 1))
            let afterRotation = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: restored.record)
            try afterRotation.undo()
            XCTAssertEqual(afterRotation.record.attempts.last?.undoneAttemptID, familiar.id)
            XCTAssertEqual(try afterRotation.reinforcementRemaining, 3)
            XCTAssertEqual(afterRotation.record.shortPlanQuestionIDs, ["fiction-1"])
            XCTAssertTrue(afterRotation.record.failureCounts.isEmpty)
            try answer(afterRotation, selection: ["A"], grade: 0)
            XCTAssertTrue(afterRotation.record.attempts.last?.tailDeferred == true)
            XCTAssertEqual(try afterRotation.info.has_task, 0)
            try afterRotation.start(day: 21_001)
            XCTAssertEqual(try afterRotation.info.review_remaining, 1)
            XCTAssertEqual(try afterRotation.info.first_known, 0)
            XCTAssertEqual(try afterRotation.info.familiar, 0)
            _ = try ExamLearningEngine(bank: bank(1), hash: fixtureHash, record: afterRotation.record)
        }
    }

    func testOnlyExplicitFamiliarPermanentlySkipsNewQuestion() async throws {
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(1), hash: fixtureHash)
            try engine.start(day: 21_000)
            try engine.familiar()
            XCTAssertEqual(engine.record.attempts.count, 1)
            XCTAssertEqual(engine.record.attempts[0].mode, "familiar")
            XCTAssertNil(engine.record.attempts[0].learningInitialization)
            try engine.start(day: 21_180)
            XCTAssertEqual(try engine.info.has_task, 0)
            XCTAssertEqual(try engine.info.familiar, 1)
            XCTAssertEqual(try engine.info.first_known, 0)
        }
    }

    func testLearningInitializationReceiptCannotDescribeWrongAnswerOrInventedFailure() async throws {
        try await MainActor.run {
            let fixture = bank(1)
            let engine = try ExamLearningEngine.fresh(bank: fixture, hash: fixtureHash)
            try engine.start(day: 21_000)
            try answer(engine, selection: ["A"], grade: 0)
            var wrong = engine.record
            wrong.attempts[0].grade = 1
            XCTAssertThrowsError(try wrong.validateContent(bank: fixture, hash: fixtureHash))
            var failure = engine.record
            failure.attempts[0].failureCountInTask = 1
            XCTAssertThrowsError(try failure.validateContent(bank: fixture, hash: fixtureHash))
            var missing = engine.record
            missing.attempts[0].learningInitialization = nil
            XCTAssertThrowsError(try missing.validateContent(bank: fixture, hash: fixtureHash))
        }
    }

    func testExamPlanUsesInclusiveCoverageWindowAndPreservesThirtyMinuteBudget() {
        let plan = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 832,
            newIntroducedToday: 0, todayDay: 21_000, examDay: 21_047)
        XCTAssertEqual(plan.daysToExam, 47)
        XCTAssertEqual(plan.newLearningDaysAvailable, 34)
        XCTAssertEqual(plan.pacingDays, 34)
        XCTAssertEqual(plan.targetNewToday, 25)
        XCTAssertEqual(plan.remainingNewToday, 25)
        XCTAssertEqual(plan.newTargetTotal, 832)
        XCTAssertEqual(plan.dailyMinutes, 30)
        XCTAssertFalse(plan.isInsideReviewBuffer)
        let longerBudget = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 832,
            newIntroducedToday: 0, todayDay: 21_000, examDay: 21_047, dailyMinutes: 60)
        XCTAssertEqual(longerBudget.targetNewToday, plan.targetNewToday)
    }

    func testExamPlanAdjustsMissedDaysAndCreditsTodaysFirstEncounters() {
        let missedDay = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 832,
            newIntroducedToday: 0, todayDay: 21_001, examDay: 21_047)
        XCTAssertEqual(missedDay.newLearningDaysAvailable, 33)
        XCTAssertEqual(missedDay.targetNewToday, 26)
        let inProgress = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 812,
            newIntroducedToday: 20, todayDay: 21_000, examDay: 21_047)
        XCTAssertEqual(inProgress.targetNewToday, 25)
        XCTAssertEqual(inProgress.remainingNewToday, 5)
        let finishedToday = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 802,
            newIntroducedToday: 30, todayDay: 21_000, examDay: 21_047)
        XCTAssertEqual(finishedToday.targetNewToday, 25)
        XCTAssertEqual(finishedToday.remainingNewToday, 0)
    }

    func testExamPlanWarnsInReviewBufferWithoutDemandingAllQuestionsImmediately() {
        let lastCoverageDay = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 100,
            newIntroducedToday: 0, todayDay: 21_033, examDay: 21_047)
        XCTAssertEqual(lastCoverageDay.newLearningDaysAvailable, 1)
        XCTAssertEqual(lastCoverageDay.targetNewToday, 100)
        XCTAssertFalse(lastCoverageDay.isInsideReviewBuffer)
        let insideBuffer = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 100,
            newIntroducedToday: 0, todayDay: 21_034, examDay: 21_047)
        XCTAssertEqual(insideBuffer.newLearningDaysAvailable, 0)
        XCTAssertEqual(insideBuffer.pacingDays, 13)
        XCTAssertEqual(insideBuffer.targetNewToday, 8)
        XCTAssertTrue(insideBuffer.isInsideReviewBuffer)
    }

    func testExamPlanStopsNewTargetsOnExamDayAndDoesNotSwitchBatchAfterward() {
        for day in [21_047, 21_048, 21_400] {
            let plan = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 100,
                newIntroducedToday: 0, todayDay: day, examDay: 21_047)
            XCTAssertEqual(plan.targetNewToday, 0)
            XCTAssertEqual(plan.remainingNewToday, 0)
            XCTAssertEqual(plan.newLearningDaysAvailable, 0)
            XCTAssertEqual(plan.pacingDays, 0)
            XCTAssertEqual(plan.isExamDay, day == 21_047)
            XCTAssertEqual(plan.examHasPassed, day > 21_047)
            XCTAssertEqual(plan.examDay, 21_047)
        }
        let finished = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 0,
            newIntroducedToday: 0, todayDay: 21_040, examDay: 21_047)
        XCTAssertEqual(finished.targetNewToday, 0)
        XCTAssertEqual(finished.remainingNewToday, 0)
        XCTAssertFalse(finished.isInsideReviewBuffer)
    }

    func testExamPlanClampsInconsistentCountsAndDoesNotChangeTwentyFiveQuestionLesson() async throws {
        let invalid = ExamStudyPlan(totalQuestionCount: 10, unseenQuestionCount: 30,
            newIntroducedToday: 20, todayDay: 21_000, examDay: 21_047)
        XCTAssertEqual(invalid.unseenQuestionCount, 10)
        XCTAssertEqual(invalid.newIntroducedToday, 0)
        XCTAssertEqual(invalid.newTargetTotal, 10)
        let empty = ExamStudyPlan(totalQuestionCount: -1, unseenQuestionCount: -3,
            newIntroducedToday: -4, todayDay: 21_000, examDay: 21_047)
        XCTAssertEqual(empty.newTargetTotal, 0)
        XCTAssertEqual(empty.targetNewToday, 0)
        try await MainActor.run {
            let engine = try ExamLearningEngine.fresh(bank: bank(832), hash: fixtureHash)
            try engine.start(day: 21_000)
            let before = engine.record.snapshot
            let plan = ExamStudyPlan(totalQuestionCount: 832, unseenQuestionCount: 832,
                newIntroducedToday: 0, todayDay: 21_001, examDay: 21_047)
            XCTAssertEqual(plan.targetNewToday, 26)
            XCTAssertEqual(try engine.info.new_remaining, 25)
            XCTAssertEqual(engine.record.snapshot, before)
        }
    }
}
