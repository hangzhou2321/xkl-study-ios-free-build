#if os(macOS)
import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Real disk import/restart/export coverage. All data is fictional and every
/// test owns a fresh temporary directory; no personal bank or progress is read.
final class ConceptStoreTests: XCTestCase {
    private struct Fixture {
        let subject: ConceptSubject
        let bank: ConceptBank
        let bankHash: String
        let bankContent: Data
        let teaching: ConceptTeaching
        let courseContent: Data

        func folder(in root: URL) -> URL {
            root.appendingPathComponent(subject.directoryName, isDirectory: true)
                .appendingPathComponent(bankHash, isDirectory: true)
        }
    }

    private struct ExportSnapshot: Decodable {
        let format: String
        let banks: [ConceptBank]
        let records: [ConceptRecord]
        let teachingAndCoaching: [String: [String: Data]]
    }

    private enum InjectedFailure: Error { case diskWrite }
    private final class TestWriter {
        var failingFilename: String?
        func write(_ data: Data, _ url: URL) throws {
            if url.lastPathComponent == failingFilename { throw InjectedFailure.diskWrite }
            try data.write(to: url, options: .atomic)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XKL-ConceptStoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(_ subject: ConceptSubject = .computer) throws -> Fixture {
        let bank = ConceptBank(id: subject.bankID, title: "虚构\(subject.title)",
            scope: "仅供自动化测试", notice: "非用户资料",
            sources: [ConceptSource(id: "test-source", title: "虚构依据", reference: "test fixture")],
            concepts: (0..<2).map { index in
                StudyConcept(id: "c\(index)", title: "虚构考点 \(index)", section: "测试",
                    method: "先识别条件，再完成虚构计算。",
                    questions: (0..<3).map { variant in
                        ConceptQuestion(id: "c\(index)-q\(variant)", type: .single,
                            prompt: "虚构考点 \(index) 的不同问题 \(variant)",
                            options: [ExamOption(id: "A", text: "正确内容 \(variant)"),
                                      ExamOption(id: "B", text: "错误内容 \(variant)")],
                            answer: ["A"], explanation: "虚构解析 \(variant)",
                            sourceIDs: ["test-source"], sourceLocation: "测试 \(index)-\(variant)",
                            verification: "独立测试数据")
                    })
            })
        try bank.validate()
        let bankBytes = try encode(bank), bankHash = StudySHA256.hex(bankBytes)
        // Deliberately retain this wrapper's exact bytes when making the course.
        let bankContent = try encode(ConceptContent(format: "xkl-concepts-v1",
            bankBytes: bankBytes, bankSHA256: bankHash))
        let teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: bankHash,
            lessons: bank.concepts.map {
                ConceptLesson(conceptID: $0.id, title: "虚构故事 \($0.id)",
                    story: "值班员遇到一个仅供测试的问题。", keyIdea: "分清给定条件。",
                    workedExample: "先写出条件，再核对结果。", commonTrap: "不要忽略单位。")
            })
        let courseContent = try encode(ConceptCourse(format: "xkl-course-v1", subject: subject,
            bankContent: bankContent, teaching: teaching))
        return Fixture(subject: subject, bank: bank, bankHash: bankHash,
            bankContent: bankContent, teaching: teaching, courseContent: courseContent)
    }

    private func input(_ data: Data, name: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private func importCourse(_ fixture: Fixture, root: URL,
                              writer: ((Data, URL) throws -> Void)? = nil) throws -> ConceptStore {
        let store: ConceptStore
        if let writer {
            store = ConceptStore(subject: fixture.subject, baseDirectory: root, writer: writer)
        } else {
            store = ConceptStore(subject: fixture.subject, baseDirectory: root)
        }
        store.importContent(try input(fixture.courseContent,
            name: fixture.subject.rawValue + ".xklcourse", in: root))
        XCTAssertFalse(store.blocked)
        XCTAssertNil(store.error)
        _ = try XCTUnwrap(store.engine)
        return store
    }

    @MainActor
    private func answerFirst(_ store: ConceptStore, choice: String = "A") throws -> ConceptAttempt {
        store.start(newLimit: 2)
        let presentation = try XCTUnwrap(store.engine?.shown)
        store.choose(choice, token: presentation.id)
        XCTAssertFalse(store.blocked)
        XCTAssertNil(store.error)
        return try XCTUnwrap(store.engine?.record.review)
    }

    @MainActor
    func testAddingCoursePreservesLegacyBankAndProgressBytesAcrossRestart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = ConceptStore(baseDirectory: root)
        store.importContent(try input(f.bankContent, name: "legacy.xklconcepts", in: root))
        XCTAssertNil(store.teaching)
        let answer = try answerFirst(store)
        let current = f.folder(in: root).appendingPathComponent("current.json")
        let content = f.folder(in: root).appendingPathComponent("content.xklconcepts")
        let previousState = try Data(contentsOf: current)
        let previousContent = try Data(contentsOf: content)
        let previousProgress = try XCTUnwrap(store.engine?.record.progress)

        store.importContent(try input(f.courseContent, name: "upgrade.xklcourse", in: root))

        XCTAssertFalse(store.blocked)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.teaching, f.teaching)
        XCTAssertEqual(try Data(contentsOf: current), previousState)
        XCTAssertEqual(try Data(contentsOf: content), previousContent)
        XCTAssertEqual(previousContent, f.bankContent)
        XCTAssertEqual(store.engine?.record.review, answer)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.engine?.record.review, answer)
        XCTAssertEqual(restarted.engine?.record.progress, previousProgress)
        XCTAssertEqual(restarted.teaching, f.teaching)
        XCTAssertEqual(try Data(contentsOf: current), previousState)
    }

    @MainActor
    func testStoryOpensOnceAndExistingAnsweredConceptDoesNotAcquireFirstLesson() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = ConceptStore(baseDirectory: root)
        store.importContent(try input(f.bankContent, name: "legacy.xklconcepts", in: root))
        let oldAnswer = try answerFirst(store)
        store.importContent(try input(f.courseContent, name: "stories.xklcourse", in: root))
        XCTAssertFalse(store.shouldAutoShowStory(conceptID: oldAnswer.presentation.conceptID))
        store.openStory(token: oldAnswer.presentation.id, automatic: true)
        XCTAssertTrue(store.coachingEvents.isEmpty)
        store.next(token: oldAnswer.presentation.id)
        let fresh = try XCTUnwrap(store.engine?.shown)
        XCTAssertTrue(store.shouldAutoShowStory(conceptID: fresh.conceptID))
        let current = f.folder(in: root).appendingPathComponent("current.json")
        let stateBeforeStory = try Data(contentsOf: current)
        store.openStory(token: fresh.id, automatic: true)
        store.openStory(token: fresh.id, automatic: true)
        XCTAssertEqual(store.coachingEvents.count, 1)
        XCTAssertEqual(store.coachingEvents.first?.automatic, true)
        XCTAssertEqual(try Data(contentsOf: current), stateBeforeStory)

        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.shown, fresh)
        XCTAssertFalse(restarted.shouldAutoShowStory(conceptID: fresh.conceptID))
        restarted.openStory(token: fresh.id, automatic: true)
        XCTAssertEqual(restarted.coachingEvents.count, 1)
        restarted.openStory(token: fresh.id, automatic: false)
        restarted.openStory(token: fresh.id, automatic: false)
        XCTAssertEqual(restarted.coachingEvents.count, 2)
        XCTAssertEqual(restarted.coachingEvents.last?.automatic, false)
        XCTAssertTrue(try XCTUnwrap(restarted.coachingEvents.last?.beforeAnswer))
        XCTAssertEqual(try Data(contentsOf: current), stateBeforeStory)
    }

    @MainActor
    func testReasonChangesAndClearAreAppendOnlyWithoutChangingObjectiveAnswer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = try importCourse(f, root: root)
        let answer = try answerFirst(store, choice: "B")
        let current = f.folder(in: root).appendingPathComponent("current.json")
        let original = try Data(contentsOf: current)
        store.setReason(.concept, attemptID: answer.id)
        let first = try XCTUnwrap(store.coachingEvents.first)
        store.setReason(.conditions, attemptID: answer.id)
        store.setReason(nil, attemptID: answer.id)
        XCTAssertEqual(store.coachingEvents.count, 3)
        XCTAssertEqual(store.coachingEvents.first, first)
        XCTAssertEqual(store.coachingEvents.map(\.sequence), [1, 2, 3])
        XCTAssertNil(store.selectedReason(attemptID: answer.id))
        XCTAssertEqual(store.engine?.record.review, answer)
        XCTAssertEqual(store.engine?.record.review?.isCorrect, false)
        XCTAssertEqual(try Data(contentsOf: current), original)

        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.coachingEvents, store.coachingEvents)
        XCTAssertNil(restarted.selectedReason(attemptID: answer.id))
        restarted.setReason(.guessed, attemptID: answer.id)
        XCTAssertEqual(restarted.coachingEvents.count, 4)
        XCTAssertEqual(restarted.selectedReason(attemptID: answer.id), .guessed)
        XCTAssertEqual(try Data(contentsOf: current), original)
        let exported = try JSONDecoder().decode(ExportSnapshot.self, from: restarted.exportRecords())
        XCTAssertEqual(exported.format, "xkl-concept-export-v2")
        XCTAssertEqual(exported.records.first?.review, answer)
        let files = try XCTUnwrap(exported.teachingAndCoaching[f.bankHash])
        let exportedRecord = try JSONDecoder().decode(ConceptCoachingRecord.self,
            from: XCTUnwrap(files["coaching-current.json"]))
        XCTAssertEqual(exportedRecord.events, restarted.coachingEvents)
        XCTAssertNotNil(files["coaching-created.json"])
        XCTAssertNotNil(files["teaching-active.json"])
        XCTAssertTrue(files.keys.contains { $0.hasPrefix("teaching/") })
    }

    @MainActor
    func testSubjectsRemainIndependentAndWrongSubjectImportDoesNotWrite() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let computer = try fixture(.computer), power = try fixture(.power)
        let computers = try importCourse(computer, root: root)
        let powers = try importCourse(power, root: root)
        let computerAnswer = try answerFirst(computers, choice: "A")
        let powerAnswer = try answerFirst(powers, choice: "B")
        let computerPath = computer.folder(in: root).appendingPathComponent("current.json")
        let powerPath = power.folder(in: root).appendingPathComponent("current.json")
        let computerBytes = try Data(contentsOf: computerPath)
        let powerBytes = try Data(contentsOf: powerPath)

        powers.importContent(try input(computer.courseContent, name: "wrong-computer.xklcourse", in: root))
        computers.importContent(try input(power.courseContent, name: "wrong-power.xklcourse", in: root))
        XCTAssertNotNil(powers.error)
        XCTAssertNotNil(computers.error)
        XCTAssertFalse(powers.blocked)
        XCTAssertFalse(computers.blocked)
        XCTAssertEqual(try Data(contentsOf: computerPath), computerBytes)
        XCTAssertEqual(try Data(contentsOf: powerPath), powerBytes)
        XCTAssertEqual(computers.engine?.record.review, computerAnswer)
        XCTAssertEqual(powers.engine?.record.review, powerAnswer)
        XCTAssertEqual(ConceptStore(subject: .computer, baseDirectory: root).engine?.record.review?.isCorrect, true)
        XCTAssertEqual(ConceptStore(subject: .power, baseDirectory: root).engine?.record.review?.isCorrect, false)
        let computerExport = try JSONDecoder().decode(ExportSnapshot.self, from: computers.exportRecords())
        let powerExport = try JSONDecoder().decode(ExportSnapshot.self, from: powers.exportRecords())
        XCTAssertEqual(computerExport.banks.map(\.id), [ConceptSubject.computer.bankID])
        XCTAssertEqual(powerExport.banks.map(\.id), [ConceptSubject.power.bankID])
    }

    @MainActor
    func testMissingCoachingCurrentWithCreationMarkerFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = try importCourse(f, root: root)
        store.start(newLimit: 2)
        store.openStory(token: try XCTUnwrap(store.engine?.shown?.id), automatic: true)
        let folder = f.folder(in: root)
        let current = folder.appendingPathComponent("current.json")
        let marker = folder.appendingPathComponent("coaching-created.json")
        let coaching = folder.appendingPathComponent("coaching-current.json")
        let objectiveBytes = try Data(contentsOf: current)
        let markerBytes = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: coaching)

        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertTrue(restarted.blocked)
        XCTAssertNotNil(restarted.error)
        XCTAssertNil(restarted.engine)
        XCTAssertEqual(try Data(contentsOf: current), objectiveBytes)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coaching.path))
        XCTAssertThrowsError(try restarted.exportRecords())
    }

    @MainActor
    func testReasonReferenceToAnotherRealAnswerFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = try importCourse(f, root: root)
        let first = try answerFirst(store)
        store.setReason(.guessed, attemptID: first.id)
        store.next(token: first.presentation.id)
        store.choose("B", token: try XCTUnwrap(store.engine?.shown?.id))
        let second = try XCTUnwrap(store.engine?.record.review)
        store.setReason(.conditions, attemptID: second.id)
        let folder = f.folder(in: root)
        let current = folder.appendingPathComponent("current.json")
        let objectiveBytes = try Data(contentsOf: current)
        let supportURL = folder.appendingPathComponent("coaching-current.json")
        let original = try JSONDecoder().decode(ConceptCoachingRecord.self, from: Data(contentsOf: supportURL))
        let old = try XCTUnwrap(original.events.first)
        for incorrectID in [second.id, UUID()] {
            var corrupted = original
            corrupted.events[0] = ConceptCoachingEvent(id: old.id, sequence: old.sequence, kind: old.kind,
                conceptID: old.conceptID, questionID: old.questionID, presentationID: old.presentationID,
                attemptID: incorrectID, reason: old.reason, automatic: old.automatic,
                beforeAnswer: old.beforeAnswer, teachingSHA256: old.teachingSHA256, recordedAt: old.recordedAt)
            // This remains structurally valid; the Store must check actual answer linkage.
            try corrupted.validate(bank: f.bank, hash: f.bankHash)
            let corruptedBytes = try encode(corrupted)
            try corruptedBytes.write(to: supportURL, options: .atomic)
            let restarted = ConceptStore(baseDirectory: root)
            XCTAssertTrue(restarted.blocked)
            XCTAssertNil(restarted.engine)
            XCTAssertNotNil(restarted.error)
            XCTAssertEqual(try Data(contentsOf: supportURL), corruptedBytes)
            XCTAssertEqual(try Data(contentsOf: current), objectiveBytes)
        }
    }

    @MainActor
    func testAnswerWriteFailureDoesNotAdvanceVisibleOrSavedProgress() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), writer = TestWriter()
        let store = try importCourse(f, root: root, writer: writer.write)
        store.start(newLimit: 2)
        let pending = try XCTUnwrap(store.engine?.shown)
        let current = f.folder(in: root).appendingPathComponent("current.json")
        let oldBytes = try Data(contentsOf: current)
        writer.failingFilename = "current.json"
        store.choose("A", token: pending.id)

        XCTAssertTrue(store.blocked)
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.engine?.record.review)
        XCTAssertEqual(store.engine?.shown, pending)
        XCTAssertTrue(try XCTUnwrap(store.engine?.record.attempts.isEmpty))
        XCTAssertEqual(try Data(contentsOf: current), oldBytes)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.shown, pending)
        XCTAssertNil(restarted.engine?.record.review)
    }

    @MainActor
    func testCoachingWriteFailureDoesNotPublishAnUnsavedObservation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), writer = TestWriter()
        let store = try importCourse(f, root: root, writer: writer.write)
        let answer = try answerFirst(store)
        let current = f.folder(in: root).appendingPathComponent("current.json")
        let oldBytes = try Data(contentsOf: current)
        writer.failingFilename = "coaching-current.json"
        store.setReason(.guessed, attemptID: answer.id)

        XCTAssertTrue(store.blocked)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.coachingEvents.isEmpty)
        XCTAssertNil(store.selectedReason(attemptID: answer.id))
        XCTAssertEqual(store.engine?.record.review, answer)
        XCTAssertEqual(try Data(contentsOf: current), oldBytes)
        // The creation marker makes an interrupted first write detectable.
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertTrue(restarted.blocked)
        XCTAssertEqual(try Data(contentsOf: current), oldBytes)
    }

    @MainActor
    func testCoachingRotationRestartAndExportRetainAllEvents() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = try importCourse(f, root: root)
        let answer = try answerFirst(store)
        store.setReason(.guessed, attemptID: answer.id)
        let folder = f.folder(in: root), current = folder.appendingPathComponent("current.json")
        let oldBytes = try Data(contentsOf: current)
        let support = folder.appendingPathComponent("coaching-current.json")
        let first = try XCTUnwrap(store.coachingEvents.first)
        var full = ConceptCoachingRecord(bankSHA256: f.bankHash)
        full.events = (1...1_000).map { sequence in
            ConceptCoachingEvent(id: UUID(), sequence: sequence, kind: "reason",
                conceptID: first.conceptID, questionID: first.questionID, presentationID: first.presentationID,
                attemptID: answer.id, reason: sequence.isMultiple(of: 2) ? .method : .concept,
                automatic: nil, beforeAnswer: false, teachingSHA256: first.teachingSHA256,
                recordedAt: first.recordedAt.addingTimeInterval(Double(sequence)))
        }
        full.nextSequence = 1_001
        try full.validate(bank: f.bank, hash: f.bankHash)
        try encode(full).write(to: support, options: .atomic)
        let loaded = ConceptStore(baseDirectory: root)
        XCTAssertFalse(loaded.blocked)
        XCTAssertEqual(loaded.coachingEvents.count, 1_000)
        loaded.setReason(.calculation, attemptID: answer.id)
        XCTAssertFalse(loaded.blocked)
        XCTAssertEqual(loaded.coachingEvents.count, 1_001)
        let after = try JSONDecoder().decode(ConceptCoachingRecord.self, from: Data(contentsOf: support))
        XCTAssertEqual(after.events.count, 1)
        XCTAssertEqual(after.events.first?.sequence, 1_001)
        XCTAssertEqual(after.nextSequence, 1_002)
        let volume = try XCTUnwrap(after.volumes.first)
        XCTAssertEqual(after.volumes.count, 1)
        XCTAssertEqual(volume.first, 1)
        XCTAssertEqual(volume.last, 1_000)
        let volumeName = "coaching-volumes/" + volume.sha256 + ".json"
        let volumeBytes = try Data(contentsOf: folder.appendingPathComponent(volumeName))
        XCTAssertEqual(StudySHA256.hex(volumeBytes), volume.sha256)
        let closed = try JSONDecoder().decode(ConceptCoachingRecord.self, from: volumeBytes)
        XCTAssertEqual(closed.events, full.events)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.coachingEvents, loaded.coachingEvents)
        XCTAssertEqual(restarted.selectedReason(attemptID: answer.id), .calculation)
        let exported = try JSONDecoder().decode(ExportSnapshot.self, from: restarted.exportRecords())
        let files = try XCTUnwrap(exported.teachingAndCoaching[f.bankHash])
        XCTAssertEqual(files[volumeName], volumeBytes)
        XCTAssertEqual(files["coaching-current.json"], try Data(contentsOf: support))
        XCTAssertEqual(try Data(contentsOf: current), oldBytes)

        // A leftover closed volume is evidence of prior logging even if its marker is gone.
        try FileManager.default.removeItem(at: support)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("coaching-created.json"))
        let missing = ConceptStore(baseDirectory: root)
        XCTAssertTrue(missing.blocked)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(volumeName)), volumeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    @MainActor
    func testUndoMayReplaceAnUnansweredPresentationWithStoryWithoutCorruptingHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(), store = try importCourse(f, root: root)
        store.start(newLimit: 2)
        let first = try XCTUnwrap(store.engine?.shown)
        store.familiar(token: first.id)
        let replaced = try XCTUnwrap(store.engine?.shown)
        store.openStory(token: replaced.id, automatic: true)
        store.undo()
        XCTAssertEqual(store.engine?.shown?.conceptID, first.conceptID)
        XCTAssertFalse(try XCTUnwrap(store.engine?.record.attempts.contains {
            $0.presentation.id == replaced.id
        }))
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.coachingEvents.count, 1)
        XCTAssertEqual(restarted.coachingEvents.first?.presentationID, replaced.id)
        XCTAssertEqual(restarted.engine?.shown?.conceptID, first.conceptID)
        XCTAssertFalse(restarted.shouldAutoShowStory(conceptID: replaced.conceptID))
    }
    private func upgrade(_ old: Fixture, suffix: String = "u1") throws -> Fixture {
        let first = old.bank.concepts[0]
        let q = ConceptQuestion(id: "added-\(suffix)", type: .single,
            prompt: "新增且不同的变式 \(suffix)",
            options: [ExamOption(id: "A", text: "新答案"), ExamOption(id: "B", text: "干扰项")],
            answer: ["A"], explanation: "新增解析", sourceIDs: ["test-source"],
            sourceLocation: "新测试位置", verification: "虚构测试")
        var concepts = old.bank.concepts
        concepts[0] = StudyConcept(id: first.id, title: first.title, section: first.section,
                                  method: first.method, questions: first.questions + [q])
        let fresh = StudyConcept(id: "fresh-\(suffix)", title: "新考点\(suffix)", section: "新增",
            method: "新方法", questions: (0..<2).map {
                ConceptQuestion(id: "fresh-\(suffix)-\($0)", type: .single, prompt: "新考点不同题 \(suffix) \($0)",
                    options: q.options, answer: q.answer, explanation: q.explanation,
                    sourceIDs: q.sourceIDs, sourceLocation: q.sourceLocation, verification: q.verification)
            })
        concepts.append(fresh)
        let bank = ConceptBank(id: old.bank.id, title: old.bank.title, scope: "扩展范围",
            notice: "虚构追加版本", sources: old.bank.sources, concepts: concepts)
        try bank.validateAppendOnly(from: old.bank)
        let data = try encode(bank), hash = StudySHA256.hex(data)
        let content = try encode(ConceptContent(format: "xkl-concepts-v1", bankBytes: data, bankSHA256: hash))
        let teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: hash,
            lessons: old.teaching.lessons + [ConceptLesson(conceptID: fresh.id, title: "新案例",
                story: "新的虚构故事", keyIdea: "新关系", workedExample: "新例题", commonTrap: "新条件")])
        let course = try encode(ConceptCourse(format: "xkl-course-v2", subject: old.subject,
                                             bankContent: content, teaching: teaching))
        return Fixture(subject: old.subject, bank: bank, bankHash: hash, bankContent: content,
                       teaching: teaching, courseContent: course)
    }

    @MainActor
    func testAppendOnlyUpgradeKeepsFamiliarDueUndoAndOriginalFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(.power), new = try upgrade(old), store = try importCourse(old, root: root)
        store.start(newLimit: 2)
        store.openStory(token: try XCTUnwrap(store.engine?.shown?.id), automatic: true)
        let answer = try answerFirst(store)
        store.setReason(.guessed, attemptID: answer.id)
        store.next(token: answer.presentation.id)
        store.familiar(token: try XCTUnwrap(store.engine?.shown?.id))
        let record = try XCTUnwrap(store.engine?.record)
        let events = store.coachingEvents
        let originalState = try Data(contentsOf: old.folder(in: root).appendingPathComponent("current.json"))
        let originalCoaching = try Data(contentsOf: old.folder(in: root).appendingPathComponent("coaching-current.json"))
        store.importContent(try input(new.courseContent, name: "update.xklcourse", in: root))
        XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        XCTAssertEqual(store.engine?.record.bankSHA256, new.bankHash)
        XCTAssertEqual(store.engine?.record.progress, record.progress)
        XCTAssertEqual(store.engine?.record.attempts, record.attempts)
        XCTAssertEqual(store.engine?.record.undoFamiliar, record.undoFamiliar)
        XCTAssertEqual(store.engine?.record.queue, record.queue)
        XCTAssertEqual(store.coachingEvents, events)
        XCTAssertEqual(try Data(contentsOf: old.folder(in: root).appendingPathComponent("current.json")), originalState)
        XCTAssertEqual(try Data(contentsOf: old.folder(in: root).appendingPathComponent("coaching-current.json")), originalCoaching)
        XCTAssertNil(store.engine?.record.progress["fresh-u1"])
        let restarted = ConceptStore(subject: .power, baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.coachingEvents, events)
        restarted.undo()
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.record.attempts.last?.mode, "undo")
        XCTAssertEqual(restarted.engine?.record.progress["c1"]?.familiar, false)
        XCTAssertFalse(restarted.shouldAutoShowStory(conceptID: "c0"))
    }

    @MainActor
    func testUpgradePreservesPendingPresentationAndRejectsDowngrade() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(), new = try upgrade(old), store = try importCourse(old, root: root)
        store.start(newLimit: 2)
        let p = try XCTUnwrap(store.engine?.shown)
        store.openStory(token: p.id, automatic: true)
        store.importContent(try input(new.courseContent, name: "new.xklcourse", in: root))
        XCTAssertFalse(store.blocked)
        XCTAssertEqual(store.engine?.shown, p)
        XCTAssertFalse(store.shouldAutoShowStory(conceptID: p.conceptID))
        store.importContent(try input(old.courseContent, name: "old.xklcourse", in: root))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.engine?.record.bankSHA256, new.bankHash)
        XCTAssertEqual(store.engine?.shown, p)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.shown, p)
    }

    @MainActor
    func testUpgradeRebasesClosedVolumesWithoutChangingAnyAttemptOrObservation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(), new = try upgrade(old), store = try importCourse(old, root: root)
        let answer = try answerFirst(store)
        store.setReason(.conditions, attemptID: answer.id)
        let base = old.folder(in: root)
        var e = try XCTUnwrap(store.engine)
        let closed = try encode(e.record), closedHash = StudySHA256.hex(closed)
        try closed.write(to: base.appendingPathComponent("volumes/\(closedHash).json"))
        try e.rotate(hash: closedHash)
        try encode(e.record).write(to: base.appendingPathComponent("current.json"))
        var journal = try JSONDecoder().decode(ConceptCoachingRecord.self,
            from: Data(contentsOf: base.appendingPathComponent("coaching-current.json")))
        let oldEvents = journal.events
        let closedJournal = try encode(journal), journalHash = StudySHA256.hex(closedJournal)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("coaching-volumes"), withIntermediateDirectories: true)
        try closedJournal.write(to: base.appendingPathComponent("coaching-volumes/\(journalHash).json"))
        try journal.rotate(hash: journalHash)
        try encode(journal).write(to: base.appendingPathComponent("coaching-current.json"))
        let loaded = ConceptStore(baseDirectory: root)
        XCTAssertFalse(loaded.blocked)
        loaded.importContent(try input(new.courseContent, name: "volumes-upgrade.xklcourse", in: root))
        XCTAssertFalse(loaded.blocked); XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.engine?.record.review, answer)
        XCTAssertEqual(loaded.coachingEvents, oldEvents)
        XCTAssertNotEqual(loaded.engine?.record.volumes.first?.sha256, closedHash)
        let volume = try XCTUnwrap(loaded.engine?.record.volumes.first)
        let rebased = try JSONDecoder().decode(ConceptRecord.self,
            from: Data(contentsOf: new.folder(in: root).appendingPathComponent("volumes/\(volume.sha256).json")))
        XCTAssertEqual(rebased.attempts, [answer])
        XCTAssertEqual(rebased.bankSHA256, new.bankHash)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("volumes/\(closedHash).json")), closed)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.selectedReason(attemptID: answer.id), .conditions)
        let exported = try JSONDecoder().decode(ExportSnapshot.self, from: restarted.exportRecords())
        XCTAssertEqual(exported.banks.count, 2)
        XCTAssertNotNil(exported.teachingAndCoaching[new.bankHash]?["migration.json"])
        XCTAssertNotNil(exported.teachingAndCoaching[new.bankHash]?["ancestors/\(old.bankHash).xklconcepts"])
    }

    @MainActor
    func testFailedUpgradeNeverSwitchesActiveAndCanRetryAfterFinalPointerFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(), new = try upgrade(old), writer = TestWriter()
        let store = try importCourse(old, root: root, writer: writer.write)
        let answer = try answerFirst(store)
        writer.failingFilename = "active.json"
        store.importContent(try input(new.courseContent, name: "interrupted.xklcourse", in: root))
        XCTAssertTrue(store.blocked)
        XCTAssertEqual(store.engine?.record.bankSHA256, old.bankHash)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.record.review, answer)
        restarted.importContent(try input(new.courseContent, name: "retry.xklcourse", in: root))
        XCTAssertFalse(restarted.blocked); XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.engine?.record.bankSHA256, new.bankHash)
        XCTAssertEqual(restarted.engine?.record.review, answer)
    }

    @MainActor
    func testTwoUpgradesKeepOriginalTeachingHashesAndAllHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(), first = try upgrade(old), second = try upgrade(first, suffix: "u2")
        let store = try importCourse(old, root: root)
        store.start(newLimit: 2)
        store.openStory(token: try XCTUnwrap(store.engine?.shown?.id), automatic: true)
        let originalEvents = store.coachingEvents
        store.importContent(try input(first.courseContent, name: "first.xklcourse", in: root))
        store.importContent(try input(second.courseContent, name: "second.xklcourse", in: root))
        XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.record.bankSHA256, second.bankHash)
        XCTAssertEqual(restarted.coachingEvents, originalEvents)
        XCTAssertFalse(restarted.shouldAutoShowStory(conceptID: "c0"))
        _ = try restarted.exportRecords()
    }

    @MainActor
    func testInterruptedUpgradeThenFurtherOldStudyRetriesWithoutLosingNewAnswers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(), new = try upgrade(old), writer = TestWriter()
        let store = try importCourse(old, root: root, writer: writer.write)
        let first = try answerFirst(store)
        writer.failingFilename = "active.json"
        let course = try input(new.courseContent, name: "update-after-study.xklcourse", in: root)
        store.importContent(course)
        XCTAssertTrue(store.blocked)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertEqual(restarted.engine?.record.bankSHA256, old.bankHash)
        restarted.next(token: first.presentation.id)
        let second = try XCTUnwrap(restarted.engine?.shown)
        restarted.choose("B", token: second.id)
        let result = try XCTUnwrap(restarted.engine?.record.review)
        restarted.setReason(.conditions, attemptID: result.id)
        let answers = try XCTUnwrap(restarted.engine?.record.attempts)
        let observations = restarted.coachingEvents
        let sourceBytes = try Data(contentsOf: old.folder(in: root).appendingPathComponent("current.json"))
        restarted.importContent(course)
        XCTAssertFalse(restarted.blocked); XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.engine?.record.bankSHA256, new.bankHash)
        XCTAssertEqual(restarted.engine?.record.attempts, answers)
        XCTAssertEqual(restarted.engine?.record.review, result)
        XCTAssertEqual(restarted.coachingEvents, observations)
        XCTAssertEqual(try Data(contentsOf: old.folder(in: root).appendingPathComponent("current.json")), sourceBytes)
        let final = ConceptStore(baseDirectory: root)
        XCTAssertFalse(final.blocked)
        XCTAssertEqual(final.engine?.record.attempts, answers)
        _ = try final.exportRecords()
    }

    @MainActor
    func testScopeUpgradeParksMultiplePendingAndPreservesOriginalBytesStoriesAndHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try fixture(.power)
        func package(_ bank: ConceptBank, lessons: [ConceptLesson], format: String) throws -> Fixture {
            let bankBytes = try encode(bank), hash = StudySHA256.hex(bankBytes)
            let content = try encode(ConceptContent(format: "xkl-concepts-v1",
                bankBytes: bankBytes, bankSHA256: hash))
            let teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: hash, lessons: lessons)
            let course = try encode(ConceptCourse(format: format, subject: .power,
                bankContent: content, teaching: teaching))
            return Fixture(subject: .power, bank: bank, bankHash: hash, bankContent: content,
                teaching: teaching, courseContent: course)
        }
        // A real multi-select pending card with one selected option, not a
        // fabricated answer or manually inserted learning history.
        let first = base.bank.concepts[0], oldQuestion = first.questions[0]
        var firstQuestions = first.questions
        firstQuestions[0] = ConceptQuestion(id: oldQuestion.id, type: .multiple,
            prompt: oldQuestion.prompt,
            options: [ExamOption(id: "A", text: "条件甲"), ExamOption(id: "B", text: "条件乙")],
            answer: ["A", "B"], explanation: "甲乙都满足测试条件",
            sourceIDs: oldQuestion.sourceIDs, sourceLocation: oldQuestion.sourceLocation,
            verification: oldQuestion.verification)
        var oldConcepts = base.bank.concepts
        oldConcepts[0] = StudyConcept(id: first.id, title: first.title, section: first.section,
            method: first.method, questions: firstQuestions)
        let oldBank = ConceptBank(id: base.bank.id, title: base.bank.title, scope: base.bank.scope,
            notice: base.bank.notice, sources: base.bank.sources, concepts: oldConcepts)
        let old = try package(oldBank, lessons: base.teaching.lessons, format: "xkl-course-v1")
        let extensionFixture = try upgrade(old, suffix: "scope")
        var newBank = extensionFixture.bank
        let include = newBank.concepts.filter { $0.id != "c0" }.flatMap(\.questions).map(\.id)
        let exclude = newBank.concepts[0].questions.map(\.id)
        newBank.studyScope = ConceptStudyScope(id: "2027-test", title: "2027虚构范围",
            sourceReference: "测试考纲", includedQuestionIDs: include,
            excludedQuestionReasons: Dictionary(uniqueKeysWithValues: exclude.map { ($0, "旧纲考点") }))
        let new = try package(newBank, lessons: extensionFixture.teaching.lessons, format: "xkl-course-v2")
        let store = try importCourse(old, root: root)
        store.start(newLimit: 2)
        let pending = try XCTUnwrap(store.engine?.shown)
        XCTAssertEqual(pending.conceptID, "c0")
        store.openStory(token: pending.id, automatic: true)
        store.choose("A", token: pending.id)
        let record = try XCTUnwrap(store.engine?.record)
        let selectedPending = try XCTUnwrap(record.presentation)
        XCTAssertEqual(selectedPending.selected, ["A"])
        XCTAssertNil(record.review)
        let events = store.coachingEvents
        XCTAssertEqual(events.count, 1)
        let oldCurrent = old.folder(in: root).appendingPathComponent("current.json")
        let oldCoaching = old.folder(in: root).appendingPathComponent("coaching-current.json")
        let stateBytes = try Data(contentsOf: oldCurrent)
        let coachingBytes = try Data(contentsOf: oldCoaching)

        store.importContent(try input(new.courseContent, name: "scope-pending.xklcourse", in: root))

        XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        XCTAssertEqual(store.engine?.record.bankSHA256, new.bankHash)
        XCTAssertEqual(store.engine?.record.progress, record.progress)
        XCTAssertEqual(store.engine?.record.attempts, record.attempts)
        XCTAssertEqual(store.engine?.record.day, record.day)
        XCTAssertEqual(store.engine?.record.nextSequence, record.nextSequence)
        XCTAssertNil(store.engine?.record.presentation)
        XCTAssertEqual(store.engine?.record.scopeSuspensions?.first?.presentation, selectedPending)
        XCTAssertFalse(try XCTUnwrap(store.engine?.record.queue.contains("c0")))
        XCTAssertEqual(store.coachingEvents, events)
        XCTAssertEqual(try Data(contentsOf: oldCurrent), stateBytes)
        XCTAssertEqual(try Data(contentsOf: oldCoaching), coachingBytes)

        let restarted = ConceptStore(subject: .power, baseDirectory: root)
        XCTAssertFalse(restarted.blocked); XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.engine?.record.bankSHA256, new.bankHash)
        XCTAssertEqual(restarted.engine?.record.scopeSuspensions?.first?.presentation, selectedPending)
        XCTAssertEqual(restarted.coachingEvents, events)
        let exported = try JSONDecoder().decode(ExportSnapshot.self, from: restarted.exportRecords())
        let migrated = try XCTUnwrap(exported.records.first { $0.bankSHA256 == new.bankHash })
        XCTAssertEqual(migrated.scopeSuspensions?.first?.presentation, selectedPending)
        XCTAssertEqual(migrated.progress, record.progress)
        XCTAssertEqual(migrated.attempts, record.attempts)
        restarted.start(newLimit: 2)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(restarted.engine?.shown?.conceptID, "c1")
        XCTAssertFalse(try XCTUnwrap(restarted.engine?.record.queue.contains("c0")))
        XCTAssertEqual(restarted.coachingEvents, events)
        XCTAssertEqual(try Data(contentsOf: oldCurrent), stateBytes)
    }

    @MainActor
    func testScopeSuspensionForClosedVolumeRejectsTamperedCopiedResultOnRestart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(.power), extensionFixture = try upgrade(old, suffix: "scope-result")
        var newBank = extensionFixture.bank
        let include = newBank.concepts.filter { $0.id != "c0" }.flatMap(\.questions).map(\.id)
        newBank.studyScope = ConceptStudyScope(id: "2027-test", title: "2027虚构范围",
            sourceReference: "测试考纲", includedQuestionIDs: include,
            excludedQuestionReasons: Dictionary(uniqueKeysWithValues:
                newBank.concepts[0].questions.map { ($0.id, "旧纲考点") }))
        let bankBytes = try encode(newBank), hash = StudySHA256.hex(bankBytes)
        let bankContent = try encode(ConceptContent(format: "xkl-concepts-v1",
            bankBytes: bankBytes, bankSHA256: hash))
        let teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: hash,
            lessons: extensionFixture.teaching.lessons)
        let course = try encode(ConceptCourse(format: "xkl-course-v2", subject: .power,
            bankContent: bankContent, teaching: teaching))
        let new = Fixture(subject: .power, bank: newBank, bankHash: hash, bankContent: bankContent,
            teaching: teaching, courseContent: course)
        let store = try importCourse(old, root: root)
        let answer = try answerFirst(store)
        store.setReason(.guessed, attemptID: answer.id)
        let events = store.coachingEvents
        let oldFolder = old.folder(in: root)
        var oldEngine = try XCTUnwrap(store.engine)
        let closed = try encode(oldEngine.record), closedHash = StudySHA256.hex(closed)
        let closedPath = oldFolder.appendingPathComponent("volumes/\(closedHash).json")
        try closed.write(to: closedPath, options: .atomic)
        try oldEngine.rotate(hash: closedHash)
        let oldCurrent = oldFolder.appendingPathComponent("current.json")
        let oldBytes = try encode(oldEngine.record)
        try oldBytes.write(to: oldCurrent, options: .atomic)
        let loaded = ConceptStore(subject: .power, baseDirectory: root)
        XCTAssertFalse(loaded.blocked)
        loaded.importContent(try input(new.courseContent, name: "scope-result.xklcourse", in: root))
        XCTAssertFalse(loaded.blocked); XCTAssertNil(loaded.error)
        XCTAssertNil(loaded.engine?.record.review)
        XCTAssertEqual(loaded.engine?.record.scopeSuspensions?.first?.review, answer)
        XCTAssertEqual(loaded.coachingEvents, events)
        XCTAssertEqual(loaded.engine?.record.progress, oldEngine.record.progress)
        XCTAssertEqual(loaded.engine?.record.day, oldEngine.record.day)
        XCTAssertEqual(try Data(contentsOf: oldCurrent), oldBytes)
        XCTAssertEqual(try Data(contentsOf: closedPath), closed)
        let restarted = ConceptStore(subject: .power, baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        _ = try restarted.exportRecords()

        let current = new.folder(in: root).appendingPathComponent("current.json")
        var corrupted = try JSONDecoder().decode(ConceptRecord.self, from: Data(contentsOf: current))
        let suspension = try XCTUnwrap(corrupted.scopeSuspensions?.first)
        let actual = try XCTUnwrap(suspension.review)
        // Keep every objective grade and progress field structurally valid;
        // only change copied metadata. A full-volume comparison must notice.
        let fake = ConceptAttempt(id: actual.id, sequence: actual.sequence, sessionID: actual.sessionID,
            presentation: actual.presentation, mode: actual.mode, isCorrect: actual.isCorrect,
            answeredAt: actual.answeredAt, day: actual.day, before: actual.before, after: actual.after,
            retryQueued: !actual.retryQueued, undoTarget: actual.undoTarget)
        corrupted.scopeSuspensions = [ConceptScopeSuspension(scopeID: suspension.scopeID,
            parkedAt: suspension.parkedAt, presentation: suspension.presentation,
            review: fake, undoFamiliar: suspension.undoFamiliar)]
        // Local structure cannot read the closed volume; Store.load must do so.
        XCTAssertNoThrow(try corrupted.validate(bank: newBank, hash: hash))
        let corruptedBytes = try encode(corrupted)
        try corruptedBytes.write(to: current, options: .atomic)
        let rejected = ConceptStore(subject: .power, baseDirectory: root)
        XCTAssertTrue(rejected.blocked)
        XCTAssertNotNil(rejected.error)
        XCTAssertNil(rejected.engine)
        XCTAssertThrowsError(try rejected.exportRecords())
        XCTAssertEqual(try Data(contentsOf: current), corruptedBytes)
        XCTAssertEqual(try Data(contentsOf: oldCurrent), oldBytes)
        XCTAssertEqual(try Data(contentsOf: closedPath), closed)
    }
}
#endif
