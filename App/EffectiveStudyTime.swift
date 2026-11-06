import Foundation
import Combine

/// Independent, user-facing activity statistics. This is intentionally not
/// used by any learning engine, question scheduler, or old StudyFlow archive.
enum EffectiveStudyArea: String, Codable, CaseIterable {
    case vocabulary, publicQuestions, math, computer, power, circuit, mechanics

    var title: String {
        switch self {
        case .vocabulary: return "英语单词"
        case .publicQuestions: return "公共题库"
        case .math: return "数学"
        case .computer: return "计算机"
        case .power: return "电力系统"
        case .circuit: return "电工技术"
        case .mechanics: return "工程力学"
        }
    }
}

struct EffectiveStudyTimeState: Codable, Equatable {
    var format = "xkl-effective-study-time-v1"
    /// Local Gregorian calendar day -> area raw value -> observed seconds.
    var days: [String: [String: Double]] = [:]

    fileprivate func validate() throws {
        guard format == "xkl-effective-study-time-v1", days.count <= 50_000 else {
            throw EffectiveStudyTimeError.invalidState
        }
        let areaNames = Set(EffectiveStudyArea.allCases.map(\.rawValue))
        for (day, values) in days {
            let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
                  pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let year = Int(pieces[0]), let month = Int(pieces[1]), let date = Int(pieces[2]),
                  (1...9999).contains(year), (1...12).contains(month), (1...31).contains(date),
                  values.count <= areaNames.count, Set(values.keys).isSubset(of: areaNames),
                  values.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }) else {
                throw EffectiveStudyTimeError.invalidState
            }
        }
    }
}

private enum EffectiveStudyTimeError: LocalizedError {
    case invalidState, invalidClock, tooLarge, concurrentChange, invalidPath, incompleteWrite, exportUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidState: return "有效学习时间文件无法核对，原文件已保留。"
        case .invalidClock: return "有效学习时间的计时来源异常，本次计时已停止。"
        case .tooLarge: return "有效学习时间文件大小异常，原文件已保留。"
        case .concurrentChange: return "有效学习时间文件已被其他操作修改，原文件已保留。"
        case .invalidPath: return "有效学习时间目录不可用，原文件已保留。"
        case .incompleteWrite: return "有效学习时间未能完整保存，原文件已保留。"
        case .exportUnavailable: return "有效学习时间受保护或未能保存，暂时不能导出。"
        }
    }
}

/// Counts observed, foreground activity only. An interaction opens a 60-second
/// observation window; longer idle tails are not counted. A killed process may
/// lose the last uncheckpointed tail, but never reconstructs unobserved time.
@MainActor
final class EffectiveStudyTimeStore: ObservableObject {
    static let idleLimit: TimeInterval = 60
    static let checkpointInterval: TimeInterval = 15
    static let recentTouchWindow: TimeInterval = 1
    /// Continuous scrolls can produce dozens of events per second. Record the
    /// latest contact immediately, but publish accumulated totals at most twice
    /// per second from touch events (the ordinary timer may also tick).
    static let touchAccountingInterval: TimeInterval = 0.5

    @Published private(set) var state = EffectiveStudyTimeState()
    @Published private(set) var isCounting = false
    @Published private(set) var blocked = false
    @Published private(set) var error: String?

    private let fileURL: URL
    private let writer: (Data, URL) throws -> Void
    private let calendar: Calendar
    private var visibleArea: EffectiveStudyArea?
    private var lastTouchUptime: TimeInterval?
    private var anchorUptime: TimeInterval?
    private var anchorDate: Date?
    private var uncheckpointedSeconds: TimeInterval = 0
    private var durableData: Data?

    init(baseDirectory: URL? = nil, calendar suppliedCalendar: Calendar? = nil,
         writer: ((Data, URL) throws -> Void)? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        fileURL = base.appendingPathComponent("EffectiveStudyTime", isDirectory: true).appendingPathComponent("current.json")
        if let suppliedCalendar { calendar = suppliedCalendar }
        else {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .current
            calendar = local
        }
        self.writer = writer ?? { data, url in try data.write(to: url, options: .atomic) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try validateDirectory()
            let raw = try readCurrent()
            let restored = try JSONDecoder().decode(EffectiveStudyTimeState.self, from: raw)
            try restored.validate()
            state = restored
            durableData = raw
        } catch {
            blocked = true
            self.error = error.localizedDescription
        }
    }

    /// The UI must supply nil for non-study screens, background or a system
    /// overlay. It must not repeatedly report nil between a home tap and its
    /// destination becoming visible; timer ticks use `tick` instead.
    func setVisibleArea(_ area: EffectiveStudyArea?, now: Date = Date(),
                        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !blocked, validClock(now, uptime) else { return }
        guard advance(now: now, uptime: uptime) else { return }
        if area == visibleArea {
            if area == nil { lastTouchUptime = nil }
            return
        }
        if uncheckpointedSeconds > 0, !persist() { return }
        let recent = lastTouchUptime.map { uptime >= $0 && uptime - $0 <= Self.recentTouchWindow } ?? false
        visibleArea = area
        anchorUptime = nil
        anchorDate = nil
        if area == nil {
            lastTouchUptime = nil
            isCounting = false
        } else if recent {
            // The interaction happened just before navigation changed views;
            // count only from when the destination became visible.
            anchorUptime = uptime
            anchorDate = now
            isCounting = true
        } else {
            lastTouchUptime = nil
            isCounting = false
        }
    }

    /// Call from a non-intercepting foreground touch/scroll observer. An
    /// interaction on a non-study home screen may qualify the ensuing screen.
    func noteActivity(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !blocked, validClock(now, uptime) else { return }
        if visibleArea != nil, let anchor = anchorUptime, let lastTouch = lastTouchUptime,
           uptime - lastTouch < Self.idleLimit, uptime - anchor < Self.touchAccountingInterval {
            lastTouchUptime = uptime
            if !isCounting { isCounting = true }
            return
        }
        guard advance(now: now, uptime: uptime) else { return }
        lastTouchUptime = uptime
        if visibleArea != nil {
            anchorUptime = uptime
            anchorDate = now
            isCounting = true
        }
    }

    /// A delayed tick clips at exactly the last-touch + 60s deadline.
    func tick(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !blocked, validClock(now, uptime) else { return }
        _ = advance(now: now, uptime: uptime)
    }

    func seconds(for area: EffectiveStudyArea, on date: Date = Date()) -> TimeInterval {
        state.days[dayKey(date)]?[area.rawValue] ?? 0
    }
    func totalSeconds(for area: EffectiveStudyArea) -> TimeInterval {
        state.days.values.reduce(0) { $0 + ($1[area.rawValue] ?? 0) }
    }

    /// Flush the currently observed tail before returning an independently
    /// exportable JSON snapshot. A conflict, invalid prior file, or uncertain
    /// write fails closed; no unrelated learning file is read or modified.
    func exportData(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Data {
        guard !blocked else { throw EffectiveStudyTimeError.exportUnavailable }
        guard validClock(now, uptime) else { throw EffectiveStudyTimeError.invalidClock }
        guard advance(now: now, uptime: uptime) else { throw EffectiveStudyTimeError.exportUnavailable }
        if uncheckpointedSeconds > 0, !persist() { throw EffectiveStudyTimeError.exportUnavailable }
        do {
            try state.validate()
            try validateDirectory()
            if let durableData {
                guard FileManager.default.fileExists(atPath: fileURL.path), try readCurrent() == durableData else {
                    throw EffectiveStudyTimeError.concurrentChange
                }
                return durableData
            }
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw EffectiveStudyTimeError.concurrentChange
            }
            // Exporting an empty history does not create or overwrite a file.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(state)
        } catch {
            blocked = true
            self.error = error.localizedDescription
            anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
            throw error
        }
    }

    private func validClock(_ now: Date, _ uptime: TimeInterval) -> Bool {
        guard now.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0 else {
            error = EffectiveStudyTimeError.invalidClock.localizedDescription
            anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
            return false
        }
        if let anchorUptime, uptime < anchorUptime {
            error = EffectiveStudyTimeError.invalidClock.localizedDescription
            self.anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
            return false
        }
        if let lastTouchUptime, uptime < lastTouchUptime {
            error = EffectiveStudyTimeError.invalidClock.localizedDescription
            anchorUptime = nil; anchorDate = nil; self.lastTouchUptime = nil; isCounting = false
            return false
        }
        return true
    }

    @discardableResult private func advance(now: Date, uptime: TimeInterval) -> Bool {
        guard let area = visibleArea, let anchor = anchorUptime,
              let startDate = anchorDate, let lastTouch = lastTouchUptime else {
            isCounting = false
            return true
        }
        let deadline = lastTouch + Self.idleLimit
        guard deadline.isFinite else {
            error = EffectiveStudyTimeError.invalidClock.localizedDescription
            anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
            return false
        }
        let stop = min(uptime, deadline)
        let seconds = max(0, stop - anchor)
        if seconds > 0 {
            guard allocate(seconds, area: area, starting: startDate) else { return false }
            anchorUptime = stop
            let projected = startDate.addingTimeInterval(seconds)
            // Duration always comes from monotonic uptime. If the wall clock
            // jumps, preserve elapsed time, then anchor future days to `now`.
            anchorDate = (stop == uptime && abs(projected.timeIntervalSince(now)) > 5) ? now : projected
            uncheckpointedSeconds += seconds
        }
        isCounting = uptime < deadline
        if uncheckpointedSeconds >= Self.checkpointInterval || (!isCounting && uncheckpointedSeconds > 0) {
            return persist()
        }
        return true
    }

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    @discardableResult private func allocate(_ seconds: TimeInterval, area: EffectiveStudyArea, starting: Date) -> Bool {
        let end = starting.addingTimeInterval(seconds)
        var cursor = starting, next = state
        while cursor < end {
            guard let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor else {
                error = EffectiveStudyTimeError.invalidClock.localizedDescription
                anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
                return false
            }
            let stop = min(end, day.end), amount = stop.timeIntervalSince(cursor)
            guard amount.isFinite, amount > 0 else { return false }
            let key = dayKey(cursor), old = next.days[key]?[area.rawValue] ?? 0
            let total = old + amount
            guard total.isFinite, total <= 1_000_000_000 else {
                error = EffectiveStudyTimeError.invalidState.localizedDescription
                anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
                return false
            }
            next.days[key, default: [:]][area.rawValue] = total
            cursor = stop
        }
        state = next
        return true
    }

    private func validateDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let metadata = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { throw EffectiveStudyTimeError.invalidPath }
    }

    private func readCurrent() throws -> Data {
        let metadata = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw EffectiveStudyTimeError.invalidPath }
        guard (metadata.fileSize ?? Int.max) <= 4 * 1_024 * 1_024 else { throw EffectiveStudyTimeError.tooLarge }
        return try Data(contentsOf: fileURL)
    }

    @discardableResult private func persist() -> Bool {
        do {
            try state.validate()
            try validateDirectory()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try validateDirectory()
            if let durableData {
                guard FileManager.default.fileExists(atPath: fileURL.path), try readCurrent() == durableData else {
                    throw EffectiveStudyTimeError.concurrentChange
                }
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                throw EffectiveStudyTimeError.concurrentChange
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try writer(data, fileURL)
            guard try readCurrent() == data else { throw EffectiveStudyTimeError.incompleteWrite }
            durableData = data
            uncheckpointedSeconds = 0
            error = nil
            return true
        } catch {
            blocked = true
            self.error = error.localizedDescription
            anchorUptime = nil; anchorDate = nil; lastTouchUptime = nil; isCounting = false
            return false
        }
    }
}
