import XCTest
import StudyCore
@testable import StudyClientModel

final class ConceptCalendarTests: XCTestCase {
    private let fixtureHash = String(repeating: "e", count: 64)
    private let yesterday = 21_000
    private let today = 21_001

    private func bank(_ count: Int = 8, variants: Int = 4, multiple: Bool = false) -> ConceptBank {
        ConceptBank(id: "calendar-fixture", title: "日历测试", scope: "虚构范围", notice: "虚构数据",
            sources: [ConceptSource(id: "s", title: "测试来源", reference: "fictional")],
            concepts: (0..<count).map { c in
                StudyConcept(id: "c\(c)", title: "考点\(c)", section: "测试", method: "测试方法",
                    questions: (0..<variants).map { v in
                        ConceptQuestion(id: "c\(c)q\(v)", type: multiple ? .multiple : .single,
                            prompt: "测试考点\(c)不同题目\(v)",
                            options: [ExamOption(id: "A", text: "甲"),
                                      ExamOption(id: "B", text: "乙"),
                                      ExamOption(id: "C", text: "丙")],
                            answer: multiple ? ["A", "B"] : ["A"],
                            explanation: "测试解析", sourceIDs: ["s"],
                            sourceLocation: "测试位置", verification: "测试核对")
                    })
            })
    }

    private func learned(_ id: String, due: Int, answered: Int?, used: Int = 1,
                         familiar: Bool = false) -> ConceptProgress {
        var p = ConceptProgress()
        p.level = 1
        p.dueDay = due
        p.lastAnsweredDay = answered
        p.usedQuestionIDs = (0..<used).map { "\(id)q\($0)" }
        p.correct = used
        p.familiar = familiar
        return p
    }

    private func encoded(_ record: ConceptRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func assertCardAndHistory(_ after: ConceptRecord, unchanged before: ConceptRecord,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.progress, before.progress, file: file, line: line)
        XCTAssertEqual(after.presentation, before.presentation, file: file, line: line)
        XCTAssertEqual(after.review, before.review, file: file, line: line)
        XCTAssertEqual(after.undoFamiliar, before.undoFamiliar, file: file, line: line)
        XCTAssertEqual(after.attempts, before.attempts, file: file, line: line)
        XCTAssertEqual(after.volumes, before.volumes, file: file, line: line)
        XCTAssertEqual(after.nextSequence, before.nextSequence, file: file, line: line)
        XCTAssertEqual(after.sessionID, before.sessionID, file: file, line: line)
        XCTAssertEqual(after.scopeSuspensions, before.scopeSuspensions, file: file, line: line)
    }

    func testExactLocalMidnightAddsDueAfterExistingThreeWithoutChangingSelection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 21, hour: 0, minute: 0, second: 0)))
        let previousSecond = midnight.addingTimeInterval(-1)
        let oldDay = try ConceptCalendar.studyDay(previousSecond)
        let newDay = try ConceptCalendar.studyDay(midnight)
        XCTAssertEqual(newDay, oldDay + 1)

        var engine = try ConceptEngine(bank: bank(multiple: true), hash: fixtureHash)
        engine.record.progress["c3"] = learned("c3", due: newDay, answered: oldDay)
        try engine.start(day: oldDay, now: previousSecond, newLimit: 3)
        engine.toggle("A", token: try XCTUnwrap(engine.record.presentation?.id))
        engine.record.retriesToday["c0"] = 1
        let before = engine.record
        XCTAssertEqual(before.queue, ["c0", "c1", "c2"])

        try engine.refreshDue(day: newDay, now: midnight)
        XCTAssertEqual(engine.record.queue, ["c0", "c1", "c2", "c3"])
        XCTAssertEqual(engine.record.day, newDay)
        XCTAssertTrue(engine.record.retriesToday.isEmpty)
        assertCardAndHistory(engine.record, unchanged: before)
        try engine.record.validate(bank: engine.bank, hash: fixtureHash)
    }

    func testSameDayOldCheckpointIsRepairedAndRepeatedRefreshIsIdempotent() throws {
        var engine = try ConceptEngine(bank: bank(), hash: fixtureHash)
        try engine.start(day: today, newLimit: 3)
        // An earlier app may already have advanced the day without adding due work.
        engine.record.progress["c3"] = learned("c3", due: today, answered: yesterday)
        engine.record.retriesToday["c0"] = 1
        let before = engine.record
        try engine.refreshDue(day: today)
        XCTAssertEqual(engine.record.queue, ["c0", "c1", "c2", "c3"])
        XCTAssertEqual(engine.record.retriesToday, before.retriesToday)
        assertCardAndHistory(engine.record, unchanged: before)
        let once = try encoded(engine.record)
        for _ in 0..<3 { try engine.refreshDue(day: today) }
        XCTAssertEqual(try encoded(engine.record), once)
    }

    func testStartRefreshesBeforeReturningForExistingPresentation() throws {
        var engine = try ConceptEngine(bank: bank(), hash: fixtureHash)
        engine.record.progress["c3"] = learned("c3", due: today, answered: yesterday)
        try engine.start(day: yesterday, newLimit: 3)
        let before = engine.record
        try engine.start(day: today, newLimit: 25)
        XCTAssertEqual(engine.record.queue, ["c0", "c1", "c2", "c3"])
        assertCardAndHistory(engine.record, unchanged: before)
        XCTAssertFalse(engine.record.queue.contains("c4"))
    }

    func testLastResultPageKeepsReviewAndAddsOtherDueWithoutRequeueingItsOwnConcept() throws {
        var engine = try ConceptEngine(bank: bank(3), hash: fixtureHash)
        engine.record.progress["c1"] = learned("c1", due: today, answered: yesterday)
        try engine.start(day: yesterday, newLimit: 1)
        let token = try XCTUnwrap(engine.record.presentation?.id)
        try engine.answer("A", token: token, day: yesterday)
        XCTAssertTrue(engine.record.queue.isEmpty)
        XCTAssertEqual(engine.record.progress["c0"]?.dueDay, today)
        let before = engine.record

        try engine.start(day: today, newLimit: 3)
        XCTAssertEqual(engine.record.queue, ["c1"])
        assertCardAndHistory(engine.record, unchanged: before)
        let once = try encoded(engine.record)
        try engine.refreshDue(day: today)
        XCTAssertEqual(try encoded(engine.record), once)
        // Once the historical result is dismissed, the store may reconcile it.
        engine.next(token: token)
        let card = engine.record.presentation
        try engine.refreshDue(day: today)
        XCTAssertEqual(engine.record.queue, ["c1", "c0"])
        XCTAssertEqual(engine.record.presentation, card)
        XCTAssertEqual(engine.record.attempts, before.attempts)
        try engine.record.validate(bank: engine.bank, hash: fixtureHash)
    }

    func testNextOnDayResumesOnlyDueConceptFromYesterdayResultWithUnseenVariant() throws {
        var engine = try ConceptEngine(bank: bank(1), hash: fixtureHash)
        try engine.start(day: yesterday)
        let first = try XCTUnwrap(engine.record.presentation)
        try engine.answer("A", token: first.id, day: yesterday)
        let before = engine.record
        XCTAssertTrue(before.queue.isEmpty)
        XCTAssertEqual(before.progress["c0"]?.dueDay, today)

        try engine.nextOnDay(token: first.id, day: today)
        XCTAssertNil(engine.record.review)
        XCTAssertEqual(engine.record.queue, ["c0"])
        XCTAssertEqual(engine.record.presentation?.questionID, "c0q1")
        XCTAssertNotEqual(engine.record.presentation?.id, first.id)
        XCTAssertEqual(engine.record.progress, before.progress)
        XCTAssertEqual(engine.record.attempts, before.attempts)
        XCTAssertEqual(engine.record.nextSequence, before.nextSequence)
        XCTAssertEqual(engine.record.sessionID, before.sessionID)
        let once = try encoded(engine.record)
        try engine.nextOnDay(token: first.id, day: today)
        XCTAssertEqual(try encoded(engine.record), once)
        XCTAssertThrowsError(try engine.nextOnDay(token: first.id, day: yesterday))
        XCTAssertEqual(try encoded(engine.record), once)
        try engine.record.validate(bank: engine.bank, hash: fixtureHash)
    }

    func testRefreshSkipsFreshFamiliarExhaustedInactiveFutureAndAlreadyAnsweredToday() throws {
        var scoped = bank()
        let inactive = Set(scoped.concepts[3].questions.map(\.id))
        let allIDs = scoped.concepts.flatMap { $0.questions.map(\.id) }
        scoped.studyScope = ConceptStudyScope(id: "scope", title: "测试范围", sourceReference: "test",
            includedQuestionIDs: allIDs.filter { !inactive.contains($0) },
            excludedQuestionReasons: Dictionary(uniqueKeysWithValues: inactive.map { ($0, "测试停用") }))
        var engine = try ConceptEngine(bank: scoped, hash: fixtureHash)
        engine.record.day = today
        engine.record.progress["c0"] = learned("c0", due: today, answered: yesterday)
        engine.record.progress["c1"] = learned("c1", due: today, answered: yesterday, familiar: true)
        engine.record.progress["c2"] = learned("c2", due: today, answered: yesterday, used: 4)
        engine.record.progress["c3"] = learned("c3", due: today, answered: yesterday)
        engine.record.progress["c4"] = learned("c4", due: today + 1, answered: yesterday)
        engine.record.progress["c5"] = learned("c5", due: today, answered: today)
        // c6/c7 have never been learned; refresh must not create fresh work.
        let before = engine.record
        try engine.refreshDue(day: today)
        XCTAssertEqual(engine.record.queue, ["c0"])
        assertCardAndHistory(engine.record, unchanged: before)
        XCTAssertNil(engine.record.presentation)
        try engine.record.validate(bank: engine.bank, hash: fixtureHash)
    }

    func testEmptyTaskStillAddsFreshAllowanceAfterUncappedDueReviews() throws {
        var engine = try ConceptEngine(bank: bank(60), hash: fixtureHash)
        for i in 0..<30 {
            engine.record.progress["c\(i)"] = learned("c\(i)", due: today, answered: yesterday)
        }
        try engine.start(day: today, newLimit: 25)
        XCTAssertEqual(engine.record.queue.count, 55)
        XCTAssertEqual(Set(engine.record.queue.prefix(30)), Set((0..<30).map { "c\($0)" }))
        XCTAssertEqual(Array(engine.record.queue.suffix(25)), (30..<55).map { "c\($0)" })
        let before = engine.record
        try engine.start(day: today, newLimit: 25)
        XCTAssertEqual(try encoded(engine.record), try encoded(before))

        var custom = try ConceptEngine(bank: bank(), hash: fixtureHash)
        custom.record.progress["c0"] = learned("c0", due: today, answered: yesterday)
        try custom.start(day: today, newLimit: 3)
        XCTAssertEqual(custom.record.queue, ["c0", "c1", "c2", "c3"])
    }

    func testDueAppendOrderIsStableAndExistingDueQueueIsNotDuplicated() throws {
        var engine = try ConceptEngine(bank: bank(), hash: fixtureHash)
        try engine.start(day: yesterday, newLimit: 3)
        for (id, due) in [("c3", today), ("c4", yesterday), ("c5", today)] {
            engine.record.progress[id] = learned(id, due: due, answered: yesterday - 1)
        }
        engine.record.queue.append("c3")
        let before = engine.record
        try engine.refreshDue(day: today)
        XCTAssertEqual(engine.record.queue, ["c0", "c1", "c2", "c3", "c4", "c5"])
        XCTAssertEqual(engine.record.queue.filter { $0 == "c3" }.count, 1)
        assertCardAndHistory(engine.record, unchanged: before)
        try engine.refreshDue(day: today)
        XCTAssertEqual(engine.record.queue.count, 6)
    }

    func testAnswerAndFamiliarAtMidnightAlsoReconcileDueWithUnchangedGrading() throws {
        var answered = try ConceptEngine(bank: bank(), hash: fixtureHash)
        answered.record.progress["c3"] = learned("c3", due: today, answered: yesterday)
        try answered.start(day: yesterday, newLimit: 3)
        let learnedBefore = answered.record.progress["c3"]
        try answered.answer("A", token: XCTUnwrap(answered.record.presentation?.id), day: today)
        XCTAssertEqual(answered.record.queue, ["c1", "c2", "c3"])
        XCTAssertEqual(answered.record.progress["c3"], learnedBefore)
        XCTAssertEqual(answered.record.progress["c0"]?.level, 1)
        XCTAssertEqual(answered.record.progress["c0"]?.dueDay, today + ConceptEngine.gaps[0])
        XCTAssertEqual(answered.record.attempts.count, 1)
        XCTAssertEqual(answered.record.attempts[0].day, today)

        var familiar = try ConceptEngine(bank: bank(), hash: fixtureHash)
        familiar.record.progress["c3"] = learned("c3", due: today, answered: yesterday)
        try familiar.start(day: yesterday, newLimit: 3)
        try familiar.familiar(token: XCTUnwrap(familiar.record.presentation?.id), day: today)
        XCTAssertEqual(familiar.record.queue, ["c1", "c2", "c3"])
        XCTAssertEqual(familiar.record.progress["c0"]?.familiar, true)
        XCTAssertEqual(familiar.record.progress["c3"], learnedBefore)
        XCTAssertEqual(familiar.record.attempts.count, 1)
        let beforeUndo = familiar.record.attempts
        familiar.undo()
        try familiar.refreshDue(day: today)
        XCTAssertEqual(familiar.record.queue, ["c0", "c1", "c2", "c3"])
        XCTAssertEqual(Array(familiar.record.attempts.prefix(1)), beforeUndo)
        XCTAssertEqual(familiar.record.attempts.count, 2)
        try familiar.record.validate(bank: familiar.bank, hash: fixtureHash)
    }

    func testRollbackOrInvalidStartLeavesEntireRecordUntouched() throws {
        var engine = try ConceptEngine(bank: bank(), hash: fixtureHash)
        try engine.start(day: today, newLimit: 3)
        engine.record.progress["c3"] = learned("c3", due: today, answered: yesterday)
        engine.record.retriesToday["c0"] = 1
        let before = try encoded(engine.record)
        XCTAssertThrowsError(try engine.refreshDue(day: yesterday))
        XCTAssertThrowsError(try engine.refreshDue(day: 17_999))
        XCTAssertThrowsError(try engine.refreshDue(day: 50_001))
        XCTAssertThrowsError(try engine.start(day: today, newLimit: 0))
        XCTAssertEqual(try encoded(engine.record), before)
    }
}
