import Foundation
import XCTest
@testable import StudyClientModel

final class ProfessionalQuestionStudyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)
    private func question(_ id: String = "source-q1", book: String = "basic") -> ProfessionalObjectiveQuestion {
        .init(id: id, type: .single, book: book, chapter: "Synthetic chapter", prompt: "Synthetic original question \(id)",
            options: [.init(id: "A", text: "one"), .init(id: "B", text: "two"), .init(id: "C", text: "three")],
            answer: ["B"], sourceLocation: "Synthetic page 1", sourceDocumentID: "synthetic", pdfPage: 1, sourceAnswer: "B")
    }
    private func package(_ qs: [ProfessionalObjectiveQuestion], revision: String = "1") -> ProfessionalQuestionPackage {
        .init(id: "synthetic-professional-power", subject: .power, title: "Synthetic originals", revision: revision,
            sources: [.init(id: "synthetic", title: "Synthetic source", reference: "synthetic-only")], questions: qs)
    }
    private func answer(_ e: inout ProfessionalQuestionEngine, _ values: [String], at date: Date) throws -> ProfessionalQuestionAttempt {
        let p = try XCTUnwrap(e.presentation); try e.saveDraft(values, token: p.id); try e.submit(token: p.id, now: date)
        return try XCTUnwrap(e.result)
    }
    private func close(_ e: inout ProfessionalQuestionEngine, at date: Date) throws {
        try e.next(token: try XCTUnwrap(e.presentation).id, now: date)
    }

    func testWrongWaitsUntilTomorrowAndNeverReturnsInSameRound() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question()])); try e.start(now: now)
        let a = try answer(&e, ["A"], at: now), day = try ConceptCalendar.studyDay(now)
        XCTAssertFalse(a.isCorrect); XCTAssertEqual(a.dueDay, day + 1)
        try close(&e, at: now); XCTAssertNil(e.presentation); try e.start(now: now); XCTAssertNil(e.presentation)
        try e.start(now: now.addingTimeInterval(86_400)); XCTAssertNotNil(e.presentation)
    }
    func testDueCountExcludesNewQuestionsAndIncludesTomorrowWrongReview() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question("first"), question("second")]))
        XCTAssertEqual(e.stats(on: now).due, 0); XCTAssertEqual(e.stats(on: now).unseen, 2)
        try e.start(now: now); _ = try answer(&e, ["A"], at: now); try close(&e, at: now)
        XCTAssertEqual(e.stats(on: now).due, 0); XCTAssertEqual(e.stats(on: now).unseen, 1)
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertEqual(e.stats(on: tomorrow).due, 1); XCTAssertEqual(e.stats(on: tomorrow).unseen, 1)
    }
    func testCorrectStartsAtThreeDaysThenSevenAndKeepsEnglishSeparate() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question()])); try e.start(now: now)
        let firstOrder = try XCTUnwrap(e.presentation).optionOrder
        let first = try answer(&e, ["B"], at: now); XCTAssertEqual(first.dueDay, first.day + 3)
        try close(&e, at: now); try e.start(now: now.addingTimeInterval(2 * 86_400)); XCTAssertNil(e.presentation)
        let later = now.addingTimeInterval(3 * 86_400); try e.start(now: later)
        XCTAssertNotEqual(e.presentation?.optionOrder, firstOrder)
        let second = try answer(&e, ["B"], at: later); XCTAssertEqual(second.dueDay, second.day + 7)
        XCTAssertEqual(e.record.progress[question().id]?.independentCorrectCount, 2)
    }
    func testWrongAfterSuccessResetsIndependentStreak() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question()])); try e.start(now: now)
        _ = try answer(&e, ["B"], at: now); try close(&e, at: now)
        let later = now.addingTimeInterval(3 * 86_400); try e.start(now: later)
        let wrong = try answer(&e, ["A"], at: later)
        XCTAssertEqual(wrong.dueDay, wrong.day + 1); XCTAssertEqual(wrong.afterProgress.correctStreak, 0)
    }
    func testRepeatedSubmitTokenCannotDoubleCountOrMutateFeedback() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question()])); try e.start(now: now)
        let p = try XCTUnwrap(e.presentation); _ = try answer(&e, ["B"], at: now)
        let record = e.record; try e.submit(token: p.id, now: now.addingTimeInterval(20))
        XCTAssertEqual(e.record, record); XCTAssertEqual(e.record.attempts.count, 1)
        XCTAssertThrowsError(try e.saveDraft(["A"], token: p.id)); XCTAssertEqual(e.record, record)
    }
    func testDraftPermutationAndSubmittedFeedbackSurviveRestore() throws {
        let pack = package([question()]); var e = try ProfessionalQuestionEngine.fresh(pack); try e.start(now: now)
        let p = try XCTUnwrap(e.presentation); try e.saveDraft(["B"], token: p.id)
        let raw = try JSONEncoder().encode(e.record)
        var restored = try ProfessionalQuestionEngine(package: pack, record: JSONDecoder().decode(ProfessionalQuestionRecord.self, from: raw))
        XCTAssertEqual(restored.presentation, e.presentation); try restored.submit(token: p.id, now: now)
        let graded = try ProfessionalQuestionEngine(package: pack, record: restored.record)
        XCTAssertEqual(graded.result, restored.result); XCTAssertEqual(graded.presentation?.optionOrder, p.optionOrder)
    }
    func testPreservedOptionOrderAndStableIDsDetermineTheGrade() throws {
        var q = question(); q.preserveOptionOrder = true
        var e = try ProfessionalQuestionEngine.fresh(package([q])); try e.start(now: now)
        XCTAssertEqual(e.presentation?.optionOrder, ["A", "B", "C"])
        XCTAssertTrue(try answer(&e, ["B"], at: now).isCorrect)
    }
    func testLetterDependentOriginalKeepsGivenOrderEvenWithoutManualFlag() throws {
        let a = question()
        let q = ProfessionalObjectiveQuestion(id: a.id, type: a.type, book: a.book, chapter: a.chapter,
            prompt: "请选择正确选项", options: [.init(id: "A", text: "one"), .init(id: "B", text: "two"), .init(id: "C", text: "以上都正确")],
            answer: ["C"], sourceLocation: a.sourceLocation, sourceDocumentID: a.sourceDocumentID, pdfPage: 1, sourceAnswer: "C")
        XCTAssertFalse(q.canShuffleOptions)
        var e = try ProfessionalQuestionEngine.fresh(package([q])); try e.start(now: now)
        XCTAssertEqual(e.presentation?.optionOrder, ["A", "B", "C"])
        XCTAssertTrue(try answer(&e, ["C"], at: now).isCorrect)
    }
    func testMultipleSelectionRequiresTheCompleteGivenAnswerSet() throws {
        let source = question()
        let q = ProfessionalObjectiveQuestion(id: source.id, type: .multiple, book: source.book, chapter: source.chapter,
            prompt: source.prompt, options: source.options, answer: ["A", "C"], sourceLocation: source.sourceLocation,
            sourceDocumentID: source.sourceDocumentID, pdfPage: source.pdfPage, sourceAnswer: "AC")
        var e = try ProfessionalQuestionEngine.fresh(package([q])); try e.start(now: now)
        XCTAssertFalse(try answer(&e, ["A"], at: now).isCorrect)
        XCTAssertFalse(q.correct(["A", "B", "C"])); XCTAssertTrue(q.correct(["C", "A"]))
    }
    func testHelpedCorrectIsRecordedWithoutIndependentSuccessOrStreak() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question()])); try e.start(now: now)
        try e.markHelped(token: try XCTUnwrap(e.presentation).id)
        let a = try answer(&e, ["B"], at: now)
        XCTAssertTrue(a.isCorrect); XCTAssertTrue(a.helped); XCTAssertFalse(a.independent)
        XCTAssertEqual(a.afterProgress.correctStreak, 0); XCTAssertEqual(a.afterProgress.independentCorrectCount, 0)
        XCTAssertEqual(e.stats(on: now).independentCorrect, 0); XCTAssertEqual(a.dueDay, a.day + 3)
    }
    func testDuplicateOriginalAcrossBooksSharesCooldownWithoutFabricatedGrade() throws {
        let a = question(), b = ProfessionalObjectiveQuestion(id: "source-reinforced", type: a.type, book: "reinforcement", chapter: a.chapter,
            prompt: a.prompt, options: a.options, answer: a.answer, sourceLocation: "Other source page", sourceDocumentID: a.sourceDocumentID,
            pdfPage: 2, sourceAnswer: a.sourceAnswer)
        var e = try ProfessionalQuestionEngine.fresh(package([b, a])); try e.start(now: now)
        XCTAssertEqual(e.currentQuestion?.id, a.id); _ = try answer(&e, ["B"], at: now); try close(&e, at: now)
        XCTAssertNil(e.presentation); XCTAssertNil(e.record.progress[b.id]); XCTAssertEqual(e.record.attempts.count, 1)
        XCTAssertEqual(e.stats(on: now).answered, 1); XCTAssertEqual(e.stats(on: now).due, 0)
    }
    func testBasicPrecedesReinforcementAndInactiveQuestionsStayArchived() throws {
        var archived = question("archived"); archived.isActive = false; archived.scopeNote = "Outside current mainline"
        var e = try ProfessionalQuestionEngine.fresh(package([archived, question("reinforced", book: "reinforcement"), question("basic")]))
        try e.start(now: now); XCTAssertEqual(e.currentQuestion?.id, "basic")
        XCTAssertEqual(e.stats(on: now).total, 2); XCTAssertEqual(e.stats(on: now).archived, 1)
    }
    func testDeferMovesToRoundTailWithoutGradeOrDueDate() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question("first"), question("second")])); try e.start(now: now)
        try e.deferCurrent(token: try XCTUnwrap(e.presentation).id, now: now)
        XCTAssertEqual(e.currentQuestion?.id, "second"); XCTAssertTrue(e.record.progress.isEmpty); XCTAssertTrue(e.record.attempts.isEmpty)
        _ = try answer(&e, ["B"], at: now); try close(&e, at: now); XCTAssertEqual(e.currentQuestion?.id, "first")
    }
    func testClockRollbackAndInvalidSubmitLeaveStateUnchanged() throws {
        var e = try ProfessionalQuestionEngine.fresh(package([question()])); try e.start(now: now); let record = e.record
        XCTAssertThrowsError(try e.start(now: now.addingTimeInterval(-86_400))); XCTAssertEqual(e.record, record)
        XCTAssertThrowsError(try e.submit(token: try XCTUnwrap(e.presentation).id, now: now)); XCTAssertEqual(e.record, record)
    }
    func testDeferredDraftAndHelpFlagRestoreWithOriginalToken() throws {
        let pack = package([question("first"), question("second")]); var e = try ProfessionalQuestionEngine.fresh(pack)
        try e.start(now: now); let first = try XCTUnwrap(e.presentation)
        try e.saveDraft(["A"], token: first.id); try e.markHelped(token: first.id)
        try e.deferCurrent(token: first.id, now: now)
        e = try ProfessionalQuestionEngine(package: pack, record: e.record)
        XCTAssertEqual(e.currentQuestion?.id, "second")
        _ = try answer(&e, ["B"], at: now); try close(&e, at: now)
        XCTAssertEqual(e.presentation?.id, first.id); XCTAssertEqual(e.presentation?.selectedOptions, ["A"])
        XCTAssertTrue(e.presentation?.helped == true); XCTAssertEqual(e.presentation?.optionOrder, first.optionOrder)
    }
    func testInactiveUntranscribedOriginalCanRemainArchivedWithoutInventedChoices() throws {
        var archived = ProfessionalObjectiveQuestion(id: "archive-unread", type: .single, book: "basic", chapter: "Source chapter",
            prompt: "Original source is present, options remain unread", options: [], answer: [], sourceLocation: "Source page 1",
            sourceDocumentID: "synthetic", pdfPage: 1, sourceAnswer: "")
        archived.isActive = false; archived.scopeNote = "Awaiting legible supplied answer"
        let pack = package([archived, question()]); try pack.validate()
        var e = try ProfessionalQuestionEngine.fresh(pack); try e.start(now: now)
        XCTAssertEqual(e.currentQuestion?.id, question().id); XCTAssertEqual(e.stats(on: now).archived, 1)
        archived.isActive = true
        XCTAssertThrowsError(try package([archived]).validate())
    }
    func testReimportIsIdempotentAndCorrectionRetainsFrozenInterruptedDefinition() throws {
        let original = package([question()]); var e = try ProfessionalQuestionEngine.fresh(original); try e.start(now: now)
        try e.saveDraft(["B"], token: try XCTUnwrap(e.presentation).id); let old = e.record
        try e.updatePackage(original); XCTAssertEqual(e.record, old)
        let q = question(); let corrected = ProfessionalObjectiveQuestion(id: q.id, type: q.type, book: q.book, chapter: q.chapter,
            prompt: q.prompt, options: q.options, answer: ["C"], sourceLocation: q.sourceLocation,
            sourceDocumentID: q.sourceDocumentID, pdfPage: q.pdfPage, sourceAnswer: "C")
        let updated = package([corrected, question("new-source")], revision: "2"); try e.updatePackage(updated)
        XCTAssertEqual(e.presentation, old.presentation); XCTAssertEqual(e.currentQuestion, q)
        XCTAssertEqual(e.record.definitions[q.definitionID], q); XCTAssertEqual(e.record.definitions[corrected.definitionID], corrected)
        XCTAssertTrue(try answer(&e, ["B"], at: now).isCorrect, "Interrupted original definition keeps its supplied key")
        let frozen = e.record; XCTAssertThrowsError(try e.updatePackage(original)); XCTAssertEqual(e.record, frozen)
        let restored = try ProfessionalQuestionEngine(package: updated, record: e.record); XCTAssertEqual(restored.record, e.record)
    }
    func testRemovingQuestionOrTamperingWithAttemptCannotResetProgress() throws {
        let pack = package([question(), question("other")]); var e = try ProfessionalQuestionEngine.fresh(pack); try e.start(now: now)
        _ = try answer(&e, ["B"], at: now); let record = e.record
        XCTAssertThrowsError(try e.updatePackage(package([question()], revision: "2"))); XCTAssertEqual(e.record, record)
        var broken = record; broken.progress[question().id]?.correctCount = 200
        XCTAssertThrowsError(try ProfessionalQuestionEngine(package: pack, record: broken))
    }
}
