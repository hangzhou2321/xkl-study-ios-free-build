import Foundation
import XCTest
@testable import StudyClientModel

final class AdaptiveDeadlinePaceTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    private func date(_ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 2, day: 9, hour: hour, minute: minute)))
    }

    func testRemainingCardsFillCoreTimeAndLateEntryIsProrated() throws {
        let now = try date(19, 30), end = try date(23)
        let rows = HourlyStudyPlan.windows(on: now, calendar: calendar)
        let pace = DeadlinePace(remaining: 35, now: now, end: end, current: nil, calendar: calendar)
        XCTAssertEqual(pace.goals.values.reduce(0, +), 35)
        XCTAssertEqual(pace.ordinaryHour, 14)
        XCTAssertEqual(pace.target(for: try XCTUnwrap(rows.first { $0.endingHour == 20 })), 7)
        XCTAssertEqual(pace.target(for: try XCTUnwrap(rows.first { $0.endingHour == 22 })), 14)
        XCTAssertEqual(pace.todayLeft(calendar: calendar), 35)
        let late = DeadlinePace(remaining: 35, now: try date(20), end: end, current: nil, calendar: calendar)
        XCTAssertEqual(late.goals.values.reduce(0, +), 35)
        XCTAssertEqual(late.ordinaryHour, 18)
        let expired = DeadlinePace(remaining: 2, now: end, end: end, current: nil, calendar: calendar)
        XCTAssertTrue(expired.goals.isEmpty)
    }

    func testOneHourCreditsFirstPassAcrossSubjectsWithoutDuplicateOrNewWarmup() throws {
        let start = try date(18), end = try date(23)
        let window = try XCTUnwrap(HourlyStudyPlan.window(at: start, calendar: calendar))
        var ledger = HourlyStudyPlan()
        XCTAssertTrue(ledger.begin(window, area: "power", at: start, firstPassTarget: 9,
                                   freeSubject: true, calendar: calendar))
        XCTAssertTrue(ledger.interact(window, area: "power", at: start, warmup: true))
        XCTAssertTrue(ledger.record(window, area: "power", itemID: "same-id", at: start, activeSeconds: nil, firstPass: true))
        XCTAssertTrue(ledger.begin(window, area: "computer", at: start, firstPassTarget: 9,
                                   freeSubject: true, calendar: calendar))
        XCTAssertFalse(ledger.interact(window, area: "computer", at: start, warmup: true))
        XCTAssertTrue(ledger.record(window, area: "computer", itemID: "same-id", at: start, activeSeconds: nil, firstPass: true))
        XCTAssertFalse(ledger.record(window, area: "power", itemID: "same-id", at: start, activeSeconds: nil, firstPass: true))
        XCTAssertFalse(ledger.record(window, area: "math", itemID: "repeat", at: start, activeSeconds: nil))
        XCTAssertFalse(ledger.record(window, area: "vocabulary", itemID: "english", at: start, activeSeconds: nil, firstPass: true))
        let copy = try JSONDecoder().decode(HourlyStudyPlan.self, from: JSONEncoder().encode(ledger))
        let slot = try XCTUnwrap(copy.slot(window))
        XCTAssertEqual(slot.credited, 2)
        XCTAssertEqual(slot.firstCardInteraction, start)
        let pace = DeadlinePace(remaining: 24, now: try date(18, 15), end: end, current: slot, calendar: calendar)
        XCTAssertEqual(pace.target(for: window), 9)
        XCTAssertEqual(pace.goals.values.reduce(0, +), 17)
        XCTAssertEqual(pace.todayLeft(calendar: calendar), 24)
    }
}
