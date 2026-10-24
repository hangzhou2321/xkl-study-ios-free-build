import XCTest
import StudyCore
@testable import StudyClientModel

final class ConceptTeachingTests: XCTestCase {
    func testSupplementGroupsValidateWithoutChangingOriginalDeckOrBank() throws {
        let (bank, original, hash, old) = try fixture(1)
        var teaching = old
        var lesson = old.lessons[0]
        lesson.recallCards = [.init(id: "c0:old", prompt: "原知识？", answer: "原答案")]
        teaching = ConceptTeaching(format: old.format, bankSHA256: hash, lessons: [lesson], syllabus: SyllabusFixture.sample())
        let originalDeck = try RecallDeck.make(subject: .computer, bank: bank, teaching: teaching)
        let group = SupplementRecallGroup(id: "yc4-h-test", title: "补充主题", branchID: "main",
            recallCards: [.init(id: "yc4-h-test:v4:test", prompt: "新知识？", answer: "新答案")])
        teaching.recallGroups = [group]
        try teaching.validate(bank: bank, hash: hash)
        XCTAssertEqual(try RecallDeck.make(subject: .computer, bank: bank, teaching: teaching).hash, try originalDeck.hash)
        let supplement = try RecallDeck.makeSupplement(subject: .computer, bank: bank, group: group)
        XCTAssertEqual(supplement.cards.map(\.id), ["yc4-h-test:v4:test"])
        XCTAssertEqual(supplement.cards.first?.conceptTitle, "补充主题")
        let course = ConceptCourse(format: "xkl-course-v4", subject: .computer, bankContent: original, teaching: teaching)
        let (loaded, sameBank) = try ConceptCourse.load(JSONEncoder().encode(course), subject: .computer)
        XCTAssertEqual(loaded.bankContent, original)
        XCTAssertEqual(sameBank, bank)
        teaching.recallGroups = [SupplementRecallGroup(id: group.id, title: group.title, branchID: "unknown", recallCards: group.recallCards)]
        XCTAssertThrowsError(try teaching.validate(bank: bank, hash: hash))
        teaching.recallGroups = [SupplementRecallGroup(id: group.id, title: group.title, branchID: "main", topicID: "unknown", recallCards: group.recallCards)]
        XCTAssertThrowsError(try teaching.validate(bank: bank, hash: hash))
        teaching.recallGroups = [group, group]
        XCTAssertThrowsError(try teaching.validate(bank: bank, hash: hash))
        teaching.recallGroups = [SupplementRecallGroup(id: group.id, title: group.title, branchID: "main",
            recallCards: (0..<31).map { .init(id: "yc4-h-test:v4:\($0)", prompt: "测试", answer: "答案") })]
        XCTAssertThrowsError(try teaching.validate(bank: bank, hash: hash))
        teaching.recallGroups = [SupplementRecallGroup(id: group.id, title: group.title, branchID: "main",
            recallCards: [.init(id: "c0:wrong", prompt: "测试", answer: "答案")])]
        XCTAssertThrowsError(try teaching.validate(bank: bank, hash: hash))
    }
    private func fixture(_ count: Int = 5) throws -> (ConceptBank, Data, String, ConceptTeaching) {
        let bank = ConceptBank(id: ConceptSubject.computer.bankID, title: "虚构教学测试",
            scope: "仅测试", notice: "虚构题",
            sources: [ConceptSource(id: "s", title: "测试", reference: "fixture")],
            concepts: (0..<count).map { c in
                StudyConcept(id: "c\(c)", title: "考点\(c)", section: "测试", method: "方法",
                    questions: (0..<3).map { q in
                        ConceptQuestion(id: "c\(c)q\(q)", type: .single, prompt: "测试\(c)-\(q)",
                            options: [ExamOption(id: "A", text: "甲"), ExamOption(id: "B", text: "乙")],
                            answer: ["A"], explanation: "测试解析", sourceIDs: ["s"],
                            sourceLocation: "虚构", verification: "测试数据")
                    })
            })
        let bytes = try JSONEncoder().encode(bank), hash = StudySHA256.hex(bytes)
        let content = try JSONEncoder().encode(ConceptContent(format: "xkl-concepts-v1", bankBytes: bytes, bankSHA256: hash))
        let teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: hash,
            lessons: bank.concepts.map {
                ConceptLesson(conceptID: $0.id, title: "小案例", story: "教学场景", keyIdea: "关系",
                              workedExample: "完整例题", commonTrap: "适用条件")
            })
        return (bank, content, hash, teaching)
    }

    func testCoursePreservesEmbeddedOriginalBytesAndRejectsWrongSubject() throws {
        let (bank, original, hash, teaching) = try fixture()
        let raw = try JSONEncoder().encode(ConceptCourse(format: "xkl-course-v1", subject: .computer,
                                                       bankContent: original, teaching: teaching))
        let (loaded, sameBank) = try ConceptCourse.load(raw, subject: .computer)
        XCTAssertEqual(loaded.bankContent, original)
        XCTAssertEqual(sameBank, bank)
        XCTAssertEqual(loaded.teaching.bankSHA256, hash)
        XCTAssertThrowsError(try ConceptCourse.load(raw, subject: .power))
        let wrongHash = ConceptTeaching(format: teaching.format, bankSHA256: String(repeating: "a", count: 64),
                                       lessons: teaching.lessons)
        XCTAssertThrowsError(try wrongHash.validate(bank: bank, hash: hash))
        let missing = ConceptTeaching(format: teaching.format, bankSHA256: hash,
                                      lessons: Array(teaching.lessons.dropLast()))
        XCTAssertThrowsError(try missing.validate(bank: bank, hash: hash))
    }

    func testThreeNewWithUncappedReviewAndOldQueuePreserved() throws {
        let (bank, _, hash, _) = try fixture(7)
        var engine = try ConceptEngine(bank: bank, hash: hash)
        for n in [3, 3, 1] {
            try engine.start(day: 21_000, newLimit: 3)
            XCTAssertEqual(engine.record.queue.count, n)
            let queue = engine.record.queue
            try engine.start(day: 21_000, newLimit: 1)
            XCTAssertEqual(engine.record.queue, queue)
            while let p = engine.record.presentation {
                try engine.answer("A", token: p.id, day: 21_000)
                engine.next(token: p.id)
            }
        }
        try engine.start(day: 21_001, newLimit: 1)
        XCTAssertEqual(engine.record.queue.count, 7)
        XCTAssertThrowsError(try engine.start(day: 21_001, newLimit: 0))
    }

    func testStoryOnceAndExistingLearningNotRelabelledAsNew() throws {
        let (bank, _, hash, _) = try fixture()
        let event = ConceptCoachingEvent(id: UUID(), sequence: 1, kind: "story",
            conceptID: "c0", questionID: "c0q0", presentationID: UUID(), attemptID: nil,
            reason: nil, automatic: true, beforeAnswer: true,
            teachingSHA256: String(repeating: "b", count: 64), recordedAt: Date())
        XCTAssertTrue(ConceptCoachingRecord.shouldAutoShow(conceptID: "c0", progress: nil, events: []))
        XCTAssertFalse(ConceptCoachingRecord.shouldAutoShow(conceptID: "c0", progress: nil, events: [event]))
        var old = ConceptProgress()
        old.usedQuestionIDs = ["c0q0"]; old.correct = 1
        XCTAssertFalse(ConceptCoachingRecord.shouldAutoShow(conceptID: "c0", progress: old, events: []))
        old = ConceptProgress(); old.familiar = true
        XCTAssertFalse(ConceptCoachingRecord.shouldAutoShow(conceptID: "c0", progress: old, events: []))
        let record = ConceptCoachingRecord(bankSHA256: hash, nextSequence: 2, events: [event])
        try record.validate(bank: bank, hash: hash)
        let restored = try JSONDecoder().decode(ConceptCoachingRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(record, restored)
    }

    func testAnnotationsAppendClearAndRotateWithoutChangingObjectiveRecord() throws {
        let (bank, _, hash, _) = try fixture()
        var engine = try ConceptEngine(bank: bank, hash: hash)
        try engine.start(day: 21_000)
        let p = try XCTUnwrap(engine.shown)
        try engine.answer("A", token: p.id, day: 21_000)
        let answer = try XCTUnwrap(engine.record.review)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(engine.record)
        var journal = ConceptCoachingRecord(bankSHA256: hash)
        let reasons: [ConceptMistakeReason?] = [.guessed, .conditions, nil]
        for reason in reasons {
            journal.events.append(ConceptCoachingEvent(id: UUID(), sequence: journal.nextSequence,
                kind: "reason", conceptID: p.conceptID, questionID: p.questionID,
                presentationID: p.id, attemptID: answer.id, reason: reason, automatic: nil,
                beforeAnswer: false, teachingSHA256: nil, recordedAt: Date()))
            journal.nextSequence += 1
        }
        try journal.validate(bank: bank, hash: hash)
        XCTAssertNil(ConceptCoachingRecord.selectedReason(attemptID: answer.id, events: journal.events))
        XCTAssertEqual(journal.events.count, 3)
        XCTAssertEqual(before, try encoder.encode(engine.record))
        let all = journal.events
        try journal.rotate(hash: String(repeating: "c", count: 64))
        try journal.validate(bank: bank, hash: hash)
        XCTAssertEqual(journal.nextSequence, 4)
        XCTAssertEqual(journal.volumes.first?.count, 3)
        XCTAssertEqual(all.first?.reason, .guessed)
        var bad = journal; bad.nextSequence = 99
        XCTAssertThrowsError(try bad.validate(bank: bank, hash: hash))
    }

    func testAppendOnlyContractRejectsHistoricalAnswerOrConceptMeaningChanges() throws {
        let (bank, _, _, _) = try fixture()
        let data = try JSONEncoder().encode(bank)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var concepts = try XCTUnwrap(root["concepts"] as? [[String: Any]])
        var questions = try XCTUnwrap(concepts[0]["questions"] as? [[String: Any]])
        questions[0]["answer"] = ["B"]
        concepts[0]["questions"] = questions
        root["concepts"] = concepts
        let changed = try JSONDecoder().decode(ConceptBank.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertNoThrow(try changed.validate())
        XCTAssertThrowsError(try changed.validateAppendOnly(from: bank))
        concepts[0]["questions"] = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["concepts"] as? [[String: Any]])[0]["questions"]
        concepts[0]["method"] = "改变旧概念的规则"
        root["concepts"] = concepts
        let reinterpreted = try JSONDecoder().decode(ConceptBank.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertThrowsError(try reinterpreted.validateAppendOnly(from: bank))
    }
}
