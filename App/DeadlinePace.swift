import Foundation

/// All subjects share a rate. No card or grade is created by the plan.
struct DeadlinePace {
    let remaining: Int
    let now: Date
    let end: Date
    let ordinaryHour: Int
    let goals: [Date: Int]
    private let reservedStart: Date?
    private let reservedTarget: Int
    private let reservedLeft: Int

    init(remaining: Int, now: Date, end: Date, current: HourlyStudyPlan.Slot?, calendar: Calendar = .current) {
        self.remaining = max(0, remaining)
        self.now = now
        self.end = end
        let running = current.flatMap { slot in
            slot.freeSubject == true && now < slot.end && slot.end <= end ? slot : nil
        }
        let reserved = min(max(0, remaining), max(0, (running?.target ?? 0) - (running?.credited ?? 0)))
        reservedLeft = reserved
        reservedTarget = running?.target ?? 0
        reservedStart = running?.start
        let offsetBase = calendar.startOfDay(for: now)
        let horizon = calendar.dateComponents([.day], from: offsetBase, to: calendar.startOfDay(for: end)).day ?? 0
        let pending = (0...max(0, min(horizon, 31))).compactMap { calendar.date(byAdding: .day, value: $0, to: offsetBase) }
            .flatMap { HourlyStudyPlan.windows(on: $0, calendar: calendar) }
            .filter { $0.end > now && $0.end <= end && $0.start != running?.start }
        let core = pending.filter { !$0.flexible }
        let windows = core.isEmpty ? pending : core
        let weights = windows.map { max(1, Int(ceil($0.end.timeIntervalSince(max(now, $0.start))))) }
        let duration = weights.reduce(0, +)
        let left = max(0, remaining - reserved)
        ordinaryHour = duration == 0 ? 0 : (left * 3600 + duration - 1) / duration
        var result: [Date: Int] = [:]
        var elapsed = 0
        var distributed = 0
        for (window, weight) in zip(windows, weights) {
            elapsed += weight
            let nextTotal = (left * elapsed + duration - 1) / duration
            result[window.start] = nextTotal - distributed
            distributed = nextTotal
        }
        goals = result
    }

    func target(for window: HourlyStudyPlan.Window) -> Int {
        guard now < window.end, window.end <= end else { return 0 }
        if window.start == reservedStart { return reservedTarget }
        if let explicit = goals[window.start] { return explicit }
        if window.flexible { return min(remaining, ordinaryHour) }
        return 0
    }

    func todayLeft(calendar: Calendar = .current) -> Int {
        let assigned = goals.reduce(0) { $0 + (calendar.isDate($1.key, inSameDayAs: now) ? $1.value : 0) }
        return calendar.isDate(reservedStart ?? .distantPast, inSameDayAs: now) ? assigned + reservedLeft : assigned
    }
}
