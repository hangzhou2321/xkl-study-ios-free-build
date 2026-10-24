import Foundation
import XCTest
import CPocket
@testable import StudyClientModel

final class PocketResumeTests: XCTestCase {
    @MainActor private func blank() throws -> PocketEngine {
        var bytes = UUID().uuid
        let pointer = withUnsafeBytes(of: &bytes) {
            xkl_engine_blank(30, $0.bindMemory(to: UInt8.self).baseAddress)
        }
        let raw = try XCTUnwrap(pointer)
        defer { xkl_engine_free(raw) }
        var data = Data(count: xkl_engine_snapshot_size(raw))
        let written = data.withUnsafeMutableBytes {
            xkl_engine_snapshot(raw, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        XCTAssertEqual(written, data.count)
        return try PocketEngine(snapshot: data)
    }

    @MainActor func testColdResumeRestoresVisibleAnswerWithoutGradingOrAdvancing() async throws {
        let original = try blank()
        try original.start(day: 20_746)
        try original.reveal()
        let before = try original.info
        let prefix = try original.events(from: 1)
        let resumed = try PocketEngine(snapshot: original.snapshot())
        try resumed.start(day: 20_746, preservingRevealedAnswer: true)
        let after = try resumed.info
        XCTAssertEqual(after.word, before.word)
        XCTAssertEqual(after.completed, before.completed)
        XCTAssertEqual(after.total_remaining, before.total_remaining)
        XCTAssertEqual(after.stage, before.stage)
        XCTAssertEqual(after.revealed, 1)
        let events = try resumed.events(from: 1)
        XCTAssertEqual(Array(events.prefix(prefix.count)), prefix)
        // Every new event is a boot/start/presentation/reveal, never an answer.
        XCTAssertTrue(events.dropFirst(prefix.count).allSatisfy { [UInt32(1), 2, 3, 4].contains($0.kind) })
    }

    @MainActor func testNextDayResumeDoesNotExposeYesterdaysAnswer() async throws {
        let original = try blank()
        try original.start(day: 20_746)
        try original.reveal()
        let before = try original.info
        let resumed = try PocketEngine(snapshot: original.snapshot())
        try resumed.start(day: 20_747, preservingRevealedAnswer: true)
        let after = try resumed.info
        XCTAssertEqual(after.word, before.word)
        XCTAssertEqual(after.completed, before.completed)
        XCTAssertEqual(after.total_remaining, before.total_remaining)
        XCTAssertEqual(after.revealed, 0)
    }

    @MainActor func testLiveCalendarRefreshKeepsTheShownMeaningWithoutRecordingAGrade() async throws {
        let engine = try blank()
        try engine.start(day: 20_746)
        try engine.reveal()
        let before = try engine.info, events = try engine.events(from: 1)
        try engine.start(day: 20_747, preservingRevealedAnswer: true, preservingShownStepAcrossDay: true)
        let after = try engine.info
        XCTAssertEqual(after.word, before.word)
        XCTAssertEqual(after.revealed, 1)
        XCTAssertEqual(after.completed, before.completed)
        XCTAssertEqual(after.new_remaining, before.new_remaining)
        XCTAssertEqual(after.selection_day, 20_747)
        XCTAssertTrue(try engine.events(from: UInt32(events.count + 1)).allSatisfy {
            [UInt32(1), 2, 3, 4].contains($0.kind)
        })
    }
}
