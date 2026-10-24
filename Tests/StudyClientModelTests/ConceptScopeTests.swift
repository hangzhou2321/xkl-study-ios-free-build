import XCTest
import StudyCore
@testable import StudyClientModel

final class ConceptScopeTests: XCTestCase {
    private let fixtureHash = String(repeating: "b", count: 64)
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func bank(_ count: Int = 2, variants: Int = 4, multiple: Bool = false) -> ConceptBank {
        ConceptBank(id: "scope-fixture", title: "测试", scope: "虚构范围", notice: "虚构测试题",
            sources: [ConceptSource(id: "s", title: "虚构来源", reference: "test")],
            concepts: (0..<count).map { c in
                StudyConcept(id: "c\(c)", title: "考点\(c)", section: "测试", method: "方法",
                    questions: (0..<variants).map { q in
                        ConceptQuestion(id: "c\(c)q\(q)", type: multiple ? .multiple : .single,
                            prompt: "考点\(c)独立题\(q)",
                            options: [ExamOption(id: "A", text: "甲"),
                                      ExamOption(id: "B", text: "乙"), ExamOption(id: "C", text: "丙")],
                            answer: multiple ? ["A", "B"] : ["A"], explanation: "测试解析",
                            sourceIDs: ["s"], sourceLocation: "测试", verification: "测试核对")
                    })
            })
    }

    private func scoped(_ bank: ConceptBank, include: [String]) -> ConceptBank {
        var result = bank
        let included = Set(include)
        let excluded = bank.concepts.flatMap(\.questions).map(\.id).filter { !included.contains($0) }
        result.studyScope = ConceptStudyScope(id: "syllabus-2027", title: "2027 主练",
            sourceReference: "fictional-syllabus", includedQuestionIDs: include,
            excludedQuestionReasons: Dictionary(uniqueKeysWithValues: excluded.map { ($0, "测试：移出主练") }))
        return result
    }

    private func migrate(_ engine: ConceptEngine, to bank: ConceptBank) throws -> ConceptEngine {
        var next = try ConceptEngine(bank: bank, hash: fixtureHash, record: engine.record)
        next.applyStudyScope(now: instant)
        try next.record.validate(bank: bank, hash: fixtureHash)
        return next
    }

    private func answer(_ engine: inout ConceptEngine, choice: String = "A") throws {
        let p = try XCTUnwrap(engine.record.presentation)
        try engine.answer(choice, token: p.id, day: engine.record.day, now: instant)
        engine.next(token: p.id, now: instant)
    }

    private func assertHistoryUnchanged(_ before: ConceptRecord, _ after: ConceptRecord,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.progress, before.progress, file: file, line: line)
        XCTAssertEqual(after.attempts, before.attempts, file: file, line: line)
        XCTAssertEqual(after.volumes, before.volumes, file: file, line: line)
        XCTAssertEqual(after.nextSequence, before.nextSequence, file: file, line: line)
        XCTAssertEqual(after.day, before.day, file: file, line: line)
        XCTAssertEqual(after.retriesToday, before.retriesToday, file: file, line: line)
        XCTAssertEqual(after.sessionID, before.sessionID, file: file, line: line)
    }

    func testLegacyBankAndRecordDecodeWithoutScopeFields() throws {
        let original = bank()
        var bankJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        bankJSON.removeValue(forKey: "studyScope")
        let decoded = try JSONDecoder().decode(ConceptBank.self, from: JSONSerialization.data(withJSONObject: bankJSON))
        XCTAssertNil(decoded.studyScope)
        XCTAssertEqual(decoded.activeQuestions(in: decoded.concepts[0]), decoded.concepts[0].questions)
        XCTAssertTrue(decoded.isActive("c0q0"))
        XCTAssertFalse(decoded.isActive("unknown"))
        let prior = ConceptRecord(bankSHA256: fixtureHash)
        var recordJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prior)) as? [String: Any])
        recordJSON.removeValue(forKey: "scopeSuspensions")
        let record = try JSONDecoder().decode(ConceptRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON))
        XCTAssertNil(record.scopeSuspensions)
        XCTAssertNoThrow(try record.validate(bank: decoded, hash: fixtureHash))
    }

    func testScopeRejectsUnknownMissingDuplicateOverlappingOrUnexplainedIDs() throws {
        let original = bank(1)
        let valid = scoped(original, include: ["c0q0"])
        XCTAssertNoThrow(try valid.validate())
        XCTAssertNoThrow(try valid.validateAppendOnly(from: original))
        func check(_ included: [String], _ excluded: [String: String]) {
            var invalid = original
            invalid.studyScope = ConceptStudyScope(id: "2027", title: "范围", sourceReference: "测试",
                includedQuestionIDs: included, excludedQuestionReasons: excluded)
            XCTAssertThrowsError(try invalid.validate())
        }
        check(["c0q0", "unknown"], ["c0q1": "停", "c0q2": "停", "c0q3": "停"])
        check(["c0q0"], ["c0q1": "停", "c0q2": "停"])
        check(["c0q0", "c0q0"], ["c0q1": "停", "c0q2": "停", "c0q3": "停"])
        check(["c0q0"], ["c0q0": "停", "c0q1": "停", "c0q2": "停", "c0q3": "停"])
        check(["c0q0"], ["c0q1": " ", "c0q2": "停", "c0q3": "停"])
        check([], ["c0q0": "停", "c0q1": "停", "c0q2": "停", "c0q3": "停"])
    }

    func testManyHistoricallyUsedQuestionsDoNotHideFewActiveUnseenVariants() throws {
        let original = bank(1, variants: 9)
        var engine = try ConceptEngine(bank: original, hash: fixtureHash)
        for offset in 0..<6 {
            try engine.start(day: 21_000 + 200 * offset, now: instant)
            try answer(&engine)
        }
        XCTAssertEqual(engine.record.progress["c0"]?.usedQuestionIDs.count, 6)
        let before = engine.record
        engine = try migrate(engine, to: scoped(original, include: ["c0q7", "c0q8"]))
        assertHistoryUnchanged(before, engine.record)
        XCTAssertEqual(engine.activeQuestionCount, 2)
        XCTAssertTrue(engine.exhausted.isEmpty)
        try engine.start(day: 22_200, now: instant)
        XCTAssertEqual(engine.question?.id, "c0q7")
        try answer(&engine)
        XCTAssertTrue(engine.exhausted.isEmpty)
        try engine.start(day: 22_500, now: instant)
        XCTAssertEqual(engine.question?.id, "c0q8")
        try answer(&engine)
        XCTAssertEqual(engine.exhausted.map(\.id), ["c0"])
    }

    func testPendingMultipleSelectionsAreParkedWithoutInventingAnAnswer() throws {
        let original = bank(2, multiple: true)
        var engine = try ConceptEngine(bank: original, hash: fixtureHash)
        try engine.start(day: 21_000, now: instant)
        let token = try XCTUnwrap(engine.shown?.id)
        engine.toggle("B", token: token)
        engine.toggle("A", token: token)
        let before = engine.record
        let newBank = scoped(original, include: ["c0q1", "c1q0"])
        engine = try migrate(engine, to: newBank)
        assertHistoryUnchanged(before, engine.record)
        XCTAssertNil(engine.record.presentation)
        let suspension = try XCTUnwrap(engine.record.scopeSuspensions?.first)
        XCTAssertEqual(suspension.scopeID, "syllabus-2027")
        XCTAssertEqual(suspension.parkedAt, instant)
        XCTAssertEqual(suspension.presentation, before.presentation)
        XCTAssertEqual(suspension.presentation?.selected, ["A", "B"])
        XCTAssertTrue(engine.record.attempts.isEmpty)
        engine.applyStudyScope(now: instant)
        XCTAssertEqual(engine.record.scopeSuspensions?.count, 1)
        try engine.start(day: 21_000, now: instant)
        XCTAssertEqual(engine.question?.id, "c0q1")
        XCTAssertEqual(engine.record.presentation?.selected, [])
        XCTAssertNil(engine.record.progress["c0"])
    }

    func testRetiredResultParksExactAttemptAndRetainsSchedule() throws {
        let original = bank(1)
        var engine = try ConceptEngine(bank: original, hash: fixtureHash)
        try engine.start(day: 21_000, now: instant)
        let token = try XCTUnwrap(engine.shown?.id)
        try engine.answer("A", token: token, day: 21_000, now: instant)
        let before = engine.record
        let newBank = scoped(original, include: ["c0q1", "c0q2"])
        var beforeExplicitMigration = try ConceptEngine(bank: newBank, hash: fixtureHash, record: before)
        beforeExplicitMigration.next(token: token, now: instant)
        XCTAssertEqual(beforeExplicitMigration.record.review, before.review)
        engine = try migrate(engine, to: newBank)
        assertHistoryUnchanged(before, engine.record)
        XCTAssertNil(engine.record.review)
        XCTAssertEqual(engine.record.scopeSuspensions?.first?.review, before.review)
        XCTAssertEqual(engine.record.progress["c0"]?.dueDay, 21_001)
        try engine.start(day: 21_000, now: instant)
        XCTAssertNil(engine.shown)
        try engine.start(day: 21_001, now: instant)
        XCTAssertEqual(engine.question?.id, "c0q1")
    }

    func testRetiredFamiliarUndoIsParkedWithoutUnmarkingFamiliar() throws {
        let original = bank(2)
        var engine = try ConceptEngine(bank: original, hash: fixtureHash)
        try engine.start(day: 21_000, now: instant)
        try engine.familiar(token: XCTUnwrap(engine.shown?.id), day: 21_000, now: instant)
        let before = engine.record
        XCTAssertTrue(before.progress["c0"]!.familiar)
        engine = try migrate(engine, to: scoped(original, include: ["c0q1", "c1q0", "c1q1"]))
        assertHistoryUnchanged(before, engine.record)
        XCTAssertNil(engine.record.undoFamiliar)
        XCTAssertEqual(engine.record.presentation, before.presentation)
        XCTAssertEqual(engine.record.scopeSuspensions?.first?.undoFamiliar, before.undoFamiliar)
        engine.undo(now: instant)
        XCTAssertTrue(engine.record.progress["c0"]!.familiar)
        XCTAssertEqual(engine.record.attempts, before.attempts)
    }

    func testEntireRetiredConceptIsNeitherFreshNorDueNorExhausted() throws {
        let original = bank(2)
        let scopedBank = scoped(original, include: ["c1q0", "c1q1"])
        var fresh = try ConceptEngine(bank: scopedBank, hash: fixtureHash)
        try fresh.start(day: 21_000, now: instant)
        XCTAssertEqual(fresh.record.queue, ["c1"])
        XCTAssertEqual(fresh.archivedConcepts.map(\.id), ["c0"])
        XCTAssertEqual(fresh.activeConcepts.map(\.id), ["c1"])
        XCTAssertFalse(fresh.exhausted.contains { $0.id == "c0" })

        var old = try ConceptEngine(bank: original, hash: fixtureHash)
        try old.start(day: 21_000, now: instant)
        try answer(&old)
        try answer(&old)
        let before = old.record
        var migrated = try migrate(old, to: scopedBank)
        assertHistoryUnchanged(before, migrated.record)
        try migrated.start(day: 21_001, now: instant)
        XCTAssertEqual(migrated.record.queue, ["c1"])
        XCTAssertEqual(migrated.question?.id, "c1q1")
        XCTAssertEqual(migrated.record.progress["c0"], before.progress["c0"])
    }

    func testPartialRetirementSkipsQuestionWithoutConsumingItAndRepairUsesActiveVariant() throws {
        let original = bank(5, variants: 3)
        let include = original.concepts.flatMap(\.questions).map(\.id).filter { $0 != "c0q1" }
        var engine = try ConceptEngine(bank: scoped(original, include: include), hash: fixtureHash)
        try engine.start(day: 21_000, now: instant)
        try answer(&engine, choice: "B")
        XCTAssertTrue(engine.record.attempts[0].retryQueued)
        for _ in 0..<3 { try answer(&engine) }
        XCTAssertEqual(engine.question?.id, "c0q2")
        try answer(&engine)
        XCTAssertEqual(engine.record.progress["c0"]?.usedQuestionIDs, ["c0q0", "c0q2"])
        XCTAssertFalse(engine.record.attempts.contains { $0.presentation.questionID == "c0q1" })
        XCTAssertEqual(engine.exhausted.filter { $0.id == "c0" }.count, 1)
    }

    func testNoRepairIsQueuedWhenOnlyRetiredVariantsRemain() throws {
        let original = bank(5, variants: 3)
        let include = original.concepts.flatMap(\.questions).map(\.id).filter {
            $0 != "c0q1" && $0 != "c0q2"
        }
        var engine = try ConceptEngine(bank: scoped(original, include: include), hash: fixtureHash)
        try engine.start(day: 21_000, now: instant)
        try answer(&engine, choice: "B")
        XCTAssertFalse(engine.record.attempts[0].retryQueued)
        XCTAssertFalse(engine.record.queue.contains("c0"))
    }

    func testScopeApplicationIsExplicitAndRetiredPendingCannotBeGraded() throws {
        let original = bank(1, multiple: true)
        var previous = try ConceptEngine(bank: original, hash: fixtureHash)
        try previous.start(day: 21_000, now: instant)
        let pending = try XCTUnwrap(previous.record.presentation)
        var engine = try ConceptEngine(bank: scoped(original, include: ["c0q1"]),
            hash: fixtureHash, record: previous.record)
        XCTAssertEqual(engine.record.presentation, pending, "Loading alone cannot discard a pointer.")
        XCTAssertNil(engine.record.scopeSuspensions)
        engine.toggle("A", token: pending.id)
        XCTAssertEqual(engine.record.presentation?.selected, [])
        XCTAssertThrowsError(try engine.answer(token: pending.id, day: 21_000))
        XCTAssertThrowsError(try engine.familiar(token: pending.id, day: 21_000))
        assertHistoryUnchanged(previous.record, engine.record)
    }

    func testSuspensionsRoundtripAndRejectFabricatedAttemptOrUnknownQuestion() throws {
        let original = bank(1)
        var previous = try ConceptEngine(bank: original, hash: fixtureHash)
        try previous.start(day: 21_000, now: instant)
        try previous.answer("A", token: XCTUnwrap(previous.shown?.id), day: 21_000, now: instant)
        let scopedBank = scoped(original, include: ["c0q1"])
        let engine = try migrate(previous, to: scopedBank)
        let encoded = try JSONEncoder().encode(engine.record)
        let decoded = try JSONDecoder().decode(ConceptRecord.self, from: encoded)
        XCTAssertEqual(decoded.scopeSuspensions, engine.record.scopeSuspensions)
        XCTAssertNoThrow(try decoded.validate(bank: scopedBank, hash: fixtureHash))
        var bad = decoded
        let actual = try XCTUnwrap(decoded.scopeSuspensions?.first?.review)
        let fabricated = ConceptAttempt(id: UUID(), sequence: actual.sequence, sessionID: actual.sessionID,
            presentation: actual.presentation, mode: actual.mode, isCorrect: actual.isCorrect,
            answeredAt: actual.answeredAt, day: actual.day, before: actual.before, after: actual.after,
            retryQueued: actual.retryQueued, undoTarget: nil)
        bad.scopeSuspensions = [ConceptScopeSuspension(scopeID: "2027", parkedAt: instant,
            presentation: nil, review: fabricated, undoFamiliar: nil)]
        XCTAssertThrowsError(try bad.validate(bank: scopedBank, hash: fixtureHash))
        let unknown = ConceptPresentation(id: UUID(), conceptID: "c0", questionID: "missing",
            order: ["A", "B", "C"], selected: ["A"], presentedAt: instant)
        bad.scopeSuspensions = [ConceptScopeSuspension(scopeID: "2027", parkedAt: instant,
            presentation: unknown, review: nil, undoFamiliar: nil)]
        XCTAssertThrowsError(try bad.validate(bank: scopedBank, hash: fixtureHash))
    }

    func testScopeCanParkResultAlreadyInAnImmutableVolume() throws {
        let original = bank(1)
        var previous = try ConceptEngine(bank: original, hash: fixtureHash)
        try previous.start(day: 21_000, now: instant)
        try previous.answer("A", token: XCTUnwrap(previous.shown?.id), day: 21_000, now: instant)
        let result = previous.record.review
        try previous.rotate(hash: String(repeating: "a", count: 64))
        let migrated = try migrate(previous, to: scoped(original, include: ["c0q1"]))
        XCTAssertEqual(migrated.record.scopeSuspensions?.first?.review, result)
        XCTAssertEqual(migrated.record.volumes, previous.record.volumes)
        XCTAssertTrue(migrated.record.attempts.isEmpty)
    }
}
