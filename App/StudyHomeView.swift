import SwiftUI

/// A navigation and stopping aid. Every answer and due date remains owned by
/// the existing subject store; a timed segment is never a completed lesson.
struct StudyHomeView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var exams: ExamStore
    @ObservedObject var computer: ConceptStore
    @ObservedObject var power: ConceptStore
    @ObservedObject var flow: StudyFlowStore
    var launch: (StudyArea, StudySegmentMode) -> Void
    @State private var selectedArea: StudyArea = .vocabulary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(returningAfterBreak ? "回来就从一小段开始" : "从这里接着学")
                        .font(.largeTitle.bold())
                    Text(returningAfterBreak
                         ? "先学 5 分钟，不用一次清空积压。原来的到期日和学习记录都还在。"
                         : "做到一半也可以停，下次从保存的位置继续。")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 18) {
                        Picker("这一段学什么", selection: $selectedArea) {
                            ForEach(StudyArea.allCases, id: \.rawValue) { area in
                                Text(area.title).tag(area)
                            }
                        }.pickerStyle(.menu)
                        Text(resumeDescription(selectedArea)).font(.headline)
                        if available(selectedArea) {
                            Text(reviewSummary(selectedArea))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if flow.state.activeArea == selectedArea, flow.state.segmentID != nil {
                            Text("上次这一段已学 \(max(0, Int(flow.state.elapsedSeconds)) / 60) 分 \(max(0, Int(flow.state.elapsedSeconds)) % 60) 秒")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            launch(selectedArea, continueMode)
                        } label: {
                            Label(selectedArea == .computer || selectedArea == .power ? "继续背卡" : (hasSavedPosition(selectedArea) ? "接着学" : "开始学习"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }.buttonStyle(.borderedProminent).disabled(!available(selectedArea))
                        Button {
                            launch(selectedArea, .fiveMinutes)
                        } label: {
                            Label("今天先学 5 分钟", systemImage: "timer")
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }.buttonStyle(.bordered).disabled(!available(selectedArea))
                        Text("到点提醒休息，可以停，也可以再学 5 分钟。计时只计算前台练习时间。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("保留原来的学习节奏").font(.headline)
                        Text("单词每课仍是 25 个新词，允许分段完成；到期复习不设总量上限。计算机与电力系统进入必学背卡主线，主卡和必要补卡自动衔接。")
                        Text("暂停只保存断点，不算答对、不推迟到期，也不清空剩余任务。")
                    }.font(.subheadline).foregroundStyle(.secondary)

                    if let error = flow.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { if let last = flow.state.lastArea { selectedArea = last } }
    }

    private var continueMode: StudySegmentMode {
        flow.state.activeArea == selectedArea ? flow.state.mode : .standard
    }

    private var returningAfterBreak: Bool {
        guard let last = flow.state.lastActivityAt else { return false }
        return (Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0) >= 3
    }

    private func available(_ area: StudyArea) -> Bool {
        switch area {
        case .vocabulary: return store.deck != nil && store.canLearn
        case .publicQuestions: return exams.bank != nil && !exams.storageBlocked
        case .computer: return computer.engine != nil && computer.teaching?.studyPlan != nil && !computer.blocked
        case .power: return power.engine != nil && power.teaching?.studyPlan != nil && !power.blocked
        }
    }

    private func hasSavedPosition(_ area: StudyArea) -> Bool {
        switch area {
        case .vocabulary: return store.info.has_task != 0
        case .publicQuestions: return exams.currentQuestion != nil || exams.isShowingResult
        case .computer: return computer.teaching?.studyPlan != nil
        case .power: return power.teaching?.studyPlan != nil
        }
    }

    private func resumeDescription(_ area: StudyArea) -> String {
        guard available(area) else { return "先到对应科目导入内容" }
        switch area {
        case .vocabulary:
            if store.info.has_task != 0, let deck = store.deck,
               Int(store.info.word) < deck.words.count {
                return "继续单词 · \(deck.words[Int(store.info.word)].word)"
            }
            return "先复习，再学新词"
        case .publicQuestions:
            if exams.isShowingResult { return "继续查看刚才的答案与解析" }
            return exams.currentQuestion != nil ? "继续刚才的题，已选选项保留" : "先复习，再做新题"
        case .computer, .power:
            return "继续必学背卡 · 自动保存与续学"
        }
    }

    private func reviewSummary(_ area: StudyArea) -> String {
        switch area {
        case .vocabulary:
            return store.info.has_task != 0
                ? "当前任务待复习 \(store.info.review_remaining) 词，可分段完成"
                : "今天到期 \(store.dueTodayCount) 词，开始后优先复习"
        case .publicQuestions:
            return exams.totalRemaining > 0
                ? "当前任务待复习 \(exams.reviewRemaining) 题，可分段完成"
                : "今天到期 \(exams.dueTodayCount) 题，开始后优先复习"
        case .computer, .power:
            let target = area == .computer ? computer : power
            guard let plan = target.teaching?.studyPlan else { return "" }
            let count = plan.mainlineCardIDs.count + plan.supplementSelections.reduce(0) { $0 + $1.mainlineCardIDs.count }
            return "必学 \(count) 张；进入后显示已学、到期和本轮进度"
        }
    }
}
