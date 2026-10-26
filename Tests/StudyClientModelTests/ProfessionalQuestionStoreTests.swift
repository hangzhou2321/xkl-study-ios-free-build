#if os(macOS)
import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

final class ProfessionalQuestionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private enum Failure: Error { case injected }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func question(_ n: Int, book: String = "basic") -> ProfessionalObjectiveQuestion {
        .init(id: "synthetic-original-\(n)", type: .single, book: book, chapter: "Synthetic chapter",
            prompt: "Synthetic supplied original question \(n)?",
            options: [.init(id: "A", text: "Synthetic first \(n)"), .init(id: "B", text: "Synthetic second \(n)")],
            answer: ["A"], sourceLocation: "Synthetic PDF page \(n)", sourceDocumentID: "synthetic-source",
            pdfPage: n, sourceAnswer: "A", explanation: "Synthetic explanation, no private question text")
    }
    private func fixture(revision: String = "1.0", count: Int = 3) -> ProfessionalQuestionPackage {
        .init(id: "synthetic-professional-bank", subject: .power, title: "Synthetic supplied originals",
            revision: revision, sources: [.init(id: "synthetic-source", title: "Synthetic only", reference: "fixture")],
            questions: (1...count).map { question($0, book: $0 == count ? "reinforcement" : "basic") })
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("professional-question-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true); return value
    }
    private func current(_ base: URL) -> URL { base.appendingPathComponent("ProfessionalQuestions/power/current.json") }
    private func initial(_ base: URL) -> URL { base.appendingPathComponent("ProfessionalQuestions/power/initial.json") }
    private func files(_ base: URL) throws -> [String: Data] {
        var values: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return values }
        for case let path as URL in enumerator where try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            values[String(path.path.dropFirst(base.path.count + 1))] = try Data(contentsOf: path)
        }
        return values
    }
    @MainActor private func prepared(_ base: URL) throws -> ProfessionalQuestionStore {
        let value = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        value.importData(try encode(fixture())); XCTAssertFalse(value.blocked, value.error ?? "")
        XCTAssertNotNil(value.engine); return value
    }
    @MainActor private func answer(_ store: ProfessionalQuestionStore, helped: Bool = false) throws -> UUID {
        store.start(now: now)
        let token = try XCTUnwrap(store.engine?.presentation?.id)
        store.saveDraft(["A"], token: token)
        if helped { store.help(token: token) }
        store.submit(token: token, now: now)
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertNotNil(store.engine?.result)
        return token
    }

    @MainActor func testNewNamespacePreservesAllExistingStudyFiles() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let protected = ["QuestionBank/current-state.json", "Study/snapshot.bin", "Study/event-log.bin", "Study/personal-state.bin",
            "MathExperience/current.json", "ComputerFoundation/current.json", "PowerSystems/current.json",
            "ProfessionalRecall/power/current.json", "KnowledgeLearning/power/current.json", "PhoneArchive/archive.bin"]
        for path in protected {
            let file = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("unchanged-" + path).utf8).write(to: file)
        }
        let before = try files(base)
        let store = try prepared(base); _ = try answer(store)
        for path in protected { XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(path)), before[path]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: current(base).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: initial(base).path))
    }

    @MainActor func testInvalidPackageIsRejectedBeforeWritingAnyArchive() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        let before = try files(base)
        store.importData(Data("{\"format\":\"wrong\"}".utf8))
        XCTAssertNotNil(store.error); XCTAssertFalse(store.blocked); XCTAssertNil(store.engine)
        XCTAssertEqual(try files(base), before)
    }

    @MainActor func testIncompleteSubmissionDoesNotLockOrWriteAnOtherwiseIntactRecord() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base); store.start(now: now)
        let token = try XCTUnwrap(store.engine?.presentation?.id), before = try Data(contentsOf: current(base))
        store.submit(token: token, now: now)
        XCTAssertFalse(store.blocked); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: current(base)), before)
        store.choose("A"); store.submit(token: token, now: now)
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertNil(store.error)
        XCTAssertEqual(store.engine?.record.attempts.count, 1)
    }

    @MainActor func testRepeatedImportKeepsGradeAndEveryDurableByteUnchanged() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base); _ = try answer(store)
        let before = try files(base), record = try XCTUnwrap(store.engine?.record)
        store.importData(try encode(fixture())); store.importData(try encode(fixture()))
        XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(store.engine?.record, record); XCTAssertEqual(try files(base), before)
    }

    @MainActor func testDraftHelpAndSubmittedFeedbackSurviveReopeningWithoutDoubleGrade() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try prepared(base); first.start(now: now)
        let token = try XCTUnwrap(first.engine?.presentation?.id), order = first.engine?.presentation?.optionOrder
        first.choose("A"); first.help(token: token)
        let resumed = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertFalse(resumed.blocked, resumed.error ?? "")
        XCTAssertEqual(resumed.engine?.presentation?.id, token)
        XCTAssertEqual(resumed.engine?.presentation?.optionOrder, order)
        XCTAssertEqual(resumed.engine?.presentation?.selectedOptions, ["A"])
        XCTAssertTrue(resumed.engine?.presentation?.helped == true)
        resumed.submit(token: token, now: now)
        XCTAssertTrue(resumed.engine?.result?.isCorrect == true)
        XCTAssertFalse(resumed.engine?.result?.independent == true)
        let raw = try Data(contentsOf: current(base))
        resumed.submit(token: token, now: now)
        XCTAssertEqual(try Data(contentsOf: current(base)), raw)
        let after = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertEqual(after.engine?.record.attempts.count, 1)
        XCTAssertEqual(after.engine?.result, resumed.engine?.result)
    }

    @MainActor func testContentAppendArchivesPriorBytesAndKeepsAllHistoryAndInitial() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base); _ = try answer(store)
        let oldRecord = try XCTUnwrap(store.engine?.record), oldResult = store.engine?.result
        let old = try Data(contentsOf: current(base)), anchor = try Data(contentsOf: initial(base))
        store.importData(try encode(fixture(revision: "1.1", count: 4)))
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertNil(store.error)
        XCTAssertEqual(store.engine?.record.attempts, oldRecord.attempts)
        XCTAssertEqual(store.engine?.result, oldResult)
        XCTAssertEqual(try Data(contentsOf: initial(base)), anchor)
        let archived = base.appendingPathComponent("ProfessionalQuestions/power/revisions/" + StudySHA256.hex(old) + ".json")
        XCTAssertEqual(try Data(contentsOf: archived), old)
        let reopened = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.package?.revision, "1.1")
        XCTAssertEqual(reopened.engine?.record.attempts, oldRecord.attempts)
        XCTAssertEqual(reopened.engine?.record.contentVersions.count, 2)
        struct Export: Decodable { let contentImports: [String: Data]; let contentRevisions: [String: Data] }
        let exported = try JSONDecoder().decode(Export.self, from: reopened.exportRecords())
        XCTAssertEqual(exported.contentImports.count, 2); XCTAssertEqual(exported.contentRevisions.count, 1)
    }

    @MainActor func testStalePageCannotOverwriteNewerPresentationOrGrade() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try prepared(base)
        let stale = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        _ = try answer(first)
        let newest = try Data(contentsOf: current(base))
        stale.start(now: now)
        XCTAssertTrue(stale.blocked); XCTAssertNil(stale.engine?.presentation)
        XCTAssertEqual(try Data(contentsOf: current(base)), newest)
    }

    @MainActor func testWriteFailureBeforeReplacementPublishesNoCandidate() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try prepared(base); first.start(now: now); first.choose("A")
        let before = try Data(contentsOf: current(base)), old = first.engine?.record
        let failing = ProfessionalQuestionStore(subject: .power, baseDirectory: base, writer: { bytes, url in
            if url.lastPathComponent == "current.json" { throw Failure.injected }
            try DurableFile.write(bytes, to: url)
        })
        failing.submit(token: try XCTUnwrap(failing.engine?.presentation?.id), now: now)
        XCTAssertTrue(failing.blocked); XCTAssertEqual(failing.engine?.record, old)
        XCTAssertEqual(try Data(contentsOf: current(base)), before)
        let reopened = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertFalse(reopened.blocked); XCTAssertEqual(reopened.engine?.record, old)
    }

    @MainActor func testErrorAfterReplacementNeverRollsBackOrDuplicatesGradeOnReopen() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try prepared(base); first.start(now: now); first.choose("A")
        let old = try Data(contentsOf: current(base)), token = try XCTUnwrap(first.engine?.presentation?.id)
        let failing = ProfessionalQuestionStore(subject: .power, baseDirectory: base, writer: { bytes, url in
            try DurableFile.write(bytes, to: url)
            if url.lastPathComponent == "current.json" { throw Failure.injected }
        })
        failing.submit(token: token, now: now)
        XCTAssertTrue(failing.blocked); XCTAssertTrue(failing.engine?.record.attempts.isEmpty == true)
        let committed = try Data(contentsOf: current(base)); XCTAssertNotEqual(committed, old)
        let reopened = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        reopened.submit(token: token, now: now)
        XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        XCTAssertEqual(try Data(contentsOf: current(base)), committed)
    }

    @MainActor func testOldPackageAndDeletedCurrentNeverResetLaterProgress() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base); _ = try answer(store)
        store.importData(try encode(fixture(revision: "1.1", count: 4)))
        let newest = try Data(contentsOf: current(base))
        store.importData(try encode(fixture()))
        XCTAssertNotNil(store.error); XCTAssertEqual(try Data(contentsOf: current(base)), newest)
        let anchor = try Data(contentsOf: initial(base))
        try FileManager.default.removeItem(at: current(base))
        let missing = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertTrue(missing.blocked); XCTAssertNil(missing.engine)
        missing.importData(try encode(fixture()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current(base).path))
        XCTAssertEqual(try Data(contentsOf: initial(base)), anchor)
    }

    @MainActor func testStagedDiscoveryDoesNotImportAndOnlyListsOwnSubjectFiles() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        let incoming = documents.appendingPathComponent("ProfessionalQuestionBanks")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try encode(fixture()).write(to: incoming.appendingPathComponent("power-originals.xklquestions"))
        try encode(fixture()).write(to: incoming.appendingPathComponent("computer-originals.xklquestions"))
        let store = ProfessionalQuestionStore(subject: .power, baseDirectory: base, documentsDirectory: documents)
        XCTAssertEqual(store.stagedFiles().map(\.lastPathComponent), ["power-originals.xklquestions"])
        XCTAssertNil(store.engine); XCTAssertFalse(FileManager.default.fileExists(atPath: current(base).path))
    }

    @MainActor func testUnknownCurrentFieldsArePreservedBeforeTypedMutation() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try prepared(base)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: current(base))) as? [String: Any])
        object["futureExtension"] = ["syntheticEvidence": "preserve-this-original-byte-file"]
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try raw.write(to: current(base))
        let restored = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertFalse(restored.blocked, restored.error ?? "")
        restored.start(now: now)
        XCTAssertFalse(restored.blocked, restored.error ?? "")
        let hash = StudySHA256.hex(raw)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("ProfessionalQuestions/power/raw/" + hash + ".json")), raw)
        struct Export: Decodable { let retainedRawArchives: [String: Data] }
        let exported = try JSONDecoder().decode(Export.self, from: restored.exportRecords())
        XCTAssertEqual(exported.retainedRawArchives[hash], raw)
    }

    @MainActor func testFailedImportArtifactDoesNotActivateContentAndRetryKeepsPriorGrade() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try prepared(base); _ = try answer(first)
        let before = try Data(contentsOf: current(base)), oldRecord = first.engine?.record
        let failing = ProfessionalQuestionStore(subject: .power, baseDirectory: base, writer: { bytes, url in
            if url.path.contains("/imports/") { throw Failure.injected }
            try DurableFile.write(bytes, to: url)
        })
        failing.importData(try encode(fixture(revision: "1.1", count: 4)))
        XCTAssertFalse(failing.blocked, "Only an immutable artifact failed; active current file is unchanged")
        XCTAssertNotNil(failing.error); XCTAssertEqual(failing.package?.revision, "1.0")
        XCTAssertEqual(failing.engine?.record, oldRecord); XCTAssertEqual(try Data(contentsOf: current(base)), before)
        let retry = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        retry.importData(try encode(fixture(revision: "1.1", count: 4)))
        XCTAssertFalse(retry.blocked, retry.error ?? ""); XCTAssertNil(retry.error)
        XCTAssertEqual(retry.package?.revision, "1.1")
        XCTAssertEqual(retry.engine?.record.attempts, oldRecord?.attempts)
    }

    @MainActor func testSymlinkedNamespaceCannotWriteIntoAnotherLearningArea() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let other = base.appendingPathComponent("QuestionBank")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let protected = other.appendingPathComponent("current-state.json"), bytes = Data("public-history-unchanged".utf8)
        try bytes.write(to: protected)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("ProfessionalQuestions"), withDestinationURL: other)
        let store = ProfessionalQuestionStore(subject: .power, baseDirectory: base)
        XCTAssertTrue(store.blocked); XCTAssertNil(store.engine)
        store.importData(try encode(fixture()))
        XCTAssertEqual(try Data(contentsOf: protected), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("power").path))
    }
}
#endif
