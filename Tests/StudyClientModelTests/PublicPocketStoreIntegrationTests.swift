#if os(macOS)
import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Synthetic-only migration and durable-storage tests; no phone files.
final class PublicPocketStoreIntegrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let bankFile: URL
        let legacy: URL
        let dual: URL
        let pocket: URL
        let marker: URL
        let hash: String
    }
    private struct PocketDisk: Decodable { let plan: PublicPocketMigrationPlan }
    private struct Export: Decodable {
        let format: String
        let pocketVersions: [PocketExport]
        let dualVersions: [DualExport]
    }
    private struct PocketExport: Decodable {
        let currentBytes: Data
        let sourceDualBytes: Data
    }
    private struct DualExport: Decodable { let dualCurrentBytes: Data; let legacyCurrentBytes: Data }

    private final class Gate {
        enum Mode { case before, after }
        let mode: Mode
        init(_ mode: Mode) { self.mode = mode }
        func write(_ data: Data, to url: URL) throws {
            if mode == .before { throw NSError(domain: "synthetic-write", code: 1) }
            try DurableFile.write(data, to: url)
            throw NSError(domain: "synthetic-write", code: 2)
        }
    }

    @MainActor private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-pocket-\(UUID().uuidString)")
        let qroot = root.appendingPathComponent("QuestionBank")
        let banks = qroot.appendingPathComponent("banks")
        let bank = PublicQuestionDualFixtures.bank(35)
        let bankBytes = try JSONEncoder().encode(bank), hash = StudySHA256.hex(bankBytes)
        let package = try JSONEncoder().encode(ExamContent(format: ExamContent.formatName,
                                                             bankBytes: bankBytes, bankSHA256: hash))
        let version = qroot.appendingPathComponent("versions").appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: banks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("volumes"), withIntermediateDirectories: true)
        let file = banks.appendingPathComponent(hash + ".xklquestions")
        try package.write(to: file)
        let copy = root.appendingPathComponent("synthetic.xklquestions")
        try package.write(to: copy)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: hash, now: Date().addingTimeInterval(-60))
        try old.start(day: ExamStore.studyDay(Date()), now: Date().addingTimeInterval(-50))
        let first = try XCTUnwrap(old.record.presentation)
        try old.selectAndSubmit("B", presentationID: first.id, now: Date().addingTimeInterval(-40))
        try old.nextQuestion(presentationID: first.id, now: Date().addingTimeInterval(-30))
        let legacy = version.appendingPathComponent("current-state.json")
        try JSONEncoder().encode(old.record).write(to: legacy)
        try JSONSerialization.data(withJSONObject: ["format": 2, "bankSHA256": hash])
            .write(to: qroot.appendingPathComponent("active-bank.json"))
        let dual = version.appendingPathComponent("dual-fsrs/current.json")
        let pocket = version.appendingPathComponent("pocket-relearn/current.json")
        return Fixture(root: root, bankFile: copy, legacy: legacy, dual: dual, pocket: pocket,
                       marker: version.appendingPathComponent("pocket-relearn-enabled.json"), hash: hash)
    }

    @MainActor private func createDual(_ f: Fixture, leaveResult: Bool) throws -> (Data, Data, UUID) {
        let old = try Data(contentsOf: f.legacy)
        let source = ExamStore(baseDirectory: f.root, legacyDualForTesting: true)
        source.prepareDualFSRSIfNeeded()
        XCTAssertTrue(source.isDualFSRS, source.error ?? "")
        let token = try XCTUnwrap(source.presentationID)
        source.selectAndSubmit("A", presentationID: token)
        XCTAssertTrue(source.isShowingResult, source.error ?? "")
        if !leaveResult {
            source.nextQuestion(presentationID: token)
            let next = try XCTUnwrap(source.presentationID)
            source.toggleOption("B", presentationID: next)
            XCTAssertEqual(source.selectedOptionIDs, ["B"])
        }
        return (old, try Data(contentsOf: f.dual), try XCTUnwrap(source.presentationID))
    }

    @MainActor func testMigrationKeepsDualAnswersSelectionAndReimport() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (old, dual, selected) = try createDual(f, leaveResult: false)
        let store = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        store.preparePocketRelearningIfNeeded()
        XCTAssertTrue(store.isPocketRelearning, store.error ?? "")
        XCTAssertEqual(store.presentationID, selected)
        XCTAssertEqual(store.selectedOptionIDs, ["B"])
        XCTAssertEqual(try Data(contentsOf: f.legacy), old)
        XCTAssertEqual(try Data(contentsOf: f.dual), dual)
        let before = try Data(contentsOf: f.pocket)
        let plan = try JSONDecoder().decode(PocketDisk.self, from: before).plan
        XCTAssertTrue(plan.record.attempts.isEmpty)
        store.importContent(from: f.bankFile); store.importContent(from: f.bankFile)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: f.pocket), before)
        let reopened = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(reopened.isPocketRelearning, reopened.error ?? "")
        XCTAssertEqual(reopened.presentationID, selected)
        XCTAssertEqual(reopened.selectedOptionIDs, ["B"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let export = try decoder.decode(Export.self, from: reopened.exportRecords())
        XCTAssertEqual(export.format, "xkl-ios-question-records-v4")
        XCTAssertEqual(export.pocketVersions.first?.currentBytes, before)
        XCTAssertEqual(export.pocketVersions.first?.sourceDualBytes, dual)
        XCTAssertEqual(export.dualVersions.first?.dualCurrentBytes, dual)
        XCTAssertEqual(export.dualVersions.first?.legacyCurrentBytes, old)
    }

    @MainActor func testOldResultDismissesOnceAndNewAnswerSurvivesRestart() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (old, dual, token) = try createDual(f, leaveResult: true)
        let store = ExamStore(baseDirectory: f.root); store.preparePocketRelearningIfNeeded()
        XCTAssertTrue(store.isPocketRelearning, store.error ?? "")
        XCTAssertTrue(store.isShowingResult)
        XCTAssertEqual(store.presentationID, token)
        let before = try Data(contentsOf: f.pocket)
        store.nextQuestion(presentationID: token)
        XCTAssertFalse(store.isShowingResult, store.error ?? "")
        let afterDismiss = try JSONDecoder().decode(PocketDisk.self, from: Data(contentsOf: f.pocket)).plan
        XCTAssertTrue(afterDismiss.record.attempts.isEmpty)
        XCTAssertNil(afterDismiss.bridgeReview)
        XCTAssertNotEqual(try Data(contentsOf: f.pocket), before)
        let next = try XCTUnwrap(store.presentationID)
        store.selectAndSubmit("A", presentationID: next)
        XCTAssertTrue(store.isShowingResult, store.error ?? "")
        let saved = try JSONDecoder().decode(PocketDisk.self, from: Data(contentsOf: f.pocket)).plan
        XCTAssertEqual(saved.record.attempts.count, 1)
        let reopened = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(reopened.isPocketRelearning, reopened.error ?? "")
        XCTAssertTrue(reopened.isShowingResult)
        XCTAssertEqual(reopened.latestAttempt?.id, saved.record.attempts[0].id)
        XCTAssertEqual(try Data(contentsOf: f.legacy), old)
        XCTAssertEqual(try Data(contentsOf: f.dual), dual)
    }

    @MainActor func testInterruptedMigrationIsRecoverableWithoutReplacingSources() async throws {
        for mode in [Gate.Mode.before, .after] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let (old, dual, token) = try createDual(f, leaveResult: false)
            let failed = ExamStore(baseDirectory: f.root, dualWriter: Gate(mode).write)
            failed.preparePocketRelearningIfNeeded()
            XCTAssertTrue(failed.storageBlocked)
            XCTAssertEqual(try Data(contentsOf: f.legacy), old)
            XCTAssertEqual(try Data(contentsOf: f.dual), dual)
            let recovered = ExamStore(baseDirectory: f.root)
            recovered.preparePocketRelearningIfNeeded()
            XCTAssertTrue(recovered.isPocketRelearning, recovered.error ?? "")
            XCTAssertEqual(recovered.presentationID, token)
            XCTAssertEqual(recovered.selectedOptionIDs, ["B"])
            XCTAssertEqual(try Data(contentsOf: f.legacy), old)
            XCTAssertEqual(try Data(contentsOf: f.dual), dual)
        }
    }

    @MainActor func testMissingPocketStateDoesNotFallBackToOlderHistory() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (old, dual, _) = try createDual(f, leaveResult: false)
        let store = ExamStore(baseDirectory: f.root); store.preparePocketRelearningIfNeeded()
        XCTAssertTrue(store.isPocketRelearning, store.error ?? "")
        let marker = try Data(contentsOf: f.marker)
        try FileManager.default.removeItem(at: f.pocket)
        let reopened = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(reopened.storageBlocked)
        XCTAssertThrowsError(try reopened.exportRecords())
        reopened.start()
        XCTAssertEqual(try Data(contentsOf: f.marker), marker)
        XCTAssertEqual(try Data(contentsOf: f.legacy), old)
        XCTAssertEqual(try Data(contentsOf: f.dual), dual)
    }

    @MainActor func testStaleWriterCannotOverwriteNewAnswer() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try createDual(f, leaveResult: false)
        let first = ExamStore(baseDirectory: f.root); first.preparePocketRelearningIfNeeded()
        XCTAssertTrue(first.isPocketRelearning, first.error ?? "")
        let stale = ExamStore(baseDirectory: f.root)
        let token = try XCTUnwrap(first.presentationID)
        first.selectAndSubmit("A", presentationID: token)
        XCTAssertTrue(first.isShowingResult, first.error ?? "")
        let newer = try Data(contentsOf: f.pocket)
        stale.selectAndSubmit("B", presentationID: token)
        XCTAssertNotNil(stale.error)
        XCTAssertEqual(try Data(contentsOf: f.pocket), newer)
        let current = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(current.isShowingResult, current.error ?? "")
        XCTAssertEqual(current.latestAttempt?.id, first.latestAttempt?.id)
    }
}
#endif
