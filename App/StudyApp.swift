import SwiftUI
import UniformTypeIdentifiers
import UIKit
import StudyCore

#if DEBUG
@main
struct StudyApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--handbook-card-preview") {
                HandbookCardPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--professional-question-preview") {
                ProfessionalQuestionPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--professional-preview") {
                ProfessionalPriorityPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--math-experience-preview") {
                MathExperiencePreview()
            } else if ProcessInfo.processInfo.arguments.contains("--math-reader-preview") {
                MathReaderPreview()
            } else { StudyApplicationRoot() }
        }
    }
}

private struct StudyApplicationRoot: View {
    @StateObject private var store = StudyStore()
    @StateObject private var examStore = ExamStore()
    @StateObject private var conceptStore = ConceptStore()
    @StateObject private var powerStore = ConceptStore(subject: .power)
    @StateObject private var flow = StudyFlowStore()
    @StateObject private var mathStore = MathStore()
    @StateObject private var mathExperience = MathExperienceStore()

    var body: some View {
        RootView(store: store, exams: examStore, concepts: conceptStore, power: powerStore, flow: flow, math: mathStore, mathExperience: mathExperience)
            .preferredColorScheme(nil)
    }
}

#else
@main
struct StudyApp: App {
    @StateObject private var store = StudyStore()
    @StateObject private var examStore = ExamStore()
    @StateObject private var conceptStore = ConceptStore()
    @StateObject private var powerStore = ConceptStore(subject: .power)
    @StateObject private var flow = StudyFlowStore()
    @StateObject private var mathStore = MathStore()
    @StateObject private var mathExperience = MathExperienceStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, exams: examStore, concepts: conceptStore, power: powerStore, flow: flow, math: mathStore, mathExperience: mathExperience)
                .preferredColorScheme(nil)
        }
    }
}

#endif

struct RootView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var exams: ExamStore
    @ObservedObject var concepts: ConceptStore
    @ObservedObject var power: ConceptStore
    @ObservedObject var flow: StudyFlowStore
    @ObservedObject var math: MathStore
    @ObservedObject var mathExperience: MathExperienceStore
    @StateObject private var handbookComputer = HandbookWordStore(subject: .computer)
    @StateObject private var handbookPower = HandbookWordStore(subject: .power)
    @StateObject private var professionalComputer = ProfessionalQuestionStore(subject: .computer)
    @StateObject private var professionalPower = ProfessionalQuestionStore(subject: .power)
    @State private var importing = false
    @State private var selectedTab = 5
    @State private var examPracticing = false
    @State private var professionalPracticing = false
    @State private var professionalRecalling = false
    @AppStorage("handbookFullScreenEnabled") private var handbookFullScreenEnabled = true
    @State private var examOverlay = false
    @State private var professionalOverlay = false
    @State private var observedCalendarDay: Date?
    @State private var subject: ConceptSubject = .computer
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $selectedTab) {
            StudyHomeView(store: store, exams: exams, computer: concepts, power: power,
                          professionalComputer: professionalComputer, professionalPower: professionalPower,
                          handbookComputer: handbookComputer, handbookPower: handbookPower,
                          flow: flow, launch: launch)
                .tabItem { Label("今天", systemImage: "house") }
                .tag(5)
            StudyView(store: store, importing: $importing, onStart: { began(.vocabulary) })
                .disabled(flow.state.activeArea == .vocabulary && flow.state.isPaused && currentPracticeArea == .vocabulary)
                .tabItem { Label("单词", systemImage: "text.book.closed") }
                .tag(0)
            ExamView(store: exams, showingPractice: $examPracticing, onStart: { began(.publicQuestions) },
                     onOverlayChanged: { examOverlay = $0; trackStudyVisibility() })
                .disabled(flow.state.activeArea == .publicQuestions && flow.state.isPaused && examPracticing)
                .tabItem { Label("题库", systemImage: "list.bullet.clipboard") }
                .tag(3)
            ProfessionalCoursesView(computer: concepts, power: power, subject: $subject,
                                    practicing: $professionalPracticing, recalling: $professionalRecalling,
                                    onStart: { began(subject == .computer ? .computer : .power) },
                                    onOverlayChanged: { professionalOverlay = $0; trackStudyVisibility() },
                                    objectiveComputer: professionalComputer, objectivePower: professionalPower,
                                    handbookComputer: handbookComputer, handbookPower: handbookPower,
                                    fullScreenEnabled: handbookFullScreenBinding)
                .toolbar(handbookFullScreenActive ? .hidden : .visible, for: .tabBar)
                .disabled(flow.state.activeArea == (subject == .computer ? StudyArea.computer : .power)
                          && flow.state.isPaused && (professionalPracticing || professionalRecalling))
                .tabItem { Label("专业课", systemImage: "books.vertical") }
                .tag(4)
            MathExperienceView(store: mathExperience, legacy: math, isVisible: selectedTab == 6)
                .tabItem { Label("数学", systemImage: "function") }
                .tag(6)
            RecordsView(store: store, importing: $importing)
                .tabItem { Label("记录", systemImage: "chart.bar.doc.horizontal") }
                .tag(2)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !handbookFullScreenActive { segmentBar }
        }
        .statusBarHidden(handbookFullScreenActive)
        .onAppear {
            refreshCalendars(force: true)
            trackStudyVisibility()
            syncExamPolicy()
        }
        .onChange(of: selectedTab) { _, _ in trackStudyVisibility() }
        .onChange(of: importing) { _, _ in trackStudyVisibility() }
        .onChange(of: examPracticing) { _, _ in trackStudyVisibility() }
        .onChange(of: professionalPracticing) { _, _ in trackStudyVisibility() }
        .onChange(of: professionalRecalling) { _, _ in trackStudyVisibility() }
        .onChange(of: subject) { _, _ in trackStudyVisibility() }
        .onChange(of: currentPracticeArea) { _, _ in trackStudyVisibility() }
        .onReceive(clock) { _ in
            if scenePhase == .active { refreshCalendars() }
            trackStudyVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCalendars(force: true)
        }
        .onChange(of: store.analysis?.conservativeEnabled) { _, _ in syncExamPolicy() }
        .onChange(of: scenePhase) { _, phase in
            trackStudyVisibility()
            if phase == .active {
                refreshCalendars(force: true)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url): store.importContent(from: url)
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .alert("请检查", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: Binding(
            get: { flow.state.needsBreak && selectedTab != 5 },
            set: { _ in }
        )) {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundStyle(.green)
                Text("这 5 分钟到这里就好").font(.title2.bold())
                Text("当前题和剩余任务都在。没做完的不会算作学会，下次继续。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("先休息，回到首页") {
                    flow.finish()
                    selectedTab = 5
                }.buttonStyle(.borderedProminent)
                Button("再学 5 分钟") {
                    flow.extendFiveMinutes()
                    trackStudyVisibility()
                }.buttonStyle(.bordered)
            }.padding(28).presentationDetents([.medium]).interactiveDismissDisabled()
        }
    }
    private var handbookFullScreenActive: Bool {
        selectedTab == 4 && professionalRecalling && handbookFullScreenBinding.wrappedValue
    }
    private var handbookFullScreenBinding: Binding<Bool> {
        // Keep the shared resume/break controls reachable while learning is paused.
        Binding(get: { handbookFullScreenEnabled && !flow.state.isPaused && !flow.state.needsBreak },
                set: { handbookFullScreenEnabled = $0 })
    }
    private func trackStudyVisibility() {
        if let area = currentPracticeArea, area != flow.state.activeArea {
            flow.followNavigation(to: area)
            if flow.error != nil || flow.state.activeArea != area {
                selectedTab = 5
            }
        }
        let overlay = importing || (selectedTab == 3 && examOverlay) || (selectedTab == 4 && professionalOverlay)
        let visible = scenePhase == .active && !overlay && currentPracticeArea == flow.state.activeArea
            && currentPracticeArea != nil
        flow.setVisible(visible)
        store.setStudyScreenVisible(scenePhase == .active && selectedTab == 0 && !importing
            && !flow.state.isPaused && !flow.state.needsBreak)
    }
    private func syncExamPolicy() {
        exams.setPolicy(conservative: store.analysis?.conservativeEnabled ?? true)
    }

    private func refreshCalendars(force: Bool = false) {
        let day = Calendar.current.startOfDay(for: Date())
        guard force || observedCalendarDay != day else { return }
        observedCalendarDay = day
        store.refreshStudyDate()
        exams.refreshStudyDate()
        concepts.refreshStudyDate()
        power.refreshStudyDate()
    }

    private var currentPracticeArea: StudyArea? {
        if selectedTab == 0, store.sessionStarted, store.currentWord != nil { return .vocabulary }
        if selectedTab == 3, examPracticing, exams.currentQuestion != nil { return .publicQuestions }
        if selectedTab == 4, professionalRecalling {
            let handbook = subject == .computer ? handbookComputer : handbookPower
            if handbook.engine?.presentation != nil { return subject == .computer ? .computer : .power }
        }
        if selectedTab == 4, professionalPracticing {
            let selected = subject == .computer ? professionalComputer : professionalPower
            if selected.engine?.presentation != nil { return subject == .computer ? .computer : .power }
        }
        return nil
    }

    private func began(_ area: StudyArea) {
        if flow.state.activeArea == area { flow.resume() }
        else { flow.begin(area: area, mode: .standard) }
        trackStudyVisibility()
    }

    private func launch(_ area: StudyArea, _ mode: StudySegmentMode) {
        refreshCalendars(force: true)
        // Starting/resuming goes through the existing stores; navigation never grades.
        switch area {
        case .vocabulary:
            guard store.canLearn else { selectedTab = 0; return }
            store.start(date: Date())
            guard store.error == nil else { return }
        case .publicQuestions:
            guard exams.bank != nil, !exams.storageBlocked else { selectedTab = 3; return }
            if !exams.sessionIsActive { exams.start() }
            guard exams.error == nil else { selectedTab = 3; return }
            examPracticing = true
        case .computer:
            subject = .computer
            professionalPracticing = false
            guard handbookComputer.engine != nil, !handbookComputer.blocked else {
                professionalRecalling = false; selectedTab = 4; return
            }
            handbookComputer.start()
            guard handbookComputer.error == nil, !handbookComputer.blocked else { selectedTab = 4; return }
            professionalRecalling = true
        case .power:
            subject = .power
            professionalPracticing = false
            guard handbookPower.engine != nil, !handbookPower.blocked else {
                professionalRecalling = false; selectedTab = 4; return
            }
            handbookPower.start()
            guard handbookPower.error == nil, !handbookPower.blocked else { selectedTab = 4; return }
            professionalRecalling = true
        }
        flow.begin(area: area, mode: mode)
        guard flow.error == nil, flow.state.activeArea == area else { selectedTab = 5; return }
        selectedTab = area.tab
        trackStudyVisibility()
    }

    @ViewBuilder private var segmentBar: some View {
        if currentPracticeArea != nil, currentPracticeArea == flow.state.activeArea {
            HStack(spacing: 12) {
                if flow.state.isPaused {
                    Button("继续这一段", systemImage: "play.fill") { flow.resume(); trackStudyVisibility() }
                } else {
                    Text(flow.state.mode == .fiveMinutes ? "先学 5 分钟" : "随时可以暂停")
                        .font(.subheadline)
                }
                Spacer()
                Text(segmentTime).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Button("暂停") { flow.pause(); selectedTab = 5; trackStudyVisibility() }
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
    }

    private var segmentTime: String {
        let seconds = max(0, Int(flow.state.elapsedSeconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct StudyView: View {
    @ObservedObject var store: StudyStore
    @Binding var importing: Bool
    var onStart: () -> Void = {}
    @AppStorage("studyHapticsEnabled") private var hapticsEnabled = true
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var scaledActionHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .footnote) private var scaledUndoHeight: CGFloat = 34

    private var actionHeight: CGFloat { verticalSizeClass == .compact ? 48 : scaledActionHeight }
    private var undoHeight: CGFloat { verticalSizeClass == .compact ? 30 : scaledUndoHeight }

    private var canRevealFromBackground: Bool {
        store.canLearn && store.sessionStarted && store.currentWord != nil &&
            store.info.revealed == 0 && !store.supplementVisible
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if store.deck == nil {
                            ContentUnavailableView {
                                Label("导入词库与进度", systemImage: "square.and.arrow.down")
                            } description: {
                                Text("选择为你准备的 .xklcontent 文件。导入后可离线使用，原有学习记录会保留。")
                            } actions: {
                                Button("选择文件") { importing = true }.buttonStyle(.borderedProminent)
                            }
                        } else if !store.canLearn {
                            ContentUnavailableView("先完成学习接力", systemImage: "arrow.triangle.2.circlepath",
                                                   description: Text(store.syncStatus))
                        } else if !store.sessionStarted {
                            Text("每课 25 个新词").font(.title2.bold())
                            Text("先复习，再学新词。到期复习不设数量上限。")
                                .foregroundStyle(.secondary)
                        } else if let word = store.currentWord {
                            taskProgress
                            Text(word.word).font(.system(.largeTitle, design: .rounded).weight(.semibold))
                                .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                            if store.info.revealed != 0 {
                                meanings(word)
                                if store.supplementVisible {
                                    Text("补看整个词。漏了另一个核心意思才算没背全，不要求补齐中文近义词。")
                                        .foregroundStyle(.secondary)
                                    Text(store.info.stage > 0 ? "完成后继续原有强化。" : "完成后安排一次间隔核对。")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                if !word.expanded.isEmpty {
                                    DisclosureGroup("其他义项与补充") {
                                        Text(word.expanded).font(.body).textSelection(.enabled).padding(.top, 8)
                                    }
                                }
                                if !word.originalDefinitionText.isEmpty {
                                    DisclosureGroup("原释义核对（选读）") {
                                        Text(word.originalDefinitionText).font(.body).textSelection(.enabled).padding(.top, 8)
                                    }
                                }
                            } else {
                                Text("回想这个词的核心意思，点击空白处显示。近义译法不必逐字背全。")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ContentUnavailableView("本次任务已完成", systemImage: "checkmark.circle",
                                                   description: Text("已保存进度。到期的复习会继续出现。"))
                            if let prompt=store.feedbackPrompt {
                                TaskFeedbackView(store:store,prompt:prompt).id(prompt.taskID)
                            }
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    .background { revealBackground }
                }
                .id(store.info.revision)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.deck != nil && store.canLearn { fixedActions }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("已熟悉") {
                        guard canRevealFromBackground else { return }
                        performStudyAction { store.answer(2) }
                    }
                    .font(.callout.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!canRevealFromBackground)
                    .opacity(store.sessionStarted && store.currentWord != nil && store.canLearn ? 1 : 0)
                    .accessibilityLabel("已熟悉，不再复习")
                    .accessibilityHint("标记后可用底部的撤销按钮恢复")
                    .accessibilityHidden(!store.sessionStarted || store.currentWord == nil || !store.canLearn)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                store.refreshStudyDate()
            }
        }
    }

    private var taskProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已完成 \(store.info.completed) 词 · 待完成 \(store.info.total_remaining) 词")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text("新词剩余 \(store.info.new_remaining)")
                Spacer()
                Text("复习剩余 \(store.info.review_remaining)")
            }.font(.caption).foregroundStyle(.secondary)
            if store.info.stage > 0 {
                Text("本轮强化 \(store.info.stage)/7").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else if store.info.partial_pending != 0 {
                Text("漏义核对").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var fixedActions: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                // Reserve every slot even when its action is unavailable. Showing
                // an answer, expanding meanings or enabling undo never moves it.
                if verticalSizeClass == .compact {
                    HStack(spacing: 10) { firstAction; secondAction; thirdAction }
                } else {
                    VStack(spacing: 10) { firstAction; secondAction; thirdAction }
                }
                Button("撤销上一次“熟悉”", systemImage: "arrow.uturn.backward") {
                    performStudyAction { store.undoFamiliar() }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .frame(height: undoHeight)
                .opacity(store.info.can_undo != 0 && store.sessionStarted ? 1 : 0)
                .disabled(store.info.can_undo == 0 || !store.sessionStarted)
                .accessibilityHidden(store.info.can_undo == 0 || !store.sessionStarted)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .background { revealBackground }
    }

    private var revealBackground: some View {
        // The tap target sits behind controls, including reserved empty slots;
        // it never handles a grading button's tap or advances a revealed card.
        Color(uiColor: .systemBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canRevealFromBackground else { return }
                performStudyAction { store.reveal() }
            }
            .allowsHitTesting(canRevealFromBackground)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var firstAction: some View {
        if !store.sessionStarted {
            actionButton(store.info.has_task != 0 ? "继续学习" : "开始学习", icon: "play.fill", color: .accentColor) {
                performStudyAction { store.start(date: Date()) }
                if store.error == nil { onStart() }
            }
        } else if store.currentWord == nil {
            actionButton("查看后续任务", icon: "arrow.right", color: .accentColor) {
                performStudyAction { store.start(date: Date()) }
                if store.error == nil { onStart() }
            }
        } else if store.supplementVisible {
            actionButton("补看完成", icon: "checkmark", color: .green) {
                performStudyAction { store.confirmSupplement() }
            }
        } else if store.info.revealed == 0 {
            actionButton("显示释义", icon: "eye", color: .accentColor) {
                performStudyAction { store.reveal() }
            }
        } else {
            actionButton("全会", icon: "checkmark", color: .green) {
                performStudyAction { store.answer(0) }
            }
        }
    }

    @ViewBuilder private var secondAction: some View {
        if !store.sessionStarted || store.currentWord == nil {
            emptyAction
        } else if store.supplementVisible {
            actionButton("返回判断", icon: "arrow.uturn.backward", color: .accentColor) {
                performStudyAction { store.cancelSupplement() }
            }
        } else if store.info.revealed == 0 {
            emptyAction
        } else {
            actionButton("没背全", icon: "text.badge.plus", color: .orange) {
                performStudyAction { store.beginSupplement() }
            }
        }
    }

    @ViewBuilder private var thirdAction: some View {
        if store.sessionStarted && store.currentWord != nil && store.info.revealed != 0 && !store.supplementVisible {
            actionButton("不认识", icon: "arrow.counterclockwise", color: .accentColor) {
                performStudyAction { store.answer(1) }
            }
        } else { emptyAction }
    }

    private var emptyAction: some View {
        Color.clear.frame(maxWidth: .infinity).frame(height: actionHeight)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func performStudyAction(_ action: () -> Void) {
        let revision = store.info.revision
        let revealed = store.info.revealed
        let supplement = store.supplementVisible
        action()
        guard hapticsEnabled,
              revision != store.info.revision || revealed != store.info.revealed || supplement != store.supplementVisible else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }

    private func meanings(_ word: StudyWord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("按意思回想，不要求逐字复述中文。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(word.core.enumerated()), id: \.offset) { index, meaning in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if word.core.count > 1 { Text("\(index + 1)").foregroundStyle(.secondary) }
                        if !meaning.pos.isEmpty { Text(meaning.pos).font(.subheadline).foregroundStyle(.secondary) }
                        Text(meaning.meaning).font(.title3).fixedSize(horizontal: false, vertical: true)
                    }
                    if store.supplementVisible {
                        Toggle("刚才漏了这个义（选填）",isOn:Binding(
                            get:{store.selectedMissingMeanings.contains(index)},
                            set:{if $0 {store.selectedMissingMeanings.insert(index)} else {store.selectedMissingMeanings.remove(index)}}))
                            .font(.subheadline).tint(.orange)
                    }
                    if !meaning.cue.isEmpty { Text(meaning.cue).font(.body).foregroundStyle(.secondary) }
                    let explanation = meaning.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let usageLabels = (meaning.usageLabels ?? []).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                    if explanation?.isEmpty == false || !usageLabels.isEmpty {
                        DisclosureGroup("解释与用法") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let explanation, !explanation.isEmpty {
                                    Text(explanation).font(.body).textSelection(.enabled)
                                }
                                if !usageLabels.isEmpty {
                                    Text(usageLabels.joined(separator: "；"))
                                        .font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.padding(.top, 8)
                        }
                    }
                }.textSelection(.enabled)
            }
            if let source=word.sourceLabel {
                Text(source).font(.caption).foregroundStyle(word.meaningPending == true ? Color.orange:Color.secondary)
            }
            if let english=word.supportingEnglish, !english.isEmpty {
                DisclosureGroup("英文依据（选读）") {
                    Text(english).font(.body).foregroundStyle(.secondary).textSelection(.enabled).padding(.top,8)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.medium))
                .lineLimit(2).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: actionHeight)
                .padding(.horizontal, 16)
                .foregroundStyle(color)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SyncView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var bluetooth: BluetoothLink

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(store.canLearn ? "在 iPhone 上学习" : "学习接力", systemImage: "iphone.and.arrow.forward")
                    Text(store.syncStatus)
                    if store.conflictCount > 0 {
                        Text("保存了 \(store.conflictCount) 份冲突记录，没有自动覆盖。请先导出记录再处理。")
                            .foregroundStyle(.orange)
                    }
                }
                Section("小设备") {
                    Text(bluetooth.status).foregroundStyle(.secondary)
                    if bluetooth.selectedID == nil {
                        Button(bluetooth.scanning ? "停止搜索" : "搜索设备") {
                            if bluetooth.scanning { bluetooth.stopScan() } else { bluetooth.scan() }
                        }.disabled(store.deck == nil)
                        ForEach(bluetooth.devices) { device in
                            Button { bluetooth.connect(device.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(String(device.id.uuidString.suffix(8))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        if let peer = store.pendingPeer {
                            Text("设备身份：\(peer.deviceID.suffix(8))").font(.caption)
                            if !store.paired {
                                Button("确认配对这台设备") { store.confirmPairing() }
                            }
                        }
                        if store.paired {
                            if store.canHandoff {
                                Button("交给小设备继续背") { store.handoffToDevice() }
                            }
                            if store.hasPendingTransfer {
                                Button("继续核对未完成的接力") { store.reconcile() }
                            }
                            if !store.canLearn && !store.hasPendingTransfer {
                                Text("要接回 iPhone，请在小设备上选择交回，并确认接力。")
                            }
                        }
                        Button("断开连接") { bluetooth.disconnect() }
                    }
                }
                Section {
                    Text("本页用于英语词库接力。题库进度保存在这台 iPhone，可在题库页导出。")
                        .foregroundStyle(.secondary)
                    Text("两边都能离线背词；同一份进度每次只在一台设备继续。连接成功不等于接力完成，未确认时会保留锁定状态。")
                    Text("小设备需要安装兼容的背词同步固件。当前版本尚未完成真机蓝牙验证。")
                        .foregroundStyle(.secondary)
                    Text("第一次接力前，需要用本机导出的初始化包配置空白小设备。普通出厂固件或独立导入的进度不能直接配对接力。")
                        .foregroundStyle(.secondary)
                }
            }.navigationTitle("同步")
        }
    }
}

struct RecordsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json,.zip] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RecordsView: View {
    @ObservedObject var store: StudyStore
    @Binding var importing: Bool
    @State private var exporting = false
    @State private var exportDocument: RecordsDocument?
    @State private var exportName = "背词记录"
    @State private var exportType: UTType = .json
    @State private var temporaryExport: URL?
    @State private var showingSync = false
    @AppStorage("studyHapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section("偏好") {
                    Toggle("轻微震动反馈", isOn: $hapticsEnabled)
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
                Section("复习优化") {
                    Toggle("保守减轮（实验）", isOn: Binding(get: { store.analysis?.conservativeEnabled ?? true },
                                                  set: { store.setConservativeEnabled($0) }))
                        .disabled(!store.canLearn)
                    LabeledContent("累计减少重复", value: "\(store.analysis?.savedRepetitions ?? 0) 次")
                    Text("上次答错或没背全后，累计 3 次合格全会；每次至少隔开 3 个不同词，其中一次至少 7 个。短间隔不计次数，答错恢复七轮，跨天复习保留。是否能省时且记得住，仍需后续记录检验。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("双 FSRS 后台比较") {
                    LabeledContent("记录的评分", value: "\(store.shadowReport?.rows.count ?? 0) 次")
                    Text(store.shadowStatus).font(.footnote).foregroundStyle(.secondary)
                    if let report=store.shadowReport,report.comparableCount>0 {
                        LabeledContent("首答影子 Brier",value:report.firstAnswerScore.brier.map { String(format:"%.3f",$0) } ?? "—")
                        LabeledContent("全评分影子 Brier",value:report.allRatingsScore.brier.map { String(format:"%.3f",$0) } ?? "—")
                    }
                    Text("一个只按每日首答更新，另一个读取全部真实评分；两者用同一批延迟首答比较。只隔午夜、撤销重答或提前看过答案的记录不计入评分。Brier 越小表示这些样本上预测误差越小，不代表已证明更省时。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("真实经过时间与前台学习时间分别记录。退后台、其他标签页不计学习用时；长时间思考照常保留。时间记录从本次升级开始，旧记录不补造时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("学习记录") {
                    LabeledContent("本版累计前台学习",value:String(format:"%.1f 分钟",(store.timing?.latestPoint?.foregroundMs ?? 0)/60_000))
                    LabeledContent("词库", value: "25,644 词")
                    LabeledContent("累计事件", value: "\(store.info.log_records) 条")
                    LabeledContent("归档日志",value:"\(store.history?.volumes.count ?? 0) 卷")
                    LabeledContent("本卷事件",value:"\(store.activeVolumeEvents) / \(store.info.log_capacity)")
                    Button("导出完整进度和日志", systemImage: "square.and.arrow.up") {
                        do {
                            let url=try store.exportFullArchive();temporaryExport=url
                            exportDocument=RecordsDocument(data:try Data(contentsOf:url,options:.mappedIfSafe))
                            exportName="背词完整档案";exportType = .zip;exporting=true
                        }
                        catch { store.error = error.localizedDescription }
                    }.disabled(!store.hasArchive)
                    Text("接近容量时自动保存旧卷并继续新卷。ZIP 包含所有已归档日志、当前进度、选填反馈和逐条事件表；导出不会删除原记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("词库与原进度") {
                    Button("导入内容包") { importing = true }
                    Text("只接收当前版本且校验通过的内容包。已有学习记录不会被再次导入的初始进度覆盖。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("首次设备初始化") {
                    Button("设备同步与学习接力", systemImage: "arrow.triangle.2.circlepath") { showingSync = true }
                    Button("导出空白小设备初始化包") {
                        do {
                            exportDocument = RecordsDocument(data: try store.exportReceiverProvisioning())
                            exportName = "空白小设备初始化";exportType = .json
                            exporting = true
                        } catch { store.error = error.localizedDescription }
                    }.disabled(!store.canLearn)
                    Text("用于后续适配的设备固件建立相同接力基线。这个文件不执行刷机，不应用于已有学习进度的设备。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("记录")
            .sheet(isPresented: $showingSync) {
                SyncView(store: store, bluetooth: store.bluetooth)
                    .safeAreaInset(edge: .top) {
                        HStack { Spacer(); Button("关闭") { showingSync = false } }.padding()
                    }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType,
                          defaultFilename: "\(exportName)-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
                if case .failure(let error) = result { store.error = error.localizedDescription }
                if let temporaryExport { try? FileManager.default.removeItem(at:temporaryExport);self.temporaryExport=nil }
            }
        }
    }
}

struct TaskFeedbackView: View {
    @ObservedObject var store:StudyStore
    let prompt:StudyFeedbackPrompt
    @State private var annoyance = -1
    @State private var fatigue = -1
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("本次感受（选填）").font(.headline)
            Text("0 表示没有，10 表示非常强烈；不填不会影响学习。").font(.footnote).foregroundStyle(.secondary)
            Picker("烦躁",selection:$annoyance) {
                Text("未填写").tag(-1)
                ForEach(0...10,id:\.self) { Text("\($0)").tag($0) }
            }
            Picker("疲劳",selection:$fatigue) {
                Text("未填写").tag(-1)
                ForEach(0...10,id:\.self) { Text("\($0)").tag($0) }
            }
            HStack {
                Button("保存反馈") { store.saveTaskFeedback(annoyance:annoyance<0 ? nil:annoyance,fatigue:fatigue<0 ? nil:fatigue) }
                    .buttonStyle(.bordered).disabled(annoyance<0 && fatigue<0)
                Button("跳过") { store.skipTaskFeedback() }.buttonStyle(.borderless)
            }
        }
    }
}

