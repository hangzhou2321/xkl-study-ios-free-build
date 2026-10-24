import Foundation
import Combine

enum StudyArea: String, Codable, CaseIterable {
    case vocabulary, publicQuestions, computer, power

    var title: String {
        switch self {
        case .vocabulary: return "单词"
        case .publicQuestions: return "公共题库"
        case .computer: return "计算机"
        case .power: return "电力系统"
        }
    }

    var tab: Int {
        switch self {
        case .vocabulary: return 0
        case .publicQuestions: return 3
        case .computer, .power: return 4
        }
    }
}

enum StudySegmentMode: String, Codable {
    case standard, fiveMinutes
}

struct StudyFlowState: Codable, Equatable {
    var format = "xkl-study-flow-v1"
    var lastArea: StudyArea?
    var activeArea: StudyArea?
    var mode: StudySegmentMode = .standard
    var elapsedSeconds: Double = 0
    var isPaused = true
    var needsBreak = false
    var lastActivityAt: Date?
    var segmentID: UUID?
    /// Total allowed foreground seconds in this segment, including explicit
    /// extensions. Nil means the ordinary, untimed mode.
    var budgetSeconds: Double?

    var remainingSeconds: Double? {
        budgetSeconds.map { max(0, $0 - elapsedSeconds) }
    }

    fileprivate func validate() throws {
        guard format == "xkl-study-flow-v1",
              elapsedSeconds.isFinite, elapsedSeconds >= 0,
              lastActivityAt?.timeIntervalSince1970.isFinite ?? true else {
            throw StudyFlowError.invalidState
        }
        if activeArea == nil {
            guard segmentID == nil, mode == .standard, elapsedSeconds == 0,
                  budgetSeconds == nil, isPaused, !needsBreak else {
                throw StudyFlowError.invalidState
            }
        } else {
            guard segmentID != nil, lastArea == activeArea else { throw StudyFlowError.invalidState }
            switch mode {
            case .standard:
                guard budgetSeconds == nil, !needsBreak else { throw StudyFlowError.invalidState }
            case .fiveMinutes:
                guard let budgetSeconds, budgetSeconds.isFinite, budgetSeconds >= 300,
                      elapsedSeconds <= budgetSeconds,
                      needsBreak == (elapsedSeconds >= budgetSeconds),
                      !needsBreak || isPaused else { throw StudyFlowError.invalidState }
            }
        }
    }
}

private enum StudyFlowError: LocalizedError {
    case invalidState, invalidClock, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidState: return "学习段文件无法核对，已保留原文件。"
        case .invalidClock: return "本次计时来源无效，计时已暂停。"
        case .tooLarge: return "学习段文件大小异常，已保留原文件。"
        }
    }
}

/// Navigation and voluntary short-session timing only. This class has no
/// reference to vocabulary, exam or concept engines and cannot change grades,
/// due dates, familiarity, question selection or learning history.
///
/// The caller supplies `tick` regularly (normally once per second), and marks
/// visible only while the actual practice screen is foreground. Monotonic
/// uptime supplies durations; `now` is descriptive metadata, never a duration.
/// Checkpoints occur at boundaries and every 15 observed foreground seconds.
/// Restart loads the last checkpoint paused; unobserved/offline time is never
/// reconstructed. A forced exit can lose the uncheckpointed tail.
@MainActor
final class StudyFlowStore: ObservableObject {
    @Published private(set) var state = StudyFlowState()
    @Published private(set) var error: String?

    static let checkpointSeconds: Double = 15
    static let timingNotice = "只计算前台练习时间，每 15 秒保存一次。异常退出后保留最近保存的计时，未观测的时间不补计。"

    private let fileURL: URL
    private let writer: (Data, URL) throws -> Void
    private var visible = false
    private var anchorUptime: TimeInterval?
    private var checkpointElapsed: Double = 0
    private var invalidExistingFile = false

    init(baseDirectory: URL? = nil, writer: ((Data, URL) throws -> Void)? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.fileURL = base.appendingPathComponent("StudyFlow", isDirectory: true)
            .appendingPathComponent("current.json")
        self.writer = writer ?? { data, url in try data.write(to: url, options: .atomic) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1_024 else { throw StudyFlowError.tooLarge }
            var restored = try JSONDecoder().decode(StudyFlowState.self, from: Data(contentsOf: fileURL))
            try restored.validate()
            // Uptime anchors deliberately never survive process lifetime.
            restored.isPaused = true
            state = restored
            checkpointElapsed = restored.elapsedSeconds
        } catch {
            invalidExistingFile = true
            self.error = error.localizedDescription
        }
    }

    /// Same area/mode means continue, preserving elapsed time and budget.
    /// Choosing a different mode explicitly starts a new segment.
    func begin(area: StudyArea, mode: StudySegmentMode = .standard, now: Date = Date(),
               uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if state.activeArea == area, state.mode == mode {
            resume(now: now, uptime: uptime)
        } else {
            startNewSegment(area: area, mode: mode, now: now, uptime: uptime)
        }
    }

    /// Following an already-open practice screen is navigation within the
    /// current segment, not a fresh budget. In particular, changing tabs cannot
    /// reset a five-minute limit or bypass a pause/break.
    func followNavigation(to area: StudyArea, now: Date = Date(),
                          uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, validClock(now, uptime) else { return }
        guard state.activeArea != nil else {
            begin(area: area, mode: .standard, now: now, uptime: uptime)
            return
        }
        guard advance(now: now, uptime: uptime) else { return }
        guard state.activeArea != area else { return }
        var next = state
        next.activeArea = area
        next.lastArea = area
        next.lastActivityAt = now
        if persist(next) {
            anchorUptime = visible && !next.isPaused && !next.needsBreak ? uptime : nil
        }
    }

    /// An explicit home-screen choice, e.g. standard -> "today, just 5 minutes".
    /// Reopening an existing five-minute segment never resets its remaining
    /// time. A completed timer needs extendFiveMinutes or finish first.
    func startNewSegment(area: StudyArea, mode: StudySegmentMode, now: Date = Date(),
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, !state.needsBreak, validClock(now, uptime) else { return }
        if state.activeArea == area, state.mode == .fiveMinutes, mode == .fiveMinutes {
            resume(now: now, uptime: uptime)
            return
        }
        guard advance(now: now, uptime: uptime), !state.needsBreak else { return }
        var next = StudyFlowState()
        next.lastArea = area
        next.activeArea = area
        next.mode = mode
        next.isPaused = false
        next.lastActivityAt = now
        next.segmentID = UUID()
        next.budgetSeconds = mode == .fiveMinutes ? 300 : nil
        if persist(next) { anchorUptime = visible ? uptime : nil }
    }

    func resume(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, state.activeArea != nil, !state.needsBreak,
              validClock(now, uptime), advance(now: now, uptime: uptime), !state.needsBreak else { return }
        var next = state
        next.isPaused = false
        next.lastActivityAt = now
        if persist(next) { anchorUptime = visible ? uptime : nil }
    }

    func pause(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, state.activeArea != nil,
              validClock(now, uptime), advance(now: now, uptime: uptime) else { return }
        var next = state
        next.isPaused = true
        next.lastActivityAt = now
        anchorUptime = nil
        _ = persist(next)
    }

    func extendFiveMinutes(now: Date = Date(),
                           uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, state.activeArea != nil, state.mode == .fiveMinutes,
              validClock(now, uptime), advance(now: now, uptime: uptime),
              let oldBudget = state.budgetSeconds else { return }
        var next = state
        next.budgetSeconds = oldBudget + 300
        next.needsBreak = false
        next.isPaused = false
        next.lastActivityAt = now
        if persist(next) { anchorUptime = visible ? uptime : nil }
    }

    /// Visibility controls the clock independently of an explicit user pause.
    /// Returning to a practice view resumes only a segment that was not paused.
    func setVisible(_ isVisible: Bool, now: Date = Date(),
                    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, validClock(now, uptime) else { return }
        guard visible != isVisible else {
            tick(now: now, uptime: uptime)
            return
        }
        guard advance(now: now, uptime: uptime) else {
            visible = isVisible
            anchorUptime = nil
            return
        }
        visible = isVisible
        anchorUptime = nil
        guard state.activeArea != nil else { return }
        // Flush an observed foreground tail before allowing an app suspension.
        if persist(state), visible, !state.isPaused, !state.needsBreak {
            anchorUptime = uptime
        }
    }

    func tick(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, validClock(now, uptime) else { return }
        _ = advance(now: now, uptime: uptime)
    }

    /// Ends this metadata segment; does not complete, grade or reset a lesson.
    func finish(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !invalidExistingFile, validClock(now, uptime), advance(now: now, uptime: uptime) else { return }
        var next = StudyFlowState()
        next.lastArea = state.activeArea ?? state.lastArea
        next.lastActivityAt = now
        anchorUptime = nil
        _ = persist(next)
    }

    func clearError() {
        if !invalidExistingFile { error = nil }
    }

    private func validClock(_ now: Date, _ uptime: TimeInterval) -> Bool {
        guard now.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0 else {
            error = StudyFlowError.invalidClock.localizedDescription
            state.isPaused = true
            anchorUptime = nil
            return false
        }
        return true
    }

    @discardableResult
    private func advance(now: Date, uptime: TimeInterval) -> Bool {
        guard visible, state.activeArea != nil, !state.isPaused, !state.needsBreak else {
            anchorUptime = nil
            return true
        }
        guard let previous = anchorUptime else {
            anchorUptime = uptime
            return true
        }
        guard uptime >= previous else {
            // Never substitute wall time when monotonic observation is invalid.
            error = StudyFlowError.invalidClock.localizedDescription
            state.isPaused = true
            anchorUptime = nil
            _ = persist(state, clearingError: false)
            return false
        }
        anchorUptime = uptime
        let delta = uptime - previous
        guard delta > 0 else { return true }
        var next = state
        next.elapsedSeconds += delta
        guard next.elapsedSeconds.isFinite else {
            error = StudyFlowError.invalidClock.localizedDescription
            state.isPaused = true
            anchorUptime = nil
            return false
        }
        next.lastActivityAt = now
        if let budget = next.budgetSeconds, next.elapsedSeconds >= budget {
            next.elapsedSeconds = budget
            next.needsBreak = true
            next.isPaused = true
            anchorUptime = nil
            // Keep the observed deadline latched in memory even if disk fails;
            // a save error must not permit resume to continue past the limit.
            state = next
            return persist(next)
        }
        state = next
        if next.elapsedSeconds - checkpointElapsed >= Self.checkpointSeconds {
            return persist(next)
        }
        return true
    }

    @discardableResult
    private func persist(_ next: StudyFlowState, clearingError: Bool = true) -> Bool {
        do {
            try next.validate()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            try writer(data, fileURL)
            state = next
            checkpointElapsed = next.elapsedSeconds
            if clearingError { error = nil }
            return true
        } catch {
            // Keep the previous area/segment and its original file. Pause the
            // in-memory timer; a later explicit boundary can retry saving.
            self.error = "学习段未能保存：" + error.localizedDescription + " 原学习成绩和记录未改动。"
            state.isPaused = true
            anchorUptime = nil
            return false
        }
    }
}
