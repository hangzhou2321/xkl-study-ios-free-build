import SwiftUI
import UniformTypeIdentifiers

/// Reads the existing study records and routes to their normal entry points.
struct StudyHomeView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var exams: ExamStore
    @ObservedObject var math: MathExperienceStore
    @ObservedObject var handbookComputer: HandbookWordStore
    @ObservedObject var handbookPower: HandbookWordStore
    @ObservedObject var handbookCircuit: HandbookWordStore
    @ObservedObject var handbookMechanics: HandbookWordStore
    @ObservedObject var refinedComputer: RefinedMemoryStore
    @ObservedObject var refinedPower: RefinedMemoryStore
    let useRefinedComputer: Bool
    let useRefinedPower: Bool
    @ObservedObject var flow: StudyFlowStore
    @ObservedObject var effectiveTime: EffectiveStudyTimeStore
    @ObservedObject var hourly: HourlyStudyTracker
    @Binding var importing: Bool
    let visible: Bool
    let lastArea: EffectiveStudyArea?
    let day: Date
    let launch: (StudyArea, StudySegmentMode) -> Void
    let launchMath: () -> Void
    let openHour: (HourlyStudyPlan.Window, EffectiveStudyArea, Int?, Bool) -> Void

    @State private var actions: [StudyHomeAction] = []
    @State private var chosenArea: EffectiveStudyArea?
    @State private var firstPassByArea: [EffectiveStudyArea: Int] = [:]
    @State private var importingSchedule = false
    @State private var choosingWindow: HourlyStudyPlan.Window?
    @State private var choosingTarget = 0

    private var choices: [EffectiveStudyArea] {
        EffectiveStudyArea.allCases.filter { (cardsRemaining[$0.rawValue] ?? 0) > 0 }
    }

    private var cardsRemaining: [String: Int] {
        var subjects = Dictionary(uniqueKeysWithValues: firstPassByArea.compactMap { (area, count) in
            [.computer, .power].contains(area) ? (area.rawValue, count) : nil
        })
        if math.guide != nil { subjects["math"] = math.formulaFirstPassIDs.count }
        return subjects
    }

    private var nextAction: StudyHomeAction? {
        if let chosen = actions.first(where: { $0.area == chosenArea }) { return chosen }
        let last = lastArea ?? flow.state.lastArea.flatMap { EffectiveStudyArea(rawValue: $0.rawValue) }
        return StudyHomeAction.next(in: actions, lastArea: last)
    }

    private var paceArea: EffectiveStudyArea? {
        guard !flow.state.needsBreak, let area = nextAction?.area,
              area != .circuit, area != .mechanics else { return nil }
        return area
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if flow.state.needsBreak { completedTimedSegment }
                    if hourly.schedule == nil && !actions.isEmpty {
                        Picker("配速科目", selection: Binding(get: { nextAction?.area }, set: { chosenArea = $0 })) {
                            ForEach(actions, id: \.area) { action in
                                Text(action.area.title).tag(Optional(action.area))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    HourlyStudyBoard(tracker: hourly, subject: paceArea,
                                     unit: nextAction?.area == .publicQuestions || nextAction?.area == .math ? "题" : "张",
                                     unseen: nextAction.flatMap { firstPassByArea[$0.area] },
                                     remainingFirstPass: cardsRemaining, enabled: !flow.state.needsBreak,
                                     open: { window, area in openHour(window, area, nil, false) },
                                     choose: { window, target in
                                         choosingTarget = target
                                         choosingWindow = window
                                     })
                    if let next = nextAction, !flow.state.needsBreak { nextCard(next) }
                    if !flow.state.needsBreak {
                        HStack {
                            Button("电路解题课") { launch(.circuit, .standard) }
                            Spacer()
                            Button("力学解题课") { launch(.mechanics, .standard) }
                        }
                        .font(.subheadline).buttonStyle(.bordered)
                        Text("电路、力学的原题进度在解题课内查看，不计入背卡首轮张数。")
                            .font(.caption).foregroundStyle(.secondary)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("导入小时计划") { importingSchedule = true }
                        .font(.footnote)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("记录") {
                        RecordsView(store: store, importing: $importing, effectiveTime: effectiveTime)
                    }
                }
            }
        }
        .confirmationDialog("先背哪一科", isPresented: Binding(
            get: { choosingWindow != nil }, set: { if !$0 { choosingWindow = nil } }
        ), titleVisibility: .visible, presenting: choosingWindow) { window in
            ForEach(choices, id: \.self) { area in
                Button("\(area.title) · 剩 \(cardsRemaining[area.rawValue] ?? 0) 张") {
                    openHour(window, area, choosingTarget, true)
                }
            }
        }
        .fileImporter(isPresented: $importingSchedule, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): hourly.importSchedule(url)
            case .failure(let error): hourly.scheduleError = error.localizedDescription
            }
        }
        .alert("小时计划", isPresented: Binding(get: { hourly.scheduleError != nil },
                                               set: { if !$0 { hourly.scheduleError = nil } })) {
            Button("知道了", role: .cancel) { hourly.scheduleError = nil }
        } message: { Text(hourly.scheduleError ?? "") }
        .onAppear { if visible { refresh(); hourly.reloadSchedule() } }
        .onChange(of: visible) { _, active in
            if active { refresh() }
        }
        .onChange(of: useRefinedComputer) { _, _ in if visible { refresh() } }
        .onChange(of: useRefinedPower) { _, _ in if visible { refresh() } }
        .onChange(of: refinedComputer.presentation?.id) { _, _ in if visible { refresh() } }
        .onChange(of: refinedPower.presentation?.id) { _, _ in if visible { refresh() } }
        .onChange(of: day) { _, _ in if visible { refresh() } }
        .onChange(of: hourly.schedule?.deadline) { _, _ in if visible { refresh() } }
    }

    private func nextCard(_ action: StudyHomeAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自由学习").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let area = StudyArea(rawValue: action.area.rawValue) {
                    Button("先学 5 分钟", systemImage: "timer") {
                        launch(area, .fiveMinutes)
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

    private var completedTimedSegment: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这 5 分钟结束了").font(.title2.weight(.semibold))
            Button("结束这一段") { flow.finish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
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
        case .circuit, .mechanics: return "进入解题课"
        case .computer, .power: return action.hasPosition ? "继续当前卡片" : "先背 1 张卡"
        }
    }

    private func detail(for action: StudyHomeAction) -> String? {
        if action.area == .circuit || action.area == .mechanics { return "讲义例题、原题与纸上练习" }
        if let refined = selectedRefined(action.area) {
            return refined.engine?.currentItem?.card.prompt ?? (action.due > 0 ? "新版逐问背卡 · 先复习到期内容" : "新版逐问背卡")
        }
        if action.hasPosition {
            if let card = handbook(for: action.area)?.engine?.currentCard { return card.title }
            if action.area == .vocabulary, let word = store.currentWord { return word.word }
            if action.area == .publicQuestions && exams.isShowingResult { return "接着看刚才的解析" }
        }
        return action.due > 0 ? "先复习到期内容" : nil
    }

    private func selectedRefined(_ area: EffectiveStudyArea) -> RefinedMemoryStore? {
        if area == .computer && useRefinedComputer { return refinedComputer }
        if area == .power && useRefinedPower { return refinedPower }
        return nil
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
        var firstPass: [EffectiveStudyArea: Int] = [:]
        firstPass[.vocabulary] = store.firstPassRemaining
        if let deck = store.deck, store.canLearn,
           store.info.has_task != 0 || store.dueTodayCount > 0 || Int(store.info.completed) + Int(store.info.familiar) < deck.words.count {
            options.append(.init(area: .vocabulary, hasPosition: store.info.has_task != 0, due: store.dueTodayCount))
        }

        if exams.bank != nil, !exams.storageBlocked { firstPass[.publicQuestions] = exams.unseenQuestionCount }
        let examPosition = exams.currentQuestion != nil || exams.isShowingResult
        if exams.bank != nil, !exams.storageBlocked,
           examPosition || exams.totalRemaining > 0 || exams.dueTodayCount > 0 || exams.unseenQuestionCount > 0 {
            options.append(.init(area: .publicQuestions, hasPosition: examPosition, due: exams.dueTodayCount))
        }

        if let engine = math.engine, !math.blocked {
            if let guide = math.guide {
                let eligible = Set(engine.baseline.content.questions.filter(\.eligible).map(\.id))
                    .intersection(guide.questions.filter(\.practiceAllowed).map(\.questionID))
                let retracted = Set(engine.events.lazy.filter { $0.kind == "undo" }.compactMap(\.target))
                let old = engine.baseline.events.lazy.filter { $0.kind == "grade" || $0.kind == "familiar" }.map(\.questionID)
                let records = engine.events.lazy.filter {
                    ($0.kind == "grade" || $0.kind == "familiar") && !retracted.contains($0.id)
                }.compactMap(\.questionID)
                firstPass[.math] = eligible.subtracting(Set(old).union(records)).count
            }
            if math.guide != nil, math.practiceQuestionCount > 0 {
                let saved = engine.current != nil && math.currentPracticeBlockedReason == nil
                if engine.current == nil || saved {
                    options.append(.init(area: .math, hasPosition: saved, due: 0))
                }
            }
        }

        for area in EffectiveStudyArea.allCases {
            if area == .circuit || area == .mechanics {
                // The native shelf opens the bundled question course. Its WebKit history
                // is measured there; archived handbook card counts are a different unit.
                options.append(.init(area: area, hasPosition: false, due: 0))
                continue
            }
            if let refined = selectedRefined(area) {
                guard !refined.blocked, let stats = refined.stats(on: date) else { continue }
                firstPass[area] = refined.firstPassRemaining
                if refined.presentation != nil || stats.due > 0 || stats.unintroduced > 0 {
                    options.append(.init(area: area, hasPosition: refined.presentation != nil, due: stats.due))
                }
                continue
            }
            guard let store = handbook(for: area), !store.blocked, let engine = store.engine else { continue }
            let stats = engine.stats(on: date)
            firstPass[area] = engine.firstPassRemaining(includingShortBook: hourly.schedule != nil)
            let short = engine.shortBookScope
            if engine.presentation != nil || stats.remainingToday > 0 || stats.due > 0 || stats.unseen > 0 ||
                (!engine.package.usesComputerCompactScope && short.active != short.all) {
                options.append(.init(area: area, hasPosition: engine.presentation != nil, due: stats.due))
            }
        }
        actions = options
        firstPassByArea = firstPass
    }
}
