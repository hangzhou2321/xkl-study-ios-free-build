import SwiftUI
import UniformTypeIdentifiers

/// This screen owns no question grades. Every card action is persisted by the
/// dedicated store before the next presentation is published.
struct ProfessionalRecallView: View {
    @StateObject private var store: ProfessionalRecallStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var exporting = false
    @State private var document: ProfessionalRecallExportDocument?
    @State private var lastReviewedCardID: String?
    @State private var lastFeedback: String?
    @State private var checking: ProfessionalRecallCheckRequest?
    @State private var exposedKnowledgeAnswers=Set<UUID>()
    @State private var knowledgeExposureError:String?
    private let subject: ConceptSubject
    private let bank: ConceptBank
    private let teaching: ConceptTeaching
    private let scope: ProfessionalRecallScope
    private let practiceStore: ConceptStore?
    private let knowledgeBaseDirectory:URL?
    #if DEBUG
    @Environment(\.professionalRecallPreview) private var preview
    #endif

    init(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching,
         scope: ProfessionalRecallScope = .mainline, baseDirectory: URL? = nil,
         practiceStore: ConceptStore? = nil) {
        self.subject = subject; self.bank = bank; self.teaching = teaching
        self.scope = scope; self.practiceStore = practiceStore
        self.knowledgeBaseDirectory=baseDirectory
        _store = StateObject(wrappedValue: ProfessionalRecallStore(subject:subject,bank:bank,
            teaching:teaching,scope:scope,baseDirectory:baseDirectory))
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let engine=store.engine {
                    progress(engine)
                    if let feedback=lastFeedback {
                        Text(feedback).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let id=lastReviewedCardID, practiceStore != nil, scope == .mainline {
                        Button { checking=ProfessionalRecallCheckRequest(id:id) } label: {
                            Label("检验刚才这张 · 可选",systemImage:"checkmark.bubble")
                        }.font(.subheadline)
                    }
                    if let item=engine.currentItem, let presentation=engine.record.presentation {
                        VStack(alignment:.leading,spacing:18) {
                            Text(item.conceptTitle).font(.subheadline).foregroundStyle(.secondary)
                            if let priority=priority(item.card) { ProfessionalCardPriorityLabel(value:priority) }
                            Text(item.card.prompt).font(.title2.weight(.semibold)).textSelection(.enabled)
                                .accessibilityIdentifier("professional-recall-prompt")
                            if presentation.revealed {
                                if teaching.knowledgeCourse==nil || exposedKnowledgeAnswers.contains(presentation.id){answer(item.card)}
                                else{ProgressView("正在保存答案查阅事件…")}
                                Text("按翻答案前的回忆自评：说对关键条件和方法即可，不要求逐字一致。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("先自己说出答案，再翻面核对。").foregroundStyle(.secondary)
                            }
                        }.id(presentation.id)
                        .task(id:"knowledge-help-\(presentation.id)-\(presentation.revealed)") {
                            if presentation.revealed{_ = recordKnowledgeAnswer(item:item,token:presentation.id)}
                        }
                        #if DEBUG
                        .task(id:"\(presentation.id):\(presentation.revealed)") {
                            preview.didRender(ProfessionalRecallPreviewObservation(cardID:item.id,revealed:presentation.revealed,scope:scope))
                        }
                        #endif
                    } else {
                        VStack(alignment:.leading,spacing:12) {
                            Label("本轮已完成",systemImage:"checkmark.circle").font(.title2.bold())
                            Text("自评和断点已保存。可以现在停下，也可以继续下一轮。")
                                .foregroundStyle(.secondary)
                            Button("继续下一轮") { lastFeedback=nil; store.start() }
                                .buttonStyle(.borderedProminent).disabled(store.blocked)
                            if let practiceStore, scope == .mainline {
                                NavigationLink("稍后独立做题检验",destination:ProfessionalSourcesView(store:practiceStore))
                                Text("刚看过答案后的练习只能检验即时运用；隔一段时间独立作答，更能检验是否掌握。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DisclosureGroup("进度与调度说明") {
                        VStack(alignment:.leading,spacing:8) {
                            Text("记住了／没记住分别对应单词引擎的答对／答错。翻答案不算记住；原题成绩独立记录。")
                            Text("证据减量：\(engine.record.analysis.conservativeEnabled ? "已开启" : "已关闭") · 与英语减量开关同步")
                            Text("第一次就能回忆正确的卡，按单词规则不再安排复习；这里记为“首次自评记住”，不能当成做题已掌握。答错后进入当轮重现和后续跨天复习。")
                            Text("本轮新卡与到期复习由同一引擎安排；离开或锁屏不会清除队列。旧背卡历史作为迁移来源保留，不伪造为新算法作答。")
                            Text("暂时不学：把当前卡及未完成的重现步骤移到当前队列后面，不记答对或答错，不改等级和复习日期。只剩这一张时可以先离开，稍后从断点继续。")
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top,8)
                    }
                } else {
                    ContentUnavailableView("背卡暂不可用",systemImage:"rectangle.on.rectangle",
                        description:Text(store.error ?? "请返回课程首页检查已导入的主线课程。"))
                }
                if let error=store.error { Text(error).foregroundStyle(.red) }
                if let knowledgeExposureError {
                    Text(knowledgeExposureError).foregroundStyle(.red)
                    if let item=store.engine?.currentItem,let p=store.engine?.record.presentation{Button("重试保存查阅事件"){_ = recordKnowledgeAnswer(item:item,token:p.id)}}
                }
            }.padding(22).frame(maxWidth:700,alignment:.leading).frame(maxWidth:.infinity)
        }
        .navigationTitle(teaching.knowledgeCourse != nil ? "知识点卡复习" : (scope == .mainline ? "必学背卡" : "拓展选学"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge:.bottom) { actions }
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                Button("导出") {
                    do { document=ProfessionalRecallExportDocument(data:try store.export()); exporting=true }
                    catch { store.error=error.localizedDescription }
                }.disabled(store.engine == nil)
            }
        }
        .fileExporter(isPresented:$exporting,document:document,contentType:.json,
            defaultFilename:"\(subject.shortTitle)-\(scope == .mainline ? "必学" : "拓展")-背卡与迁移记录") {
                if case .failure(let error)=$0 { store.error=error.localizedDescription }
            }
        .sheet(item:$checking) { request in
            if let practiceStore { NavigationStack { ProfessionalRecallQuestionCheckView(store:practiceStore,cardID:request.id) } }
        }
        .task { store.start() }
        .onChange(of:scenePhase) { _,phase in
            // Resuming the foreground must not silently admit another lesson
            // after the completion screen has been reached.
            if phase == .active, store.engine?.currentItem != nil {
                store.start()
                if let item=store.engine?.currentItem,let p=store.engine?.record.presentation,p.revealed {
                    exposedKnowledgeAnswers.remove(p.id);_ = recordKnowledgeAnswer(item:item,token:p.id)
                }
            }
        }
        #if DEBUG
        .task(id:preview.lessonScrollTarget) {
            if let target=preview.lessonScrollTarget {
                try? await Task.sleep(for:.milliseconds(150))
                scroll.scrollTo(target,anchor:.top)
            }
        }
        #endif
        }
    }

    @ViewBuilder private func progress(_ engine:ProfessionalRecallEngine)->some View {
        if let day=try? ConceptCalendar.studyDay(Date()), let stats=try? engine.stats(on:UInt32(day)) {
            VStack(alignment:.leading,spacing:7) {
                Text("\(scope == .mainline ? "必学主线" : "拓展选学") · 已开始 \(stats.introduced) / \(stats.total) 张")
                    .font(.subheadline.weight(.medium))
                ProgressView(value:Double(stats.introduced),total:Double(max(1,stats.total)))
                Text("待学 \(stats.unintroduced) · 到期 \(stats.due)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("首次自评记住 \(stats.firstKnown) 张 · 不代表会做题").font(.caption).foregroundStyle(.secondary)
                if let info=try? engine.info {
                    Text("本轮已完成 \(info.completed) · 剩余 \(info.total_remaining)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("新自评：记住 \(stats.recalled) 次／没记住 \(stats.forgotten) 次")
                    .font(.caption).foregroundStyle(.secondary)
                if stats.legacyRemembered + stats.legacyForgotten > 0 {
                    Text("另保留旧自评：记住 \(stats.legacyRemembered) 次／没记住 \(stats.legacyForgotten) 次")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var actions:some View {
        if let engine=store.engine, let item=engine.currentItem, let p=engine.record.presentation {
            VStack(spacing:8) {
                if p.revealed {
                    HStack(spacing:14) {
                        Button("没记住") { grade(false,item:item,token:p.id) }
                            .buttonStyle(.bordered).tint(.orange)
                            .frame(maxWidth:.infinity,minHeight:44)
                            .accessibilityIdentifier("professional-recall-forgotten")
                        Button("记住了") { grade(true,item:item,token:p.id) }
                            .buttonStyle(.borderedProminent).tint(.green)
                            .frame(maxWidth:.infinity,minHeight:44)
                            .accessibilityIdentifier("professional-recall-remembered")
                    }
                } else {
                    Button("翻答案") { if recordKnowledgeAnswer(item:item,token:p.id){store.reveal(token:p.id)} }
                        .buttonStyle(.borderedProminent).frame(maxWidth:.infinity,minHeight:44)
                        .accessibilityIdentifier("professional-recall-reveal")
                }
                if engine.canPostpone {
                    Button("暂时不学 · 本轮稍后") {
                        store.postpone(token:p.id)
                        if !store.blocked, store.error == nil, store.engine?.record.presentation?.id != p.id {
                            lastFeedback="已移到当前队列后面，未计入自评；稍后仍会回来。"
                            lastReviewedCardID=nil
                        }
                    }.font(.subheadline).accessibilityIdentifier("professional-recall-postpone")
                } else {
                    Text("本轮只剩这张，可先离开，稍后从这里继续。")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("professional-recall-postpone-last-card")
                }
            }.controlSize(.large).padding(.horizontal,20).padding(.vertical,10).background(.bar)
                .disabled(store.blocked || (p.revealed && teaching.knowledgeCourse != nil && !exposedKnowledgeAnswers.contains(p.id)))
        }
    }

    private func grade(_ remembered:Bool,item:RecallDeck.Item,token:UUID) {
        store.grade(remembered:remembered,token:token)
        guard !store.blocked,store.error == nil,store.engine?.record.presentation?.id != token else { return }
        lastReviewedCardID=item.id
        lastFeedback=remembered ? "上一张已保存：记住了" : "上一张已保存：没记住，已按单词规则安排重现"
    }
    private func recordKnowledgeAnswer(item:RecallDeck.Item,token:UUID)->Bool {
        guard let course=teaching.knowledgeCourse else{return true}
        if exposedKnowledgeAnswers.contains(token){return true}
        do {
            try KnowledgeExposureLedger.record(course:course,pointIDs:[item.conceptID],kind:"recall",reference:item.id,baseDirectory:knowledgeBaseDirectory)
            exposedKnowledgeAnswers.insert(token);knowledgeExposureError=nil;return true
        } catch{knowledgeExposureError="答案查阅事件未保存，暂不显示；原自评记录保留。"+error.localizedDescription;return false}
    }
    private func priority(_ card:RecallCard)->ProfessionalCardPriority? {
        teaching.cardPriorities?.first { $0.cardID == card.id && $0.sourceCardDigest == card.professionalDigest }
    }
    @ViewBuilder private func answer(_ card:RecallCard)->some View {
        Text(card.answer).font(.system(size:25)).textSelection(.enabled)
            .accessibilityIdentifier("professional-recall-answer")
        if let lesson=teaching.applicationLesson(for:card) {
            ProfessionalCardLessonView(lesson:lesson)
        }
        if let detail=card.detail,!detail.isEmpty {
            DisclosureGroup("解释与来源") { Text(detail).font(.body).textSelection(.enabled).padding(.top,8) }
        }
        ForEach((teaching.cardCorrections ?? []).filter { $0.cardID == card.id && $0.sourceCardDigest == card.professionalDigest },id:\.cardID) { correction in
            Text("此卡有校勘，请展开核对").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
            DisclosureGroup("校勘说明") {
                VStack(alignment:.leading,spacing:8) { Text(correction.note); Text(correction.sourceRef).font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let priority=priority(card) { ProfessionalCardPriorityEvidence(value:priority) }
    }
}

/// Looking at a teaching example never grades a card or creates an original-question attempt.
private struct ProfessionalCardLessonView:View {
    let lesson:ProfessionalCardLesson
    @State private var showExample=false
    @State private var showTransfer=false
    @State private var showHint=false
    @State private var showSolution=false
    #if DEBUG
    @Environment(\.professionalRecallPreview) private var preview
    #endif
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("把知识用起来").font(.headline)
            Text(lesson.title).font(.subheadline).foregroundStyle(.secondary)
            Text(lesson.intuition).textSelection(.enabled)
                .accessibilityIdentifier("professional-lesson-intuition")
            DisclosureGroup("什么时候能这样用") {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(Array(lesson.conditions.enumerated()),id:\.offset) { _,condition in Text("• \(condition)") }
                }.padding(.top,6)
            }
            DisclosureGroup("完整例题 · 新编讲解",isExpanded:$showExample) {
                VStack(alignment:.leading,spacing:10) {
                    Text(lesson.workedExample.prompt).font(.body.weight(.medium))
                    steps(lesson.workedExample.steps)
                    Text("结论：\(lesson.workedExample.answer)").font(.body.weight(.medium))
                }.textSelection(.enabled).padding(.top,8)
                    .accessibilityIdentifier("professional-lesson-worked-example")
            }
            .id("professional-lesson-worked")
            DisclosureGroup("换个条件，先自己判断",isExpanded:$showTransfer) {
                VStack(alignment:.leading,spacing:12) {
                    Text(lesson.transferCheck.prompt).font(.body.weight(.medium)).textSelection(.enabled)
                        .accessibilityIdentifier("professional-lesson-transfer-prompt")
                    if showHint { Text(lesson.transferHint).foregroundStyle(.secondary) }
                    if !showSolution {
                        HStack {
                            Button("给一点提示") { showHint=true }.disabled(showHint)
                            Spacer()
                            Button("我想好了，看推理") { showSolution=true }
                                .accessibilityIdentifier("professional-lesson-reveal-solution")
                        }.buttonStyle(.bordered)
                    } else {
                        steps(lesson.transferCheck.steps)
                        Text("结论：\(lesson.transferCheck.answer)").font(.body.weight(.medium)).textSelection(.enabled)
                            .accessibilityIdentifier("professional-lesson-transfer-answer")
                    }
                    Text("这段用于理解和自检，不记原题成绩，也不会替本卡评为记住。稍后独立做题才能检验迁移。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top,8)
            }
            .id("professional-lesson-transfer")
            DisclosureGroup("讲义依据") {
                ForEach(Array(lesson.sourceRefs.enumerated()),id:\.offset) { _,ref in Text(ref).font(.caption).textSelection(.enabled) }
            }
        }.padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
        .onAppear {
            #if DEBUG
            showExample=preview.lessonExampleExpanded;showTransfer=preview.lessonTransferExpanded;showSolution=preview.lessonSolutionVisible
            #endif
        }
    }
    private func steps(_ values:[String])->some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(Array(values.enumerated()),id:\.offset) { index,value in Text("\(index+1). \(value)").textSelection(.enabled) }
        }
    }
}

/// Optional checks are restricted to the already selected lecture mainline.
/// Opening from a just-reviewed card is explicitly recorded as assisted practice.
private struct ProfessionalRecallQuestionCheckView:View {
    @ObservedObject var store:ConceptStore
    let cardID:String
    @Environment(\.dismiss) private var dismiss
    private var linkedQuestions:[ConceptQuestion] {
        let selected=Set(store.teaching?.studyPlan?.sourceQuestionIDs ?? [])
        let linked=Set((store.teaching?.questionLinks ?? []).filter {
            $0.primaryCardIDs.contains(cardID) || $0.supplementCardIDs.contains(cardID)
        }.map(\.questionID))
        let used=Set(store.engine?.record.progress.values.flatMap(\.usedQuestionIDs) ?? [])
        return (store.engine?.bank.concepts.flatMap(\.questions) ?? [])
            .filter { selected.contains($0.id) && linked.contains($0.id) }
            .sorted { (used.contains($0.id) ? 1:0, $0.id) < (used.contains($1.id) ? 1:0, $1.id) }
    }
    private var originalIDs:Set<String> { Set((store.teaching?.sourceLeaves ?? []).compactMap(\.bankQuestionID)) }
    var body:some View {
        List {
            Section {
                Text("先做一道，检验能否把刚才的知识用起来；随时可以返回背卡。")
                Text("刚看过关联卡，本入口记为参考过卡片的即时练习，不作为独立盲测。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.engine?.shown != nil {
                Section { NavigationLink("继续已保存的当前题") { ProfessionalSourcePracticeView(store:store,exposedCardID:cardID,returnToCards:{ dismiss() }) } }
            }
            questionSection("对应珞研原题",questions:Array(linkedQuestions.filter { originalIDs.contains($0.id) }.prefix(2)))
            questionSection("同知识点变式",questions:Array(linkedQuestions.filter { !originalIDs.contains($0.id) }.prefix(2)))
            if linkedQuestions.isEmpty {
                Text("这张卡暂没有已绑定且可呈现的主线练习。可以继续背卡；尚不能据此验证独立解题能力。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("答错后可在题内打开相关知识卡和讲解，重新核对条件与方法。做题不会替卡片评为记住。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("返回背卡") { dismiss() }
            }
        }.navigationTitle("轻量检验")
    }
    @ViewBuilder private func questionSection(_ title:String,questions:[ConceptQuestion])->some View {
        if !questions.isEmpty {
            Section(title) {
                ForEach(questions) { question in
                    NavigationLink {
                        ProfessionalSourceStartView(store:store,question:question,exposedCardID:cardID,returnToCards:{ dismiss() })
                    } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Text(question.prompt).lineLimit(3)
                            Text(question.sourceLocation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct ProfessionalRecallCheckRequest:Identifiable { let id:String }

private struct ProfessionalRecallExportDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.json] }
    var data:Data
    init(data:Data) { self.data=data }
    init(configuration:ReadConfiguration) throws { data=configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration) throws ->FileWrapper { FileWrapper(regularFileWithContents:data) }
}

#if DEBUG
struct ProfessionalRecallPreviewObservation:Equatable {
    let cardID:String
    let revealed:Bool
    let scope:ProfessionalRecallScope
}
struct ProfessionalRecallPreviewState {
    var didRender:(ProfessionalRecallPreviewObservation)->Void = { _ in }
    var lessonExampleExpanded=false
    var lessonTransferExpanded=false
    var lessonSolutionVisible=false
    var lessonScrollTarget:String?=nil
}
private struct ProfessionalRecallPreviewKey:EnvironmentKey {
    static let defaultValue=ProfessionalRecallPreviewState()
}
extension EnvironmentValues {
    var professionalRecallPreview:ProfessionalRecallPreviewState {
        get { self[ProfessionalRecallPreviewKey.self] }
        set { self[ProfessionalRecallPreviewKey.self]=newValue }
    }
}
#endif
