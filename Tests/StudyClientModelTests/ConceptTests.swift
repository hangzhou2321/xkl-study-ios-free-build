import XCTest
import StudyCore
@testable import StudyClientModel

final class ConceptTests: XCTestCase {
    private let fixtureHash = String(repeating: "e", count: 64)
    private func bank(_ count: Int = 5, variants: Int = 12, multiple: Bool = false) -> ConceptBank {
        ConceptBank(id: "fictional", title: "虚构测试", scope: "测试", notice: "虚构数据",
            sources: [ConceptSource(id: "s", title: "测试依据", reference: "fictional")],
            concepts: (0..<count).map { c in
                StudyConcept(id: "c\(c)", title: "考点\(c)", section: "测试", method: "测试方法",
                    questions: (0..<variants).map { v in
                        ConceptQuestion(id: "c\(c)q\(v)", type: multiple ? .multiple : .single,
                            prompt: "虚构考点\(c)的不同题\(v)",
                            options: [ExamOption(id: "A", text: "甲"), ExamOption(id: "B", text: "乙"), ExamOption(id: "C", text: "丙")],
                            answer: multiple ? ["A", "B"] : ["A"],
                            explanation: "测试解析", sourceIDs: ["s"], sourceLocation: "测试位置", verification: "测试核对")
                    })
            })
    }
    private func roundtrip(_ e: ConceptEngine) throws -> ConceptEngine {
        try ConceptEngine(bank: e.bank, hash: fixtureHash,
            record: JSONDecoder().decode(ConceptRecord.self, from: JSONEncoder().encode(e.record)))
    }
    private func answer(_ e: inout ConceptEngine, _ id: String = "A", day: Int = 21_000) throws {
        let p = try XCTUnwrap(e.record.presentation)
        try e.answer(id, token: p.id, day: day)
        try e.record.validate(bank: e.bank, hash: fixtureHash)
        e.next(token: p.id)
    }

    func testPackRequiresHashSourcesExplanationAndDifferentPrompts() throws {
        let original = bank(), bytes = try JSONEncoder().encode(original)
        let pack = ConceptContent(format: "xkl-concepts-v1", bankBytes: bytes, bankSHA256: StudySHA256.hex(bytes))
        XCTAssertEqual(try ConceptContent.load(JSONEncoder().encode(pack)).1, original)
        XCTAssertThrowsError(try ConceptContent.load(JSONEncoder().encode(
            ConceptContent(format: "xkl-concepts-v1", bankBytes: bytes, bankSHA256: fixtureHash))))
        let c = original.concepts[0]
        let bad = ConceptBank(id: original.id, title: original.title, scope: original.scope, notice: original.notice,
            sources: original.sources, concepts: [
                StudyConcept(id: c.id, title: c.title, section: c.section, method: c.method,
                             questions: [c.questions[0], c.questions[0]])
            ])
        XCTAssertThrowsError(try bad.validate())
    }
    func testCorrectReturnsTomorrowWithDifferentQuestionAndNeverMarksFamiliar() throws {
        var e = try ConceptEngine(bank: bank(1), hash: fixtureHash)
        try e.start(day: 21_000)
        let first = try XCTUnwrap(e.question?.id)
        try answer(&e)
        XCTAssertNil(e.shown)
        XCTAssertEqual(e.record.progress["c0"]?.dueDay, 21_001)
        XCTAssertFalse(e.record.progress["c0"]!.familiar)
        try e.start(day: 21_000)
        XCTAssertNil(e.shown)
        try e.start(day: 21_001)
        XCTAssertNotEqual(e.question?.id, first)
        try answer(&e, day: 21_001)
        XCTAssertEqual(e.record.progress["c0"]?.dueDay, 21_003)
        XCTAssertEqual(e.record.progress["c0"]?.delayedCorrect, 1)
    }
    func testWrongUsesUnseenVariantAfterThreeOtherConceptsAndOnlyOneRetry() throws {
        var e = try ConceptEngine(bank: bank(), hash: fixtureHash)
        try e.start(day: 21_000)
        let original = try XCTUnwrap(e.question?.id)
        try answer(&e, "B")
        XCTAssertTrue(e.record.attempts[0].retryQueued)
        for c in ["c1", "c2", "c3"] {
            XCTAssertEqual(e.concept?.id, c)
            try answer(&e)
        }
        XCTAssertEqual(e.concept?.id, "c0")
        XCTAssertNotEqual(e.question?.id, original)
        try answer(&e, "B")
        XCTAssertFalse(e.record.attempts.last!.retryQueued)
        XCTAssertEqual(e.record.progress["c0"]?.wrong, 2)
        XCTAssertEqual(e.record.progress["c0"]?.dueDay, 21_001)
        XCTAssertFalse(e.record.queue.contains("c0"))
    }
    func testShortTailWaitsForNextDayAndRepairCorrectDoesNotAdvanceLevel() throws {
        var solo = try ConceptEngine(bank: bank(1), hash: fixtureHash)
        try solo.start(day: 21_000)
        try answer(&solo, "B")
        XCTAssertNil(solo.shown)
        try solo.start(day: 21_000)
        XCTAssertNil(solo.shown)
        try solo.start(day: 21_001)
        XCTAssertEqual(solo.question?.id, "c0q1")
        var e = try ConceptEngine(bank: bank(), hash: fixtureHash)
        try e.start(day: 21_000)
        try answer(&e, "B")
        for _ in 0..<3 { try answer(&e) }
        try answer(&e)
        XCTAssertEqual(e.record.progress["c0"]?.level, 0)
        XCTAssertEqual(e.record.progress["c0"]?.delayedCorrect, 0)
        XCTAssertEqual(e.record.progress["c0"]?.dueDay, 21_001)
    }
    func testExhaustedVariantsNeverCycleOrDeclareMastery() throws {
        var e = try ConceptEngine(bank: bank(1, variants: 2), hash: fixtureHash)
        try e.start(day: 21_000)
        try answer(&e)
        try e.start(day: 21_001)
        try answer(&e, day: 21_001)
        try e.start(day: 21_010)
        XCTAssertNil(e.shown)
        XCTAssertEqual(e.exhausted.map(\.id), ["c0"])
        XCTAssertFalse(e.record.progress["c0"]!.familiar)
        XCTAssertEqual(e.record.attempts.count, 2)
    }
    func testResultPageAndSelectionsPersistAndStaleTapCannotGradeNext() throws {
        var e = try ConceptEngine(bank: bank(2), hash: fixtureHash)
        try e.start(day: 21_000)
        let original = try XCTUnwrap(e.record.presentation)
        try e.answer("A", token: original.id, day: 21_000)
        let record = e.record
        e = try roundtrip(e)
        XCTAssertEqual(e.record.review, record.review)
        try e.start(day: 21_001)
        XCTAssertEqual(e.shown?.id, original.id)
        try e.answer("B", token: original.id, day: 21_001)
        XCTAssertEqual(e.record.attempts.count, 1)
        e.next(token: original.id)
        let next = e.shown
        try e.answer("A", token: original.id, day: 21_001)
        e.next(token: original.id)
        XCTAssertEqual(e.shown, next)
        XCTAssertEqual(e.record.attempts.count, 1)
    }
    func testMultipleChoiceMissingAndExtraAreWrong() throws {
        var e = try ConceptEngine(bank: bank(1, multiple: true), hash: fixtureHash)
        try e.start(day: 21_000)
        var token = try XCTUnwrap(e.shown?.id)
        e.toggle("A", token: token)
        e = try roundtrip(e)
        XCTAssertEqual(e.shown?.selected, ["A"])
        try e.answer(token: token, day: 21_000)
        XCTAssertEqual(e.record.review?.isCorrect, false)
        e.next(token: token)
        try e.start(day: 21_001)
        token = try XCTUnwrap(e.shown?.id)
        for id in ["A", "B", "C"] { e.toggle(id, token: token) }
        try e.answer(token: token, day: 21_001)
        XCTAssertEqual(e.record.review?.isCorrect, false)
    }
    func testFamiliarUndoPreservesOriginalVariantAndAppendOnlyHistory() throws {
        var e = try ConceptEngine(bank: bank(2), hash: fixtureHash)
        try e.start(day: 21_000)
        let first = try XCTUnwrap(e.shown)
        try e.familiar(token: first.id, day: 21_000)
        let prior = e.record.attempts
        e = try roundtrip(e)
        e.undo()
        XCTAssertEqual(e.shown?.questionID, first.questionID)
        XCTAssertEqual(e.shown?.order, first.order)
        XCTAssertNotEqual(e.shown?.id, first.id)
        XCTAssertFalse(e.record.progress["c0"]!.familiar)
        XCTAssertEqual(Array(e.record.attempts.prefix(1)), prior)
        XCTAssertEqual(e.record.attempts.last?.undoTarget, prior[0].id)
        try e.record.validate(bank: e.bank, hash: fixtureHash)
    }
    func testRotationKeepsResultUndoAndSequenceAcrossVolumes() throws {
        var e = try ConceptEngine(bank: bank(2), hash: fixtureHash)
        try e.start(day: 21_000)
        let first = try XCTUnwrap(e.shown?.id)
        try e.answer("A", token: first, day: 21_000)
        let result = e.record.review
        try e.rotate(hash: String(repeating: "a", count: 64))
        e = try roundtrip(e)
        XCTAssertEqual(e.record.review, result)
        e.next(token: first)
        try e.familiar(token: XCTUnwrap(e.shown?.id), day: 21_000)
        try e.rotate(hash: String(repeating: "b", count: 64))
        e = try roundtrip(e)
        e.undo()
        XCTAssertEqual(e.record.attempts[0].sequence, 3)
        XCTAssertEqual(e.record.volumes.count, 2)
        XCTAssertEqual(e.record.nextSequence, 4)
        try e.record.validate(bank: e.bank, hash: fixtureHash)
    }
    func testTwentyFiveNewConceptsAndUncappedDueReviews() throws {
        var e = try ConceptEngine(bank: bank(51), hash: fixtureHash)
        for expected in [25, 25, 1] {
            try e.start(day: 21_000)
            XCTAssertEqual(e.record.queue.count, expected)
            while e.record.presentation != nil { try answer(&e) }
        }
        try e.start(day: 21_001)
        XCTAssertEqual(e.record.queue.count, 51)
        XCTAssertEqual(Set(e.record.attempts.map { $0.presentation.questionID }).count, 51)
    }
    func testClockRollbackAndBadHistoryFailClosed() throws {
        var e = try ConceptEngine(bank: bank(1), hash: fixtureHash)
        try e.start(day: 21_000)
        let p = try XCTUnwrap(e.shown)
        XCTAssertThrowsError(try e.answer("A", token: p.id, day: 20_999))
        XCTAssertTrue(e.record.attempts.isEmpty)
        try e.answer("A", token: p.id, day: 21_000)
        var bad = e.record
        bad.nextSequence += 1
        XCTAssertThrowsError(try ConceptEngine(bank: e.bank, hash: fixtureHash, record: bad))
        bad = e.record
        bad.progress["c0"]!.usedQuestionIDs.append("not-in-bank")
        XCTAssertThrowsError(try ConceptEngine(bank: e.bank, hash: fixtureHash, record: bad))
    }
    func testShuffledOptionsAreNotNewVariantButDifferentNumericalCandidatesAre() throws {
        let original = bank(1), c = original.concepts[0], q = c.questions[0]
        func variant(_ options: [ExamOption]) -> ConceptQuestion {
            ConceptQuestion(id: "different-id", type: q.type, prompt: q.prompt,
                options: options, answer: q.answer, explanation: q.explanation,
                sourceIDs: q.sourceIDs, sourceLocation: q.sourceLocation, verification: q.verification)
        }
        func with(_ second: ConceptQuestion) -> ConceptBank {
            ConceptBank(id: original.id, title: original.title, scope: original.scope,
                notice: original.notice, sources: original.sources, concepts: [
                    StudyConcept(id: c.id, title: c.title, section: c.section, method: c.method,
                                 questions: [q, second])
                ])
        }
        XCTAssertThrowsError(try with(variant(Array(q.options.reversed()))).validate())
        let different = [ExamOption(id: "A", text: "12"), ExamOption(id: "B", text: "21"),
                         ExamOption(id: "C", text: "35")]
        XCTAssertNoThrow(try with(variant(different)).validate())
    }
}
