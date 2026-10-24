import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Exam practice has its own content, progress and records. Answer keys only
/// become visible after the store has durably saved a submitted attempt.
struct ExamView: View {
    @ObservedObject var store: ExamStore
    @State private var importing = false
    @State private var exporting = false
    @Binding var showingPractice: Bool
    var onStart: () -> Void = {}
    var onOverlayChanged: (Bool) -> Void = { _ in }
    @State private var actionLocked = false
    @State private var exportDocument: ExamRecordsDocument?
    @AppStorage("studyHapticsEnabled") private var hapticsEnabled = true
    @AppStorage("examTargetDay") private var examTargetDay = 20_793 // 2026-12-06
    @AppStorage("examDailyMinutes") private var examDailyMinutes = 30
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var scaledActionHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .footnote) private var scaledUndoHeight: CGFloat = 34

    private var actionHeight: CGFloat { verticalSizeClass == .compact ? 48 : scaledActionHeight }
    private var undoHeight: CGFloat { verticalSizeClass == .compact ? 30 : scaledUndoHeight }

    var body: some View {
        NavigationStack {
            directory
                .navigationTitle("题库")
                .navigationDestination(isPresented: $showingPractice) {
                    practice
                }
                .toolbar {
                    if store.bank != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("导入题库", systemImage: "square.and.arrow.down") {
                                    importing = true
                                }
                                Button("导出答题记录", systemImage: "square.and.arrow.up") {
                                    exportRecords()
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .accessibilityLabel("题库操作")
                            }
                        }
                    }
                }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url):
                store.importContent(from: url)
            case .failure(let error):
                store.error = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "国网题库-答题记录-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
        ) { result in
            if case .failure(let error) = result {
                store.error = error.localizedDescription
            }
        }
        .alert("请检查", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .onChange(of: importing || exporting || store.error != nil) { _, shown in onOverlayChanged(shown) }
    }

    @ViewBuilder
    private var directory: some View {
        if let bank = store.bank {
            bankDirectory(bank)
        } else {
            ContentUnavailableView {
                Label("导入题库", systemImage: "list.bullet.rectangle")
            } description: {
                Text("选择为你准备的 .xklquestions 文件，之后可离线练习。")
            } actions: {
                Button("选择文件") { importing = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func bankDirectory(_ bank: ExamBank) -> some View {
        List {
            Section {
                Text(bank.title).font(.headline)
                HStack {
                    metric("题目", value: bank.questions.count)
                    Spacer()
                    metric("已练", value: store.totalAnsweredCount)
                    Spacer()
                    metric("待加强", value: store.wrongCount)
                }
                .padding(.vertical, 6)
                Text("按题目统计；作答按实际选项自动判分，“待加强”按各题最近一次客观结果更新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("学习") {
                Text("每课 25 道新题").font(.headline)
                Text("先复习，再学新题。到期复习不限量。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("新题默认进入学习；确定已经掌握的题，可点右上角“已熟悉”跳过。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(store.sessionIsActive ? "继续任务" : "开始学习", systemImage: "play.fill") {
                    start()
                }
                .disabled(store.storageBlocked || actionLocked)
                Text("整题记忆，保留跨天复习。每次出现时打乱选项，作答中途保持顺序。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("返回题库不会丢失当前题目和已选选项。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            examPlanSection(bank)

            Section("题库复习") {
                Toggle("题库减轮（试行）", isOn: Binding(
                    get: { store.examReductionEnabled },
                    set: { store.setExamReduction(enabled: $0) }
                ))
                .disabled(store.storageBlocked || actionLocked)
                if store.examReductionEnabled {
                    Text("新题或首次答错后最多核对 3 次；同一任务再次答错会加强。只剩同一道题时，答对当前这次后，剩余核对留到明天。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("关闭后，新题和答错题按七轮强化规则；已有安排保留，不再提前结束只剩同题的核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("这是一项可关闭的试行调整，长期记忆效果仍需从后续记录检验。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("章节") {
                ForEach(store.sections, id: \.self) { section in
                    LabeledContent(section, value: "\(bank.questions.filter { $0.section == section }.count) 题")
                }
            }

            Section("答题记录") {
                Button("导出答题记录", systemImage: "square.and.arrow.up") {
                    exportRecords()
                }
                Text("保留实际选择、选项顺序、原文答案和评分。历史记录继续保留，导出不会清除进度。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("来源") {
                Text(bank.sourceName).font(.subheadline).textSelection(.enabled)
                Text("答案按原 PDF。每题标有来源页码，可回到原文件核对。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("题库练习单独保存，不改变背词进度和复习安排。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if store.storageBlocked {
                Section {
                    Label("记录暂时无法保存，请先处理上方提示。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text("可以先导出现有答题记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func examPlanSection(_ bank: ExamBank) -> some View {
        let plan = ExamStudyPlan(totalQuestionCount: bank.questions.count,
            unseenQuestionCount: store.unseenQuestionCount,
            newIntroducedToday: store.newIntroducedToday, todayDay: store.planningDay,
            examDay: examTargetDay, dailyMinutes: examDailyMinutes, reviewBufferDays: 14)
        return Section("考前计划") {
            DatePicker("考试日期", selection: Binding(
                get: { date(forDay: examTargetDay) },
                set: { if let day = try? ExamStore.studyDay($0) { examTargetDay = Int(day) } }
            ), displayedComponents: .date)
            Stepper("每日预算 \(examDailyMinutes) 分钟", value: $examDailyMinutes, in: 10...180, step: 5)
            if plan.examHasPassed {
                Text("本次考试日期已过。需要准备下一批时，再设置新的考试日期。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if plan.isExamDay {
                Text("今天考试，不再安排新题目标。已有学习记录继续保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("距考试 \(plan.daysToExam) 天 · 还未接触 \(store.unseenQuestionCount) 题")
                    .font(.subheadline)
                Text("今日覆盖新题 \(store.newIntroducedToday) / \(plan.targetNewToday) · 还需 \(plan.remainingNewToday) 题")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if plan.isInsideReviewBuffer {
                    Text("已进入预留的复习期，还有新题未覆盖；目标按考前剩余天数重算。")
                        .font(.footnote).foregroundStyle(.orange)
                } else {
                    Text("目标截至 \(date(forDay: examTargetDay - 14).formatted(.dateTime.month().day()))（含当天）覆盖新题，留出约两周复习。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("先处理到期复习，再学新题。目标包含主动标记已熟悉的题；每课仍为 25 道新题，可中途暂停。时间预算不代表完成用时，也不会隐藏到期题。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func date(forDay day: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        var parts = utc.dateComponents([.year, .month, .day],
            from: Date(timeIntervalSince1970: Double(day) * 86_400))
        parts.hour = 12
        return local.date(from: parts) ?? Date()
    }

    private func metric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var practice: some View {
        Group {
            if store.isShowingResult, let question = store.currentQuestion {
                questionContent(question)
            } else if store.sessionIsComplete {
                completedPractice
            } else if let question = store.currentQuestion {
                questionContent(question)
            } else {
                ContentUnavailableView(
                    "当前没有题目",
                    systemImage: "checkmark.circle",
                    description: Text("返回题库查看进度或开始后续任务。")
                )
            }
        }
        .navigationTitle("题库学习")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("已熟悉") {
                    guard store.canMarkFamiliar else { return }
                    performAction { store.markFamiliar() }
                }
                .font(.callout.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!store.canMarkFamiliar || actionLocked || store.storageBlocked)
                .opacity(store.currentQuestion == nil ? 0 : 1)
                .accessibilityLabel("已熟悉，不再复习")
                .accessibilityHint("可用底部的撤销按钮恢复")
                .accessibilityHidden(store.currentQuestion == nil)
            }
        }
    }

    private var completedPractice: some View {
        ContentUnavailableView {
            Label("本次任务已完成", systemImage: "checkmark.circle")
        } description: {
            Text("进度已保存，到期的复习会继续出现。")
        } actions: {
            Button("返回题库") { showingPractice = false }
                .buttonStyle(.borderedProminent)
            if store.canUndo {
                Button("撤销上次跳过", systemImage: "arrow.uturn.backward") {
                    performAction { store.undoFamiliar() }
                }
                .disabled(actionLocked || store.storageBlocked)
            }
        }
    }

    private func questionContent(_ question: ExamQuestion) -> some View {
        let presentationID = store.presentationID
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                questionHeader(question)
                Text(question.prompt)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 12) {
                    ForEach(store.shuffledOptions, id: \.id) { option in
                        ExamOptionRow(
                            option: option,
                            displayLabel: store.displayLabel(for: option.id),
                            isSelected: selectedOptionsForDisplay.contains(option.id),
                            isRevealed: store.isRevealed,
                            isCorrect: store.isRevealed && question.answer.contains(option.id),
                            isEnabled: !store.isRevealed && !store.storageBlocked && !actionLocked
                        ) {
                            selectOption(option.id, question: question, presentationID: presentationID)
                        }
                    }
                }

                if store.isRevealed {
                    answerResult(question)
                }
                Text(sourcePageLabel(question))
                    .font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if store.storageBlocked {
                    Label("记录暂时无法保存，请返回题库处理提示。", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // A repeat of the same question is a new presentation. Selection,
        // revealing and restoring keep this ID and the option order stable.
        .id(store.presentationID)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            fixedActions
        }
    }

    private func questionHeader(_ question: ExamQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("待完成 \(store.totalRemaining) 题")
                    .monospacedDigit()
                Spacer()
                Text(question.type.title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            Text("\(question.section) · 第 \(question.number) 题")
                .font(.footnote).foregroundStyle(.secondary)
            Text("新题剩余 \(store.newRemaining) · 复习剩余 \(store.reviewRemaining)")
                .font(.footnote).foregroundStyle(.secondary)
            if !store.isShowingResult && store.stage > 0 {
                Text("强化核对")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            } else if !store.isShowingResult && store.partialPending {
                Text("漏项核对")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !store.isRevealed {
                Text(question.type.rawValue == "multiple"
                     ? "选择所有正确选项，再提交；少选、多选均算错。"
                     : "点击一个选项，直接查看结果。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func answerResult(_ question: ExamQuestion) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            Label(resultTitle, systemImage: resultIcon)
                .font(.headline).foregroundStyle(resultColor)
            Text("本次选择：\(optionLabel(selectedOptionsForDisplay))")
                .font(.body)
            VStack(alignment: .leading, spacing: 8) {
                Text("本次正确选项").font(.body.weight(.semibold))
                ForEach(store.shuffledOptions.filter { question.answer.contains($0.id) }) { option in
                    Text("\(store.displayLabel(for: option.id))．\(option.text)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.pendingGrade == 1 && question.type.rawValue == "multiple" {
                Text("少选、多选或错选都算错。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.latestAttempt?.learningInitialization != nil {
                Text("首次答对已记录，仍会继续核对和跨天复习。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("答案按原 PDF")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var fixedActions: some View {
        let presentationID = store.presentationID
        return VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                if store.isShowingResult {
                    actionButton("下一题", color: .accentColor) {
                        nextQuestion(presentationID: presentationID)
                    }
                } else if store.currentQuestion?.type == .multiple {
                    actionButton("提交答案", color: .accentColor, enabled: !store.selectedOptionIDs.isEmpty) {
                        submitAnswer(presentationID: presentationID)
                    }
                } else {
                    Text("点击上方选项作答")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: actionHeight)
                }
                Button("撤销上次跳过", systemImage: "arrow.uturn.backward") {
                    guard store.canUndo else { return }
                    performAction { store.undoFamiliar() }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .frame(height: undoHeight)
                .disabled(!store.canUndo || store.storageBlocked || actionLocked)
                .opacity(store.canUndo ? 1 : 0)
                .accessibilityHidden(!store.canUndo)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func actionButton(_ title: String, color: Color, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: actionHeight)
                .padding(.horizontal, 14)
                .foregroundStyle(color)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled && !store.storageBlocked && !actionLocked ? 1 : 0.45)
        .disabled(!enabled || store.storageBlocked || actionLocked)
    }

    private var selectedOptionsForDisplay: Set<String> {
        if store.isRevealed, let attempt = store.latestAttempt {
            return Set(attempt.selectedOptions)
        }
        return store.selectedOptionIDs
    }

    private func start() {
        if !store.sessionIsActive {
            store.start()
        }
        if store.error == nil && (store.currentQuestion != nil || store.sessionIsComplete) {
            showingPractice = true
            onStart()
        }
    }

    private func selectOption(_ id: String, question: ExamQuestion, presentationID: UUID?) {
        guard !store.isShowingResult, !store.storageBlocked, !actionLocked,
              let presentationID else { return }
        if question.type == .multiple {
            store.toggleOption(id, presentationID: presentationID)
        } else {
            performAction {
                store.selectAndSubmit(id, presentationID: presentationID)
            } succeeded: {
                store.isShowingResult && store.presentationID == presentationID &&
                    store.latestAttempt?.questionID == question.id
            }
        }
    }

    private func submitAnswer(presentationID: UUID?) {
        guard !store.isShowingResult, !store.storageBlocked, let presentationID,
              !store.selectedOptionIDs.isEmpty else { return }
        performAction {
            store.submit(presentationID: presentationID)
        } succeeded: {
            store.isShowingResult && store.presentationID == presentationID
        }
    }

    private func nextQuestion(presentationID: UUID?) {
        guard store.isShowingResult, let presentationID else { return }
        performAction {
            store.nextQuestion(presentationID: presentationID)
        } succeeded: {
            !store.isShowingResult || store.presentationID != presentationID
        }
    }

    private func performAction(_ action: () -> Void) {
        performAction(action, succeeded: { true })
    }

    private func performAction(_ action: () -> Void, succeeded: () -> Bool) {
        guard !actionLocked, !store.storageBlocked else { return }
        actionLocked = true
        action()
        if store.error == nil && !store.storageBlocked && succeeded() && hapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        // Avoid an accidental second tap immediately after revealing a result.
        // Persisted presentation tokens also reject delayed callbacks.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            actionLocked = false
        }
    }

    private func exportRecords() {
        do {
            exportDocument = ExamRecordsDocument(data: try store.exportRecords())
            exporting = true
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func optionLabel(_ identifiers: Set<String>) -> String {
        store.shuffledOptions
            .filter { identifiers.contains($0.id) }
            .map { store.displayLabel(for: $0.id) }
            .joined(separator: "、")
    }

    private var resultTitle: String {
        store.pendingGrade == 0 ? "选择正确" : "选择有误"
    }

    private var resultIcon: String {
        store.pendingGrade == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var resultColor: Color {
        store.pendingGrade == 0 ? .green : .red
    }

    private func sourcePageLabel(_ question: ExamQuestion) -> String {
        if question.pageStart == question.pageEnd {
            return "PDF 第 \(question.pageStart) 页"
        }
        return "PDF 第 \(question.pageStart)–\(question.pageEnd) 页"
    }
}

private struct ExamOptionRow: View {
    let option: ExamOption
    let displayLabel: String
    let isSelected: Bool
    let isRevealed: Bool
    let isCorrect: Bool
    let isEnabled: Bool
    let action: () -> Void

    private var indicatorColor: Color {
        if isRevealed && isCorrect { return .green }
        if isRevealed && isSelected { return .red }
        return isSelected ? .accentColor : .secondary
    }

    private var indicator: String {
        if isRevealed && isCorrect { return "checkmark.circle.fill" }
        if isRevealed && isSelected { return "xmark.circle.fill" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private var statusLabel: String {
        if isRevealed && isCorrect { return isSelected ? "已选，正确选项" : "正确选项" }
        if isRevealed && isSelected { return "已选，错误选项" }
        return isSelected ? "已选" : "未选"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: indicator)
                    .font(.title3)
                    .foregroundStyle(indicatorColor)
                    .frame(width: 24)
                    .padding(.top, 1)
                Text(displayLabel).font(.body.weight(.semibold))
                Text(option.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color.primary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(indicatorColor.opacity(isSelected || (isRevealed && isCorrect) ? 0.09 : 0.025),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(indicatorColor.opacity(isSelected || (isRevealed && isCorrect) ? 0.7 : 0.2),
                            lineWidth: isSelected || (isRevealed && isCorrect) ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(displayLabel)，\(option.text)，\(statusLabel)")
    }
}

private struct ExamRecordsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
