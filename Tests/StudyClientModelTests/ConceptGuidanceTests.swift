import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Fictional content only. No private bank, phone state or course is accessed.
struct GuidanceFixture {
    let bank: ConceptBank
    let bankContent: Data
    let teaching: ConceptTeaching
    let teachingContent: Data
    var hash: String { StudySHA256.hex(teachingContent) }
    var course: ConceptCourse { ConceptCourse(format: "xkl-course-v2", subject: .computer, bankContent: bankContent, teaching: teaching) }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    init(revision: String = "first", append: Bool = false, guideEnabled: Bool = true) throws {
        bank = ConceptBank(id: ConceptSubject.computer.bankID, title: "虚构课程", scope: "测试", notice: "非用户材料",
            sources: [ConceptSource(id: "fiction", title: "虚构", reference: "test fixture")],
            concepts: (0..<(append ? 3 : 2)).map { index in
                StudyConcept(id: "c\(index)", title: "考点\(index)", section: "章节", method: "虚构方法",
                    questions: (0..<2).map { variant in
                        ConceptQuestion(id: "c\(index)-q\(variant)", type: .single, prompt: "不同的测试题\(index)-\(variant)",
                            options: [ExamOption(id: "a", text: "虚构正确选项"), ExamOption(id: "b", text: "虚构错误选项")],
                            answer: ["a"], explanation: "测试解析", sourceIDs: ["fiction"], sourceLocation: "合成测试",
                            verification: "自动化测试")
                    })
            })
        let bankBytes = try Self.encode(bank), bankHash = StudySHA256.hex(bankBytes)
        bankContent = try Self.encode(ConceptContent(format: "xkl-concepts-v1", bankBytes: bankBytes, bankSHA256: bankHash))
        teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: bankHash,
            lessons: bank.concepts.map { concept in
                ConceptLesson(conceptID: concept.id, title: "虚构讲解", story: "虚构场景", keyIdea: "虚构定义",
                    workedExample: "虚构例题", commonTrap: "虚构条件", guide: guideEnabled ? ConceptGuide(version: 1,
                        goal: "看懂\(revision)", referenceQuestionIDs: [concept.questions[0].id],
                        relatedConceptIDs: concept.id == "c0" ? ["c1"] : ["c0"],
                        remember: [.init(prompt: "回忆一", answer: "核对一"), .init(prompt: "回忆二", answer: "核对二")],
                        steps: [
                            .init(id: "scene", title: "场景", body: "虚构场景。", visual: .init(kind: "flow", items: [
                                .init(label: "输入", detail: "给定条件"), .init(label: "输出", detail: "根据条件判断")])),
                            .init(id: "define", title: "定义", body: "先定义术语。"),
                            .init(id: "check", title: "关系", body: "解释关系。", check: .init(prompt: "哪个判断有依据？",
                                options: [.init(id: "a", text: "有依据", feedback: "满足所给条件。"),
                                          .init(id: "b", text: "忽略条件", feedback: "遗漏了关键条件。")], answerID: "a", repairStepID: "define")),
                            .init(id: "transfer", title: "迁移", body: "条件改变时重新判断。")]) : nil)
            })
        teachingContent = try Self.encode(teaching)
    }
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XKL-Guidance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func write(_ data: Data, _ url: URL) throws { try data.write(to: url, options: .atomic) }
    func store(at root: URL) throws -> ConceptGuidanceStore {
        let store = try ConceptGuidanceStore(directory: root, subject: .computer, writer: Self.write)
        try store.archive(bankContent: bankContent, teachingContent: teachingContent, teachingHash: hash)
        return store
    }
}

final class ConceptGuidanceTests: XCTestCase {
    func testLegacyLessonJSONAndConstructorRemainCompatible() throws {
        let lesson = ConceptLesson(conceptID: "old", title: "旧讲解", story: "故事", keyIdea: "要点", workedExample: "例题", commonTrap: "条件")
        let data = try GuidanceFixture.encode(lesson)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["guide"])
        XCTAssertNil(try JSONDecoder().decode(ConceptLesson.self, from: data).guide)
        let legacy = try GuidanceFixture(guideEnabled: false)
        XCTAssertNoThrow(try ConceptCourse.load(GuidanceFixture.encode(legacy.course), subject: .computer))
    }

    func testGuideRejectsUnknownReferencesDuplicateStepsOptionsAndFutureRepair() throws {
        let fixture = try GuidanceFixture()
        let guide = try XCTUnwrap(fixture.teaching.lessons[0].guide)
        try guide.validate(conceptID: "c0", bank: fixture.bank)
        func modified(_ edit: (inout [String: Any]) -> Void) throws -> ConceptGuide {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: GuidanceFixture.encode(guide)) as? [String: Any])
            edit(&object)
            return try JSONDecoder().decode(ConceptGuide.self, from: JSONSerialization.data(withJSONObject: object))
        }
        for key in ["referenceQuestionIDs", "relatedConceptIDs"] {
            let changed = try modified { $0[key] = ["not-existing"] }
            XCTAssertThrowsError(try changed.validate(conceptID: "c0", bank: fixture.bank))
        }
        let duplicate = try modified {
            var steps = $0["steps"] as! [[String: Any]]; steps[1]["id"] = "scene"; $0["steps"] = steps
        }
        XCTAssertThrowsError(try duplicate.validate(conceptID: "c0", bank: fixture.bank))
        for modification in ["future", "answer", "duplicate", "feedback"] {
            let changed = try modified {
                var steps = $0["steps"] as! [[String: Any]], check = steps[2]["check"] as! [String: Any]
                if modification == "future" { check["repairStepID"] = "transfer" }
                if modification == "answer" { check["answerID"] = "missing" }
                if modification == "duplicate" || modification == "feedback" {
                    var options = check["options"] as! [[String: Any]]
                    if modification == "duplicate" { options[1]["id"] = "a" } else { options[1]["feedback"] = "" }
                    check["options"] = options
                }
                steps[2]["check"] = check; $0["steps"] = steps
            }
            XCTAssertThrowsError(try changed.validate(conceptID: "c0", bank: fixture.bank))
        }
    }

    func testStepChecksRepairRecallAndRestartRestoreExactPosition() throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try GuidanceFixture(), store = try f.store(at: root), presentation = UUID()
        try store.open(conceptID: "c0", teachingHash: f.hash, presentationID: presentation)
        try store.act("step", stepID: "define"); try store.act("step", stepID: "check")
        XCTAssertThrowsError(try store.act("step", stepID: "transfer"))
        try store.act("answer", choiceID: "b")
        XCTAssertEqual(store.allEvents.last?.correct, false)
        try store.act("step", stepID: "define")
        let reloaded = try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write)
        XCTAssertEqual(reloaded.record, store.record)
        XCTAssertEqual(reloaded.record.active?.presentationID, presentation)
        try reloaded.act("step", stepID: "check"); try reloaded.act("answer", choiceID: "a")
        try reloaded.act("step", stepID: "transfer"); try reloaded.act("step", stepID: ConceptGuide.recallStepID)
        XCTAssertEqual(reloaded.record.active?.revealedRecall, [])
        try reloaded.act("remember", recallIndex: 0)
        XCTAssertEqual(reloaded.record.active?.revealedRecall, [0])
        try reloaded.act("finish")
        XCTAssertNil(reloaded.record.active)
        XCTAssertTrue(reloaded.record.positions.values.first!.completed)
        XCTAssertEqual(reloaded.allEvents.filter { $0.kind == "answer" }.map(\.correct), [false, true])
    }

    func testTeachingVersionAndAppendBankPreserveOldSessionsAndBytes() throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try GuidanceFixture(), new = try GuidanceFixture(revision: "updated", append: true)
        let store = try old.store(at: root)
        try store.open(conceptID: "c0", teachingHash: old.hash, presentationID: nil)
        try store.act("step", stepID: "define")
        let oldEvents = store.allEvents
        let oldContent = try Data(contentsOf: root.appendingPathComponent("guidance-content/\(old.hash).json"))
        try store.archive(bankContent: new.bankContent, teachingContent: new.teachingContent, teachingHash: new.hash)
        try store.open(conceptID: "c0", teachingHash: new.hash, presentationID: nil)
        XCTAssertEqual(store.record.positions.count, 2)
        try store.open(conceptID: "c0", teachingHash: old.hash, presentationID: nil)
        XCTAssertEqual(store.record.active?.stepID, "define")
        XCTAssertEqual(Array(store.allEvents.prefix(oldEvents.count)), oldEvents)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("guidance-content/\(old.hash).json")), oldContent)
        let reloaded = try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write)
        XCTAssertEqual(reloaded.record, store.record)
        XCTAssertNotNil(try reloaded.exportFiles()["guidance-content/\(new.hash).json"])
    }

    func testRotationExportsAllEventsAndMissingOrCorruptVolumeFailsClosed() throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try GuidanceFixture(), store = try f.store(at: root)
        try store.open(conceptID: "c0", teachingHash: f.hash, presentationID: nil)
        var seeded = store.record
        let first = try XCTUnwrap(seeded.events.first), guide = try XCTUnwrap(f.teaching.lessons[0].guide)
        for sequence in 2...1_000 {
            let event = ConceptGuidanceEvent(eventID: UUID(), sequence: sequence, kind: "open", sessionID: first.sessionID,
                conceptID: "c0", bankSHA256: first.bankSHA256, teachingSHA256: f.hash, stepID: "scene", choiceID: nil,
                correct: nil, recallIndex: nil, presentationID: nil, recordedAt: Date())
            try seeded.apply(event, guide: guide, bankHash: first.bankSHA256)
        }
        try GuidanceFixture.write(GuidanceFixture.encode(seeded), root.appendingPathComponent("guidance-current.json"))
        let loaded = try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write)
        try loaded.act("step", stepID: "define")
        XCTAssertEqual(loaded.record.events.count, 1)
        XCTAssertEqual(loaded.record.volumes.count, 1)
        let replay = try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write)
        XCTAssertEqual(replay.allEvents.count, 1_001)
        let files = try replay.exportFiles(), ref = try XCTUnwrap(replay.record.volumes.first)
        XCTAssertNotNil(files["guidance-volumes/\(ref.sha256).json"])
        let volume = root.appendingPathComponent("guidance-volumes/\(ref.sha256).json")
        try Data("corrupt".utf8).write(to: volume)
        XCTAssertThrowsError(try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write))
        XCTAssertThrowsError(try replay.exportFiles())
        XCTAssertEqual(replay.record, loaded.record)
    }

    func testWriteFailurePreservesMemoryAndCurrentBytesAndMissingCurrentCannotReset() throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try GuidanceFixture(), initial = try f.store(at: root)
        try initial.open(conceptID: "c0", teachingHash: f.hash, presentationID: nil)
        let current = root.appendingPathComponent("guidance-current.json"), before = try Data(contentsOf: current)
        enum Failure: Error { case injected }
        let failing = try ConceptGuidanceStore(directory: root, subject: .computer, writer: { _, _ in throw Failure.injected })
        XCTAssertThrowsError(try failing.act("step", stepID: "define"))
        XCTAssertEqual(failing.record, initial.record)
        XCTAssertEqual(try Data(contentsOf: current), before)
        try FileManager.default.removeItem(at: current)
        XCTAssertThrowsError(try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("guidance-created.json").path))
    }

    func testCorruptPositionMissingTeachingAndForeignSubjectAreRejected() throws {
        for corruption in ["position", "teaching", "subject"] {
            let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
            let f = try GuidanceFixture(), store = try f.store(at: root)
            try store.open(conceptID: "c0", teachingHash: f.hash, presentationID: nil)
            if corruption == "teaching" {
                try FileManager.default.removeItem(at: root.appendingPathComponent("guidance-content/\(f.hash).json"))
            } else if corruption == "subject" {
                try GuidanceFixture.write(GuidanceFixture.encode(ConceptSubject.power), root.appendingPathComponent("guidance-created.json"))
            } else {
                var corrupt = store.record
                let key = try XCTUnwrap(corrupt.activeKey)
                corrupt.positions[key]?.stepID = "transfer"
                try GuidanceFixture.write(GuidanceFixture.encode(corrupt), root.appendingPathComponent("guidance-current.json"))
            }
            XCTAssertThrowsError(try ConceptGuidanceStore(directory: root, subject: .computer, writer: GuidanceFixture.write))
        }
    }
}

#if os(macOS)
final class ConceptGuidanceIntegrationTests: XCTestCase {
    @MainActor func testImportGuidanceAndAllLearningActionsLeaveFormalRecordByteIdentical() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try GuidanceFixture(guideEnabled: false), guided = try GuidanceFixture()
        let input = root.appendingPathComponent("synthetic.xklcourse")
        try GuidanceFixture.write(GuidanceFixture.encode(legacy.course), input)
        let store = ConceptStore(baseDirectory: root)
        store.importContent(input); store.start(newLimit: 2)
        let before = try XCTUnwrap(store.engine?.record), presentation = try XCTUnwrap(store.engine?.shown)
        let state = root.appendingPathComponent("ComputerFoundation/\(guided.teaching.bankSHA256)/current.json")
        let bytes = try Data(contentsOf: state)
        try GuidanceFixture.write(GuidanceFixture.encode(guided.course), input)
        store.importContent(input)
        XCTAssertEqual(try GuidanceFixture.encode(XCTUnwrap(store.engine?.record)), try GuidanceFixture.encode(before))
        store.openGuidance(conceptID: presentation.conceptID, presentationID: presentation.id)
        store.guidanceAction("step", stepID: "define"); store.guidanceAction("step", stepID: "check")
        store.guidanceAction("answer", choiceID: "b"); store.guidanceAction("answer", choiceID: "a")
        store.guidanceAction("step", stepID: "transfer"); store.guidanceAction("step", stepID: ConceptGuide.recallStepID)
        store.guidanceAction("remember", recallIndex: 0); store.guidanceAction("finish")
        XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        XCTAssertEqual(try GuidanceFixture.encode(XCTUnwrap(store.engine?.record)), try GuidanceFixture.encode(before))
        XCTAssertEqual(try Data(contentsOf: state), bytes)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertEqual(try GuidanceFixture.encode(XCTUnwrap(restarted.engine?.record)), try GuidanceFixture.encode(before))
        XCTAssertEqual(restarted.guidance, store.guidance)
        struct Export: Decodable { let guidance: [String: Data] }
        let export = try JSONDecoder().decode(Export.self, from: store.exportRecords())
        XCTAssertNotNil(export.guidance["guidance-current.json"])
        XCTAssertTrue(export.guidance.keys.contains { $0.hasPrefix("guidance-content/") })
        // Formal grading remains the same separate path and still works.
        restarted.choose("a", token: presentation.id)
        XCTAssertEqual(restarted.engine?.record.review?.isCorrect, true)
        XCTAssertEqual(restarted.engine?.record.attempts.count, before.attempts.count + 1)
    }

    @MainActor func testAppendCourseDoesNotRewriteGuidanceAndResumesHistoricalVersion() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try GuidanceFixture(), new = try GuidanceFixture(revision: "append", append: true)
        let input = root.appendingPathComponent("synthetic.xklcourse"), store = ConceptStore(baseDirectory: root)
        try GuidanceFixture.write(GuidanceFixture.encode(old.course), input); store.importContent(input)
        store.openGuidance(conceptID: "c0"); store.guidanceAction("step", stepID: "define")
        let position = try XCTUnwrap(store.guidance?.active), before = try XCTUnwrap(store.guidance)
        let file = root.appendingPathComponent("ComputerFoundation/guidance-current.json"), bytes = try Data(contentsOf: file)
        try GuidanceFixture.write(GuidanceFixture.encode(new.course), input); store.importContent(input)
        XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        XCTAssertEqual(store.guidance, before)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        store.resumeGuidance(position)
        XCTAssertEqual(store.guidance?.active?.stepID, "define")
        XCTAssertEqual(store.guidanceLesson?.guide?.goal, "看懂first")
        XCTAssertFalse(ConceptStore(baseDirectory: root).blocked)
    }

    @MainActor func testGuidanceWriteFailureBlocksFurtherActionsWithoutTouchingFormalState() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try GuidanceFixture(), input = root.appendingPathComponent("synthetic.xklcourse")
        try GuidanceFixture.write(GuidanceFixture.encode(f.course), input)
        enum Failure: Error { case injected }
        var shouldFail = false
        let store = ConceptStore(baseDirectory: root, writer: { data, url in
            if shouldFail && url.lastPathComponent == "guidance-current.json" { throw Failure.injected }
            try GuidanceFixture.write(data, url)
        })
        store.importContent(input); store.start()
        let before = try XCTUnwrap(store.engine?.record)
        shouldFail = true
        store.openGuidance(conceptID: "c0")
        XCTAssertTrue(store.blocked)
        XCTAssertEqual(try GuidanceFixture.encode(XCTUnwrap(store.engine?.record)), try GuidanceFixture.encode(before))
        XCTAssertEqual(store.guidance?.events.count, 0)
        XCTAssertTrue(ConceptStore(baseDirectory: root).blocked, "Created marker prevents accidental fresh state after the initial write fails.")
    }
}
#endif
