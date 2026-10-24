#if os(macOS)
import Foundation
import XCTest
@testable import StudyClientModel

final class StudyFlowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Writer {
        enum Failure: Error { case disk }
        var shouldFail = false
        var count = 0
        func write(_ data: Data, _ url: URL) throws {
            if shouldFail { throw Failure.disk }
            count += 1
            try data.write(to: url, options: .atomic)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XKL-StudyFlowTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func current(_ root: URL) -> URL {
        root.appendingPathComponent("StudyFlow/current.json")
    }

    private func read(_ root: URL) throws -> StudyFlowState {
        try JSONDecoder().decode(StudyFlowState.self, from: Data(contentsOf: current(root)))
    }

    @MainActor
    func testFiveMinutesStopsAtBudgetAndNeverGradesOrKeepsCounting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 100)
        store.begin(area: .vocabulary, mode: .fiveMinutes, now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(299), uptime: 399)
        XCTAssertEqual(store.state.elapsedSeconds, 299)
        XCTAssertEqual(store.state.remainingSeconds, 1)
        XCTAssertFalse(store.state.needsBreak)
        store.tick(now: start.addingTimeInterval(400), uptime: 500)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertTrue(store.state.needsBreak)
        XCTAssertEqual(try read(root), store.state)
        store.tick(now: start.addingTimeInterval(10_000), uptime: 10_100)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files, ["StudyFlow"], "Flow metadata must not create learning-engine files.")
    }

    @MainActor
    func testVisibilityExcludesBackgroundAndNavigationTime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.begin(area: .computer, mode: .fiveMinutes, now: start, uptime: 10)
        store.tick(now: start.addingTimeInterval(30), uptime: 40)
        XCTAssertEqual(store.state.elapsedSeconds, 0)
        store.setVisible(true, now: start.addingTimeInterval(30), uptime: 40)
        store.tick(now: start.addingTimeInterval(40), uptime: 50)
        XCTAssertEqual(store.state.elapsedSeconds, 10)
        store.setVisible(false, now: start.addingTimeInterval(42), uptime: 52)
        XCTAssertEqual(store.state.elapsedSeconds, 12)
        XCTAssertEqual(try read(root).elapsedSeconds, 12)
        store.tick(now: start.addingTimeInterval(6042), uptime: 6052)
        XCTAssertEqual(store.state.elapsedSeconds, 12)
        store.setVisible(true, now: start.addingTimeInterval(6042), uptime: 6052)
        store.tick(now: start.addingTimeInterval(6047), uptime: 6057)
        XCTAssertEqual(store.state.elapsedSeconds, 17)
    }

    @MainActor
    func testWallClockJumpsAndDayChangesDoNotAffectElapsedDuration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 100)
        store.begin(area: .power, now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(86_400), uptime: 120)
        XCTAssertEqual(store.state.elapsedSeconds, 20)
        store.tick(now: start.addingTimeInterval(-86_400), uptime: 130)
        XCTAssertEqual(store.state.elapsedSeconds, 30)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.state.needsBreak)
    }

    @MainActor
    func testExplicitPauseSurvivesVisibilityChangesUntilResume() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .publicQuestions, mode: .fiveMinutes, now: start, uptime: 0)
        let id = store.state.segmentID
        store.pause(now: start.addingTimeInterval(27), uptime: 27)
        XCTAssertEqual(store.state.elapsedSeconds, 27)
        store.setVisible(false, now: start.addingTimeInterval(28), uptime: 28)
        store.setVisible(true, now: start.addingTimeInterval(100), uptime: 100)
        store.tick(now: start.addingTimeInterval(200), uptime: 200)
        XCTAssertEqual(store.state.elapsedSeconds, 27)
        store.resume(now: start.addingTimeInterval(200), uptime: 200)
        store.tick(now: start.addingTimeInterval(210), uptime: 210)
        XCTAssertEqual(store.state.elapsedSeconds, 37)
        XCTAssertEqual(store.state.segmentID, id)
    }

    @MainActor
    func testRestartPausesAtLastCheckpointAndDoesNotInventOfflineTime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer()
        let store = StudyFlowStore(baseDirectory: root, writer: writer.write)
        store.setVisible(true, now: start, uptime: 100)
        store.begin(area: .computer, mode: .fiveMinutes, now: start, uptime: 100)
        let segment = store.state.segmentID
        for n in 1...22 { store.tick(now: start.addingTimeInterval(Double(n)), uptime: 100 + Double(n)) }
        XCTAssertEqual(store.state.elapsedSeconds, 22)
        XCTAssertEqual(try read(root).elapsedSeconds, 15)
        XCTAssertEqual(writer.count, 2, "Begin plus the 15-second checkpoint only.")
        let bytes = try Data(contentsOf: current(root))
        let restarted = StudyFlowStore(baseDirectory: root)
        XCTAssertEqual(try Data(contentsOf: current(root)), bytes, "Read/restore does not overwrite the original file.")
        XCTAssertEqual(restarted.state.elapsedSeconds, 15)
        XCTAssertEqual(restarted.state.remainingSeconds, 285)
        XCTAssertEqual(restarted.state.segmentID, segment)
        XCTAssertEqual(restarted.state.activeArea, .computer)
        XCTAssertTrue(restarted.state.isPaused)
        restarted.setVisible(true, now: start.addingTimeInterval(100_000), uptime: 9000)
        restarted.tick(now: start.addingTimeInterval(200_000), uptime: 10000)
        XCTAssertEqual(restarted.state.elapsedSeconds, 15)
        restarted.resume(now: start.addingTimeInterval(200_000), uptime: 10000)
        restarted.tick(now: start.addingTimeInterval(200_010), uptime: 10010)
        XCTAssertEqual(restarted.state.elapsedSeconds, 25)
    }

    @MainActor
    func testNeedsBreakSurvivesRestartAndCannotBeBypassedByResumeOrBegin() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .power, mode: .fiveMinutes, now: start, uptime: 0)
        store.tick(now: start.addingTimeInterval(300), uptime: 300)
        let prior = store.state
        let restarted = StudyFlowStore(baseDirectory: root)
        restarted.setVisible(true, now: start.addingTimeInterval(500), uptime: 500)
        restarted.resume(now: start.addingTimeInterval(500), uptime: 500)
        restarted.begin(area: .power, mode: .fiveMinutes, now: start.addingTimeInterval(500), uptime: 500)
        restarted.begin(area: .computer, mode: .standard, now: start.addingTimeInterval(500), uptime: 500)
        restarted.tick(now: start.addingTimeInterval(900), uptime: 900)
        XCTAssertEqual(restarted.state, prior)
    }

    @MainActor
    func testExplicitExtensionAddsFiveMinutesWithoutResettingElapsedOrSegment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .power, mode: .fiveMinutes, now: start, uptime: 0)
        store.tick(now: start.addingTimeInterval(300), uptime: 300)
        let id = store.state.segmentID
        store.extendFiveMinutes(now: start.addingTimeInterval(600), uptime: 600)
        XCTAssertEqual(store.state.budgetSeconds, 600)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        XCTAssertEqual(store.state.remainingSeconds, 300)
        XCTAssertFalse(store.state.needsBreak)
        XCTAssertEqual(store.state.segmentID, id)
        store.tick(now: start.addingTimeInterval(900), uptime: 900)
        XCTAssertTrue(store.state.needsBreak)
        XCTAssertEqual(store.state.elapsedSeconds, 600)
    }

    @MainActor
    func testSameAreaContinuePreservesBudgetButExplicitModeChangeStartsFiveMinutes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .vocabulary, now: start, uptime: 0)
        store.tick(now: start.addingTimeInterval(50), uptime: 50)
        let standardID = store.state.segmentID
        store.startNewSegment(area: .vocabulary, mode: .fiveMinutes, now: start.addingTimeInterval(50), uptime: 50)
        XCTAssertNotEqual(store.state.segmentID, standardID)
        XCTAssertEqual(store.state.elapsedSeconds, 0)
        XCTAssertEqual(store.state.budgetSeconds, 300)
        store.pause(now: start.addingTimeInterval(80), uptime: 80)
        let shortID = store.state.segmentID
        store.startNewSegment(area: .vocabulary, mode: .fiveMinutes, now: start.addingTimeInterval(180), uptime: 180)
        XCTAssertEqual(store.state.segmentID, shortID)
        XCTAssertEqual(store.state.elapsedSeconds, 30)
        XCTAssertEqual(store.state.remainingSeconds, 270)
    }

    @MainActor
    func testDifferentAreaStartsNewSegmentAndFinishKeepsLastArea() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .publicQuestions, now: start, uptime: 0)
        let first = store.state.segmentID
        store.tick(now: start.addingTimeInterval(20), uptime: 20)
        store.begin(area: .computer, mode: .fiveMinutes, now: start.addingTimeInterval(20), uptime: 20)
        XCTAssertEqual(store.state.lastArea, .computer)
        XCTAssertEqual(store.state.activeArea, .computer)
        XCTAssertNotEqual(store.state.segmentID, first)
        XCTAssertEqual(store.state.elapsedSeconds, 0)
        store.finish(now: start.addingTimeInterval(40), uptime: 40)
        XCTAssertEqual(store.state.lastArea, .computer)
        XCTAssertNil(store.state.activeArea)
        XCTAssertNil(store.state.segmentID)
        XCTAssertNil(store.state.budgetSeconds)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertFalse(store.state.needsBreak)
        let restarted = StudyFlowStore(baseDirectory: root)
        XCTAssertEqual(restarted.state, store.state)
    }

    @MainActor
    func testFollowingPracticeNavigationRetainsBudgetSegmentAndElapsedTime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .vocabulary, mode: .fiveMinutes, now: start, uptime: 0)
        let id = store.state.segmentID
        store.tick(now: start.addingTimeInterval(40), uptime: 40)
        store.followNavigation(to: .publicQuestions, now: start.addingTimeInterval(50), uptime: 50)
        XCTAssertEqual(store.state.elapsedSeconds, 50, "Settle the previous foreground tail.")
        XCTAssertEqual(store.state.activeArea, .publicQuestions)
        XCTAssertEqual(store.state.lastArea, .publicQuestions)
        XCTAssertEqual(store.state.mode, .fiveMinutes)
        XCTAssertEqual(store.state.segmentID, id)
        XCTAssertEqual(store.state.budgetSeconds, 300)
        XCTAssertFalse(store.state.isPaused)
        store.tick(now: start.addingTimeInterval(70), uptime: 70)
        store.followNavigation(to: .power, now: start.addingTimeInterval(80), uptime: 80)
        XCTAssertEqual(store.state.elapsedSeconds, 80)
        XCTAssertEqual(store.state.remainingSeconds, 220)
        XCTAssertEqual(store.state.segmentID, id)
        let restored = StudyFlowStore(baseDirectory: root)
        XCTAssertEqual(restored.state.activeArea, .power)
        XCTAssertEqual(restored.state.lastArea, .power)
        XCTAssertEqual(restored.state.elapsedSeconds, 80)
        XCTAssertEqual(restored.state.budgetSeconds, 300)
        XCTAssertEqual(restored.state.segmentID, id)
        XCTAssertTrue(restored.state.isPaused)
    }

    @MainActor
    func testFollowingNavigationCannotBypassDeadlineReachedDuringTheSwitch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .vocabulary, mode: .fiveMinutes, now: start, uptime: 0)
        let id = store.state.segmentID
        store.tick(now: start.addingTimeInterval(295), uptime: 295)
        store.followNavigation(to: .computer, now: start.addingTimeInterval(305), uptime: 305)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        XCTAssertEqual(store.state.activeArea, .computer)
        XCTAssertEqual(store.state.segmentID, id)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertTrue(store.state.needsBreak)
        store.followNavigation(to: .power, now: start.addingTimeInterval(500), uptime: 500)
        store.resume(now: start.addingTimeInterval(500), uptime: 500)
        store.tick(now: start.addingTimeInterval(700), uptime: 700)
        XCTAssertEqual(store.state.activeArea, .power)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        XCTAssertEqual(store.state.budgetSeconds, 300)
        XCTAssertTrue(store.state.needsBreak)
        XCTAssertEqual(try read(root), store.state)
    }

    @MainActor
    func testFollowingNavigationPreservesExplicitPauseAndStartsStandardOnlyWhenEmpty() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 0)
        store.followNavigation(to: .computer, now: start, uptime: 0)
        XCTAssertEqual(store.state.mode, .standard)
        XCTAssertEqual(store.state.activeArea, .computer)
        let id = store.state.segmentID
        XCTAssertNotNil(id)
        store.pause(now: start.addingTimeInterval(10), uptime: 10)
        store.followNavigation(to: .publicQuestions, now: start.addingTimeInterval(100), uptime: 100)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertFalse(store.state.needsBreak)
        XCTAssertEqual(store.state.elapsedSeconds, 10)
        XCTAssertEqual(store.state.segmentID, id)
        XCTAssertNil(store.state.budgetSeconds)
        store.tick(now: start.addingTimeInterval(200), uptime: 200)
        XCTAssertEqual(store.state.elapsedSeconds, 10)
        store.resume(now: start.addingTimeInterval(200), uptime: 200)
        store.tick(now: start.addingTimeInterval(205), uptime: 205)
        XCTAssertEqual(store.state.elapsedSeconds, 15)
    }

    @MainActor
    func testNavigationWriteFailureKeepsPreviousAreaAndDurableMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer()
        let store = StudyFlowStore(baseDirectory: root, writer: writer.write)
        store.begin(area: .vocabulary, mode: .fiveMinutes, now: start, uptime: 0)
        let before = store.state
        let bytes = try Data(contentsOf: current(root))
        writer.shouldFail = true
        store.followNavigation(to: .power, now: start.addingTimeInterval(5), uptime: 5)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.state.activeArea, before.activeArea)
        XCTAssertEqual(store.state.lastArea, before.lastArea)
        XCTAssertEqual(store.state.segmentID, before.segmentID)
        XCTAssertEqual(store.state.budgetSeconds, before.budgetSeconds)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertEqual(try Data(contentsOf: current(root)), bytes)
    }

    @MainActor
    func testWriteFailurePreservesOriginalFileAndDoesNotSwitchArea() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer()
        let store = StudyFlowStore(baseDirectory: root, writer: writer.write)
        store.begin(area: .vocabulary, now: start, uptime: 0)
        let bytes = try Data(contentsOf: current(root)), segment = store.state.segmentID
        writer.shouldFail = true
        store.begin(area: .power, mode: .fiveMinutes, now: start.addingTimeInterval(10), uptime: 10)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertEqual(store.state.activeArea, .vocabulary)
        XCTAssertEqual(store.state.segmentID, segment)
        XCTAssertEqual(try Data(contentsOf: current(root)), bytes)
        let restarted = StudyFlowStore(baseDirectory: root)
        XCTAssertEqual(restarted.state.activeArea, .vocabulary)
        XCTAssertTrue(restarted.state.isPaused)
        writer.shouldFail = false
        store.resume(now: start.addingTimeInterval(20), uptime: 20)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.state.isPaused)
    }

    @MainActor
    func testCheckpointFailurePausesWithoutOverwritingLastDurableCheckpoint() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer()
        let store = StudyFlowStore(baseDirectory: root, writer: writer.write)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .computer, mode: .fiveMinutes, now: start, uptime: 0)
        store.tick(now: start.addingTimeInterval(15), uptime: 15)
        let bytes = try Data(contentsOf: current(root))
        writer.shouldFail = true
        store.tick(now: start.addingTimeInterval(30), uptime: 30)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertEqual(store.state.elapsedSeconds, 30)
        XCTAssertEqual(try Data(contentsOf: current(root)), bytes)
        store.tick(now: start.addingTimeInterval(200), uptime: 200)
        XCTAssertEqual(store.state.elapsedSeconds, 30)
        XCTAssertEqual(StudyFlowStore(baseDirectory: root).state.elapsedSeconds, 15)
    }

    @MainActor
    func testDeadlineRemainsLatchedWhenSavingTheBreakFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer()
        let store = StudyFlowStore(baseDirectory: root, writer: writer.write)
        store.setVisible(true, now: start, uptime: 0)
        store.begin(area: .power, mode: .fiveMinutes, now: start, uptime: 0)
        store.tick(now: start.addingTimeInterval(285), uptime: 285)
        let oldBytes = try Data(contentsOf: current(root))
        writer.shouldFail = true
        store.tick(now: start.addingTimeInterval(300), uptime: 300)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.state.needsBreak)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        store.resume(now: start.addingTimeInterval(400), uptime: 400)
        store.tick(now: start.addingTimeInterval(500), uptime: 500)
        XCTAssertTrue(store.state.needsBreak)
        XCTAssertEqual(store.state.elapsedSeconds, 300)
        XCTAssertEqual(try Data(contentsOf: current(root)), oldBytes)
        writer.shouldFail = false
        store.pause(now: start.addingTimeInterval(500), uptime: 500)
        XCTAssertNil(store.error)
        XCTAssertTrue(StudyFlowStore(baseDirectory: root).state.needsBreak)
    }

    @MainActor
    func testCorruptMetadataFailsClosedWithoutAffectingOtherFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = current(root).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bad = Data("{not valid json".utf8)
        try bad.write(to: current(root))
        let other = root.appendingPathComponent("original-learning-record.bin")
        let learning = Data([1, 2, 3, 4])
        try learning.write(to: other)
        let store = StudyFlowStore(baseDirectory: root)
        XCTAssertNotNil(store.error)
        store.begin(area: .power, mode: .fiveMinutes, now: start, uptime: 0)
        store.finish(now: start, uptime: 0)
        store.clearError()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: current(root)), bad)
        XCTAssertEqual(try Data(contentsOf: other), learning)
    }

    @MainActor
    func testMonotonicRollbackPausesInsteadOfSubstitutingWallTime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyFlowStore(baseDirectory: root)
        store.setVisible(true, now: start, uptime: 100)
        store.begin(area: .power, now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(10), uptime: 110)
        store.tick(now: start.addingTimeInterval(10_000), uptime: 90)
        XCTAssertEqual(store.state.elapsedSeconds, 10)
        XCTAssertTrue(store.state.isPaused)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try read(root).elapsedSeconds, 10)
        store.resume(now: start.addingTimeInterval(10_000), uptime: 90)
        store.tick(now: start.addingTimeInterval(10_005), uptime: 95)
        XCTAssertEqual(store.state.elapsedSeconds, 15)
        XCTAssertNil(store.error)
    }

    func testAreaRoutingIsStableAndMetadataCodable() throws {
        XCTAssertEqual(StudyArea.vocabulary.tab, 0)
        XCTAssertEqual(StudyArea.publicQuestions.tab, 3)
        XCTAssertEqual(StudyArea.computer.tab, 4)
        XCTAssertEqual(StudyArea.power.tab, 4)
        XCTAssertEqual(Set(StudyArea.allCases.map(\.title)).count, 4)
        let value = StudyFlowState()
        XCTAssertEqual(try JSONDecoder().decode(StudyFlowState.self,
            from: JSONEncoder().encode(value)), value)
    }
}
#endif
