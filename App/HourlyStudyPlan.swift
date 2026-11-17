import Foundation

struct HourlyStudyPlan: Codable {
    static let goal = 6
    private(set) var slots: [Slot] = []

    struct Window: Identifiable, Equatable {
        let start: Date
        let end: Date
        let endingHour: Int
        var id: Date { start }
        var flexible: Bool { endingHour == 17 || endingHour == 22 }
    }

    struct Slot: Codable, Equatable {
        let start: Date
        let end: Date
        let flexible: Bool
        let target: Int
        var area: String?
        var firstCardInteraction: Date?
        var ordinaryFirstInteraction: Date?
        var ordinaryArea: String?
        var units: [Unit] = []
        var credited: Int { min(units.count, target) }
        var latencySeconds: Int? {
            firstCardInteraction.map { Int($0.timeIntervalSince(start)) }
        }
        var ordinaryLatencySeconds: Int? {
            ordinaryFirstInteraction.map { Int($0.timeIntervalSince(start)) }
        }
        var typicalSeconds: Double? {
            let samples = units.compactMap(\.activeSeconds).filter { $0 >= 1 }.sorted()
            guard samples.count >= 2 else { return nil }
            return (samples[(samples.count - 1) / 2] + samples[samples.count / 2]) / 2
        }
        func paceMargin(at now: Date) -> Int? {
            guard credited < target, now < end, let typicalSeconds else { return nil }
            return Int((end.timeIntervalSince(now) - Double(target - credited) * typicalSeconds).rounded())
        }
    }

    struct Unit: Codable, Equatable {
        let itemID: String
        let at: Date
        let activeSeconds: Double?
    }

    static func windows(on date: Date, calendar: Calendar = .current) -> [Window] {
        (14...23).compactMap { hour in
            guard let start = calendar.date(bySettingHour: hour - 1, minute: 0, second: 0, of: date),
                  let end = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) else { return nil }
            return .init(start: start, end: end, endingHour: hour)
        }
    }

    static func window(at date: Date, calendar: Calendar = .current) -> Window? {
        windows(on: date, calendar: calendar).first { $0.start <= date && date < $0.end }
    }

    func slot(_ window: Window) -> Slot? { slots.first { $0.start == window.start } }

    func target(for window: Window, calendar: Calendar = .current) -> Int {
        guard window.flexible else { return Self.goal }
        if let active = slot(window), active.area != nil { return active.target }
        let earlier = Self.windows(on: window.start, calendar: calendar).filter { $0.end <= window.start }
        let outstanding = earlier.reduce(0) { balance, earlierWindow in
            let completed = slot(earlierWindow)?.credited ?? 0
            return balance + (earlierWindow.flexible ? -completed : Self.goal - completed)
        }
        return min(Self.goal, max(0, outstanding))
    }

    func remaining(on date: Date, calendar: Calendar = .current) -> Int {
        let windows = Self.windows(on: date, calendar: calendar)
        return windows.filter { !$0.flexible }.count * Self.goal
            - windows.reduce(0) { $0 + (slot($1)?.credited ?? 0) }
    }

    func delivery(on date: Date, calendar: Calendar = .current) -> (completed: Int, total: Int) {
        let core = Self.windows(on: date, calendar: calendar).filter { !$0.flexible }
        return (core.filter { (slot($0)?.credited ?? 0) == Self.goal }.count, core.count)
    }

    /// Planned capacity is credited to the selected course only if the learner spends
    /// those future windows on first-pass work in that course.
    func firstPassETA(unseen: Int, now: Date, calendar: Calendar = .current) -> Date? {
        guard unseen > 0 else { return nil }
        var left = unseen
        let today = Self.windows(on: now, calendar: calendar).filter { !$0.flexible }
        for window in today where now < window.end {
            left -= Self.goal - (slot(window)?.credited ?? 0)
            if left <= 0 { return window.end }
        }
        let daily = today.count * Self.goal
        guard daily > 0,
              let future = calendar.date(byAdding: .day, value: (left - 1) / daily + 1, to: now) else { return nil }
        let index = (left - 1) % daily / Self.goal
        return Self.windows(on: future, calendar: calendar).filter { !$0.flexible }[index].end
    }

    @discardableResult mutating func begin(_ window: Window, area: String, at date: Date, calendar: Calendar = .current) -> Bool {
        let goal = target(for: window, calendar: calendar)
        guard window.start <= date, date < window.end, goal > 0 else { return false }
        if let index = slots.firstIndex(where: { $0.start == window.start }) {
            guard slots[index].area == nil else { return false }
            let baseline = slots[index]
            slots[index] = Slot(start: window.start, end: window.end, flexible: window.flexible,
                                target: goal, area: area, firstCardInteraction: nil,
                                ordinaryFirstInteraction: baseline.ordinaryFirstInteraction, ordinaryArea: baseline.ordinaryArea)
        } else {
            slots.append(Slot(start: window.start, end: window.end, flexible: window.flexible,
                              target: goal, area: area))
        }
        return true
    }

    @discardableResult mutating func interact(_ window: Window, area: String, at date: Date, warmup: Bool) -> Bool {
        guard window.start <= date, date < window.end else { return false }
        if let index = slots.firstIndex(where: { $0.start == window.start }) {
            if warmup {
                guard slots[index].area == area, slots[index].firstCardInteraction == nil else { return false }
                slots[index].firstCardInteraction = date
            } else {
                guard slots[index].area == nil, slots[index].ordinaryFirstInteraction == nil else { return false }
                slots[index].ordinaryFirstInteraction = date
                slots[index].ordinaryArea = area
            }
        } else {
            guard !warmup, !window.flexible else { return false }
            slots.append(Slot(start: window.start, end: window.end, flexible: false, target: Self.goal,
                              ordinaryFirstInteraction: date, ordinaryArea: area))
        }
        return true
    }

    @discardableResult mutating func record(_ window: Window, area: String, itemID: String,
                                           at date: Date, activeSeconds: Double?) -> Bool {
        guard let index = slots.firstIndex(where: { $0.start == window.start }),
              date < slots[index].end, let first = slots[index].firstCardInteraction, date >= first,
              slots[index].area == area, !itemID.isEmpty, slots[index].credited < slots[index].target,
              !slots[index].units.contains(where: { $0.itemID == itemID }) else { return false }
        slots[index].units.append(Unit(itemID: itemID, at: date, activeSeconds: activeSeconds))
        return true
    }

    func latencyComparison(on date: Date, calendar: Calendar = .current) -> (guided: [Int], ordinary: [Int]) {
        let today = calendar.startOfDay(for: date)
        guard let earliest = calendar.date(byAdding: .day, value: -13, to: today) else { return ([], []) }
        // Classify slots that began in ordinary study as baseline only.
        // A later switch into guided study doesn't count as a second observation.
        let recent = slots.filter { !$0.flexible && $0.start >= earliest && $0.start <= date }
        return (recent.filter { $0.ordinaryFirstInteraction == nil }.compactMap(\.latencySeconds),
                recent.compactMap(\.ordinaryLatencySeconds))
    }
}

struct HourlyStudyAnswer {
    static let committed = Notification.Name("HourlyStudyAnswerCommitted")
    let area: String
    let itemID: String?
    let at: Date

    func post() {
        NotificationCenter.default.post(name: Self.committed, object: nil, userInfo: ["answer": self])
    }
}
