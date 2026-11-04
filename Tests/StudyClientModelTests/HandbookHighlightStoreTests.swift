import Foundation
import XCTest
@testable import StudyClientModel

#if canImport(Combine)
final class HandbookHighlightStoreTests: XCTestCase {
    private struct Export: Decodable { let files: [String: Data] }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func package(_ subject: ConceptSubject) -> HandbookCardPackage {
        let card = HandbookCard(id: "synthetic-card", sourceGroupIDs: ["synthetic"], topicNumber: 1,
            title: "合成卡", prompt: "合成问题", answerSummary: "合成答案", blocks: [], sourcePages: [1],
            examples: [], sourceNotes: [], chapterID: "chapter")
        return .init(id: "synthetic-\(subject.rawValue)", subject: subject, title: "Synthetic", revision: "1",
            source: .init(title: "Synthetic", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64), pdfPageCount: 1, includedPages: [1]),
            chapters: [.init(id: "chapter", title: "Synthetic")], cards: [card])
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-highlights-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func selection(_ doc: HandbookHighlightDocument, field id: String, text: String) throws -> NSRange {
        let field = try XCTUnwrap(doc.fields.first { $0.id == id })
        let local = (field.text as NSString).range(of: text)
        XCTAssertNotEqual(local.location, NSNotFound)
        return NSRange(location: field.range.location + local.location, length: local.length)
    }

    @MainActor func testSaveRemoveRestartAndExportLeaveSchedulerAndOtherSubjectUntouched() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let computer = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        computer.importData(try JSONEncoder().encode(package(.computer)))
        XCTAssertNil(computer.error)
        computer.start(now: now)
        let beforeState = try XCTUnwrap(computer.engine?.state)
        let directory = root.appendingPathComponent("HandbookWordRecall/computer")
        let schedulerFiles = ["current.json", "initial.json", "legacy-baseline.json"]
        let beforeBytes = try Dictionary(uniqueKeysWithValues: schedulerFiles.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
        let powerSentinel = root.appendingPathComponent("other-subject-sentinel")
        let sentinelBytes = Data("unaltered-other-subject".utf8); try sentinelBytes.write(to: powerSentinel)
        let card = try XCTUnwrap(computer.engine?.currentCard)
        let doc = HandbookHighlightDocument(card: card, guide: nil)
        let marks = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        XCTAssertNil(marks.error)
        marks.apply(document: doc, selection: try selection(doc, field: "summary", text: "合成"), remove: false)
        XCTAssertFalse(marks.blocked); XCTAssertNil(marks.error); XCTAssertEqual(marks.state.spans.count, 1)
        XCTAssertEqual(computer.engine?.state, beforeState)
        for (name, bytes) in beforeBytes { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), bytes) }
        XCTAssertEqual(try Data(contentsOf: powerSentinel), sentinelBytes)
        let restarted = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        XCTAssertEqual(restarted.state, marks.state)
        let exported = try JSONDecoder().decode(Export.self, from: computer.exportRecords())
        XCTAssertNotNil(exported.files["personal-highlights/current.json"])
        restarted.apply(document: doc, selection: try selection(doc, field: "summary", text: "合"), remove: true)
        XCTAssertFalse(restarted.blocked); XCTAssertEqual(restarted.state.spans.count, 1)
        let revisions = directory.appendingPathComponent("personal-highlights/revisions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: revisions.path).count, 1)
        XCTAssertEqual(HandbookHighlightStore(subject: .computer, baseDirectory: root).state, restarted.state)
        XCTAssertEqual(computer.engine?.state, beforeState)
        for (name, bytes) in beforeBytes { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), bytes) }
        XCTAssertTrue(HandbookHighlightStore(subject: .power, baseDirectory: root).state.spans.isEmpty)
    }

    @MainActor func testConcurrentEditorAndCorruptFileNeverOverwriteOtherMarks() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = HandbookHighlightDocument(card: package(.computer).cards[0], guide: nil)
        let first = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        let stale = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        first.apply(document: doc, selection: try selection(doc, field: "summary", text: "合"), remove: false)
        XCTAssertFalse(first.blocked)
        let path = root.appendingPathComponent("HandbookWordRecall/computer/personal-highlights/current.json")
        let committed = try Data(contentsOf: path)
        stale.apply(document: doc, selection: try selection(doc, field: "summary", text: "成"), remove: false)
        XCTAssertTrue(stale.blocked); XCTAssertEqual(try Data(contentsOf: path), committed)
        XCTAssertEqual(HandbookHighlightStore(subject: .computer, baseDirectory: root).state, first.state)
        let damaged = Data("{ invalid json".utf8); try damaged.write(to: path, options: .atomic)
        let broken = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        XCTAssertTrue(broken.blocked)
        broken.apply(document: doc, selection: try selection(doc, field: "summary", text: "成"), remove: false)
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }

    @MainActor func testSelectionErrorDoesNotBlockAndPostWriteFailureRequiresReopen() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = HandbookHighlightDocument(card: package(.power).cards[0], guide: nil)
        let regular = HandbookHighlightStore(subject: .power, baseDirectory: root)
        regular.apply(document: doc, selection: NSRange(location: 0, length: 1), remove: false)
        XCTAssertFalse(regular.blocked); XCTAssertNotNil(regular.error)
        regular.apply(document: doc, selection: try selection(doc, field: "summary", text: "合"), remove: false)
        XCTAssertFalse(regular.blocked); XCTAssertNil(regular.error)

        let secondRoot = try temporary(); defer { try? FileManager.default.removeItem(at: secondRoot) }
        enum Injected: Error { case failedAfterWrite }
        let failing = HandbookHighlightStore(subject: .power, baseDirectory: secondRoot) { bytes, url in
            try bytes.write(to: url, options: .atomic); throw Injected.failedAfterWrite
        }
        failing.apply(document: doc, selection: try selection(doc, field: "summary", text: "合"), remove: false)
        XCTAssertTrue(failing.blocked); XCTAssertTrue(failing.state.spans.isEmpty)
        let reopened = HandbookHighlightStore(subject: .power, baseDirectory: secondRoot)
        XCTAssertFalse(reopened.blocked); XCTAssertEqual(reopened.state.spans.count, 1)
    }
}
#endif
