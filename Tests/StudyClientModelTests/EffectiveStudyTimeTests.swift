#if canImport(Combine)
import Combine
import Foundation
import XCTest
@testable import StudyClientModel

final class EffectiveStudyTimeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_799_000_000)

    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("effective-time-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }
    private func current(_ root: URL) -> URL { root.appendingPathComponent("EffectiveStudyTime/current.json") }

    @MainActor func testTouchesOutsideLearningDoNotRepublishAnUnchangedPausedTimer() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        var changes = 0
        let observer = store.objectWillChange.sink { changes += 1 }
        store.noteActivity(now: start, uptime: 100)
        store.noteActivity(now: start.addingTimeInterval(0.1), uptime: 100.1)
        store.tick(now: start.addingTimeInterval(1), uptime: 101)
        XCTAssertEqual(changes, 0, "Navigation touches must not republish an unchanged inactive timer")
        XCTAssertFalse(store.isCounting)
        store.setVisibleArea(.computer, now: start.addingTimeInterval(2), uptime: 102)
        store.noteActivity(now: start.addingTimeInterval(2), uptime: 102)
        store.tick(now: start.addingTimeInterval(12), uptime: 112)
        XCTAssertTrue(store.isCounting)
        XCTAssertEqual(store.seconds(for: .computer, on: start), 10, accuracy: 0.0001)
        withExtendedLifetime(observer) {}
    }

    @MainActor func testIdleIsCappedAtSixtySecondsAndInteractionResumes() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        store.setVisibleArea(.computer, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(30), uptime: 130)
        XCTAssertEqual(store.seconds(for: .computer, on: start), 30, accuracy: 0.0001)
        store.tick(now: start.addingTimeInterval(120), uptime: 220)
        XCTAssertEqual(store.seconds(for: .computer, on: start), 60, accuracy: 0.0001)
        XCTAssertFalse(store.isCounting)
        store.tick(now: start.addingTimeInterval(130), uptime: 230)
        XCTAssertEqual(store.seconds(for: .computer, on: start), 60, accuracy: 0.0001)
        store.noteActivity(now: start.addingTimeInterval(150), uptime: 250)
        store.tick(now: start.addingTimeInterval(160), uptime: 260)
        XCTAssertEqual(store.seconds(for: .computer, on: start), 70, accuracy: 0.0001)
        XCTAssertTrue(store.isCounting)
    }

    @MainActor func testHighFrequencyScrollExtendsDeadlineWithoutPerTouchDiskWrites() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        var writes = 0
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar(), writer: { data, url in
            writes += 1; try data.write(to: url, options: .atomic)
        })
        store.setVisibleArea(.power, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        for i in 1...100 {
            let delta = Double(i) / 10
            store.noteActivity(now: start.addingTimeInterval(delta), uptime: 100 + delta)
        }
        XCTAssertEqual(writes, 0)
        store.tick(now: start.addingTimeInterval(80), uptime: 180)
        XCTAssertEqual(store.seconds(for: .power, on: start), 70, accuracy: 0.0001)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(store.isCounting)
    }

    @MainActor func testNoTouchNoCountAndBackgroundNeverAutoResumes() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        store.setVisibleArea(.math, now: start, uptime: 10)
        store.tick(now: start.addingTimeInterval(20), uptime: 30)
        XCTAssertEqual(store.seconds(for: .math, on: start), 0)
        store.noteActivity(now: start.addingTimeInterval(20), uptime: 30)
        store.setVisibleArea(nil, now: start.addingTimeInterval(25), uptime: 35)
        XCTAssertEqual(store.seconds(for: .math, on: start), 5, accuracy: 0.0001)
        store.setVisibleArea(.math, now: start.addingTimeInterval(26), uptime: 36)
        store.tick(now: start.addingTimeInterval(40), uptime: 50)
        XCTAssertEqual(store.seconds(for: .math, on: start), 5, accuracy: 0.0001)
        XCTAssertFalse(store.isCounting)
        store.noteActivity(now: start.addingTimeInterval(40), uptime: 50)
        store.tick(now: start.addingTimeInterval(45), uptime: 55)
        XCTAssertEqual(store.seconds(for: .math, on: start), 10, accuracy: 0.0001)
    }

    @MainActor func testRecentHomeTouchStartsOnlyAfterDestinationAppears() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        store.noteActivity(now: start, uptime: 10)
        store.setVisibleArea(.power, now: start.addingTimeInterval(0.25), uptime: 10.25)
        store.tick(now: start.addingTimeInterval(10.25), uptime: 20.25)
        XCTAssertEqual(store.seconds(for: .power, on: start), 10, accuracy: 0.0001)
        store.setVisibleArea(nil, now: start.addingTimeInterval(10.25), uptime: 20.25)
        store.setVisibleArea(.power, now: start.addingTimeInterval(10.5), uptime: 20.5)
        store.tick(now: start.addingTimeInterval(15.5), uptime: 25.5)
        XCTAssertEqual(store.seconds(for: .power, on: start), 10, accuracy: 0.0001)
    }

    @MainActor func testNavigationAttributionAndNoAutomaticCredit() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        store.setVisibleArea(.power, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(15), uptime: 115)
        store.noteActivity(now: start.addingTimeInterval(16), uptime: 116)
        store.setVisibleArea(.circuit, now: start.addingTimeInterval(16.1), uptime: 116.1)
        store.tick(now: start.addingTimeInterval(21.1), uptime: 121.1)
        XCTAssertEqual(store.seconds(for: .power, on: start), 16.1, accuracy: 0.0001)
        XCTAssertEqual(store.seconds(for: .circuit, on: start), 5, accuracy: 0.0001)
        // A programmatic switch long after the last touch does not start a new subject.
        store.setVisibleArea(.publicQuestions, now: start.addingTimeInterval(25), uptime: 125)
        store.tick(now: start.addingTimeInterval(35), uptime: 135)
        XCTAssertEqual(store.seconds(for: .publicQuestions, on: start), 0)
        XCTAssertEqual(store.seconds(for: .circuit, on: start), 8.9, accuracy: 0.0001)
    }

    @MainActor func testCrossMidnightSplitsActualMonotonicSeconds() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let cal = utcCalendar()
        let before = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 59, second: 50)))
        let after = before.addingTimeInterval(20)
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: cal)
        store.setVisibleArea(.vocabulary, now: before, uptime: 200)
        store.noteActivity(now: before, uptime: 200)
        store.tick(now: after, uptime: 220)
        XCTAssertEqual(store.seconds(for: .vocabulary, on: before), 10, accuracy: 0.0001)
        XCTAssertEqual(store.seconds(for: .vocabulary, on: after), 10, accuracy: 0.0001)
        XCTAssertEqual(store.totalSeconds(for: .vocabulary), 20, accuracy: 0.0001)
    }

    @MainActor func testRestartDoesNotInventUnobservedTimeOrReplayCheckpoints() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        first.setVisibleArea(.computer, now: start, uptime: 100)
        first.noteActivity(now: start, uptime: 100)
        first.tick(now: start.addingTimeInterval(15), uptime: 115)
        first.tick(now: start.addingTimeInterval(19), uptime: 119)
        XCTAssertEqual(first.seconds(for: .computer, on: start), 19, accuracy: 0.0001)
        let reopened = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        XCTAssertEqual(reopened.seconds(for: .computer, on: start), 15, accuracy: 0.0001)
        reopened.setVisibleArea(.computer, now: start.addingTimeInterval(1000), uptime: 1100)
        reopened.tick(now: start.addingTimeInterval(1010), uptime: 1110)
        XCTAssertEqual(reopened.seconds(for: .computer, on: start), 15, accuracy: 0.0001)
        reopened.noteActivity(now: start.addingTimeInterval(1010), uptime: 1110)
        reopened.tick(now: start.addingTimeInterval(1015), uptime: 1115)
        reopened.tick(now: start.addingTimeInterval(1015), uptime: 1115)
        XCTAssertEqual(reopened.seconds(for: .computer, on: start), 20, accuracy: 0.0001)
    }

    @MainActor func testBadOrExternallyChangedTimeFileIsNeverOverwritten() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = current(dir)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("not-a-time-record".utf8); try broken.write(to: target)
        let protected = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        XCTAssertTrue(protected.blocked)
        protected.setVisibleArea(.power, now: start, uptime: 1)
        protected.noteActivity(now: start, uptime: 1)
        protected.tick(now: start.addingTimeInterval(100), uptime: 101)
        XCTAssertEqual(try Data(contentsOf: target), broken)

        let other = try root(); defer { try? FileManager.default.removeItem(at: other) }
        let store = EffectiveStudyTimeStore(baseDirectory: other, calendar: utcCalendar())
        store.setVisibleArea(.power, now: start, uptime: 1)
        store.noteActivity(now: start, uptime: 1)
        store.tick(now: start.addingTimeInterval(15), uptime: 16)
        let externallyEdited = Data("external-change".utf8); try externallyEdited.write(to: current(other), options: .atomic)
        store.tick(now: start.addingTimeInterval(30), uptime: 31)
        XCTAssertTrue(store.blocked)
        XCTAssertFalse(store.isCounting)
        XCTAssertEqual(try Data(contentsOf: current(other)), externallyEdited)
    }

    @MainActor func testFailedWriteAndClockRollbackPreserveOtherSubjectFiles() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("StudyFlow/current.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("original-study-flow-record".utf8); try original.write(to: marker)
        struct SaveFailure: Error { }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar(), writer: { _, _ in throw SaveFailure() })
        store.setVisibleArea(.publicQuestions, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(15), uptime: 115)
        XCTAssertTrue(store.blocked)
        XCTAssertFalse(store.isCounting)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current(dir).path))

        let next = try root(); defer { try? FileManager.default.removeItem(at: next) }
        let clock = EffectiveStudyTimeStore(baseDirectory: next, calendar: utcCalendar())
        clock.setVisibleArea(.circuit, now: start, uptime: 10)
        clock.noteActivity(now: start, uptime: 10)
        clock.tick(now: start.addingTimeInterval(5), uptime: 15)
        clock.tick(now: start.addingTimeInterval(6), uptime: 14)
        XCTAssertEqual(clock.seconds(for: .circuit, on: start), 5, accuracy: 0.0001)
        XCTAssertFalse(clock.isCounting)
        XCTAssertNotNil(clock.error)
    }

    @MainActor func testUncertainCommittedWriteBlocksUntilSafeReopenWithoutDoubleCounting() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        struct UncertainWrite: Error { }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar(), writer: { data, url in
            try data.write(to: url, options: .atomic)
            throw UncertainWrite()
        })
        store.setVisibleArea(.math, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(15), uptime: 115)
        XCTAssertTrue(store.blocked)
        let saved = try Data(contentsOf: current(dir))
        store.tick(now: start.addingTimeInterval(30), uptime: 130)
        XCTAssertEqual(try Data(contentsOf: current(dir)), saved)
        let reopened = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        XCTAssertFalse(reopened.blocked)
        XCTAssertEqual(reopened.seconds(for: .math, on: start), 15, accuracy: 0.0001)
        reopened.setVisibleArea(.math, now: start.addingTimeInterval(30), uptime: 130)
        reopened.tick(now: start.addingTimeInterval(45), uptime: 145)
        XCTAssertEqual(reopened.seconds(for: .math, on: start), 15, accuracy: 0.0001)
    }

    @MainActor func testTwoStoresDoNotOverwriteEachOthersFirstCheckpoint() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        let stale = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        first.setVisibleArea(.circuit, now: start, uptime: 100)
        first.noteActivity(now: start, uptime: 100)
        stale.setVisibleArea(.power, now: start, uptime: 100)
        stale.noteActivity(now: start, uptime: 100)
        first.tick(now: start.addingTimeInterval(15), uptime: 115)
        let firstBytes = try Data(contentsOf: current(dir))
        stale.tick(now: start.addingTimeInterval(15), uptime: 115)
        XCTAssertTrue(stale.blocked)
        XCTAssertEqual(try Data(contentsOf: current(dir)), firstBytes)
        XCTAssertFalse(first.blocked)
    }

    @MainActor func testExportEmptyHistoryDoesNotCreateOrModifyFiles() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("StudyFlow/current.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("original-study-flow-record".utf8); try original.write(to: marker)
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        let data = try store.exportData(now: start, uptime: 10)
        let decoded = try JSONDecoder().decode(EffectiveStudyTimeState.self, from: data)
        XCTAssertEqual(decoded.format, "xkl-effective-study-time-v1")
        XCTAssertTrue(decoded.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current(dir).path))
        XCTAssertEqual(try Data(contentsOf: marker), original)
    }

    @MainActor func testExportFlushesObservedTailAndRoundTripsAllSubjectsWithoutDoubleCount() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        store.setVisibleArea(.power, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(5), uptime: 105)
        let first = try store.exportData(now: start.addingTimeInterval(12), uptime: 112)
        XCTAssertEqual(try Data(contentsOf: current(dir)), first)
        XCTAssertEqual(try JSONDecoder().decode(EffectiveStudyTimeState.self, from: first), store.state)
        XCTAssertEqual(store.seconds(for: .power, on: start), 12, accuracy: 0.0001)
        store.noteActivity(now: start.addingTimeInterval(13), uptime: 113)
        store.setVisibleArea(.circuit, now: start.addingTimeInterval(13), uptime: 113)
        store.tick(now: start.addingTimeInterval(18), uptime: 118)
        let second = try store.exportData(now: start.addingTimeInterval(18), uptime: 118)
        let state = try JSONDecoder().decode(EffectiveStudyTimeState.self, from: second)
        XCTAssertEqual(state, store.state)
        XCTAssertEqual(store.seconds(for: .power, on: start), 13, accuracy: 0.0001)
        XCTAssertEqual(store.seconds(for: .circuit, on: start), 5, accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: current(dir)), second)
        XCTAssertEqual(try store.exportData(now: start.addingTimeInterval(18), uptime: 118), second)
    }

    @MainActor func testExportFailureAndConcurrentChangesNeverOverwriteExistingHistory() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let seed = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        seed.setVisibleArea(.computer, now: start, uptime: 100)
        seed.noteActivity(now: start, uptime: 100)
        seed.tick(now: start.addingTimeInterval(15), uptime: 115)
        let saved = try Data(contentsOf: current(dir))
        struct SaveFailure: Error { }
        let failed = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar(), writer: { _, _ in throw SaveFailure() })
        failed.setVisibleArea(.computer, now: start.addingTimeInterval(20), uptime: 120)
        failed.noteActivity(now: start.addingTimeInterval(20), uptime: 120)
        XCTAssertThrowsError(try failed.exportData(now: start.addingTimeInterval(25), uptime: 125))
        XCTAssertTrue(failed.blocked)
        XCTAssertEqual(try Data(contentsOf: current(dir)), saved)

        let other = try root(); defer { try? FileManager.default.removeItem(at: other) }
        let concurrent = EffectiveStudyTimeStore(baseDirectory: other, calendar: utcCalendar())
        concurrent.setVisibleArea(.math, now: start, uptime: 100)
        concurrent.noteActivity(now: start, uptime: 100)
        concurrent.tick(now: start.addingTimeInterval(15), uptime: 115)
        let external = Data("external-change".utf8); try external.write(to: current(other), options: .atomic)
        XCTAssertThrowsError(try concurrent.exportData(now: start.addingTimeInterval(15), uptime: 115))
        XCTAssertTrue(concurrent.blocked)
        XCTAssertEqual(try Data(contentsOf: current(other)), external)
    }

    @MainActor func testExportRejectsDamagedExistingFileWithoutReplacingIt() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = current(dir)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("damaged-history".utf8); try damaged.write(to: file)
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: utcCalendar())
        XCTAssertTrue(store.blocked)
        XCTAssertThrowsError(try store.exportData(now: start, uptime: 1))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    @MainActor func testMechanicsIsIndependentAndOldSixSubjectHistoryStillLoadsAndExports() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let cal = utcCalendar(), components = cal.dateComponents([.year, .month, .day], from: start)
        let day = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        let existing = EffectiveStudyTimeState(days: [day: ["vocabulary": 31, "power": 17, "circuit": 23]])
        let file = current(dir)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(existing).write(to: file, options: .atomic)
        let store = EffectiveStudyTimeStore(baseDirectory: dir, calendar: cal)
        XCTAssertFalse(store.blocked, store.error ?? "")
        XCTAssertEqual(store.seconds(for: .vocabulary, on: start), 31, accuracy: 0.0001)
        XCTAssertEqual(store.seconds(for: .power, on: start), 17, accuracy: 0.0001)
        XCTAssertEqual(store.seconds(for: .circuit, on: start), 23, accuracy: 0.0001)
        XCTAssertEqual(store.seconds(for: .mechanics, on: start), 0, accuracy: 0.0001)
        XCTAssertEqual(EffectiveStudyArea.mechanics.title, "工程力学")
        store.setVisibleArea(.mechanics, now: start, uptime: 100)
        store.noteActivity(now: start, uptime: 100)
        store.tick(now: start.addingTimeInterval(12), uptime: 112)
        let exported = try store.exportData(now: start.addingTimeInterval(12), uptime: 112)
        let decoded = try JSONDecoder().decode(EffectiveStudyTimeState.self, from: exported)
        XCTAssertEqual(decoded.days[day]?["vocabulary"], 31)
        XCTAssertEqual(decoded.days[day]?["power"], 17)
        XCTAssertEqual(decoded.days[day]?["circuit"], 23)
        XCTAssertEqual(decoded.days[day]?["mechanics"], 12)
        XCTAssertEqual(store.totalSeconds(for: .mechanics), 12, accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: file), exported)
    }
}
#endif
