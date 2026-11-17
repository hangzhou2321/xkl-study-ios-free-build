import Foundation

/// A plan imported separately from the course and its records.
struct FirstPassSchedule: Codable {
    static let subjects: Set<String> = ["power", "computer", "circuit", "mechanics", "math"]
    struct Assignment: Codable, Equatable, Identifiable {
        let beginsAt: Int64
        let subject: String
        let cards: Int
        var id: Int64 { beginsAt }
        var start: Date { Date(timeIntervalSince1970: Double(beginsAt)) }
    }

    let format: String
    let assignments: [Assignment]

    var deadline: Date? { assignments.last?.start.addingTimeInterval(3600) }

    static func load(_ data: Data, calendar: Calendar = .current) throws -> Self {
        guard data.count <= 64 * 1024 else { throw InvalidSchedule() }
        let schedule = try JSONDecoder().decode(Self.self, from: data)
        let rows = schedule.assignments
        guard schedule.format == "xkl-first-pass-hours-v1", (1...248).contains(rows.count),
              Set(rows.map(\.id)).count == rows.count,
              rows.map(\.id) == rows.map(\.id).sorted(),
              let first = rows.first, let last = rows.last, (1_570_000_000...4_102_444_800).contains(first.beginsAt),
              (1_570_000_000...4_102_444_800).contains(last.beginsAt), last.beginsAt - first.beginsAt < 32 * 86400 else {
            throw InvalidSchedule()
        }
        guard rows.allSatisfy({ row in
            guard (1...60).contains(row.cards), subjects.contains(row.subject),
                  let window = HourlyStudyPlan.window(at: row.start, calendar: calendar) else { return false }
            return window.start == row.start && !window.flexible
        }) else { throw InvalidSchedule() }
        return schedule
    }

    struct InvalidSchedule: LocalizedError {
        var errorDescription: String? { "这个文件不是有效的首轮小时计划。" }
    }
}
