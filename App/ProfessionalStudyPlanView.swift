import SwiftUI
import StudyCore

struct ProfessionalRecallSelection {
    let id: String; let title: String; let cardIDs: [String]; let deckSHA256: String
    static func identifier(planID:String,scope:String,groupID:String="primary")->String {
        let value=[planID,scope,groupID].map { "\($0.utf8.count):\($0)" }.joined()
        return "professional-"+StudySHA256.hex(Data(value.utf8))
    }
}

struct ProfessionalStudyPlanView: View {
    let subject: ConceptSubject; let bank: ConceptBank; let teaching: ConceptTeaching
    var recallBaseDirectory: URL? = nil
    var practiceStore: ConceptStore? = nil
    var body: some View {
        List {
            if let plan = teaching.studyPlan {
                Section("当前必学主线") {
                    Text("基础、强化一次、强化二次讲义；以能独立完成珞研基础题与强化题为目标。")
                    Text("\(plan.mainlineCardIDs.count + plan.supplementSelections.reduce(0) { $0 + $1.mainlineCardIDs.count }) 张卡自动衔接，无需按原卡包或补卡包分别学习。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("从课程首页的“继续背卡”接着学。拓展卡不会进入必学队列。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("拓展选学") {
                    Text("不影响必学进度，按需要再学。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("进入拓展选学 · \(plan.relatedCardIDs.count + plan.supplementSelections.reduce(0) { $0 + $1.relatedCardIDs.count }) 张") {
                        ProfessionalRecallView(subject:subject,bank:bank,teaching:teaching,scope:.related,baseDirectory:recallBaseDirectory,practiceStore:practiceStore)
                    }
                }
                Section("记录与学习优先级") {
                    Text("原卡和题目 ID 保持；旧背卡记录先备份，再迁移到独立的单词同款调度。导出位于背卡页右上角，包含旧档案。")
                    Text("优先／常规／拓展表示学习优先级，不是真题考频。卡片自评与原题作答分别保存。")
                }.font(.footnote).foregroundStyle(.secondary)
            } else { Text("本课程尚无主线计划，请导入最新版课程。原记录保留。") }
        }.navigationTitle("拓展与学习范围")
    }
}

#if DEBUG
private struct ProfessionalQuestionZoomPreview {
    var autoOpen=false
    var didAppear:(Int,Int)->Void = { _,_ in }
}
private struct ProfessionalQuestionZoomKey: EnvironmentKey {
    static let defaultValue=ProfessionalQuestionZoomPreview()
}
private extension EnvironmentValues {
    var professionalQuestionZoomPreview: ProfessionalQuestionZoomPreview {
        get { self[ProfessionalQuestionZoomKey.self] }
        set { self[ProfessionalQuestionZoomKey.self]=newValue }
    }
}
#endif

struct ProfessionalVisualView: View {
    let visual: ProfessionalQuestionVisual
    var onFailure: (String) -> Void = { _ in }
    @State private var zoomed=false
    #if DEBUG
    @Environment(\.professionalQuestionZoomPreview) private var zoomPreview
    #endif
    var body: some View {
        if visual.kind == "vector", let diagram = visual.diagram {
            ConceptDiagramView(diagram: diagram)
        } else if let raster = visual.raster {
            if let image = try? raster.croppedCGImage() {
                VStack(alignment:.leading,spacing:10) {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel(raster.altText)
                        .onTapGesture { zoomed=true }
                    Button("放大题图") { zoomed=true }.buttonStyle(.bordered)
                }
                .fullScreenCover(isPresented:$zoomed) {
                    NavigationStack {
                        ScrollView([.horizontal,.vertical]) {
                            // This is the same verified crop, never the full source page.
                            Image(decorative:image,scale:1).frame(width:CGFloat(image.width),height:CGFloat(image.height)).accessibilityLabel(raster.altText)
                        }.navigationTitle("题图 · 横竖滑动查看").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("关闭") { zoomed=false } }
                    }
                    #if DEBUG
                    .onAppear { zoomPreview.didAppear(image.width,image.height) }
                    #endif
                }
                #if DEBUG
                .onAppear { if zoomPreview.autoOpen { zoomed=true } }
                #endif
            } else {
                Text("题图暂不可读，本题暂缓作答。").foregroundStyle(.orange).onAppear { onFailure("题图暂不可读") }
            }
        } else { Text("题图暂不可读，本题暂缓作答。").foregroundStyle(.orange).onAppear { onFailure("题图暂不可读") } }
    }
}

#if DEBUG
private struct ProfessionalPriorityPreviewState {
    var openCard=false
    var didRender:(String)->Void = { _ in }
}
private struct ProfessionalPriorityPreviewKey:EnvironmentKey { static let defaultValue=ProfessionalPriorityPreviewState() }
private extension EnvironmentValues {
    var professionalPriorityPreview:ProfessionalPriorityPreviewState {
        get { self[ProfessionalPriorityPreviewKey.self] }
        set { self[ProfessionalPriorityPreviewKey.self]=newValue }
    }
}
#endif

struct ProfessionalCardPriorityLabel: View {
    let value: ProfessionalCardPriority
    #if DEBUG
    @Environment(\.professionalPriorityPreview) private var preview
    #endif
    var body: some View {
        Text(value.title).font(.caption.weight(.semibold)).padding(.horizontal,10).padding(.vertical,5)
            .background(Color.accentColor.opacity(0.12),in:Capsule()).accessibilityLabel("学习优先级："+value.title)
            #if DEBUG
            .onAppear { preview.didRender(value.cardID) }
            #endif
    }
}
struct ProfessionalCardPriorityEvidence: View {
    let value: ProfessionalCardPriority
    var body: some View {
        DisclosureGroup("学习优先级依据") {
            VStack(alignment:.leading,spacing:8) {
                Text(value.basisTitle).font(.subheadline)
                Text(value.reason).font(.body)
                Text("当前资料关联 \(Set(value.sourceQuestionIDs).count) 道主线原题，不是真题考频或考试出现次数。").font(.footnote).foregroundStyle(.secondary)
                if value.level == "extension" { Text("拓展选学不表示不会考，也不表示这项知识普遍不重要。").font(.footnote).foregroundStyle(.secondary) }
            }.padding(.top,8)
        }
    }
}

private struct ProfessionalCardReference: Identifiable { let id: String; let card: RecallCard }
private struct ProfessionalGuideReference: Identifiable { let id: String; let lesson: ConceptLesson }
struct ProfessionalQuestionCardsView: View {
    let primaryIDs: [String]; let supplementIDs: [String]; var guideIDs: [String] = []; let teaching: ConceptTeaching; let bank: ConceptBank; let subject: ConceptSubject
    @State private var selection: ProfessionalCardReference?
    @State private var guideSelection: ProfessionalGuideReference?
    #if DEBUG
    @Environment(\.professionalPriorityPreview) private var priorityPreview
    #endif
    private var cards: [RecallCard] {
        let primary = (try? RecallDeck.make(subject: subject, bank: bank, teaching: teaching).cards.map(\.card)) ?? []
        return primary.filter { primaryIDs.contains($0.id) } + (teaching.recallGroups ?? []).flatMap(\.recallCards).filter { supplementIDs.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !cards.isEmpty { Text("查知识卡 · 不记录记住成绩").font(.headline) }
            ForEach(cards) { card in Button(card.prompt) { selection = ProfessionalCardReference(id: card.id, card: card) } }
            ForEach(guideIDs, id: \.self) { id in
                if let lesson=teaching.lessons.first(where: { $0.conceptID == id && $0.guide != nil }) {
                    Button("图解与讲解 · " + lesson.title) { guideSelection=ProfessionalGuideReference(id:id,lesson:lesson) }
                }
            }
        }
        #if DEBUG
        .onAppear { if priorityPreview.openCard,selection == nil,let card=cards.first { selection=ProfessionalCardReference(id:card.id,card:card) } }
        #endif
        .sheet(item: $selection) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let priority=teaching.cardPriorities?.first(where: { $0.cardID == item.card.id && $0.sourceCardDigest == item.card.professionalDigest }) {
                            ProfessionalCardPriorityLabel(value:priority)
                            ProfessionalCardPriorityEvidence(value:priority)
                        }
                        Text(item.card.prompt).font(.system(size: 26).weight(.semibold))
                        Text(item.card.answer).font(.system(size: 25))
                        if let detail = item.card.detail { DisclosureGroup("详细说明") { Text(detail).font(.system(size: 22)) } }
                        ForEach((teaching.cardCorrections ?? []).filter { $0.cardID == item.id && $0.sourceCardDigest == item.card.professionalDigest }, id: \.cardID) { correction in
                            Text("校勘说明：" + correction.note).foregroundStyle(.orange)
                            Text(correction.sourceRef).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("本页只查阅知识，不提交卡片自评，也不改变原题成绩。").font(.footnote).foregroundStyle(.secondary)
                    }.padding(22)
                }.navigationTitle("知识卡").toolbar { Button("关闭") { selection = nil } }
            }
        }
        .sheet(item:$guideSelection) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                        Text("关键要点").font(.headline)
                        Text(item.lesson.keyIdea).font(.system(size:25)).textSelection(.enabled)
                        Text("例子").font(.headline)
                        Text(item.lesson.workedExample).font(.system(size:24)).textSelection(.enabled)
                        if let guide=item.lesson.guide {
                            Text(guide.goal).font(.subheadline).foregroundStyle(.secondary)
                            ForEach(guide.steps) { step in
                                Text(step.title).font(.headline)
                                Text(step.body).font(.system(size:24)).textSelection(.enabled)
                                if let visual=step.visual {
                                    ForEach(Array(visual.items.enumerated()),id: \.offset) { _, item in
                                        VStack(alignment:.leading,spacing:6) { Text(item.label).bold(); Text(item.detail) }.font(.system(size:22))
                                    }
                                }
                                if let diagram=step.diagram { ConceptDiagramView(diagram:diagram) }
                            }
                        }
                        Text("仅查阅讲解，不提交检查或卡片自评。").font(.footnote).foregroundStyle(.secondary)
                    }.padding(22)
                }.navigationTitle(item.lesson.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("关闭") { guideSelection=nil } }
            }
        }
    }
}

/// A practice-only gate. Source browsing continues to use the read-only card view directly.
struct ProfessionalPracticeCardsView: View {
    @ObservedObject var store: ConceptStore
    let token: UUID
    let primaryIDs: [String]; let supplementIDs: [String]; let guideIDs: [String]
    let teaching: ConceptTeaching; let bank: ConceptBank
    var body: some View {
        if !primaryIDs.isEmpty || !supplementIDs.isEmpty || !guideIDs.isEmpty {
            if store.engine?.shown?.id == token {
                if store.engine?.record.review != nil || store.currentQuestionUsedCardHelp {
                    ProfessionalQuestionCardsView(primaryIDs:primaryIDs,supplementIDs:supplementIDs,guideIDs:guideIDs,teaching:teaching,bank:bank,subject:store.subject)
                } else {
                    Button("查看本题知识卡") {
                        guard store.engine?.shown?.id == token else { return }
                        _ = store.openLinkedCardHelp(token:token)
                    }.buttonStyle(.bordered).disabled(store.blocked)
                }
            }
        }
    }
}

struct ProfessionalSourcesView: View {
    @ObservedObject var store: ConceptStore
    var sourceAssetRoot: URL? = nil
    private var sections: ProfessionalSourceSections {
        ProfessionalSourceSections.make(practiceQuestionIDs:(store.engine?.bank.concepts.flatMap(\.questions) ?? []).map(\.id),
            sourceBankQuestionIDs:(store.teaching?.sourceLeaves ?? []).compactMap(\.bankQuestionID),
            selectedPlanQuestionIDs:store.teaching?.studyPlan?.sourceQuestionIDs)
    }
    private var usedQuestionIDs: Set<String> { Set(store.engine?.record.progress.values.flatMap(\.usedQuestionIDs) ?? []) }
    private func questions(_ ids:[String])->[ConceptQuestion] {
        let bank=store.engine?.bank.concepts.flatMap(\.questions) ?? []
        let byID=Dictionary(uniqueKeysWithValues:bank.map { ($0.id,$0) })
        return ids.compactMap { byID[$0] }
    }
    private func availableCount(_ ids:[String])->Int {
        ids.filter { !usedQuestionIDs.contains($0) && store.sourceQuestionAvailability($0) == nil }.count
    }
    var body: some View {
        List {
            if let teaching=store.teaching {
                if store.engine?.shown != nil {
                    Section { NavigationLink("继续上次题目") { ProfessionalSourcePracticeView(store:store) } }
                }
                if sections.usesLegacyFallback {
                    Section("全部课程练习 · \(sections.extensionQuestionIDs.count) 道") {
                        Text("当前课程没有讲义主线计划，保留全部练习入口；已作答的题仍可查阅。").font(.footnote).foregroundStyle(.secondary)
                        ForEach(questions(sections.extensionQuestionIDs)) { question in questionLink(question) }
                    }
                } else {
                    Section("珞研原题 · 共 \(sections.lectureQuestionIDs.count) 道 · 可开始 \(availableCount(sections.lectureQuestionIDs)) 道") {
                        Text("包含讲义内题和已核对的基础／强化题册题，具体来源见题目。先独立回忆，再用变式检验运用；已作答题保留查阅。").font(.footnote).foregroundStyle(.secondary)
                        ForEach(questions(sections.lectureQuestionIDs)) { question in questionLink(question) }
                        if sections.lectureQuestionIDs.isEmpty { Text("本范围暂无已绑定的珞研原题，可查看下方变式、拓展及完整来源资料。").foregroundStyle(.secondary) }
                    }
                    Section("其他练习入口") {
                        NavigationLink("同考点变式 · \(sections.variantQuestionIDs.count) 道") {
                            practiceList(title:"同考点变式",ids:sections.variantQuestionIDs,notice:"用于核对同一知识能否迁移；这是已整理的变式练习，不代表真实未见题盲测。")
                        }
                        NavigationLink("拓展与旧题库 · \(sections.extensionQuestionIDs.count) 道") {
                            practiceList(title:"拓展与旧题库",ids:sections.extensionQuestionIDs,notice:"这些练习完整保留，作为拓展和查漏入口；不计入本次默认讲义主线。")
                        }
                    }
                }
                Section("完整来源资料") {
                    NavigationLink("来源图与索引 · \((teaching.sourceLeaves ?? []).count) 条") {
                        List {
                            ForEach(teaching.sourceLeaves ?? [],id: \.sourceQuestionID) { leaf in
                                NavigationLink { ProfessionalSourceLeafView(store:store,leaf:leaf,sourceAssetRoot:sourceAssetRoot) } label: {
                                    VStack(alignment:.leading) { Text(leaf.label); ProfessionalSourceBadges(leaf:leaf) }
                                }
                            }
                        }.navigationTitle("完整来源资料")
                    }
                    Text("来源图和待补条目均保留，只读索引不作为已完成练习或成绩。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("珞研检验与资料")
    }
    private func questionLink(_ question:ConceptQuestion)->some View {
        NavigationLink { ProfessionalSourceStartView(store:store,question:question) } label: {
            VStack(alignment:.leading,spacing:5) {
                Text(question.prompt).lineLimit(2)
                Text(question.sourceLocation).font(.caption).foregroundStyle(.secondary)
                if usedQuestionIDs.contains(question.id) { Text("已作答 · 可查看记录与解析").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func practiceList(title:String,ids:[String],notice:String)->some View {
        List {
            Section { Text(notice).font(.footnote).foregroundStyle(.secondary); Text("共 \(ids.count) 道 · 当前可开始 \(availableCount(ids)) 道").font(.subheadline) }
            ForEach(questions(ids)) { question in questionLink(question) }
            if ids.isEmpty { Text("此范围暂无已核验练习。") }
        }.navigationTitle(title)
    }
}

struct ProfessionalSourceStartView: View {
    @ObservedObject var store: ConceptStore
    let question: ConceptQuestion
    var exposedCardID: String? = nil
    var returnToCards: (() -> Void)? = nil
    @State private var entered = false
    var body: some View {
        Group {
            if entered { ProfessionalSourcePracticeView(store:store,exposedCardID:exposedCardID,returnToCards:returnToCards) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error=store.error { Text(error).foregroundStyle(.red) }
                        Text(question.sourceLocation).font(.subheadline).foregroundStyle(.secondary)
                        Text(question.prompt).font(.system(size: 26))
                        if let note=store.teaching?.questionPracticeNotes?.first(where: { $0.questionID == question.id }) {
                            ProfessionalQuestionPracticeNoteView(store:store,note:note,exposedCardID:exposedCardID,returnToCards:returnToCards)
                        }
                        if let reason = store.sourceQuestionAvailability(question.id) {
                            if store.teaching?.questionPracticeNotes?.contains(where: { $0.questionID == question.id }) != true {
                                Text(reason).foregroundStyle(.secondary)
                            }
                            if let token=store.engine?.shown?.id {
                                Button("继续当前题") {
                                    if let exposedCardID { guard store.recordRecallCardExposure(cardID:exposedCardID,token:token) else { return } }
                                    entered = true
                                }
                            }
                            if let history=try? store.sourceQuestionHistory(question.id), !history.isEmpty {
                                Text("已保存 \(history.count) 次历史作答，不重复记分。").font(.footnote)
                                DisclosureGroup("查看原题解析") { Text(question.explanation).font(.system(size:24)).textSelection(.enabled) }
                            }
                        } else {
                            let captured = store.engine?.shown?.id
                            Button("做这道题") {
                                store.startQuestion(question.id, expectedCurrentToken: captured)
                                guard store.error == nil, store.engine?.question?.id == question.id else { return }
                                if let exposedCardID, let token=store.engine?.shown?.id {
                                    guard store.recordRecallCardExposure(cardID:exposedCardID,token:token) else { return }
                                }
                                entered = true
                            }.buttonStyle(.borderedProminent).disabled(store.blocked)
                        }
                    }.padding(22)
                }
            }
        }.navigationTitle("题目详情")
    }
}

/// Display-only editorial notes; the ConceptStore independently enforces holds.
struct ProfessionalQuestionPracticeNoteView:View {
    @ObservedObject var store:ConceptStore
    let note:ProfessionalQuestionPracticeNote
    var exposedCardID:String?=nil
    var returnToCards:(()->Void)?=nil
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Label("此题暂缓判分",systemImage:"text.badge.exclamationmark").font(.headline).foregroundStyle(.orange)
            Text(note.reason).textSelection(.enabled)
            Text(note.sourceRef).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach((store.engine?.bank.concepts.flatMap(\.questions) ?? []).filter { note.replacementQuestionIDs.contains($0.id) }) { replacement in
                NavigationLink {
                    ProfessionalSourceStartView(store:store,question:replacement,exposedCardID:exposedCardID,returnToCards:returnToCards)
                } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text("可改做这道已核验题")
                        Text(replacement.prompt).font(.subheadline).lineLimit(2)
                    }
                }
            }
            Text("旧作答与原题内容保留；校勘未完成前不新增本题成绩。").font(.footnote).foregroundStyle(.secondary)
        }.padding(14).background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }
}

private struct ProfessionalSourceBadges: View {
    let leaf: ProfessionalSourceLeaf
    private var sourceText: String {
        switch leaf.sourceStatus.rawValue {
        case "VERIFIED": return "源题已核"
        case "AMBIGUOUS": return "源题有歧义"
        default: return "源题尚未核验"
        }
    }
    private var readinessText: String {
        switch leaf.courseReadiness.rawValue {
        case "READY": return "课程已就绪"
        case "AWAITING_CARD": return "课程待补知识卡"
        case "AWAITING_DIAGRAM": return "课程待补题图"
        case "UNSUPPORTED_RESPONSE_TYPE": return "当前不支持此作答形式"
        case "AWAITING_CANONICAL_BINDING": return "课程待关联完整练习"
        default: return "仅保留来源资料"
        }
    }
    private var scopeText: String {
        switch leaf.scope.rawValue {
        case "MAINLINE": return "主线"
        case "RELATED_FOUNDATION": return "相关基础"
        default: return "旧范围资料"
        }
    }
    var body: some View {
        Text("\(scopeText) · \(sourceText) · \(readinessText)").font(.caption).foregroundStyle(.secondary)
    }
}

private struct ProfessionalSourceImageView: View {
    let visual: ProfessionalQuestionVisual
    var assetRoot: URL? = nil
    @State private var image: CGImage?
    @State private var fullImage: CGImage?
    @State private var failed = false
    @State private var fullScreen = false
    private var altText: String { visual.sourceFile?.altText ?? visual.raster?.altText ?? "来源图" }
    private var sourceVisualIdentity: String {
        let hash=visual.sourceFile?.sha256 ?? visual.raster?.sha256 ?? "vector"
        let crop=visual.sourceFile?.crop ?? visual.raster?.crop
        return "\(visual.id)|\(hash)|\(crop?.x ?? 0)|\(crop?.y ?? 0)|\(crop?.width ?? 1)|\(crop?.height ?? 1)"
    }
    var body: some View {
        Group {
            if visual.kind == "vector", let diagram=visual.diagram { ConceptDiagramView(diagram:diagram) }
            else if let image {
                Image(decorative:image,scale:1).resizable().scaledToFit().accessibilityLabel(altText)
                    .onTapGesture { openOriginal() }
                Button("全屏查看原图") { openOriginal() }.buttonStyle(.bordered)
                if failed { Text("完整原图暂不可读，请检查来源资料。").foregroundStyle(.secondary) }
            } else if failed { Text("本机原图暂不可读，请检查是否已导入对应来源资料。").foregroundStyle(.secondary) }
            else { ProgressView("正在打开原图…") }
        }
        .task(id:sourceVisualIdentity) {
            image=nil; fullImage=nil; failed=false
            guard visual.kind != "vector" else { return }
            do {
                if visual.kind == "sourceFile", let source=visual.sourceFile { image=try source.croppedCGImage(assetRoot:assetRoot) }
                else if visual.kind == "raster", let raster=visual.raster { image=try raster.croppedCGImage() }
                else { failed=true }
            } catch { failed=true }
        }
        .fullScreenCover(isPresented:$fullScreen) {
            NavigationStack {
                if let fullImage {
                    ScrollView([.horizontal,.vertical]) {
                        Image(decorative:fullImage,scale:1).frame(width:CGFloat(fullImage.width),height:CGFloat(fullImage.height)).accessibilityLabel(altText)
                    }.navigationTitle("原图 · 横竖滑动查看").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("关闭") { fullScreen=false } }
                }
            }
        }
    }
    private func openOriginal() {
        do {
            if visual.kind == "sourceFile", let source=visual.sourceFile { fullImage=try source.decodedCGImage(assetRoot:assetRoot) }
            else if visual.kind == "raster", let raster=visual.raster { fullImage=try raster.decodedCGImage() }
            else { fullImage=image }
            if fullImage != nil { failed=false; fullScreen=true }
        } catch { failed=true }
    }
}

private struct ProfessionalSourceLeafView: View {
    @ObservedObject var store: ConceptStore
    let leaf: ProfessionalSourceLeaf
    var sourceAssetRoot: URL? = nil
    @State private var exposureSourceID:String?
    private var exposureReady:Bool { exposureSourceID == leaf.sourceQuestionID }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if exposureReady {
                    Text(leaf.label).font(.title2.bold())
                    Text("起始页：\(leaf.page) · 见下列原图与上下文").font(.subheadline)
                    ProfessionalSourceBadges(leaf:leaf)
                    if !leaf.reason.isEmpty { Text(leaf.reason).font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(leaf.allVisuals) { visual in
                        Text(visual.sourceFile?.altText ?? visual.raster?.altText ?? visual.diagram?.description ?? "来源图与上下文").font(.subheadline).foregroundStyle(.secondary)
                        ProfessionalSourceImageView(visual:visual,assetRoot:sourceAssetRoot)
                    }
                    if let teaching=store.teaching, let bank=store.engine?.bank {
                        ProfessionalQuestionCardsView(primaryIDs:leaf.primaryCardIDs,supplementIDs:leaf.supplementCardIDs,teaching:teaching,bank:bank,subject:store.subject)
                    }
                    if leaf.status == "verified", let id=leaf.bankQuestionID,
                       let question=store.engine?.bank.concepts.flatMap(\.questions).first(where: { $0.id == id }) {
                        Text("来源页可能包含多题答案，已记录打开同页源资料；同页原题随后作答会注明资料辅助。").font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("查看完整核验题") { ProfessionalSourceStartView(store:store,question:question) }
                    } else { Text("本条仅作资料与知识卡索引，尚未开放练习。").foregroundStyle(.secondary) }
                } else {
                    Text(store.error ?? "正在保存资料查看记录…").foregroundStyle(store.error == nil ? Color.secondary:Color.red)
                    if store.error != nil { Button("重试打开资料") { prepareExposure() } }
                }
            }.padding(22)
        }.navigationTitle("来源资料")
            .task(id:leaf.sourceQuestionID) { prepareExposure() }
    }
    private func prepareExposure() {
        guard store.recordSourceExposure(sourceQuestionID:leaf.sourceQuestionID) else { return }
        exposureSourceID=leaf.sourceQuestionID
    }
}

struct ProfessionalSourcePracticeView: View {
    @ObservedObject var store: ConceptStore
    var exposedCardID:String?=nil
    var returnToCards: (() -> Void)? = nil
    @State private var imageFailure: String?
    private var exposurePending:Bool {
        guard let exposedCardID,store.engine?.record.review == nil,let links=store.currentQuestionLinks else { return false }
        return (links.primaryCardIDs.contains(exposedCardID) || links.supplementCardIDs.contains(exposedCardID)) && !store.currentQuestionUsedCardHelp
    }
    var body: some View {
        Group {
            if let engine=store.engine, let question=engine.question, let shown=engine.shown {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let error=store.error { Text(error).foregroundStyle(.red) }
                        Text(question.type.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(question.sourceLocation).font(.subheadline).foregroundStyle(.secondary)
                        Text(question.prompt).font(.system(size: 26)).textSelection(.enabled)
                        if let note=store.teaching?.questionPracticeNotes?.first(where: { $0.questionID == question.id }) {
                            ProfessionalQuestionPracticeNoteView(store:store,note:note,exposedCardID:exposedCardID,returnToCards:returnToCards)
                        }
                        if let presentation=store.teaching?.questionPresentations?.first(where: { $0.questionID == question.id }) {
                            ForEach(presentation.beforeAnswer) { visual in ProfessionalVisualView(visual:visual,onFailure:{ imageFailure=$0 }) }
                        }
                        ForEach(shown.order, id: \.self) { id in
                            if let option=question.options.first(where: { $0.id == id }) {
                                Button {
                                    guard store.engine?.shown?.id == shown.id, imageFailure == nil, !exposurePending, store.currentQuestionPracticeBlockedReason == nil else { return }
                                    store.choose(id,token:shown.id)
                                } label: {
                                    HStack(alignment:.top) {
                                        Image(systemName:shown.selected.contains(id) ? "checkmark.circle.fill":"circle")
                                        Text(ExamPresentation.label(id,in:shown.order)).bold()
                                        Text(option.text).frame(maxWidth:.infinity,alignment:.leading)
                                    }.font(.system(size:24)).padding().background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                                }.buttonStyle(.plain).disabled(engine.record.review != nil || store.blocked || imageFailure != nil || exposurePending || store.currentQuestionPracticeBlockedReason != nil)
                            }
                        }
                        if let review=engine.record.review {
                            Label(review.isCorrect == true ? "选择正确":"选择有误",systemImage:review.isCorrect == true ? "checkmark.circle.fill":"xmark.circle.fill").font(.headline)
                            Text("正确选项："+shown.order.filter { question.answer.contains($0) }.map { ExamPresentation.label($0,in:shown.order) }.joined(separator:"、")).font(.system(size:25))
                            Text(question.explanation.components(separatedBy:"\n").first ?? question.explanation).font(.system(size:24))
                            DisclosureGroup("详细说明") { Text(question.explanation).font(.system(size:22)).textSelection(.enabled) }
                            if let presentation=store.teaching?.questionPresentations?.first(where: { $0.questionID == question.id }) {
                                ForEach(presentation.afterAnswer) { visual in ProfessionalVisualView(visual:visual) }
                            }
                            Text(store.currentQuestionUsedCardHelp ? "本次作答前参考过关联卡片或原题资料。" : "本 App 未记录关联卡片或原题资料辅助。").font(.footnote).foregroundStyle(.secondary)
                            Text("本次客观作答已保存；知识卡记住成绩不受影响。").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let links=store.teaching?.questionLinks?.first(where: { $0.questionID == question.id }), let teaching=store.teaching {
                            ProfessionalPracticeCardsView(store:store,token:shown.id,primaryIDs:links.primaryCardIDs,supplementIDs:links.supplementCardIDs,guideIDs:links.guideConceptIDs,teaching:teaching,bank:engine.bank)
                        }
                        if store.currentQuestionUsedCardHelp && engine.record.review == nil {
                            Text("已记录：本次作答前参考过关联卡片或原题资料。").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let imageFailure { Text(imageFailure+"，本题暂缓作答。").foregroundStyle(.orange) }
                        if let reason=store.currentQuestionPracticeBlockedReason { Text(reason).foregroundStyle(.secondary) }
                    }.padding(22).frame(maxWidth:760).frame(maxWidth:.infinity)
                }.id(shown.id).onChange(of:shown.id) { _,_ in imageFailure=nil }
                .task(id:shown.id) {
                    if let exposedCardID { _ = store.recordRecallCardExposure(cardID:exposedCardID,token:shown.id) }
                }
                .safeAreaInset(edge:.bottom) {
                    if engine.record.review != nil {
                        Button(returnToCards == nil ? "完成本题，继续队列" : "完成检验，返回背卡") {
                            guard store.engine?.shown?.id == shown.id else { return }
                            store.next(token:shown.id)
                            if store.error == nil { returnToCards?() }
                        }.buttonStyle(.borderedProminent).padding().frame(maxWidth:.infinity).background(.bar).disabled(store.blocked)
                    } else if engine.record.review == nil && question.type == .multiple {
                        Button("提交答案") { guard store.engine?.shown?.id == shown.id, imageFailure == nil, !exposurePending, store.currentQuestionPracticeBlockedReason == nil else { return }; store.submit(token:shown.id) }
                            .buttonStyle(.borderedProminent).padding().frame(maxWidth:.infinity).background(.bar).disabled(shown.selected.isEmpty || store.blocked || imageFailure != nil || exposurePending || store.currentQuestionPracticeBlockedReason != nil)
                    }
                }
            } else { ContentUnavailableView("暂无当前题",systemImage:"checkmark.circle",description:Text("回到资料页选择一题完整核验题。")) }
        }.navigationTitle("练习作答")
    }
}

#if DEBUG
import UIKit

/// Fresh, synthetic course and real production store; never points at user AppSupport.
@MainActor private final class ProfessionalPreviewFixture: ObservableObject {
    let store: ConceptStore
    let root: URL
    let subject: ConceptSubject
    let selectedCase: String
    var recallPreviewSelection: ProfessionalRecallSelection?
    var recallPreviewGroup: SupplementRecallGroup?
    var expectedUnifiedCardID:String?
    var expectedUnifiedToken:UUID?
    var expectedUnifiedRevealed=false
    var expectedUnifiedAttempts=0
    var expectedSourceToken:UUID?
    var exposedRecallCardID:String?
    init() {
        let args=ProcessInfo.processInfo.arguments
        func value(_ key:String)->String? { guard let i=args.firstIndex(of:key),i+1<args.count else { return nil }; return args[i+1] }
        subject=value("--professional-subject") == "power" ? .power:.computer
        selectedCase=value("--professional-case") ?? "plan"
        let unifiedPreview=selectedCase.hasPrefix("unified-")
        let groupingPreview=["source-groups","source-groups-learned","source-exposure"].contains(selectedCase) || unifiedPreview
        let priorityPreview=["card-priority-front","card-priority-sheet"].contains(selectedCase) || unifiedPreview
        root=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-professional-"+UUID().uuidString,isDirectory:true)
        let target=ConceptStore(subject:subject,baseDirectory:root)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let subjectID=subject.bankID
            let first=ConceptQuestion(id:"synthetic-question-1",type:.single,prompt:"某设备只在开关接通时工作。已知开关闭合，输入为1，输出应为哪项？",options:[ExamOption(id:"yes",text:"输出1"),ExamOption(id:"no",text:"输出0")],answer:["yes"],explanation:"输出为1。\n闭合开关可传递输入；断开时不满足工作条件。",sourceIDs:["synthetic-source"],sourceLocation:groupingPreview ? "讲义原题 · 纯合成示例1":"纯合成示例第1题",verification:"合成fixture核验")
            let second=ConceptQuestion(id:"synthetic-question-2",type:.single,prompt:"同一设备在开关断开时，是否满足工作条件？",options:[ExamOption(id:"yes",text:"满足"),ExamOption(id:"no",text:"不满足")],answer:["no"],explanation:"不满足。\n先核对开关状态，再判断条件。",sourceIDs:["synthetic-source"],sourceLocation:groupingPreview ? "同考点变式 · 纯合成示例2":"纯合成示例第2题",verification:"合成fixture核验")
            let extensionQuestion=ConceptQuestion(id:"synthetic-question-3",type:.single,prompt:"拓展例：给定工作条件尚未确认，可以先认定设备工作吗？",options:[ExamOption(id:"yes",text:"可以"),ExamOption(id:"no",text:"不可以")],answer:["no"],explanation:"不能省略必要条件。",sourceIDs:["synthetic-source"],sourceLocation:"拓展旧题库 · 纯合成示例3",verification:"合成fixture核验")
            let questions=groupingPreview ? [first,second,extensionQuestion]:[first,second]
            let concept=StudyConcept(id:"synthetic-concept",title:"条件与状态",section:"合成基础",method:"先核对给定条件，再判断状态。",questions:questions)
            let bank=ConceptBank(id:subjectID,title:"合成专业课预览",scope:"仅测试界面",notice:"新写合成内容，不是真实题库。",sources:[ConceptSource(id:"synthetic-source",title:"合成题源",reference:"Synthetic fixture")],concepts:[concept])
            let cards=[RecallCard(id:"synthetic-concept:condition",prompt:"判断设备是否工作，先核对什么？",answer:"先核对题目给出的开关状态与必要工作条件。",detail:"不能只看输入，还要检查条件是否满足。"),RecallCard(id:"synthetic-concept:boundary",prompt:"条件不满足时，能直接沿用正常工作结论吗？",answer:"不能，应先重新核对适用边界。")]
            let diagram=ConceptDiagram(version:1,title:"合成闭合开关",width:320,height:160,description:"合成示意：两个接点由连线相接，表示闭合状态。",shapes:[.init(kind:"ellipse",x:126,y:76,width:8,height:8,stroke:"ink",fill:"white"),.init(kind:"ellipse",x:186,y:76,width:8,height:8,stroke:"ink",fill:"white")],paths:[.init(points:[.init(x:20,y:80),.init(x:130,y:80)],color:"ink",dashed:false,arrow:false),.init(points:[.init(x:130,y:80),.init(x:190,y:80),.init(x:300,y:80)],color:"ink",dashed:false,arrow:false)],labels:[.init(text:"闭合状态",x:70,y:110,width:180,height:30,size:18,color:"ink",align:"center",bold:true)])
            let guide=ConceptGuide(version:1,goal:"先识别状态，再判断工作条件。",referenceQuestionIDs:[first.id,second.id],relatedConceptIDs:[],remember:[.init(prompt:"判断前先核对什么？",answer:"给定状态与必要条件。"),.init(prompt:"状态变了怎么办？",answer:"重新核对适用条件。")],steps:[
                .init(id:"condition",title:"先看条件",body:"先读清题目给出的开关状态。",visual:.init(kind:"flow",items:[.init(label:"状态",detail:"核对开关是闭合还是断开。"),.init(label:"条件",detail:"判断工作条件是否满足。")]),diagram:diagram),
                .init(id:"input",title:"再看输入",body:"在条件满足后，再核对输入的取值。"),
                .init(id:"check",title:"核对边界",body:"不要把闭合状态的结论套到断开状态。",check:.init(prompt:"闭合和断开能直接沿用同一个判断吗？",options:[.init(id:"yes",text:"不能",feedback:"先核对状态。"),.init(id:"no",text:"可以",feedback:"应重新检查适用条件。")],answerID:"yes",repairStepID:"condition")),
                .init(id:"conclusion",title:"给出结论",body:"用条件、输入和状态共同支持结论。")])
            let lesson=ConceptLesson(conceptID:concept.id,title:concept.title,story:"先看条件再作判断。",keyIdea:"必要条件不能省略。",workedExample:"开关断开时不满足工作条件。",commonTrap:"忽略开关状态。",guide:guide,recallCards:cards)
            let bankBytes=try JSONEncoder().encode(bank),hash=StudySHA256.hex(bankBytes)
            let deck=RecallDeck(subject:subject,bankID:subjectID,cards:cards.map { RecallDeck.Item(conceptID:concept.id,conceptTitle:concept.title,card:$0) })
            let format=UIGraphicsImageRendererFormat();format.scale=1
            let wideQuestion=["question","question-zoom"].contains(selectedCase)
            let imageWidth:CGFloat=wideQuestion ? 1200:600
            let imageHeight:CGFloat=wideQuestion ? 440:220
            let image=UIGraphicsImageRenderer(size:CGSize(width:imageWidth,height:imageHeight),format:format).image { context in
                UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:imageWidth,height:imageHeight))
                if wideQuestion {
                    let line=UIBezierPath();line.move(to:CGPoint(x:70,y:105));line.addLine(to:CGPoint(x:1120,y:105));line.lineWidth=3;UIColor.black.setStroke();line.stroke()
                    for (x,label) in [(CGFloat(110),"Z₇ · 合成细标签"),(CGFloat(760),"Rₓ · 合成细标签")] {
                        (label as NSString).draw(at:CGPoint(x:x,y:55),withAttributes:[.font:UIFont.systemFont(ofSize:18),.foregroundColor:UIColor.black])
                    }
                    ("输入1 · 闭合开关 · 输出" as NSString).draw(at:CGPoint(x:380,y:130),withAttributes:[.font:UIFont.systemFont(ofSize:24),.foregroundColor:UIColor.black])
                    ("不可显示的答案（纯合成）" as NSString).draw(at:CGPoint(x:40,y:300),withAttributes:[.font:UIFont.boldSystemFont(ofSize:48),.foregroundColor:UIColor.red])
                } else {
                    ("1 ─── o──o ─── 输出" as NSString).draw(at:CGPoint(x:35,y:80),withAttributes:[.font:UIFont.systemFont(ofSize:38),.foregroundColor:UIColor.black])
                }
            }
            let bytes=image.pngData()!,pixels=image.cgImage!
            let raster=ProfessionalRasterAsset(mimeType:"image/png",bytes:bytes,sha256:StudySHA256.hex(bytes),pixelWidth:pixels.width,pixelHeight:pixels.height,crop:ProfessionalNormalizedCrop(x:0,y:0,width:1,height:wideQuestion ? 0.5:1),altText:"合成闭合开关示意")
            let visual=ProfessionalQuestionVisual(id:"synthetic-visual",kind:"raster",raster:raster)
            let supplementCards=(1...13).map { index in RecallCard(id:"synthetic-supplement:card-\(index)",prompt:"合成补卡\(index)：判断前应怎样核对条件？",answer:"先检查适用条件，再核对输入和状态。") }
            let supplement=SupplementRecallGroup(id:"synthetic-supplement",title:"合成补充卡组",branchID:"synthetic-branch",recallCards:supplementCards)
            let syllabus=ConceptSyllabusTree(version:1,title:"合成考纲树",outlineSource:"2027 合成预览",frequencyNote:"仅测试，不代表考试频率。",sources:[.init(id:"synthetic-source",title:"合成资料",kind:"book",edition:"2027 合成",sha256:StudySHA256.hex(Data("synthetic-source-metadata".utf8)),fileName:"synthetic-professional.pdf")],branches:[.init(id:"synthetic-branch",title:"合成基础",syllabusText:"只测试专业课界面。",scope:"mainline")],topics:[.init(id:"synthetic-topic",branchID:"synthetic-branch",title:"合成条件",conceptIDs:[concept.id])],leaves:[])
            let partition=ProfessionalSupplementSelection(groupID:supplement.id,mainlineCardIDs:Array(supplementCards.prefix(3)).map(\.id),relatedCardIDs:Array(supplementCards.dropFirst(3)).map(\.id))
            let plan=ProfessionalStudyPlan(format:"xkl-professional-plan-v1",id:"synthetic-plan",subject:subject,basePrimaryDeckSHA256:try deck.hash,mainlineCardIDs:[cards[0].id],relatedCardIDs:[cards[1].id],mainlineSupplementGroupIDs:[supplement.id],relatedSupplementGroupIDs:[supplement.id],supplementSelections:[partition],priorityConceptIDs:[concept.id],sourceQuestionIDs:[first.id,second.id])
            let presentations=questions.map { ProfessionalQuestionPresentation(questionID:$0.id,sourceQuestionDigest:$0.professionalDigest,requiredDiagram:$0.id == first.id,beforeAnswer:$0.id == first.id ? [visual]:[],afterAnswer:[]) }
            let guideOnly=selectedCase == "guide-only"
            let links=questions.map { ProfessionalQuestionLinks(questionID:$0.id,sourceQuestionDigest:$0.professionalDigest,primaryCardIDs:guideOnly ? [] : [cards[0].id],supplementCardIDs:[],guideConceptIDs:[concept.id]) }
            let correction=ProfessionalCardCorrection(cardID:cards[0].id,sourceCardDigest:cards[0].professionalDigest,note:"合成校勘例：条件必须完整核对。",sourceRef:"合成说明")
            let sourceAssetDirectory=root.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true)
            try FileManager.default.createDirectory(at:sourceAssetDirectory,withIntermediateDirectories:true)
            let sourceHash=StudySHA256.hex(bytes)
            try bytes.write(to:sourceAssetDirectory.appendingPathComponent(sourceHash+".png"),options:.atomic)
            let sourceAsset=ProfessionalSourceFileAsset(sha256:sourceHash,mimeType:"image/png",byteCount:bytes.count,pixelWidth:pixels.width,pixelHeight:pixels.height,crop:ProfessionalNormalizedCrop(x:0,y:0,width:1,height:1),altText:"合成本地原图")
            let sourceVisual=ProfessionalQuestionVisual(id:"synthetic-source-file",kind:"sourceFile",sourceFile:sourceAsset)
            let continuation=UIGraphicsImageRenderer(size:CGSize(width:600,height:220),format:format).image { context in
                UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:600,height:220))
                ("合成续页：仍需核对完整条件" as NSString).draw(at:CGPoint(x:20,y:80),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
            }
            let continuationBytes=continuation.pngData()!,continuationPixels=continuation.cgImage!
            let continuationHash=StudySHA256.hex(continuationBytes)
            try continuationBytes.write(to:sourceAssetDirectory.appendingPathComponent(continuationHash+".png"),options:.atomic)
            let continuationAsset=ProfessionalSourceFileAsset(sha256:continuationHash,mimeType:"image/png",byteCount:continuationBytes.count,pixelWidth:continuationPixels.width,pixelHeight:continuationPixels.height,crop:ProfessionalNormalizedCrop(x:0,y:0,width:1,height:1),altText:"合成续页上下文，第2页")
            let continuationVisual=ProfessionalQuestionVisual(id:"synthetic-continuation",kind:"sourceFile",sourceFile:continuationAsset)
            let leaf=ProfessionalSourceLeaf(sourceQuestionID:"synthetic-leaf",sourceID:"synthetic-source",page:1,label:"待核源图示例",status:"pending",visual:sourceVisual,primaryCardIDs:[cards[0].id],supplementCardIDs:[],sourceStatus:.unverified,courseReadiness:.awaitingCanonicalBinding,scope:.mainline,reason:"合成来源图尚未完成逐题绑定，只作资料与知识卡索引。",additionalVisuals:[continuationVisual])
            let lectureLeaf=ProfessionalSourceLeaf(sourceQuestionID:"synthetic-lecture",sourceID:"synthetic-source",page:1,label:"讲义原题 · 合成出处1",status:"verified",bankQuestionID:first.id,visual:sourceVisual,primaryCardIDs:[cards[0].id],supplementCardIDs:[],sourceStatus:.verified,courseReadiness:.ready,scope:.mainline,reason:"纯合成原题绑定。")
            let lectureAlias=ProfessionalSourceLeaf(sourceQuestionID:"synthetic-lecture-alias",sourceID:"synthetic-source",page:2,label:"同一原题 · 合成出处2",status:"verified",bankQuestionID:first.id,visual:sourceVisual,primaryCardIDs:[cards[0].id],supplementCardIDs:[],sourceStatus:.verified,courseReadiness:.ready,scope:.mainline,reason:"纯合成来源别名，不增加练习题数。")
            var teaching=ConceptTeaching(format:"xkl-teaching-v1",bankSHA256:hash,lessons:[lesson],syllabus:syllabus,recallGroups:[supplement],primaryRecallDeck:deck,studyPlan:plan,questionPresentations:presentations,questionLinks:links,cardCorrections:[correction],sourceLeaves:(groupingPreview || priorityPreview) ? [leaf,lectureLeaf,lectureAlias]:[leaf])
            if unifiedPreview {
                teaching.cardLessons=[ProfessionalCardLesson(id:"synthetic-capacity-method",title:"容量怎样连接到持续时间",bindings:(cards+supplementCards).map { .init(cardID:$0.id,sourceCardDigest:$0.professionalDigest) },intuition:"把容量看作水箱里的水量，功率看作放水速度；水箱大不等于放得快。",conditions:["使用题目明确给定的可用容量。","输出功率恒定；额定容量若有限制，需要先换成可用容量。"],workedExample:.init(prompt:"合成例：可用能量12单位，输出3单位每小时，能坚持多久？",steps:["先找总量12和每小时输出3。","12÷3=4，单位是小时。"],answer:"4小时。"),transferCheck:.init(prompt:"改成只允许用一半能量，输出仍为3单位每小时。还能坚持4小时吗？",steps:["先把12乘一半，得到可用6。","6÷3=2，原来的4小时已不适用。"],answer:"不能，只能2小时。"),transferHint:"先改可用总量，再除以原输出速度。",sourceRefs:["纯合成界面测试，无用户题库。"])]
            }
            if priorityPreview {
                let mainline=Set(plan.mainlineCardIDs+plan.supplementSelections.flatMap(\.mainlineCardIDs))
                teaching.cardPriorities=(cards+supplementCards).map { card in
                    let level=card.id == cards[0].id ? "priority":(mainline.contains(card.id) ? "regular":"extension")
                    return ProfessionalCardPriority(cardID:card.id,sourceCardDigest:card.professionalDigest,level:level,classificationBasis:level == "priority" ? "foundation":(level == "regular" ? "local_detail":"extension"),reason:level == "priority" ? "先建立学习框架，再练习应用。":(level == "regular" ? "用于核对具体条件与应用边界。":"作为当前主线之外的进一步学习。"),sourceQuestionIDs:card.id == cards[0].id ? [first.id]:[])
                }
            }
            let package=ConceptContent(format:"xkl-concepts-v1",bankBytes:bankBytes,bankSHA256:hash)
            let course=ConceptCourse(format:"xkl-course-v5",subject:subject,bankContent:try JSONEncoder().encode(package),teaching:teaching)
            let path=root.appendingPathComponent("synthetic.xklcourse")
            try JSONEncoder().encode(course).write(to:path)
            target.importContent(path)
            if ["question","question-zoom","answer","guide-only","source-groups-learned","card-priority-sheet","unified-assisted-resume"].contains(selectedCase) {
                target.startQuestion(first.id,expectedCurrentToken:nil)
                if ["answer","source-groups-learned"].contains(selectedCase),let token=target.engine?.shown?.id { target.choose("yes",token:token) }
            }
            if selectedCase == "card-priority-sheet",let token=target.engine?.shown?.id { precondition(target.openLinkedCardHelp(token:token),"Synthetic card help must persist") }
            if selectedCase == "card-priority-front" {
                let recall=RecallStore(subject:subject,bank:bank,teaching:teaching,baseDirectory:root)
                recall.act("start",newLimit:1)
                precondition(!recall.blocked && recall.error == nil && recall.engine?.record.state.shown?.revealed == false,"Synthetic recall front must persist")
            }
            if ["supplement-mainline","supplement-related"].contains(selectedCase) {
                let mainline=selectedCase == "supplement-mainline"
                let scope=mainline ? "mainline":"related"
                let selected=mainline ? partition.mainlineCardIDs:partition.relatedCardIDs
                let fullHash=try RecallDeck.makeSupplement(subject:subject,bank:bank,group:supplement).hash
                let selection=ProfessionalRecallSelection(id:ProfessionalRecallSelection.identifier(planID:plan.id,scope:scope,groupID:supplement.id),title:mainline ? "合成主线补卡":"合成拓展补卡",cardIDs:selected,deckSHA256:fullHash)
                let recall=RecallStore(subject:subject,bank:bank,teaching:teaching,baseDirectory:root,supplementGroup:supplement)
                recall.applySelection(planID:selection.id,cardIDs:selected,expectedDeckSHA256:fullHash)
                precondition(!recall.blocked && recall.error == nil && recall.engine?.selectedTotal == selected.count,"Synthetic supplement selection failed")
                recallPreviewGroup=supplement; recallPreviewSelection=selection
            }
            if unifiedPreview, selectedCase != "unified-home" {
                let scope:ProfessionalRecallScope=selectedCase == "unified-related" ? .related:.mainline
                let unified=ProfessionalRecallStore(subject:subject,bank:bank,teaching:teaching,scope:scope,baseDirectory:root)
                unified.start()
                if selectedCase == "unified-postponed",let token=unified.engine?.record.presentation?.id {
                    unified.postpone(token:token)
                    precondition(unified.engine?.record.postponements?.count == 1 && unified.engine?.record.attempts.isEmpty == true,"Postpone must be ungraded and durable")
                }
                if selectedCase == "unified-last-card" {
                    while let current=unified.engine,let p=current.record.presentation,(try current.info.total_remaining) > 1 {
                        unified.reveal(token:p.id);unified.grade(remembered:true,token:p.id)
                        precondition(!unified.blocked,"Synthetic last-card preparation must persist")
                    }
                    precondition(unified.engine?.canPostpone == false,"A last card cannot loop through postpone")
                }
                if (["unified-answer","unified-resume","unified-assisted-resume"].contains(selectedCase) || selectedCase.hasPrefix("unified-lesson")),let token=unified.engine?.record.presentation?.id { unified.reveal(token:token) }
                if selectedCase == "unified-assisted-resume",let p=unified.engine?.record.presentation {
                    exposedRecallCardID=p.cardID
                    expectedSourceToken=target.engine?.shown?.id
                    precondition(!target.currentQuestionUsedCardHelp && target.engine?.record.attempts.isEmpty == true,"Prior question must be unanswered and unassisted before card check")
                    unified.grade(remembered:true,token:p.id)
                }
                if selectedCase == "unified-resume",let token=unified.engine?.record.presentation?.id {
                    unified.grade(remembered:false,token:token)
                    if let next=unified.engine?.record.presentation?.id { unified.reveal(token:next) }
                }
                precondition(!unified.blocked && unified.error == nil && unified.engine?.currentItem != nil,"Unified synthetic fixture failed")
                expectedUnifiedCardID=unified.engine?.currentItem?.id
                expectedUnifiedToken=unified.engine?.record.presentation?.id
                expectedUnifiedRevealed=unified.engine?.record.presentation?.revealed ?? false
                expectedUnifiedAttempts=unified.engine?.record.attempts.count ?? 0
            }
            precondition(!target.blocked && target.error == nil && target.engine != nil && target.teaching != nil,"Synthetic professional fixture failed: \(target.error ?? "missing model")")
        } catch { fatalError("Synthetic professional fixture failed: \(error)") }
        store=target
    }
}

struct ProfessionalPriorityPreview: View {
    @StateObject private var fixture=ProfessionalPreviewFixture()
    @State private var zoomAppeared=false
    @State private var zoomWidth=0
    @State private var zoomHeight=0
    @State private var receiptReported=false
    @State private var priorityCardVisible:String?
    @State private var unifiedRendered:ProfessionalRecallPreviewObservation?
    var body: some View {
        NavigationStack {
            if let bank=fixture.store.engine?.bank,let teaching=fixture.store.teaching {
                if fixture.selectedCase == "unified-home" {
                    ConceptView(store:fixture.store,practicing:.constant(false),recalling:.constant(false))
                } else if fixture.selectedCase == "unified-assisted-resume" {
                    ProfessionalSourcePracticeView(store:fixture.store,exposedCardID:fixture.exposedRecallCardID)
                } else if fixture.selectedCase.hasPrefix("unified-") {
                    ProfessionalRecallView(subject:fixture.subject,bank:bank,teaching:teaching,
                        scope:fixture.selectedCase == "unified-related" ? .related:.mainline,
                        baseDirectory:fixture.root,practiceStore:fixture.store)
                } else if ["question","question-zoom","answer","guide-only","card-priority-sheet"].contains(fixture.selectedCase) { ProfessionalSourcePracticeView(store:fixture.store) }
                else if ["sources","source-groups","source-groups-learned"].contains(fixture.selectedCase) { ProfessionalSourcesView(store:fixture.store,sourceAssetRoot:fixture.root.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true)) }
                else if fixture.selectedCase == "source-exposure",let leaf=teaching.sourceLeaves?.first(where: { $0.bankQuestionID != nil }) {
                    ProfessionalSourceLeafView(store:fixture.store,leaf:leaf,sourceAssetRoot:fixture.root.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true))
                }
                else if fixture.selectedCase == "source-image",let leaf=teaching.sourceLeaves?.first {
                    ProfessionalSourceLeafView(store:fixture.store,leaf:leaf,sourceAssetRoot:fixture.root.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true))
                } else if ["supplement-mainline","supplement-related"].contains(fixture.selectedCase),let group=fixture.recallPreviewGroup,let selection=fixture.recallPreviewSelection {
                    RecallStudyView(subject:fixture.subject,bank:bank,teaching:teaching,supplementGroup:group,planSelection:selection,baseDirectory:fixture.root)
                } else if ["recall","card-priority-front"].contains(fixture.selectedCase) {
                    RecallStudyView(subject:fixture.subject,bank:bank,teaching:teaching,baseDirectory:fixture.root)
                } else { ProfessionalStudyPlanView(subject:fixture.subject,bank:bank,teaching:teaching,recallBaseDirectory:fixture.root) }
            }
        }.environment(\.professionalQuestionZoomPreview,ProfessionalQuestionZoomPreview(autoOpen:fixture.selectedCase == "question-zoom",didAppear:{ width,height in zoomWidth=width; zoomHeight=height; zoomAppeared=true }))
        .environment(\.professionalPriorityPreview,ProfessionalPriorityPreviewState(openCard:fixture.selectedCase == "card-priority-sheet",didRender:{ priorityCardVisible=$0 }))
        .environment(\.professionalRecallPreview,ProfessionalRecallPreviewState(didRender:{ unifiedRendered=$0 },lessonExampleExpanded:fixture.selectedCase == "unified-lesson-example",lessonTransferExpanded:fixture.selectedCase.hasPrefix("unified-lesson-transfer"),lessonSolutionVisible:fixture.selectedCase == "unified-lesson-transfer-answer",lessonScrollTarget:fixture.selectedCase == "unified-lesson-example" ? "professional-lesson-worked" : (fixture.selectedCase.hasPrefix("unified-lesson-transfer") ? "professional-lesson-transfer":nil)))
        .onChange(of:unifiedRendered) { _,value in if value != nil { reportWhenReady() } }
        .onAppear { if !["question-zoom","card-priority-front","card-priority-sheet"].contains(fixture.selectedCase) && (!fixture.selectedCase.hasPrefix("unified-") || ["unified-home","unified-assisted-resume"].contains(fixture.selectedCase)) { reportWhenReady() } }
        .onChange(of:priorityCardVisible) { _,id in if id != nil && ["card-priority-front","card-priority-sheet"].contains(fixture.selectedCase) { reportWhenReady() } }
        .onChange(of:zoomAppeared) { _,shown in if shown && fixture.selectedCase == "question-zoom" { reportWhenReady() } }
    }
    private func reportWhenReady() {
        guard !receiptReported else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !receiptReported,criticalStateReady() else { print("PROFESSIONAL_PREVIEW_NOT_READY"); return }
            receiptReported=true
            writeReadyReceipt()
            print("PROFESSIONAL_PREVIEW_RENDERED subject=\(fixture.subject.rawValue) case=\(fixture.selectedCase)")
        }
    }
    private func criticalStateReady()->Bool {
        guard !fixture.store.blocked,fixture.store.error == nil,let engine=fixture.store.engine,let teaching=fixture.store.teaching else { return false }
        switch fixture.selectedCase {
        case "unified-home": return teaching.studyPlan != nil && engine.shown == nil && engine.record.attempts.isEmpty
        case "unified-assisted-resume":
            return engine.shown?.id == fixture.expectedSourceToken && engine.record.review == nil && engine.record.attempts.isEmpty && fixture.store.currentQuestionUsedCardHelp && fixture.exposedRecallCardID != nil
        case "unified-front","unified-answer","unified-related","unified-resume","unified-lesson-example","unified-lesson-transfer","unified-lesson-transfer-answer","unified-postponed","unified-last-card":
            let scope:ProfessionalRecallScope=fixture.selectedCase == "unified-related" ? .related:.mainline
            let unified=ProfessionalRecallStore(subject:fixture.subject,bank:engine.bank,teaching:teaching,scope:scope,baseDirectory:fixture.root)
            guard !unified.blocked,unified.error == nil,let saved=unified.engine,let p=saved.record.presentation,
                  let observed=unifiedRendered,observed.scope == scope,observed.cardID == p.cardID,observed.revealed == p.revealed,
                  p.cardID == fixture.expectedUnifiedCardID,p.id == fixture.expectedUnifiedToken,
                  p.revealed == fixture.expectedUnifiedRevealed,saved.record.attempts.count == fixture.expectedUnifiedAttempts,
                  let plan=teaching.studyPlan else { return false }
            let mainline=Set(plan.mainlineCardIDs+plan.supplementSelections.flatMap(\.mainlineCardIDs))
            guard (scope == .mainline) == mainline.contains(p.cardID),engine.record.attempts.isEmpty else { return false }
            return true
        case "question-zoom": return zoomAppeared && zoomWidth == 1200 && zoomHeight == 220 && engine.shown != nil && engine.record.review == nil && !fixture.store.currentQuestionUsedCardHelp
        case "question", "guide-only":
            guard engine.shown != nil,engine.record.review == nil else { return false }
            if fixture.selectedCase == "guide-only" { return fixture.store.currentQuestionLinks?.primaryCardIDs.isEmpty == true && fixture.store.currentQuestionLinks?.supplementCardIDs.isEmpty == true && fixture.store.currentQuestionLinks?.guideConceptIDs.isEmpty == false }
        case "card-priority-front", "card-priority-sheet":
            guard let visible=priorityCardVisible,let label=teaching.cardPriorities?.first(where: { $0.cardID == visible }),label.level == "priority",Set(label.sourceQuestionIDs).count == 1 else { return false }
            if fixture.selectedCase == "card-priority-sheet" { return engine.shown != nil && engine.record.review == nil && fixture.store.currentQuestionUsedCardHelp }
            let recall=RecallStore(subject:fixture.subject,bank:engine.bank,teaching:teaching,baseDirectory:fixture.root)
            return !recall.blocked && recall.engine?.item?.id == visible && recall.engine?.record.state.shown?.revealed == false && !(recall.engine?.record.events.contains { $0.kind == "grade" } ?? true)
        case "answer": return engine.record.review != nil
        case "source-exposure":
            guard let leaf=teaching.sourceLeaves?.first(where: { $0.bankQuestionID != nil }),let id=leaf.bankQuestionID else { return false }
            return fixture.store.coachingEvents.filter { $0.kind == "source-read" && $0.questionID == id }.count == 1 && engine.record.attempts.isEmpty && engine.shown == nil
        case "source-image":
            guard let leaf=teaching.sourceLeaves?.first else { return false }
            for visual in leaf.allVisuals {
                if let source=visual.sourceFile {
                    do { _ = try source.croppedCGImage(assetRoot:fixture.root.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true)) } catch { return false }
                }
            }
        case "supplement-mainline", "supplement-related", "recall":
            let recall=RecallStore(subject:fixture.subject,bank:engine.bank,teaching:teaching,baseDirectory:fixture.root,supplementGroup:fixture.recallPreviewGroup)
            guard !recall.blocked,recall.error == nil,let saved=recall.engine else { return false }
            if let requested=fixture.recallPreviewSelection { return saved.record.state.selection?.id == requested.id && saved.record.state.selection?.cardIDs == requested.cardIDs && (try? saved.deck.hash) == requested.deckSHA256 }
        case "source-groups", "source-groups-learned":
            let grouped=ProfessionalSourceSections.make(practiceQuestionIDs:engine.bank.concepts.flatMap(\.questions).map(\.id),sourceBankQuestionIDs:(teaching.sourceLeaves ?? []).compactMap(\.bankQuestionID),selectedPlanQuestionIDs:teaching.studyPlan?.sourceQuestionIDs)
            guard grouped.lectureQuestionIDs == ["synthetic-question-1"],grouped.variantQuestionIDs == ["synthetic-question-2"],grouped.extensionQuestionIDs == ["synthetic-question-3"] else { return false }
            if fixture.selectedCase == "source-groups-learned" { return engine.record.progress.values.contains { $0.usedQuestionIDs.contains("synthetic-question-1") } && engine.shown?.questionID == "synthetic-question-1" && engine.record.review != nil }
        case "plan", "sources": break
        default: return false
        }
        return true
    }
    private func writeReadyReceipt() {
        let args=ProcessInfo.processInfo.arguments
        guard args.contains("--professional-preview"),let index=args.firstIndex(of:"--preview-capture-id"),index+1<args.count,let uuid=UUID(uuidString:args[index+1]) else { return }
        let captureID=uuid.uuidString.lowercased()
        do {
            let receipt:[String:Any]=["suite":"professional","subject":fixture.subject.rawValue,"case":fixture.selectedCase,"captureID":captureID,"ready":true]
            let bytes=try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys)
            let path=FileManager.default.temporaryDirectory.appendingPathComponent("professional-preview-ready-"+captureID+".json")
            try bytes.write(to:path,options:.atomic)
        } catch { print("PROFESSIONAL_PREVIEW_RECEIPT_FAILED") }
    }
}
#endif

