#if os(macOS)
import XCTest
import StudyCore
@testable import StudyClientModel

final class RecallStoreTests: XCTestCase {
    @MainActor func testSupplementUsesIndependentArchiveAndPreservesOldProgressExactly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bank, old) = try fixture()
        let original = RecallStore(subject: .computer, bank: bank, teaching: old, baseDirectory: root)
        original.act("start", newLimit: 1)
        let oldBytes = try original.export()
        var teaching = old
        let group = SupplementRecallGroup(id: "yc4-h-test", title: "独立补充主题", branchID: "main",
            recallCards: [.init(id: "yc4-h-test:v4:new", prompt: "新卡？", answer: "新答案")])
        teaching.recallGroups = [group]
        let supplement = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root, supplementGroup: group)
        XCTAssertFalse(supplement.blocked)
        supplement.act("start", newLimit: 1)
        XCTAssertEqual(supplement.engine?.item?.id, "yc4-h-test:v4:new")
        let restarted = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertFalse(restarted.blocked)
        XCTAssertEqual(try restarted.export(), oldBytes)
        XCTAssertEqual(restarted.engine?.record, original.engine?.record)
        let restartedSupplement = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root, supplementGroup: group)
        XCTAssertEqual(restartedSupplement.engine?.record, supplement.engine?.record)
    }
    private func fixture() throws -> (ConceptBank, ConceptTeaching) {
        let bank = ConceptBank(id: ConceptSubject.computer.bankID, title: "Synthetic bank", scope: "Test", notice: "Synthetic",
            sources: [ConceptSource(id: "s", title: "Test", reference: "fixture")],
            concepts: [StudyConcept(id: "c", title: "Test concept", section: "Test", method: "Test method", questions: [
                ConceptQuestion(id: "q", type: .single, prompt: "Synthetic question?",
                    options: [.init(id: "A", text: "One"), .init(id: "B", text: "Two")], answer: ["A"],
                    explanation: "Synthetic reason", sourceIDs: ["s"], sourceLocation: "Fixture", verification: "Test"),
                ConceptQuestion(id: "q2", type: .single, prompt: "Different synthetic question?",
                    options: [.init(id: "A", text: "First"), .init(id: "B", text: "Second")], answer: ["B"],
                    explanation: "Different synthetic reason", sourceIDs: ["s"], sourceLocation: "Fixture 2", verification: "Test")])])
        let hash = StudySHA256.hex(try JSONEncoder().encode(bank))
        let teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: hash,
            lessons: [ConceptLesson(conceptID: "c", title: "Synthetic lesson", story: "Synthetic story", keyIdea: "Test idea",
                workedExample: "Synthetic example", commonTrap: "Synthetic trap", recallCards: [
                    RecallCard(id: "c:1", prompt: "Recall question?", answer: "Recall answer")])])
        try bank.validate(); try teaching.validate(bank: bank, hash: hash)
        return (bank, teaching)
    }
    @MainActor func testRealDiskRestartExportAndOriginalCourseFilesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("ComputerFoundation/current.json")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("original learning history must remain exact".utf8); try sentinel.write(to: original)
        let (bank, teaching) = try fixture()
        let store = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertFalse(store.blocked)
        store.act("start", newLimit: 1)
        let token = try XCTUnwrap(store.engine?.record.state.shown?.id)
        store.act("reveal", token: token)
        let restarted = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertEqual(restarted.engine?.record, store.engine?.record)
        XCTAssertTrue(restarted.engine?.record.state.shown?.revealed == true)
        restarted.act("grade", token: token, remembered: true)
        let archive = try JSONDecoder().decode(RecallArchive.self, from: restarted.export())
        _ = try RecallEngine(deck: archive.deck, record: archive.record)
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
        XCTAssertEqual(archive.record.state.progress["c:1"]?.remembered, 1)
        let path = root.appendingPathComponent("RecallCards/computer/\(try archive.deck.hash)/recall.json")
        try FileManager.default.removeItem(at: path)
        let missing = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertTrue(missing.blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
    }
    @MainActor func testFailedWriteDoesNotAdvanceUIAndRestartRecoversSavedRecord() throws {
        final class Writer {
            var fail = false
            func write(_ data: Data, _ url: URL) throws {
                if fail { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture(); let writer = Writer()
        let store = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root, writer: writer.write)
        store.act("start", newLimit: 1)
        let token = try XCTUnwrap(store.engine?.record.state.shown?.id)
        store.act("reveal", token: token)
        let before = store.engine?.record; writer.fail = true
        store.act("grade", token: token, remembered: true)
        XCTAssertTrue(store.blocked); XCTAssertEqual(store.engine?.record, before)
        let restored = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertFalse(restored.blocked); XCTAssertEqual(restored.engine?.record, before)
        restored.act("grade", token: token, remembered: true)
        XCTAssertEqual(restored.engine?.record.state.progress["c:1"]?.remembered, 1)
    }
}
#endif
