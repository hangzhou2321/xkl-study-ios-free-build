import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ProfessionalCoursesView: View {
    @ObservedObject var computer: ConceptStore
    @ObservedObject var power: ConceptStore
    @Binding var subject: ConceptSubject
    @Binding var practicing: Bool
    @Binding var recalling: Bool
    var onStart: () -> Void = {}
    var onOverlayChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Picker("专业课", selection: Binding(get: { subject }, set: {
                practicing = false
                recalling = false
                subject = $0
            })) {
                Text(ConceptSubject.computer.shortTitle).tag(ConceptSubject.computer)
                Text(ConceptSubject.power.shortTitle).tag(ConceptSubject.power)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ConceptView(store: subject == .computer ? computer : power,
                        practicing: $practicing, recalling: $recalling, onStart: onStart, onOverlayChanged: onOverlayChanged)
                .id(subject.rawValue)
        }
    }
}

struct ConceptView: View {
    @ObservedObject var store: ConceptStore
    @State private var importing = false
    @Binding var practicing: Bool
    @Binding var recalling: Bool
    var onStart: () -> Void = {}
    var onOverlayChanged: (Bool) -> Void = { _ in }
    @State private var exporting = false
    @State private var document: ConceptExportDocument?
    @State private var actionLocked = false
    @State private var newConceptLimit = 3
    @State private var storyExpanded = false
    @State private var guidancePresented = false
    @State private var guidanceReturnsToPractice = false
    @State private var questionImageFailure: String?
    @AppStorage("studyHapticsEnabled") private var haptics = true

    var body: some View {
        NavigationStack {
            Group {
                if let engine = store.engine {
                    List {
                        if let course=store.teaching?.knowledgeCourse,let teaching=store.teaching {
                            Section("按知识点重新学习") {
                                Text("先讲懂，再做小题诊断；卡住时回到这个知识点或前置知识。").font(.subheadline)
                                Text("\(course.points.count) 张全新知识点卡 · 基础、强化一二讲义合并到同一知识点").font(.footnote).foregroundStyle(.secondary)
                                Button{recalling=true;onStart()}label:{Label("继续学习",systemImage:"play.fill").font(.headline).frame(maxWidth:.infinity,minHeight:44)}
                                    .buttonStyle(.borderedProminent).disabled(store.blocked)
                                Text("旧卡已全部撤下。旧记录原档保留，新诊断没有继承旧自评分数。").font(.caption).foregroundStyle(.secondary)
                            }
                            Section("辅助复习") {
                                NavigationLink("复习新知识点卡 · 单词同款调度"){
                                    ProfessionalRecallView(subject:store.subject,bank:engine.bank,teaching:teaching)
                                }
                                Text("每张卡就是一个知识点；记忆自评与小题作答分别保存。").font(.caption).foregroundStyle(.secondary)
                            }
                            Section("题库对应与原档") {
                                NavigationLink("查看基础／强化题与知识点的对应关系"){KnowledgeSourcesView(course:course)}
                                Text("组合题可对应多个知识点。题源疑点、方法缺口与范围边界单独列出，不当作已经会做。").font(.footnote).foregroundStyle(.secondary)
                                Text("原题库作答、旧背卡快照和日志均保留；本版不清库、不恢复旧备份。").font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Section("旧版卡组已撤下") {
                                Text("请导入新版知识点课程。原卡、原题作答和学习记录保留归档，不会自动转换成新卡成绩。")
                                Button("导入知识点课程") { importing = true }
                            }

                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("\(store.subject.title)考点练习", systemImage: store.subject.symbol)
                    } description: {
                        Text("导入准备好的 .xklcourse 课程包，包含小故事、例题和核对后的变式。也支持原有 .xklconcepts 题库。")
                    } actions: {
                        Button("选择文件") { importing = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(store.subject.title)
            .navigationDestination(isPresented: $practicing) { practice }
            .navigationDestination(isPresented: $recalling) {
                if let course=store.teaching?.knowledgeCourse {
                    KnowledgeLearningView(course:course,priorities:store.teaching?.cardPriorities ?? [])
                } else {
                    ContentUnavailableView("背卡主线暂不可用",systemImage:"rectangle.on.rectangle",description:Text("返回课程首页，导入带主线计划的最新版课程。"))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入课程或题库") { importing = true }
                        Button("导出全部练习记录") {
                            do { document = ConceptExportDocument(data: try store.exportRecords()); exporting = true }
                            catch { store.error = error.localizedDescription }
                        }.disabled(store.engine == nil)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) {
            switch $0 {
            case .success(let url): store.importContent(url)
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "\(store.subject.title)-逐次练习记录") {
            if case .failure(let error) = $0 { store.error = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $guidancePresented, onDismiss: {
            if store.guidance?.active != nil { store.guidanceAction("leave") }
        }) {
            ConceptGuidanceView(store: store, close: { guidancePresented = false },
                                returnToPractice: guidanceReturnsToPractice)
        }
        .alert("请检查", isPresented: Binding(get: { store.error != nil && !guidancePresented }, set: { if !$0 && !guidancePresented { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: importing || exporting || guidancePresented || store.error != nil) { _, shown in onOverlayChanged(shown) }
        .onDisappear { onOverlayChanged(guidancePresented) }
    }

    @ViewBuilder private func legacyPracticeControls(_ engine:ConceptEngine)->some View {
        Section("旧练习队列与记录") {
            Text(engine.bank.title).font(.headline)
            Text(engine.bank.scope).font(.footnote).foregroundStyle(.secondary)
            Text("主练 \(engine.activeConcepts.count) 个考点 · \(engine.activeQuestionCount) 道题")
            Text("累计已练 \(engine.record.progress.values.filter { !$0.usedQuestionIDs.isEmpty }.count) 个考点")
            if let scope = engine.bank.studyScope {
                Text(scope.title).font(.subheadline.weight(.medium))
                let parkedCount = engine.bank.concepts.reduce(0) { $0 + $1.questions.count } - engine.activeQuestionCount
                Text("另有 \(parkedCount) 道题已停用，原学习记录保留，不再进入新学或到期复习。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let url = URL(string: scope.sourceReference), url.scheme == "https" {
                    Link("查看范围依据", destination: url).font(.footnote)
                } else {
                    Text(scope.sourceReference).font(.caption).foregroundStyle(.secondary)
                }
            }
            Stepper("本次新考点：\(newConceptLimit)", value: $newConceptLimit, in: 1...25)
                .disabled(engine.shown != nil || store.blocked)
            Text(engine.shown == nil ? "到期复习全部加入；新考点从少量开始，可按实际用时调整。" : "当前练习继续原队列；结束后可设置下次的新考点数量。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(engine.shown == nil ? "开始练习" : "继续练习", systemImage: "play.fill") {
                if engine.shown == nil { store.start(newLimit: newConceptLimit) }
                if store.error == nil { practicing = true; onStart() }
            }
            .disabled(store.blocked)
            if store.teaching == nil {
                Text("当前题库还没有故事和例题。导入对应课程包后即可查看，原学习记录会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section("练习方式") {
            Text("每次默认 3 个新考点，可选 1—25 个；到期复习全部加入。答完看解析，后续改用同考点的另一道题。")
            Text("新考点可先看分步讲解，再回到原题；旧课程仍可展开故事。讲解小检查、回忆核对和选填错因不会改变客观判分。")
            Text("答错后最多补做一道未做过的变式；至少隔开 3 个其他考点，题量不足就留到明天。")
            Text("已答过的原题不会自动重刷。用完变式会显示待补题，不算已掌握。")
            Text("这是独立的专业课练习，不计入公共题库的 30 分钟预算。")
        }.font(.footnote)
    }

    @ViewBuilder private var practice: some View {
        if let e = store.engine, let c = e.concept, let q = e.question, let p = e.shown {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(c.section) · \(q.type.title)").font(.footnote).foregroundStyle(.secondary)
                    Text(c.title).font(.headline)
                    if store.currentLesson?.guide != nil {
                        Button {
                            showGuidance(c.id, fromPractice: true)
                        } label: {
                            Label("分步讲解 · 弄懂后回到这道题", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered).disabled(store.blocked || actionLocked)
                    }
                    if let lesson = store.currentLesson {
                        story(lesson, token: p.id)
                    }
                    Text(q.sourceLocation).font(.subheadline).foregroundStyle(.secondary)
                    Text(q.prompt).font(.system(size:26)).textSelection(.enabled)
                    if let note=store.teaching?.questionPracticeNotes?.first(where: { $0.questionID == q.id }) {
                        ProfessionalQuestionPracticeNoteView(store:store,note:note)
                    }
                    if let presentation=store.teaching?.questionPresentations?.first(where: { $0.questionID == q.id }) {
                        ForEach(presentation.beforeAnswer) { visual in ProfessionalVisualView(visual:visual,onFailure:{ questionImageFailure=$0 }) }
                    }
                    if let links=store.teaching?.questionLinks?.first(where: { $0.questionID == q.id }), let teaching=store.teaching {
                        ProfessionalPracticeCardsView(store:store,token:p.id,primaryIDs:links.primaryCardIDs,supplementIDs:links.supplementCardIDs,guideIDs:links.guideConceptIDs,teaching:teaching,bank:e.bank)
                    }
                    if let questionImageFailure { Text(questionImageFailure+"，本题暂缓作答。").foregroundStyle(.orange) }
                    if let reason=store.currentQuestionPracticeBlockedReason { Text(reason).foregroundStyle(.secondary) }
                    ForEach(p.order, id: \.self) { id in
                        if let option = q.options.first(where: { $0.id == id }) {
                            Button {
                                guard questionImageFailure == nil, store.currentQuestionPracticeBlockedReason == nil else { return }; perform { store.choose(id, token: p.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: indicator(id, presentation: p, question: q, revealed: e.record.review != nil))
                                    Text(ExamPresentation.label(id, in: p.order)).bold()
                                    Text(option.text).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(16)
                                .foregroundStyle(color(id, p: p, q: q, revealed: e.record.review != nil))
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                            .disabled(e.record.review != nil || store.blocked || actionLocked || questionImageFailure != nil || store.currentQuestionPracticeBlockedReason != nil)
                        }
                    }
                    if let answer = e.record.review {
                        Label(answer.isCorrect == true ? "选择正确" : "选择有误",
                              systemImage: answer.isCorrect == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(answer.isCorrect == true ? Color.green : Color.red)
                            .font(.headline)
                        if store.teaching?.questionLinks?.contains(where: { $0.questionID == q.id && (!$0.primaryCardIDs.isEmpty || !$0.supplementCardIDs.isEmpty || !$0.guideConceptIDs.isEmpty) }) == true {
                            Text(store.currentQuestionUsedCardHelp ? "本次作答前参考过关联卡片或原题资料。" : "本 App 未记录关联卡片或原题资料辅助。").font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("正确选项：" + p.order.filter { q.answer.contains($0) }
                            .map { ExamPresentation.label($0, in: p.order) }.joined(separator: "、"))
                        Text(q.explanation.components(separatedBy:"\n").first ?? q.explanation).font(.system(size:24)).textSelection(.enabled)
                        DisclosureGroup("详细说明") { Text(q.explanation).font(.system(size:22)).textSelection(.enabled) }
                        if let presentation=store.teaching?.questionPresentations?.first(where: { $0.questionID == q.id }) {
                            ForEach(presentation.afterAnswer) { visual in ProfessionalVisualView(visual:visual) }
                        }
                        Text("解题方法").font(.headline)
                        Text(e.bank.studyScope == nil ? c.method : (store.currentLesson?.keyIdea ?? c.method))
                            .textSelection(.enabled)
                        feedback(attemptID: answer.id)
                        Text(answer.retryQueued && e.record.queue.contains(c.id) ? "稍后用另一道题补练，中间至少隔 3 个其他考点。" : "本次已保存，后续复习按当前考纲换题。")
                            .font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup("题目来源与答案核对") {
                            Text(q.sourceLocation).font(.footnote)
                            Text(q.verification).font(.footnote)
                            ForEach(e.bank.sources.filter { q.sourceIDs.contains($0.id) }) { source in
                                if let url = URL(string: source.reference), url.scheme == "https" {
                                    Link(source.title, destination: url).font(.footnote)
                                } else { Text(source.title).font(.footnote) }
                            }
                        }
                    } else {
                        Text(q.type == .multiple ? "选择全部正确项后提交；少选、多选都算错。" : "点击选项直接查看结果。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading).padding(24)
                .frame(maxWidth: .infinity)
            }
            .id(p.id)
            .task(id: p.id) {
                storyExpanded = false
                questionImageFailure = nil
                if let position = store.guidance?.active, position.presentationID == p.id {
                    guidanceReturnsToPractice = true
                    guidancePresented = true
                } else if e.record.review == nil, store.shouldAutoShowGuidance(conceptID: c.id) {
                    showGuidance(c.id, fromPractice: true)
                } else if e.record.review == nil, store.currentLesson?.guide == nil, store.currentLesson != nil,
                   store.shouldAutoShowStory(conceptID: c.id) {
                    store.openStory(token: p.id, automatic: true)
                    if store.error == nil { storyExpanded = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Divider()
                    if e.record.review != nil {
                        Button("下一题") { perform { store.next(token: p.id) } }
                            .buttonStyle(.borderedProminent).frame(height: 48)
                    } else if q.type == .multiple {
                        Button("提交答案") { guard questionImageFailure == nil, store.currentQuestionPracticeBlockedReason == nil else { return }; perform { store.submit(token: p.id) } }
                            .buttonStyle(.borderedProminent).frame(height: 48)
                            .disabled(p.selected.isEmpty || questionImageFailure != nil || store.currentQuestionPracticeBlockedReason != nil)
                    } else {
                        Text("点击上方选项作答").font(.footnote).foregroundStyle(.secondary).frame(height: 48)
                    }
                    Button("撤销已熟悉") { perform { store.undo() } }
                        .font(.footnote).frame(height: 32)
                        .disabled(e.record.undoFamiliar == nil || e.record.review != nil)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20).background(.bar)
                .disabled(actionLocked || store.blocked)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("已熟悉") { perform { store.familiar(token: p.id) } }
                        .disabled(e.record.review != nil || store.blocked || actionLocked)
                        .accessibilityLabel("已熟悉这个考点，不再自动复习，可撤销")
                }
            }
            .opacity(guidancePresented || store.guidance?.active?.presentationID == p.id ||
                (e.record.review == nil && store.shouldAutoShowGuidance(conceptID: c.id)) ? 0 : 1)
            .accessibilityHidden(guidancePresented || store.guidance?.active?.presentationID == p.id ||
                (e.record.review == nil && store.shouldAutoShowGuidance(conceptID: c.id)))
            .navigationTitle(store.subject.shortTitle).navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView {
                Label("本次练习已结束", systemImage: "checkmark.circle")
            } description: {
                Text("记录已保存。到期后继续练不同的题；缺少变式的考点在目录单独显示。")
            } actions: {
                Button("返回目录") { practicing = false }
                if store.engine?.record.undoFamiliar != nil {
                    Button("撤销已熟悉") { perform { store.undo() } }.disabled(store.blocked)
                }
            }
        }
    }

    private func showGuidance(_ conceptID: String, fromPractice: Bool) {
        store.openGuidance(conceptID: conceptID, presentationID: fromPractice ? store.engine?.shown?.id : nil)
        if store.error == nil && store.guidance?.active != nil {
            guidanceReturnsToPractice = fromPractice
            guidancePresented = true
        }
    }

    private func story(_ lesson: ConceptLesson, token: UUID) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { storyExpanded },
            set: { expanded in
                if expanded && !storyExpanded {
                    store.openStory(token: token, automatic: false)
                    if store.error != nil { return }
                }
                storyExpanded = expanded
            }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                Text(lesson.story)
                Text("抓住这一点").font(.subheadline.bold())
                Text(lesson.keyIdea)
                Text("跟着做一题").font(.subheadline.bold())
                Text(lesson.workedExample)
                Text("容易忽略的条件").font(.subheadline.bold())
                Text(lesson.commonTrap)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            Label(lesson.title, systemImage: "book.pages")
                .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func feedback(attemptID: UUID) -> some View {
        let selected = store.selectedReason(attemptID: attemptID)
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(ConceptMistakeReason.allCases) { reason in
                    Button {
                        perform { store.setReason(reason, attemptID: attemptID) }
                    } label: {
                        if selected == reason {
                            Label(reason.title, systemImage: "checkmark")
                        } else {
                            Text(reason.title)
                        }
                    }
                }
                if selected != nil {
                    Divider()
                    Button("清除标记", role: .destructive) {
                        perform { store.setReason(nil, attemptID: attemptID) }
                    }
                }
            } label: {
                Label(selected?.title ?? "标记错因／蒙的（选填）", systemImage: "tag")
                    .frame(minHeight: 44)
            }
            .disabled(actionLocked || store.blocked)
            if let selected {
                Text(suggestion(selected)).font(.subheadline)
                if let lesson = store.currentLesson {
                    Text(supplement(selected, lesson: lesson))
                        .font(.subheadline).textSelection(.enabled)
                }
                Text("可更改或清除；不会修改这次对错，也不会额外增加强化轮数。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func suggestion(_ reason: ConceptMistakeReason) -> String {
        switch reason {
        case .concept:
            return "先分清概念各自解决什么问题，再比较易混淆的区别。"
        case .method:
            return "先找到题目要求和已知条件，跟着例题补上解题的关键一步。"
        case .calculation:
            return "分步复核运算、单位、正负号和数量级，避免把算错当成概念不会。"
        case .conditions:
            return "重新圈出题目的限制条件，检查结论或公式在哪些条件下才成立。"
        case .guessed:
            return "记下这次有猜测，试着说出选择依据；后续用另一道题检验。"
        }
    }

    private func supplement(_ reason: ConceptMistakeReason, lesson: ConceptLesson) -> String {
        switch reason {
        case .concept, .guessed: return lesson.keyIdea
        case .method, .calculation: return lesson.workedExample
        case .conditions: return lesson.commonTrap
        }
    }

    private func indicator(_ id: String, presentation p: ConceptPresentation,
                           question q: ConceptQuestion, revealed: Bool) -> String {
        if revealed && q.answer.contains(id) { return "checkmark.circle.fill" }
        if revealed && p.selected.contains(id) { return "xmark.circle.fill" }
        return p.selected.contains(id) ? "largecircle.fill.circle" : "circle"
    }
    private func color(_ id: String, p: ConceptPresentation, q: ConceptQuestion, revealed: Bool) -> Color {
        if revealed && q.answer.contains(id) { return .green }
        if revealed && p.selected.contains(id) { return .red }
        return .primary
    }
    private func perform(_ action: () -> Void) {
        guard !actionLocked, !store.blocked else { return }
        actionLocked = true
        action()
        if store.error == nil && haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            actionLocked = false
        }
    }
}

private struct ConceptExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
