import SwiftUI

struct HourlyStudyWarmup: Identifiable {
    let id: Date
    let title: String
    let cue: String
    let answer: String

    init(window: HourlyStudyPlan.Window, title: String, card: HandbookCard? = nil) {
        id = window.start
        self.title = title
        if let card {
            cue = card.prompt
            answer = card.answerSummary
        } else {
            let examples = [("3 × 2", "6"), ("9 − 4", "5"), ("18 ÷ 3", "6"), ("7 + 8", "15"),
                            ("8 × 4", "32"), ("21 ÷ 7", "3"), ("12 − 7", "5"), ("6 + 9", "15"),
                            ("20 ÷ 5", "4"), ("3 × 7", "21")]
            (cue, answer) = examples[window.endingHour - 14]
        }
    }
}

@MainActor
final class HourlyStudyTracker: ObservableObject {
    @Published private(set) var plan = HourlyStudyPlan()
    @Published private(set) var storageError = false
    @Published private(set) var schedule: FirstPassSchedule?
    @Published var scheduleError: String?
    @Published var warmup: HourlyStudyWarmup?
    @Published private(set) var active: HourlyStudyPlan.Slot?
    @Published private(set) var settled: HourlyStudyPlan.Slot?
    private let file: URL
    private let scheduleFile: URL
    private let writer = DispatchQueue(label: "local.xkl.study.hourly-plan")
    private let live = StudyPaceActivity()
    private var lookup: CardLookupSession?
    private var finishTask: Task<Void, Never>?
    private var foreground = true
    private var blocked = false
    private var timingArea: String?
    private var engagedSince: TimeInterval?
    private var accumulated = 0.0

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = support.appendingPathComponent("HourlyStudyPlan/slots.json")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        scheduleFile = documents.appendingPathComponent("FirstPassDeadline/plan.json")
        reloadSchedule()
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { plan = try JSONDecoder().decode(HourlyStudyPlan.self, from: Data(contentsOf: file)) }
        catch { storageError = true; blocked = true }
    }

    func reloadSchedule() {
        guard FileManager.default.fileExists(atPath: scheduleFile.path),
              let data = try? Data(contentsOf: scheduleFile),
              let next = try? FirstPassSchedule.load(data),
              schedule?.assignments != next.assignments else { return }
        schedule = next
    }

    func importSchedule(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let validated = try FirstPassSchedule.load(data)
            try FileManager.default.createDirectory(at: scheduleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: scheduleFile, options: .atomic)
            schedule = validated
        } catch { scheduleError = error.localizedDescription }
    }

    func open(_ window: HourlyStudyPlan.Window, area: EffectiveStudyArea, card: HandbookCard?,
              firstPassTarget: Int? = nil, now: Date = .now) {
        guard !blocked, window.start <= now, now < window.end else { return }
        let started = plan.begin(window, area: area.rawValue, at: now, firstPassTarget: firstPassTarget)
        guard let slot = plan.slot(window), slot.area == area.rawValue else { return }
        if started { save() }
        settled = nil
        if active?.start != slot.start { timeVisible(nil); accumulated = 0 }
        active = slot
        if slot.firstCardInteraction == nil {
            warmup = HourlyStudyWarmup(window: window, title: area.title, card: card)
        }
        armDeadline(until: window.end, now: now)
        syncLive(now: now)
    }

    func warmupInteraction(now: Date = .now) {
        guard let active, let area = active.area,
              let window = HourlyStudyPlan.window(at: now), active.start == window.start else { return }
        if plan.interact(window, area: area, at: now, warmup: true) {
            self.active = plan.slot(window)
            save()
        }
    }

    func closeWarmup() {
        warmup = nil
    }

    func ordinaryInteraction(area: EffectiveStudyArea, now: Date = .now) {
        guard !blocked, let window = HourlyStudyPlan.window(at: now),
              plan.slot(window)?.ordinaryFirstInteraction == nil,
              plan.slot(window)?.area == nil else { return }
        if plan.interact(window, area: area.rawValue, at: now, warmup: false) { save() }
    }

    func scene(active foreground: Bool, now: Date = .now) {
        self.foreground = foreground
        if foreground { reloadSchedule() } else { timeVisible(nil) }
        settleIfDue(now: now)
        syncLive(now: now)
    }

    func timeVisible(_ area: EffectiveStudyArea?) {
        let next = area?.rawValue
        guard next != timingArea else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if let began = engagedSince { accumulated += max(0, time - began) }
        timingArea = next
        engagedSince = next == active?.area && next != nil ? time : nil
    }

    func record(_ answer: HourlyStudyAnswer) {
        guard !blocked, let itemID = answer.itemID, let window = HourlyStudyPlan.window(at: answer.at),
              active?.start == window.start, active?.area == answer.area else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let interval = accumulated + (engagedSince.map { max(0, time - $0) } ?? 0)
        if plan.record(window, area: answer.area, itemID: itemID, at: answer.at,
                       activeSeconds: interval > 0 ? interval : nil, firstPass: answer.firstPass) {
            accumulated = 0
            engagedSince = timingArea == answer.area ? time : nil
            active = plan.slot(window)
            save()
            syncLive(now: .now)
        }
    }

    func settleIfDue(now: Date = .now) {
        guard let slot = active, now >= slot.end else { return }
        settled = slot
        active = nil
        warmup = nil
        engagedSince = nil
        accumulated = 0
        syncLive(now: now)
    }

    func setLookup(_ session: CardLookupSession?, now: Date = .now) {
        lookup = session
        syncLive(now: now)
    }

    func dismissSettlement() { settled = nil }

    private func armDeadline(until deadline: Date, now: Date) {
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now)))) }
            catch { return }
            guard let self else { return }
            let current = Date()
            if current < deadline { self.armDeadline(until: deadline, now: current) }
            else { self.settleIfDue(now: current) }
        }
    }

    private func syncLive(now: Date) {
        live.sync(slot: active, subject: active?.area.flatMap { EffectiveStudyArea(rawValue: $0)?.title },
                  lookup: lookup, away: !foreground, now: now)
    }

    private func save() {
        let snapshot = plan
        let destination = file
        writer.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
            } catch {
                Task { @MainActor [weak self] in self?.storageError = true }
            }
        }
    }
}

struct HourlyStudyBoard: View {
    @ObservedObject var tracker: HourlyStudyTracker
    let subject: EffectiveStudyArea?
    let unit: String
    let unseen: Int?
    let remainingFirstPass: [String: Int]
    let enabled: Bool
    let open: (HourlyStudyPlan.Window, EffectiveStudyArea, Int?) -> Void

    var body: some View {
        TimelineView(.periodic(from: Calendar.current.startOfDay(for: .now), by: 60)) { context in
            let now = context.date
            let plan = tracker.plan
            let delivery = plan.delivery(on: now)
            let datedPlan = tracker.schedule.flatMap { $0.includesDay(now) ? $0 : nil }
            let today = datedPlan?.rows(on: now) ?? []
            let plannedLeft = today.reduce(0) { $0 + max(0, $1.cards - plan.firstPassCredit(at: $1.start, subject: $1.subject)) }
            let flexibleCredit = HourlyStudyPlan.windows(on: now).filter(\.flexible).reduce(0) { sum, window in
                guard let slot = plan.slot(window), slot.firstPassOnly == true else { return sum }
                return sum + slot.credited
            }
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text("今天的配速").font(.headline)
                    Spacer()
                    if let deadline = datedPlan?.deadline {
                        Text(deadline, format: .dateTime.month().day().hour().minute())
                            .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("准点 \(delivery.completed)/\(delivery.total)").font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if datedPlan != nil {
                    Text("今天计划还差 \(max(0, plannedLeft - flexibleCredit)) 张")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text("五科剩余 \(remainingFirstPass.values.reduce(0, +)) 张 · 只计首轮自评")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("今日还差 \(plan.remaining(on: now)) 张／题")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                }
                if datedPlan == nil, let subject, let unseen {
                    if let eta = plan.firstPassETA(unseen: unseen, now: now) {
                        Text("\(subject.title)还有 \(unseen)\(unit)未过首轮 · 预计 \(eta.formatted(.dateTime.month().day().hour()))")
                            .font(.subheadline)
                        Text("按此后核心小时槽每轮完成 6\(unit)新内容估算")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if unseen == 0 {
                        Text("\(subject.title)首轮已过").font(.subheadline)
                    }
                }
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    ForEach(HourlyStudyPlan.windows(on: now)) { window in
                        cell(window, now: now, schedule: datedPlan)
                    }
                }
                metricSummary(plan.latencyComparison(on: now))
                if tracker.storageError {
                    Label("配速记录写入有异常，课程进度仍由原学习页面保存。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func cell(_ window: HourlyStudyPlan.Window, now: Date, schedule: FirstPassSchedule?) -> some View {
        let slot = tracker.plan.slot(window)
        let assigned = schedule?.assignment(for: window, in: tracker.plan, remaining: remainingFirstPass)
        let storedArea = slot?.area.flatMap(EffectiveStudyArea.init(rawValue:))
        let plannedArea = assigned.flatMap { EffectiveStudyArea(rawValue: $0.subject) }
        let area = storedArea ?? (schedule == nil ? subject : plannedArea)
        let target = storedArea != nil ? (slot?.target ?? 0)
            : (schedule == nil ? tracker.plan.target(for: window) : assigned?.cards ?? 0)
        let current = window.start <= now && now < window.end
        let closed = now >= window.end
        let credited = slot?.credited ?? 0
        return Button {
            if let area, target > 0 {
                let isFirstPass = storedArea != nil ? slot?.firstPassOnly == true : schedule != nil
                open(window, area, isFirstPass ? target : nil)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(window.endingHour - 1):00–\(window.endingHour):00")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Spacer(minLength: 4)
                    if current, area != nil, target > 0 {
                        Image(systemName: "arrow.right.circle.fill").accessibilityHidden(true)
                    }
                }
                let label = schedule != nil && area != nil ? (area?.title ?? "") + " · " : ""
                Text(target == 0 ? (window.flexible ? "弹性 · 补交" : "未排课")
                     : window.flexible ? label + "补交 \(credited)/\(target)"
                     : label + (closed ? "封盘 " : "") + "\(credited)/\(target)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(current ? Color.teal : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(current ? Color.teal.opacity(0.15) : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !current || area == nil || target == 0)
    }

    private func metricSummary(_ metrics: (guided: [Int], ordinary: [Int])) -> some View {
        DisclosureGroup("看启动数据") {
            VStack(alignment: .leading, spacing: 6) {
                Text("统计最近 14 天。准点目标为核心时段每天至少 6/8。")
                Text("配速启动 \(mean(metrics.guided))")
                Text("普通学习启动 \(mean(metrics.ordinary))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private func mean(_ samples: [Int]) -> String {
        guard !samples.isEmpty else { return "暂无样本" }
        let seconds = samples.reduce(0, +) / samples.count
        return "平均 \(seconds / 60)分\(seconds % 60)秒（\(samples.count) 个时段）"
    }
}

struct HourlyStudyHeader: View {
    let slot: HourlyStudyPlan.Slot
    var body: some View {
        TimelineView(.periodic(from: slot.start, by: 1)) { context in
            let seconds = max(0, Int(ceil(slot.end.timeIntervalSince(context.date))))
            let margin = slot.paceMargin(at: context.date)
            HStack(spacing: 8) {
                Text("距离整点封盘 \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                Divider().frame(height: 13)
                if slot.credited == slot.target { Text("已交付").foregroundStyle(.teal) }
                else if let margin {
                    Text(String(format: "配速 %+.0f秒", Double(margin)))
                        .foregroundStyle(margin < 0 ? Color.orange : Color.teal)
                } else { Text("配速采样中").foregroundStyle(.secondary) }
            }
            .font(.footnote.monospacedDigit())
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
}

struct HourlyStudyProgress: View {
    let slot: HourlyStudyPlan.Slot
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(12, max(HourlyStudyPlan.goal, slot.target)), id: \.self) { step in
                let lit = slot.target <= 12 ? slot.credited : slot.credited * 12 / slot.target
                Capsule().fill(step < lit ? Color.teal
                    : step < slot.target ? Color.secondary.opacity(0.24) : Color.secondary.opacity(0.1))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 5)
        .animation(.easeOut(duration: 0.14), value: slot.credited)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本轮完成 \(slot.credited) / \(slot.target)")
    }
}

struct HourlyStudyWarmupView: View {
    let card: HourlyStudyWarmup
    let touched: () -> Void
    let continueStudy: () -> Void
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(card.title + " · 暖机首卡").font(.subheadline).foregroundStyle(.secondary)
            Text(card.cue).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if revealed { Text(card.answer).font(.title3).foregroundStyle(.teal) }
            Button(revealed ? "进入本轮" : "翻答案", systemImage: revealed ? "arrow.right" : "rectangle.on.rectangle") {
                if revealed { continueStudy() }
                else { touched(); revealed = true }
            }
            .buttonStyle(.borderedProminent).tint(.teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
