#if os(macOS)
import Foundation
import XCTest
@testable import StudyClientModel

final class HandbookCardStoreTests: XCTestCase {
    private enum Failure: Error { case injected }
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value)
    }
    private func fixture(revision: String = "1.0", count: Int = 2) -> HandbookCardPackage {
        .init(id: "synthetic-handbook", subject: .computer, title: "Synthetic readable knowledge cards", revision: revision,
            source: .init(title: "Synthetic source", fileName: "synthetic.pdf", sha256: String(repeating: "b", count: 64), pdfPageCount: 10, includedPages: Array(1...10)),
            chapters: [.init(id: "synthetic-chapter", title: "Synthetic chapter")], cards: (1...count).map { n in
                .init(id: "synthetic-card-\(n)", sourceGroupIDs: ["synthetic-group-\(n)"], topicNumber: n,
                    title: "Synthetic knowledge \(n)", prompt: "Recall synthetic fact \(n)", answerSummary: "Synthetic answer \(n)",
                    blocks: [], sourcePages: [n], examples: [], sourceNotes: [], chapterID: "synthetic-chapter")
            })
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("handbook-card-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func current(_ base: URL) -> URL { base.appendingPathComponent("HandbookCards/computer/current.json") }
    private func initial(_ base: URL) -> URL { base.appendingPathComponent("HandbookCards/computer/initial.json") }
    private func files(_ base: URL) throws -> [String: Data] {
        let base = base.standardizedFileURL.resolvingSymlinksInPath(), prefix = base.pathComponents
        var result = [String: Data]()
        guard let all = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let file as URL in all where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard path.count > prefix.count, Array(path.prefix(prefix.count)) == prefix else { throw CocoaError(.fileReadInvalidFileName) }
            let key = path.dropFirst(prefix.count).joined(separator: "/")
            guard result[key] == nil else { throw CocoaError(.fileReadCorruptFile) }
            result[key] = try Data(contentsOf: file)
        }
        return result
    }
    @MainActor private func prepared(_ base: URL, writer: @escaping (Data, URL) throws -> Void = DurableFile.write) throws -> HandbookCardStore {
        let store = HandbookCardStore(baseDirectory: base, documentsDirectory: base, writer: writer)
        store.importData(try encode(fixture()))
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertNotNil(store.engine)
        return store
    }
    @MainActor private func reveal(_ store: HandbookCardStore) throws -> UUID {
        store.start(now: now); let id = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: id, now: now); XCTAssertFalse(store.blocked, store.error ?? "")
        return id
    }

    @MainActor func testNewCardStoreNeverChangesAnyOldLearningNamespace() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let protected = ["QuestionBank/current-state.json", "Study/snapshot.bin", "Study/event-log.bin", "Study/personal-state.bin", "MathExperience/current.json", "ComputerFoundation/current.json", "PowerSystems/current.json", "ProfessionalRecall/computer/current.json", "KnowledgeRecall/computer/current.json", "KnowledgeLearning/computer/current.json", "ProfessionalQuestions/computer/current.json", "PhoneArchive/archive.bin"]
        for path in protected {
            let p = base.appendingPathComponent(path); try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("retain-" + path).utf8).write(to: p)
        }
        let before = try files(base), store = try prepared(base), token = try reveal(store)
        store.rate(remembered: false, token: token, now: now)
        XCTAssertFalse(store.blocked, store.error ?? "")
        for path in protected { XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(path)), try XCTUnwrap(before[path])) }
    }
    @MainActor func testDuplicateImportAndRatingAreByteIdenticalNoOps() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base), token = try reveal(store)
        store.rate(remembered: true, token: token, now: now)
        let record = try XCTUnwrap(store.engine?.record), tree = try files(base)
        store.importData(try encode(fixture())); store.rate(remembered: false, token: token, now: now)
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertEqual(store.engine?.record, record)
        XCTAssertEqual(try files(base), tree)
    }
    @MainActor func testBackSideAndSelfRatingSurviveReopening() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base), token = try reveal(store)
        let reopened = HandbookCardStore(baseDirectory: base)
        XCTAssertEqual(reopened.engine?.presentation?.id, token); XCTAssertEqual(reopened.engine?.presentation?.revealed, true)
        XCTAssertTrue(try XCTUnwrap(reopened.engine).record.ratings.isEmpty)
        reopened.rate(remembered: false, token: token, now: now)
        let rated = HandbookCardStore(baseDirectory: base)
        XCTAssertEqual(rated.engine?.record.ratings.count, 1)
        XCTAssertEqual(rated.engine?.record.ratings[0].remembered, false)
        XCTAssertEqual(rated.engine?.record.ratings[0].nextDueAt, now.addingTimeInterval(86_400))
    }
    @MainActor func testContentUpdatePreservesInitialAndEveryOldSelfRating() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base), token = try reveal(store)
        store.rate(remembered: true, token: token, now: now)
        let initialBytes = try Data(contentsOf: initial(base)), record = try XCTUnwrap(store.engine?.record)
        store.importData(try encode(fixture(revision: "1.1", count: 3)))
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertEqual(store.engine?.record.ratings, record.ratings)
        XCTAssertEqual(store.engine?.record.progress, record.progress)
        XCTAssertEqual(store.engine?.presentation, record.presentation)
        XCTAssertEqual(try Data(contentsOf: initial(base)), initialBytes)
        let opened = HandbookCardStore(baseDirectory: base)
        XCTAssertFalse(opened.blocked, opened.error ?? ""); XCTAssertEqual(opened.package?.cards.count, 3)
    }
    @MainActor func testDifferentlySerializedSourcePackageIsRetainedInCompleteExport() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base), token = try reveal(store)
        store.rate(remembered: true, token: token, now: now)
        let record = try XCTUnwrap(store.engine?.record), initialBytes = try Data(contentsOf: initial(base))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(fixture())) as? [String: Any])
        json["syntheticFutureSourceField"] = "retain raw source metadata"
        let raw = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        store.importData(raw)
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertEqual(store.engine?.record, record)
        XCTAssertEqual(try Data(contentsOf: initial(base)), initialBytes)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportRecords()) as? [String: Any])
        let imports = try XCTUnwrap(exported["contentImports"] as? [String: String])
        XCTAssertEqual(imports.count, 2); XCTAssertTrue(imports.values.contains(raw.base64EncodedString()))
    }
    @MainActor func testFailedRatingWriteDoesNotPublishOrResetTheSavedBackSide() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        var fail = false
        let store = try prepared(base) { data, url in if fail { throw Failure.injected }; try DurableFile.write(data, to: url) }
        let token = try reveal(store), before = try Data(contentsOf: current(base)); fail = true
        store.rate(remembered: true, token: token, now: now)
        XCTAssertTrue(store.blocked); XCTAssertTrue(try XCTUnwrap(store.engine).record.ratings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: current(base)), before)
        let reopened = HandbookCardStore(baseDirectory: base)
        XCTAssertFalse(reopened.blocked, reopened.error ?? ""); XCTAssertEqual(reopened.engine?.presentation?.id, token)
        XCTAssertEqual(reopened.engine?.presentation?.revealed, true)
    }
    @MainActor func testErrorAfterReplacementRecoversCommittedRatingWithoutRollbackOrDoubleCount() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        var fail = false
        let store = try prepared(base) { data, url in
            try DurableFile.write(data, to: url)
            if fail, url.lastPathComponent == "current.json" { throw Failure.injected }
        }
        let token = try reveal(store); fail = true; store.rate(remembered: false, token: token, now: now)
        XCTAssertTrue(store.blocked)
        let reopened = HandbookCardStore(baseDirectory: base)
        XCTAssertFalse(reopened.blocked, reopened.error ?? ""); XCTAssertEqual(reopened.engine?.record.ratings.count, 1)
        let before = try Data(contentsOf: current(base)); reopened.rate(remembered: true, token: token, now: now)
        XCTAssertEqual(reopened.engine?.record.ratings.count, 1); XCTAssertEqual(try Data(contentsOf: current(base)), before)
    }
    @MainActor func testMissingCurrentNeverReinitializesAnExistingLearner() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try prepared(base), token = try reveal(store); store.rate(remembered: true, token: token, now: now)
        try FileManager.default.removeItem(at: current(base)); let before = try files(base)
        let reopened = HandbookCardStore(baseDirectory: base); XCTAssertTrue(reopened.blocked)
        reopened.importData(try encode(fixture())); XCTAssertEqual(try files(base), before)
    }
    @MainActor func testInvalidPackageRejectedBeforeAnyImportArchive() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = HandbookCardStore(baseDirectory: base), before = try files(base)
        store.importData(Data("{\"format\":\"wrong\"}".utf8))
        XCTAssertFalse(store.blocked); XCTAssertNotNil(store.error); XCTAssertNil(store.engine)
        XCTAssertEqual(try files(base), before)
    }
    @MainActor func testConcurrentOldPageCannotOverwriteNewSelfRating() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try prepared(base), token = try reveal(first), stale = HandbookCardStore(baseDirectory: base)
        first.rate(remembered: false, token: token, now: now)
        let actual = try Data(contentsOf: current(base)); stale.rate(remembered: true, token: token, now: now)
        XCTAssertTrue(stale.blocked); XCTAssertEqual(try Data(contentsOf: current(base)), actual)
        XCTAssertEqual(HandbookCardStore(baseDirectory: base).engine?.record.ratings.first?.remembered, false)
    }
    @MainActor func testSymlinkNamespaceCannotPointIntoPublicLearningFiles() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let publicRoot = base.appendingPathComponent("QuestionBank"), sentinel = publicRoot.appendingPathComponent("current.json")
        try FileManager.default.createDirectory(at: publicRoot, withIntermediateDirectories: true)
        let saved = Data("synthetic retained public record".utf8); try saved.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("HandbookCards"), withDestinationURL: publicRoot)
        let store = HandbookCardStore(baseDirectory: base); XCTAssertTrue(store.blocked)
        store.importData(try encode(fixture())); XCTAssertEqual(try Data(contentsOf: sentinel), saved)
    }
    @MainActor func testStagedDiscoveryUsesOnlyHandbookFolderAndMatchingSubject() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("HandbookCards")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = try encode(fixture()); try raw.write(to: folder.appendingPathComponent("baodian-computer.xklflashcards"))
        try raw.write(to: folder.appendingPathComponent("baodian-power.xklflashcards"))
        let namespace = base.appendingPathComponent("private-support")
        let store = HandbookCardStore(baseDirectory: namespace, documentsDirectory: base)
        XCTAssertEqual(store.stagedFiles().map(\.lastPathComponent), ["baodian-computer.xklflashcards"])
        XCTAssertNil(store.engine)
    }
}
#endif
