import Foundation
import XCTest
@testable import StudyClientModel

final class FirstPassScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }

    private func window(_ startHour: Int) throws -> HourlyStudyPlan.Window {
        let datetime = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 2, day: 9, hour: startHour)))
        return try XCTUnwrap(HourlyStudyPlan.window(at: datetime, calendar: calendar))
    }

    private func assignment(_ window: HourlyStudyPlan.Window, _ subject: String, _ cards: Int) -> FirstPassSchedule.Assignment {
        .init(beginsAt: Int64(window.start.timeIntervalSince1970), subject: subject, cards: cards)
    }

    func testDeadlinePlanCreditsSevenDistinctFirstPassCardsOnly() throws {
        let row = try window(18), subject = "power", task = assignment(row, subject, 7)
        let raw = try JSONEncoder().encode(FirstPassSchedule(format: "xkl-first-pass-hours-v1", assignments: [task]))
        let schedule = try FirstPassSchedule.load(raw, calendar: calendar)
        XCTAssertEqual(schedule.deadline, row.end)

        var ledger = HourlyStudyPlan()
        XCTAssertTrue(ledger.begin(row, area: subject, at: row.start, firstPassTarget: task.cards, calendar: calendar))
        XCTAssertTrue(ledger.interact(row, area: subject, at: row.start, warmup: true))
        XCTAssertFalse(ledger.record(row, area: subject, itemID: "review", at: row.start, activeSeconds: nil))
        for i in 0..<7 {
            XCTAssertTrue(ledger.record(row, area: subject, itemID: "fresh-\(i)", at: row.start, activeSeconds: nil, firstPass: true))
        }
        XCTAssertFalse(ledger.record(row, area: subject, itemID: "next", at: row.end, activeSeconds: nil, firstPass: true))
        let decoded = try JSONDecoder().decode(HourlyStudyPlan.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded.firstPassCredit(at: row.start, subject: subject), 7)
    }

    func testRejectsDuplicateWindows() throws {
        let task = assignment(try window(15), "math", 7)
        let duplicate = FirstPassSchedule(format: "xkl-first-pass-hours-v1", assignments: [task, task])
        XCTAssertThrowsError(try FirstPassSchedule.load(JSONEncoder().encode(duplicate), calendar: calendar))
    }
}
