import Foundation
import XCTest
@testable import StudyClientModel

final class HourlyStudyPlanTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return result
    }

    private func time(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 17,
                                           hour: hour, minute: minute, second: second))!
    }

    func testBoardUsesEightCoreHoursAndTwoFlexibleDeadlines() {
        let rows = HourlyStudyPlan.windows(on: time(13), calendar: calendar)
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first?.start, time(13))
        XCTAssertEqual(rows.last?.end, time(23))
        XCTAssertEqual(rows.filter(\.flexible).map(\.endingHour), [17, 22])
        XCTAssertNil(HourlyStudyPlan.window(at: time(23), calendar: calendar))
        XCTAssertEqual(HourlyStudyPlan().remaining(on: time(13), calendar: calendar), 48)
    }

    func testLateOrDuplicateAnswersDoNotChangeSealedProgress() throws {
        let start = time(19)
        let row = try XCTUnwrap(HourlyStudyPlan.window(at: start, calendar: calendar))
        var plan = HourlyStudyPlan()
        XCTAssertTrue(plan.begin(row, area: "power", at: start))
        XCTAssertFalse(plan.record(row, area: "power", itemID: "before-warmup", at: start, activeSeconds: nil))
        XCTAssertTrue(plan.interact(row, area: "power", at: time(19, 8), warmup: true))
        XCTAssertFalse(plan.interact(row, area: "power", at: time(19, 10), warmup: true))
        XCTAssertTrue(plan.record(row, area: "power", itemID: "same", at: time(19, 9), activeSeconds: 60))
        XCTAssertFalse(plan.record(row, area: "power", itemID: "same", at: time(19, 10), activeSeconds: 60))
        XCTAssertFalse(plan.record(row, area: "computer", itemID: "other", at: time(19, 11), activeSeconds: 60))
        XCTAssertFalse(plan.record(row, area: "power", itemID: "at-deadline", at: time(20), activeSeconds: 60))
        XCTAssertTrue(plan.record(row, area: "power", itemID: "last", at: time(19, 59, 59), activeSeconds: 120))
        let restored = try JSONDecoder().decode(HourlyStudyPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(restored.slot(row)?.credited, 2)
        XCTAssertEqual(restored.slot(row)?.latencySeconds, 480)
        XCTAssertEqual(restored.slot(row)?.typicalSeconds, 90)
        XCTAssertEqual(restored.slot(row)?.paceMargin(at: time(19, 58)), -240)
        XCTAssertNil(restored.slot(row)?.paceMargin(at: time(20)))
    }

    func testFlexibleHoursRepayDebtButCannotCreateOnTimeCredit() throws {
        let rows = HourlyStudyPlan.windows(on: time(13), calendar: calendar)
        var plan = HourlyStudyPlan()
        let flex = try XCTUnwrap(rows.first(where: \.flexible))
        XCTAssertEqual(plan.target(for: flex, calendar: calendar), 6)
        for row in rows.prefix(3) {
            XCTAssertTrue(plan.begin(row, area: "power", at: row.start))
            XCTAssertTrue(plan.interact(row, area: "power", at: row.start, warmup: true))
            let total = row.endingHour == 16 ? 4 : 6
            for id in 0..<total {
                XCTAssertTrue(plan.record(row, area: "power", itemID: String(id), at: row.start, activeSeconds: nil))
            }
        }
        XCTAssertEqual(plan.target(for: flex, calendar: calendar), 2)
        XCTAssertTrue(plan.begin(flex, area: "computer", at: flex.start, calendar: calendar))
        XCTAssertTrue(plan.interact(flex, area: "computer", at: flex.start, warmup: true))
        for id in 0..<2 {
            XCTAssertTrue(plan.record(flex, area: "computer", itemID: String(id), at: flex.start, activeSeconds: nil))
        }
        XCTAssertFalse(plan.record(flex, area: "computer", itemID: "extra", at: flex.start, activeSeconds: nil))
        XCTAssertEqual(plan.delivery(on: flex.end, calendar: calendar).completed, 2)
        XCTAssertEqual(plan.remaining(on: flex.end, calendar: calendar), 30)
    }

    func testETAUsesFutureCoreWindowsAndAdvancesAtTheBoundary() {
        let plan = HourlyStudyPlan()
        XCTAssertEqual(plan.firstPassETA(unseen: 1, now: time(12), calendar: calendar), time(14))
        XCTAssertEqual(plan.firstPassETA(unseen: 1, now: time(16), calendar: calendar), time(18))
        XCTAssertEqual(plan.firstPassETA(unseen: 1, now: time(22, 55), calendar: calendar), time(23))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: time(14))
        XCTAssertEqual(plan.firstPassETA(unseen: 7, now: time(22, 55), calendar: calendar), tomorrow)
        XCTAssertNil(plan.firstPassETA(unseen: 0, now: time(22, 55), calendar: calendar))
    }

    func testBaselineIsNeverCountedTwiceWithWarmup() throws {
        var plan = HourlyStudyPlan()
        let start = time(19)
        let row = try XCTUnwrap(HourlyStudyPlan.window(at: start, calendar: calendar))
        XCTAssertTrue(plan.interact(row, area: "math", at: time(19, 7), warmup: false))
        XCTAssertTrue(plan.begin(row, area: "math", at: time(19, 8)))
        XCTAssertTrue(plan.interact(row, area: "math", at: time(19, 9), warmup: true))
        let comparison = plan.latencyComparison(on: time(21), calendar: calendar)
        XCTAssertEqual(comparison.ordinary, [420])
        XCTAssertTrue(comparison.guided.isEmpty)
    }
}
