import Foundation

/// A plan imported separately from the course and its records.
struct FirstPassSchedule: Codable {
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
        let allowed: Set<String> = ["power", "computer", "circuit", "mechanics", "math"]
        guard rows.allSatisfy({ row in
            guard (1...60).contains(row.cards), allowed.contains(row.subject),
                  let window = HourlyStudyPlan.window(at: row.start, calendar: calendar) else { return false }
            return window.start == row.start && !window.flexible
        }) else { throw InvalidSchedule() }
        return schedule
    }

    func includesDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let first = assignments.first, let last = assignments.last else { return false }
        return calendar.startOfDay(for: date) >= calendar.startOfDay(for: first.start)
            && calendar.startOfDay(for: date) <= calendar.startOfDay(for: last.start)
    }

    func rows(on day: Date, calendar: Calendar = .current) -> [Assignment] {
        assignments.filter { calendar.isDate($0.start, inSameDayAs: day) }
    }

    func assignment(for window: HourlyStudyPlan.Window, in ledger: HourlyStudyPlan,
                    remaining: [String: Int], calendar: Calendar = .current) -> Assignment? {
        let stamp = Int64(window.start.timeIntervalSince1970)
        if !window.flexible { return assignments.first { $0.beginsAt == stamp } }
        var shortfalls: [(area: String, cards: Int)] = []
        for task in rows(on: window.start, calendar: calendar) {
            guard task.start.addingTimeInterval(3600) <= window.start else { break }
            let completed = ledger.firstPassCredit(at: task.start, subject: task.subject)
            guard task.cards > completed else { continue }
            if let index = shortfalls.firstIndex(where: { $0.area == task.subject }) {
                shortfalls[index].cards += task.cards - completed
            } else {
                shortfalls.append((task.subject, task.cards - completed))
            }
        }
        for earlier in HourlyStudyPlan.windows(on: window.start, calendar: calendar)
            where earlier.flexible && earlier.end <= window.start {
            guard let slot = ledger.slot(earlier), slot.firstPassOnly == true,
                  let index = shortfalls.firstIndex(where: { $0.area == slot.area }) else { continue }
            shortfalls[index].cards -= slot.credited
        }
        guard let task = shortfalls.first(where: { $0.cards > 0 && (remaining[$0.area] ?? 0) > 0 }) else { return nil }
        return .init(beginsAt: stamp, subject: task.area, cards: min(7, task.cards, remaining[task.area] ?? 0))
    }

    struct InvalidSchedule: LocalizedError {
        var errorDescription: String? { "这个文件不是有效的首轮小时计划。" }
    }
}
