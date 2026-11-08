#if os(macOS)
import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Synthetic banks and temporary directories only. No device or user archive is read.
final class PublicDualStoreIntegrationTests: XCTestCase {
    private enum InitialState: Equatable { case selected, familiar, result }

    private struct Fixture {
        let root: URL
        let package: URL
        let legacyURL: URL
        let dualRoot: URL
        let hash: String
        let legacy: ExamDiskRecord
        let legacyRemaining: Int
        var currentURL: URL { dualRoot.appendingPathComponent("current.json") }
    }

    private struct DiskProbe: Decodable {
        let rootLegacySHA256: String
        let state: PublicQuestionDualState
        let priorDualRevisionSHA256s: [String]
    }

    private final class WriteGate {
        enum Mode: Equatable { case success, beforeWrite, afterWrite }
        var mode: Mode = .success
        func write(_ data: Data, to url: URL) throws {
            if mode == .beforeWrite { throw NSError(domain: "synthetic-write", code: 1) }
            try DurableFile.write(data, to: url)
            if mode == .afterWrite { throw NSError(domain: "synthetic-write", code: 2) }
        }
    }

    private final class TestClock {
        var now = Date()
    }

    @MainActor private func fixture(_ initial: InitialState = .selected,
                                     yesterday: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-dual-tests-\(UUID().uuidString)", isDirectory: true)
        let qroot = root.appendingPathComponent("QuestionBank", isDirectory: true)
        let banks = qroot.appendingPathComponent("banks", isDirectory: true)
        let sourceHash = String(repeating: "a", count: 64)
        let isMultiple = initial == .selected
        let bank = ExamBank(id: "synthetic-public-bank", title: "虚构测试",
            sourceName: "synthetic.pdf", sourceSHA256: sourceHash, totalPages: 1,
            questions: (1...30).map { number in
                ExamQuestion(id: "fake-\(number)", number: number,
                    type: isMultiple ? .multiple : .single, section: "虚构章节",
                    prompt: "虚构题 \(number)",
                    options: [ExamOption(id: "A", text: "甲"), ExamOption(id: "B", text: "乙"),
                              ExamOption(id: "C", text: "丙")],
                    answer: isMultiple ? ["A", "B"] : ["A"], pageStart: 1, pageEnd: 1)
            })
        let raw = try JSONEncoder().encode(bank), hash = StudySHA256.hex(raw)
        let package = ExamContent(format: ExamContent.formatName, bankBytes: raw, bankSHA256: hash)
        let packageBytes = try JSONEncoder().encode(package)
        let version = qroot.appendingPathComponent("versions", isDirectory: true).appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(at: banks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("volumes", isDirectory: true), withIntermediateDirectories: true)
        let bankFile = banks.appendingPathComponent(hash + ".xklquestions")
        try packageBytes.write(to: bankFile)
        let importFile = root.appendingPathComponent("synthetic-import.xklquestions")
        try packageBytes.write(to: importFile)
        let oldTime = Date().addingTimeInterval(-60)
        let old = try ExamLearningEngine.fresh(bank: bank, hash: hash, now: oldTime)
        let today = UInt32(try ConceptCalendar.studyDay(Date()))
        try old.start(day: yesterday ? today - 1 : today, now: oldTime.addingTimeInterval(1))
        switch initial {
        case .selected:
            try old.toggle("A") // selected but deliberately unsubmitted
        case .familiar:
            try old.familiar(now: oldTime.addingTimeInterval(2))
        case .result:
            try old.selectAndSubmit("A", presentationID: old.record.presentation?.id,
                                    now: oldTime.addingTimeInterval(2))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateURL = version.appendingPathComponent("current-state.json")
        try encoder.encode(old.record).write(to: stateURL)
        let active = try JSONSerialization.data(withJSONObject: ["format": 2, "bankSHA256": hash], options: [.sortedKeys])
        try active.write(to: qroot.appendingPathComponent("active-bank.json"))
        return Fixture(root: root, package: importFile, legacyURL: stateURL,
            dualRoot: version.appendingPathComponent("dual-fsrs", isDirectory: true),
            hash: hash, legacy: old.record, legacyRemaining: Int(try old.info.total_remaining))
    }

    private func disk(_ fixture: Fixture) throws -> DiskProbe {
        try JSONDecoder().decode(DiskProbe.self, from: Data(contentsOf: fixture.currentURL))
    }
    private func anchor(_ fixture: Fixture, hash: String) throws -> ExamDiskRecord {
        let path = fixture.dualRoot.appendingPathComponent("anchors", isDirectory: true).appendingPathComponent(hash + ".json")
        let bytes = try Data(contentsOf: path)
        XCTAssertEqual(StudySHA256.hex(bytes), hash)
        return try JSONDecoder().decode(ExamDiskRecord.self, from: bytes)
    }
    private func remove(_ fixture: Fixture) { try? FileManager.default.removeItem(at: fixture.root) }

    @MainActor func testImmediateMigrationAndSameBankReimportAreIdempotent() async throws {
        let f = try fixture(); defer { remove(f) }
        let oldBytes = try Data(contentsOf: f.legacyURL)
        let oldPresentation = try XCTUnwrap(f.legacy.presentation)
        let store = ExamStore(baseDirectory: f.root)
        XCTAssertFalse(store.storageBlocked); XCTAssertFalse(store.isDualFSRS)
        store.prepareDualFSRSIfNeeded()
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        XCTAssertEqual(store.presentationID, oldPresentation.id)
        XCTAssertEqual(store.selectedOptionIDs, ["A"])
        XCTAssertEqual(store.shuffledOptions.map(\.id), oldPresentation.optionOrder)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), oldBytes)
        let firstBytes = try Data(contentsOf: f.currentURL), first = try disk(f)
        XCTAssertEqual(first.rootLegacySHA256, StudySHA256.hex(oldBytes))
        XCTAssertEqual(first.state.legacyAttempts, f.legacy.attempts)
        XCTAssertTrue(first.state.events.isEmpty)
        XCTAssertEqual(first.state.initialCarry.count, f.legacyRemaining)
        store.prepareDualFSRSIfNeeded()
        store.importContent(from: f.package)
        store.importContent(from: f.package)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), oldBytes)
        let reopened = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(reopened.isDualFSRS, reopened.error ?? "")
        XCTAssertEqual(reopened.presentationID, oldPresentation.id)
        XCTAssertEqual(reopened.selectedOptionIDs, ["A"])
        XCTAssertEqual(reopened.shuffledOptions.map(\.id), oldPresentation.optionOrder)
    }

    @MainActor func testRootStartupAcrossCalendarDayPreservesOldSnapshotAndSelection() async throws {
        for usePolicyFirst in [false, true] {
            let f = try fixture(yesterday: true); defer { remove(f) }
            let original = try Data(contentsOf: f.legacyURL)
            let originalSelection = try XCTUnwrap(f.legacy.presentation)
            let before = try PocketEngine(snapshot: f.legacy.snapshot).info
            let today = UInt32(try ConceptCalendar.studyDay(Date()))
            XCTAssertEqual(before.selection_day, today - 1)
            let store = ExamStore(baseDirectory: f.root)
            if usePolicyFirst { store.setPolicy(conservative: !f.legacy.analysis.conservativeEnabled) }
            else { store.refreshStudyDate() }
            XCTAssertTrue(store.isDualFSRS, store.error ?? "")
            XCTAssertEqual(try Data(contentsOf: f.legacyURL), original)
            XCTAssertEqual(store.presentationID, originalSelection.id)
            XCTAssertEqual(store.selectedOptionIDs, ["A"])
            let first = try Data(contentsOf: f.currentURL)
            store.refreshStudyDate(); store.setExamReduction(enabled: false)
            XCTAssertEqual(try Data(contentsOf: f.legacyURL), original)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), first)
            XCTAssertEqual((try disk(f)).state.initialCarry.count, f.legacyRemaining)
        }
    }

    @MainActor func testMigrationWriteFailureKeepsLegacyAndCanRecover() async throws {
        let f = try fixture(); defer { remove(f) }
        let old = try Data(contentsOf: f.legacyURL), gate = WriteGate(); gate.mode = .beforeWrite
        let failed = ExamStore(baseDirectory: f.root, dualWriter: gate.write)
        failed.prepareDualFSRSIfNeeded()
        XCTAssertTrue(failed.storageBlocked); XCTAssertFalse(failed.isDualFSRS)
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.currentURL.path))
        let recovered = ExamStore(baseDirectory: f.root)
        XCTAssertFalse(recovered.storageBlocked)
        recovered.prepareDualFSRSIfNeeded()
        XCTAssertTrue(recovered.isDualFSRS, recovered.error ?? "")
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        XCTAssertTrue((try disk(f)).state.events.isEmpty)
    }

    @MainActor func testFailureAfterDurableAnswerRecoversResultWithoutDuplicateScore() async throws {
        let f = try fixture(.familiar); defer { remove(f) }
        let old = try Data(contentsOf: f.legacyURL), gate = WriteGate()
        let store = ExamStore(baseDirectory: f.root, dualWriter: gate.write)
        store.prepareDualFSRSIfNeeded()
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        let token = try XCTUnwrap(store.presentationID)
        gate.mode = .afterWrite
        store.selectAndSubmit("A", presentationID: token)
        XCTAssertTrue(store.storageBlocked)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        let recovered = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(recovered.isDualFSRS, recovered.error ?? "")
        XCTAssertTrue(recovered.isShowingResult)
        XCTAssertEqual(recovered.presentationID, token)
        let state = try disk(f).state
        XCTAssertEqual(state.events.filter { $0.kind == "answer" }.count, 1)
        XCTAssertEqual(recovered.latestAttempt?.id, state.events.last?.attempt?.id)
        let again = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(again.isShowingResult)
        XCTAssertEqual(again.latestAttempt?.id, recovered.latestAttempt?.id)
        XCTAssertEqual(try disk(f).state.events.filter { $0.kind == "answer" }.count, 1)
    }

    @MainActor func testLegacyUndoUsesRealEventAndKeepsBothAnchors() async throws {
        let f = try fixture(.familiar); defer { remove(f) }
        let old = try Data(contentsOf: f.legacyURL)
        let oldAttempt = try XCTUnwrap(f.legacy.attempts.last)
        XCTAssertEqual(oldAttempt.mode, "familiar")
        let store = ExamStore(baseDirectory: f.root)
        store.prepareDualFSRSIfNeeded()
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        XCTAssertTrue(store.canUndo)
        let beforeBytes = try Data(contentsOf: f.currentURL)
        let before = try disk(f)
        store.undoFamiliar()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.currentQuestion?.id, oldAttempt.questionID)
        XCTAssertFalse(store.canUndo)
        let after = try disk(f)
        XCTAssertNotEqual(after.state.legacyAnchorSHA256, before.state.legacyAnchorSHA256)
        XCTAssertEqual(after.rootLegacySHA256, before.rootLegacySHA256)
        let revision = StudySHA256.hex(beforeBytes)
        XCTAssertTrue(after.priorDualRevisionSHA256s.contains(revision))
        let revisionURL = f.dualRoot.appendingPathComponent("revisions").appendingPathComponent(revision + ".json")
        XCTAssertEqual(try Data(contentsOf: revisionURL), beforeBytes)
        let undoAnchor = try anchor(f, hash: after.state.legacyAnchorSHA256)
        XCTAssertEqual(undoAnchor.attempts.count, f.legacy.attempts.count + 1)
        XCTAssertEqual(undoAnchor.attempts.last?.mode, "undo")
        XCTAssertEqual(undoAnchor.attempts.last?.undoneAttemptID, oldAttempt.id)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        let reopened = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(reopened.isDualFSRS, reopened.error ?? "")
        XCTAssertEqual(reopened.currentQuestion?.id, oldAttempt.questionID)
    }

    @MainActor func testNewScorePreventsRebasingOldUndoAndStaleWriterCannotOverwrite() async throws {
        let f = try fixture(.familiar); defer { remove(f) }
        let old = try Data(contentsOf: f.legacyURL)
        let store = ExamStore(baseDirectory: f.root); store.prepareDualFSRSIfNeeded()
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        let before = try disk(f), stale = ExamStore(baseDirectory: f.root)
        let token = try XCTUnwrap(store.presentationID)
        store.selectAndSubmit("A", presentationID: token)
        XCTAssertTrue(store.isShowingResult, store.error ?? "")
        let scoredBytes = try Data(contentsOf: f.currentURL)
        stale.selectAndSubmit("B", presentationID: token)
        XCTAssertNotNil(stale.error)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), scoredBytes)
        store.nextQuestion(presentationID: token)
        XCTAssertTrue(store.canUndo)
        store.undoFamiliar() // This undoes the new dual answer, not the old anchor.
        XCTAssertNil(store.error)
        var after = try disk(f)
        XCTAssertEqual(after.state.legacyAnchorSHA256, before.state.legacyAnchorSHA256)
        XCTAssertTrue(after.priorDualRevisionSHA256s.isEmpty)
        XCTAssertEqual(after.state.events.filter { $0.kind == "answer" }.count, 1)
        XCTAssertEqual(after.state.events.filter { $0.kind == "undo" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        let afterUndo = try Data(contentsOf: f.currentURL)
        store.undoFamiliar() // Repeated undo must never fall back to the old anchor.
        XCTAssertEqual(try Data(contentsOf: f.currentURL), afterUndo)
        after = try disk(f)
        XCTAssertEqual(after.state.legacyAnchorSHA256, before.state.legacyAnchorSHA256)
        XCTAssertTrue(after.priorDualRevisionSHA256s.isEmpty)
    }

    @MainActor func testOldResultPageSurvivesMigrationAndRestartWithoutRegrading() async throws {
        let f = try fixture(.result); defer { remove(f) }
        let old = try Data(contentsOf: f.legacyURL)
        let oldReview = try XCTUnwrap(f.legacy.answerReview)
        let nextPresentation = try XCTUnwrap(f.legacy.presentation)
        let store = ExamStore(baseDirectory: f.root); store.prepareDualFSRSIfNeeded()
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        XCTAssertTrue(store.isShowingResult)
        XCTAssertEqual(store.presentationID, oldReview.presentation.id)
        XCTAssertEqual(store.latestAttempt?.id, oldReview.attempt.id)
        let restarted = ExamStore(baseDirectory: f.root)
        XCTAssertTrue(restarted.isShowingResult)
        XCTAssertEqual(restarted.presentationID, oldReview.presentation.id)
        XCTAssertEqual(restarted.latestAttempt?.id, oldReview.attempt.id)
        XCTAssertTrue((try disk(f)).state.events.isEmpty)
        restarted.nextQuestion(presentationID: oldReview.presentation.id)
        XCTAssertFalse(restarted.isShowingResult)
        XCTAssertEqual(restarted.presentationID, nextPresentation.id)
        let final = try disk(f)
        XCTAssertTrue(final.state.events.isEmpty)
        XCTAssertEqual(final.state.legacyAttempts, f.legacy.attempts)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        let reopened = ExamStore(baseDirectory: f.root)
        XCTAssertEqual(reopened.presentationID, nextPresentation.id)
        XCTAssertFalse(reopened.isShowingResult)
    }

    @MainActor func testDelayedRetryKeepsCurrentAnswerAndDoesNotChangeDailyTrack() async throws {
        let f = try fixture(.familiar); defer { remove(f) }
        let old = try Data(contentsOf: f.legacyURL), clock = TestClock()
        let store = ExamStore(baseDirectory: f.root, clock: { clock.now })
        store.prepareDualFSRSIfNeeded()
        XCTAssertTrue(store.isDualFSRS, store.error ?? "")
        let wrongID = try XCTUnwrap(store.currentQuestion?.id)
        let shown = try XCTUnwrap(store.presentationID)
        store.selectAndSubmit("B", presentationID: shown)
        XCTAssertTrue(store.isShowingResult, store.error ?? "")
        XCTAssertEqual(store.retryAvailable, 0)
        XCTAssertEqual(store.retryNextAvailableAt, clock.now.addingTimeInterval(600))
        clock.now = clock.now.addingTimeInterval(599)
        store.refreshStudyDate()
        XCTAssertEqual(store.retryAvailable, 0)
        XCTAssertFalse(store.canStartRetry)
        clock.now = clock.now.addingTimeInterval(1)
        store.refreshStudyDate()
        XCTAssertEqual(store.retryAvailable, 1)
        XCTAssertFalse(store.canStartRetry)
        let beforeResultAttempt = try Data(contentsOf: f.currentURL)
        store.startRetry()
        XCTAssertEqual(try Data(contentsOf: f.currentURL), beforeResultAttempt)
        XCTAssertEqual(store.presentationID, shown)
        XCTAssertTrue(store.isShowingResult)

        store.nextQuestion(presentationID: shown)
        let next = try XCTUnwrap(store.presentationID)
        store.toggleOption("B", presentationID: next)
        XCTAssertEqual(store.selectedOptionIDs, ["B"])
        let beforeSelectedAttempt = try Data(contentsOf: f.currentURL)
        store.startRetry()
        XCTAssertEqual(try Data(contentsOf: f.currentURL), beforeSelectedAttempt)
        XCTAssertEqual(store.presentationID, next)
        XCTAssertEqual(store.selectedOptionIDs, ["B"])
        XCTAssertFalse(store.canStartRetry)

        // Finish only the already-open synthetic page; this does not discard
        // the rest of the carried task or force it to be completed first.
        var completed = 0
        while store.presentationID != nil && !store.isShowingResult {
            XCTAssertLessThan(completed, 20)
            if completed >= 20 { break }
            store.markFamiliar(); completed += 1
        }
        XCTAssertNil(store.error)
        XCTAssertTrue(store.canStartRetry)
        let before = try disk(f).state
        let daily = try XCTUnwrap(before.daily[wrongID])
        let shadow = try XCTUnwrap(before.all[wrongID])
        let carried = before.carry
        store.startRetry()
        XCTAssertEqual(store.currentQuestion?.id, wrongID)
        XCTAssertEqual(try disk(f).state.carry, carried)
        let retryToken = try XCTUnwrap(store.presentationID)
        store.selectAndSubmit("A", presentationID: retryToken)
        XCTAssertTrue(store.isShowingResult, store.error ?? "")
        let after = try disk(f).state
        XCTAssertEqual(after.daily[wrongID], daily)
        XCTAssertNotEqual(after.all[wrongID], shadow)
        XCTAssertEqual(after.carry, carried)
        XCTAssertEqual(try Data(contentsOf: f.legacyURL), old)
        let reopened = ExamStore(baseDirectory: f.root, clock: { clock.now })
        XCTAssertTrue(reopened.isShowingResult, reopened.error ?? "")
        XCTAssertEqual(reopened.latestAttempt?.id, store.latestAttempt?.id)
        XCTAssertEqual(try disk(f).state.events.filter { $0.kind == "startRetry" }.count, 1)
    }
}
#endif
