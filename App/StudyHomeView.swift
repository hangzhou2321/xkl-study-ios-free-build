import SwiftUI

/// Reads the existing study records and routes to their normal entry points.
struct StudyHomeView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var exams: ExamStore
    @ObservedObject var math: MathExperienceStore
    @ObservedObject var handbookComputer: HandbookWordStore
    @ObservedObject var handbookPower: HandbookWordStore
    @ObservedObject var handbookCircuit: HandbookWordStore
    @ObservedObject var handbookMechanics: HandbookWordStore
    @ObservedObject var flow: StudyFlowStore
    @ObservedObject var effectiveTime: EffectiveStudyTimeStore
    @ObservedObject var novelStore: StudyNovelStore
    @Binding var importing: Bool
    let visible: Bool
    let lastArea: EffectiveStudyArea?
    let day: Date
    let launch: (StudyArea, StudySegmentMode) -> Void
    let launchMath: () -> Void
    let readNovel: () -> Void

    @State private var actions: [StudyHomeAction] = []
    @State private var performed: [EffectiveStudyArea: String] = [:]
    @State private var chosenArea: EffectiveStudyArea?
    @State private var restUntil: TimeInterval?

    private var nextAction: StudyHomeAction? {
        if let chosen = actions.first(where: { $0.area == chosenArea }) { return chosen }
        let last = lastArea ?? flow.state.lastArea.flatMap { EffectiveStudyArea(rawValue: $0.rawValue) }
        return StudyHomeAction.next(in: actions, lastArea: last)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let restUntil {
                        breakCard(until: restUntil)
                    } else if let next = nextAction {
                        nextCard(next)
                    } else {
                        ContentUnavailableView("现在没有可继续的任务", systemImage: "checkmark.circle",
                                               description: Text("从底部打开任一科目查看进度。"))
                    }
                    if restUntil == nil && (!performed.isEmpty || novelStore.active?.nextUnread != nil) {
                        breakActions
                    }
                    if !performed.isEmpty {
                        doneList
                    }
                    EffectiveStudyTimeSummary(store: effectiveTime)
                        .padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 20))
                    if let error = flow.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("今天").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("记录") {
                        RecordsView(store: store, importing: $importing, effectiveTime: effectiveTime)
                    }
                }
            }
        }
        .onAppear { if visible { refresh() } }
        .onChange(of: visible) { _, active in
            if active { refresh() }
        }
        .onChange(of: day) { _, _ in if visible { refresh() } }
    }

    private func nextCard(_ action: StudyHomeAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("现在做一件事").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if actions.count > 1 || action.area != .math {
                    Menu {
                        if actions.count > 1 {
                            Section("换科目") {
                                ForEach(actions, id: \.area) { item in
                                    Button(item.area.title) { chosenArea = item.area }
                                }
                            }
                        }
                        if let area = StudyArea(rawValue: action.area.rawValue) {
                            Button("先学 5 分钟", systemImage: "timer") {
                                chosenArea = nil
                                launch(area, .fiveMinutes)
                            }.disabled(flow.state.needsBreak)
                        }
                    } label: {
                        Text(actions.count > 1 ? "换科目" : "更多")
                    }.font(.subheadline)
                }
            }
            Text(action.area.title).font(.title2.weight(.semibold))
            if let detail = detail(for: action) {
                Text(verbatim: detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Button { begin(action) } label: {
                Label(actionTitle(action), systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(flow.state.needsBreak)
            .accessibilityIdentifier("today-next-study")
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var breakActions: some View {
        HStack(spacing: 14) {
            if !performed.isEmpty {
                Button("休息 2 分钟", systemImage: "timer") {
                    restUntil = ProcessInfo.processInfo.systemUptime + 120
                }
            }
            if novelStore.active?.nextUnread != nil {
                Button("读已解锁的一章", systemImage: "book", action: readNovel)
            }
        }.buttonStyle(.bordered)
    }

    private func breakCard(until end: TimeInterval) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let left = max(0, Int(ceil(end - ProcessInfo.processInfo.systemUptime)))
            VStack(alignment: .leading, spacing: 12) {
                Text(left == 0 ? "休息结束" : "休息一下").font(.title2.weight(.semibold))
                if left > 0 {
                    Text("还剩 \(left / 60):\(String(format: "%02d", left % 60))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button(left == 0 ? "回到下一步" : "结束休息") { restUntil = nil; refresh() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var doneList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今天已做").font(.headline)
            ForEach(EffectiveStudyArea.allCases.filter { performed[$0] != nil }, id: \.rawValue) { area in
                HStack {
                    Label(area.title, systemImage: "checkmark")
                    Spacer()
                    Text(verbatim: performed[area] ?? "").foregroundStyle(.secondary)
                }.font(.subheadline)
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("today-done-list")
    }

    private func begin(_ action: StudyHomeAction) {
        chosenArea = nil
        if let area = StudyArea(rawValue: action.area.rawValue) {
            let mode = flow.state.activeArea == area ? flow.state.mode : .standard
            launch(area, mode)
        } else {
            launchMath()
        }
    }

    private func actionTitle(_ action: StudyHomeAction) -> String {
        switch action.area {
        case .vocabulary: return action.hasPosition ? "继续当前单词" : "先背 1 个单词"
        case .publicQuestions, .math: return action.hasPosition ? "继续当前题" : "先做 1 题"
        case .computer, .power, .circuit, .mechanics: return action.hasPosition ? "继续当前卡片" : "先背 1 张卡"
        }
    }

    private func detail(for action: StudyHomeAction) -> String? {
        if action.hasPosition {
            if let card = handbook(for: action.area)?.engine?.currentCard { return card.title }
            if action.area == .vocabulary, let word = store.currentWord { return word.word }
            if action.area == .publicQuestions && exams.isShowingResult { return "接着看刚才的解析" }
        }
        return action.due > 0 ? "先复习到期内容" : nil
    }

    private func handbook(for area: EffectiveStudyArea) -> HandbookWordStore? {
        switch area {
        case .computer: return handbookComputer
        case .power: return handbookPower
        case .circuit: return handbookCircuit
        case .mechanics: return handbookMechanics
        case .vocabulary, .publicQuestions, .math: return nil
        }
    }

    private func refresh() {
        let date = Date()
        var options: [StudyHomeAction] = []
        var done: [EffectiveStudyArea: String] = [:]

        let words = store.reviewCount(on: date)
        if words > 0 { done[.vocabulary] = "\(words) 次作答" }
        if let deck = store.deck, store.canLearn,
           store.info.has_task != 0 || store.dueTodayCount > 0 || Int(store.info.completed) + Int(store.info.familiar) < deck.words.count {
            options.append(.init(area: .vocabulary, hasPosition: store.info.has_task != 0, due: store.dueTodayCount))
        }

        if let day = try? ConceptCalendar.studyDay(date) {
            let answers = exams.novelAnswerHistory.lazy.filter { $0.day == UInt32(day) }.count
            if answers > 0 { done[.publicQuestions] = "\(answers) 次作答" }
        }
        let examPosition = exams.currentQuestion != nil || exams.isShowingResult
        if exams.bank != nil, !exams.storageBlocked,
           examPosition || exams.totalRemaining > 0 || exams.dueTodayCount > 0 || exams.unseenQuestionCount > 0 {
            options.append(.init(area: .publicQuestions, hasPosition: examPosition, due: exams.dueTodayCount))
        }

        if let engine = math.engine, !math.blocked {
            let today = Calendar.current.startOfDay(for: date)
            let undone = Set(engine.events.lazy.filter { $0.kind == "undo" }.compactMap(\.target))
            let grades = engine.events.lazy.filter {
                $0.timestamp >= today && $0.timestamp <= date && !undone.contains($0.id)
            }
            let problems = grades.filter { $0.kind == "grade" }.count
            let cards = grades.filter { $0.kind == "card-grade" }.count
            if problems > 0 || cards > 0 {
                done[.math] = [
                    problems > 0 ? "\(problems) 次做题自评" : nil,
                    cards > 0 ? "\(cards) 次背卡自评" : nil
                ].compactMap { $0 }.joined(separator: " · ")
            }
            if math.guide != nil, math.practiceQuestionCount > 0 {
                let saved = engine.current != nil && math.currentPracticeBlockedReason == nil
                if engine.current == nil || saved {
                    options.append(.init(area: .math, hasPosition: saved, due: 0))
                }
            }
        }

        for area in EffectiveStudyArea.allCases {
            guard let store = handbook(for: area), !store.blocked, let engine = store.engine else { continue }
            let stats = engine.stats(on: date)
            if stats.ratedToday > 0 { done[area] = "\(stats.ratedToday) 次背卡自评" }
            if engine.presentation != nil || stats.remainingToday > 0 || stats.due > 0 || stats.unseen > 0 {
                options.append(.init(area: area, hasPosition: engine.presentation != nil, due: stats.due))
            }
        }
        actions = options
        performed = done
    }
}
