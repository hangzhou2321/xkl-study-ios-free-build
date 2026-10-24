import SwiftUI
import UIKit
import StudyCore

private struct MathCardSelection: Identifiable { let id: String; let presentationID: UUID?; let recall: Bool; var recallSessionID: UUID? = nil }

struct MathExperienceView: View {
    @ObservedObject var store: MathExperienceStore
    @ObservedObject var legacy: MathStore
    var isVisible: Bool = true
    var previewCase: String? = nil
    var previewFont: Double? = nil
    @AppStorage("math.experience.fontSize") private var storedFontSize = 26.0
    @State private var fontSize = 26.0
    @State private var inCourse = true
    @State private var card: MathCardSelection?
    @State private var renderFailure: String?
    @State private var readyParts = Set<String>()
    @State private var previewReported = false
    @State private var familiarExpanded = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        #if DEBUG
        let _ = MathPreviewTrace.phase("experience.body",flag:inCourse)
        #endif
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Color.clear.frame(height: 1).id("math-top")
                        if inCourse {
                            course
                            #if DEBUG
                                .onAppear { MathPreviewTrace.phase("experience.course-appear") }
                            #endif
                        }
                        else if let engine = store.engine, let session = engine.current,
                                let q = engine.currentQuestion,
                                let guide = store.guide?.questions.first(where: { $0.questionID == q.id }) {
                            question(q, guide: guide, session: session, content: engine.baseline.content)
                            #if DEBUG
                                .onAppear { MathPreviewTrace.phase("experience.question-appear") }
                            #endif
                        } else { course }
                    }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .onChange(of: store.engine?.current?.id) { _, _ in
                    renderFailure = nil
                    proxy.scrollTo("math-top", anchor: .top)
                }
                .onChange(of: questionReady) { _, ready in
                    if ready { renderFailure = nil }
                    if ready, previewCase != nil {
                        if previewCase == "answer" { proxy.scrollTo("math-answer", anchor: .top) }
                        if previewCase == "details" { proxy.scrollTo("math-details", anchor: .bottom) }
                        if previewCase == "hint" { proxy.scrollTo("math-hint", anchor: .top) }
                        if previewCase != "card" { reportPreview() }
                    }
                }
            }
            .navigationTitle(inCourse ? "数学课程" : "数学")
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .toolbar { if !inCourse { Button("回到课程") { pauseCurrent(); inCourse = true } } }
            .onAppear {
                #if DEBUG
                MathPreviewTrace.phase("experience.outer-appear-enter")
                #endif
                store.processGuideInbox()
                #if DEBUG
                MathPreviewTrace.phase("experience.inbox-return")
                #endif
                configurePreview()
                #if DEBUG
                MathPreviewTrace.phase("experience.configure-return")
                #endif
                syncVisibility()
                #if DEBUG
                MathPreviewTrace.phase("experience.outer-appear-return")
                #endif
            }
            .onChange(of: isVisible) { _, _ in syncVisibility() }
            .onChange(of: fontSize) { _, value in if previewCase == nil { storedFontSize = value } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { pauseCurrent() }
                else if !inCourse && isVisible { resumeCurrent() }
            }
            .sheet(item: $card) { selection in cardSheet(selection) }
            .alert("数学记录", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
    }
    private var course: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("完整做题，再评价").font(.title2.bold())
            Text("先独立计算；需要时看一条提示。揭晓后按本次实际完成情况评价。知识卡和原题分别记录。")
            if let engine = store.engine, store.guide != nil {
                Text("原题：\(store.practiceQuestionCount) · 熟悉：\(engine.familiar.count) · 卡片队列：\(engine.cardQueue.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("已有效评价原题：\(effectiveQuestionCount(engine)) · 已评价知识卡：\(engine.cardMemories.count)").font(.subheadline)
                Button(engine.current == nil ? "开始做题" : "继续当前题") {
                    if engine.current == nil { store.start() } else { resumeCurrent() }
                    if store.engine?.current != nil { inCourse = false }
                }.buttonStyle(.borderedProminent).disabled(store.blocked)
                DisclosureGroup("熟悉列表（默认不复习）", isExpanded: $familiarExpanded) {
                    ForEach(engine.baseline.content.questions.filter { engine.familiar.contains($0.id) }) { q in
                        VStack(alignment: .leading) {
                            Text(neutralTitle(q))
                            HStack {
                                Button("恢复复习") { guard store.engine?.current?.id == engine.current?.id else { return }; store.restore(q.id) }
                                Button(engine.current == nil ? "主动抽查" : "暂存当前题并抽查") { guard store.engine?.current?.id == engine.current?.id else { return }; store.spotCheck(q.id); if store.engine?.current?.questionID == q.id { inCourse = false } }

                            }.buttonStyle(.bordered)
                        }
                    }
                }
                DisclosureGroup("独立知识卡复习（\(engine.cardQueue.count)）") {
                    ForEach(store.guide?.cards.filter { engine.cardQueue.contains($0.id) } ?? []) { c in
                        Button(c.title) { if store.startCardRecall(c.id, questionSessionID: engine.current?.id), let recall = store.engine?.currentCard { card = MathCardSelection(id: c.id, presentationID: engine.current?.id, recall: true, recallSessionID: recall.id) } }
                    }
                }
            } else {
                Text("尚无通过验证的完整做题内容。请先导入原数学包及匹配的排版指导包；未验证内容不能开始评分。")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("原版数学（只读核对）") {
                if let engine = legacy.engine {
                    Text("旧记录保留为不可变基线；本入口仅核对课程与题目。")
                    Text(engine.archive.content.title)
                    Text("\(engine.archive.events.count) 条旧事件")
                } else { Text("本机尚无旧数学档案。") }
            }
        }
    }
    private func neutralTitle(_ q: MathQuestion) -> String {
        let ordinal = (store.engine?.baseline.content.questions.firstIndex(where: { $0.id == q.id }) ?? 0) + 1
        return "\(q.type) · 来源序号 \(ordinal)"
    }
    @ViewBuilder private func question(_ q: MathQuestion, guide: MathGuideQuestion, session: MathExperienceSession, content: MathContent) -> some View {
        HStack {
            Text(neutralTitle(q)).font(.headline)
            Spacer()
            Button("A−") { fontSize = max(20, fontSize - 2) }.disabled(fontSize <= 20)
            Text("\(Int(fontSize))").font(.caption)
            Button("A+") { fontSize = min(34, fontSize + 2) }.disabled(fontSize >= 34)
        }.buttonStyle(.bordered)
        rich(guide.stem, role: "stem", session: session)
        ForEach(Array(guide.options.enumerated()), id: \.offset) { _, option in
            HStack(alignment: .top) {
                Text(option.label).font(.system(size: fontSize).bold()).padding(.top, 5)
                rich(option.blocks, role: "option-\(option.label)", session: session)
            }
        }
        if guide.requiresDiagram {
            ForEach(Array(guide.diagramVisuals.enumerated()), id: \.offset) { index, visual in
                MathExperienceImage(visual: visual, content: content, onReady: { ready in setReady(ready, role: "diagram-\(index)", session: session) }, onFailure: { if current(session.id) { renderFailure = $0 } })
                    .id(partKey("diagram-\(index)", session: session))
            }
        }
        DisclosureGroup("原完整题图核对") {
            ForEach(Array(q.questionVisuals.enumerated()), id: \.offset) { _, visual in MathExperienceImage(visual: visual, content: content) }
        }
        if session.hintShown {
            Text("提示").font(.headline).id("math-hint")
            rich(guide.hint, role: "hint", session: session)
        }
        if session.answerShown {
            Divider()
            Text("答案").font(.headline).id("math-answer")
            rich(guide.answer, role: "answer", session: session)
            Text("关键一步").font(.headline)
            rich(guide.keyStep, role: "keyStep", session: session)
            if !guide.notes.isEmpty {
                Text("题目校勘说明").font(.headline)
                ForEach(Array(guide.notes.enumerated()), id: \.offset) { _, note in Text(verbatim: note).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true) }
            }
            DisclosureGroup("详细解法", isExpanded: Binding(get: { store.engine?.current?.detailsExpanded ?? false }, set: { expanded in
                guard current(session.id) else { return }; if expanded { store.details(sessionID: session.id) } else { store.setExpanded(false, sessionID: session.id) }
            })) {
                if session.detailsExpanded { rich(guide.details, role: "details", session: session) }
            }.id("math-details")
        }
        if session.hintShown || session.answerShown {
            VStack(alignment: .leading) {
                Text("相关知识卡 · 仅查阅不记成绩").font(.headline)
                ForEach(guide.cardIDs, id: \.self) { id in
                    Button(store.guide?.cards.first(where: { $0.id == id })?.title ?? "知识卡") {
                        guard current(session.id) else { return }
                        store.openCard(id, sessionID: session.id)
                        if store.error == nil { card = MathCardSelection(id: id, presentationID: session.id, recall: false) }
                    }
                }
            }
        }
        if let reason = store.currentPracticeBlockedReason { Text("本题暂缓练习：\(reason)").foregroundStyle(.orange) }
        if let renderFailure { Text("公式排版失败，已暂停本题操作：\(renderFailure)").foregroundStyle(.red) }
    }
    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if store.canUndo { let captured = store.engine?.current?.id; Button("撤销上一题操作（15秒内）") { guard store.engine?.current?.id == captured else { return }; store.undo(); if store.engine?.current != nil { inCourse = false } }.buttonStyle(.bordered) }
            }
            if !inCourse, let session = store.engine?.current {
                VStack(spacing: 10) {
                if session.answerShown {
                    HStack {
                        Button("独立做对") { act(session.id) { store.grade(.independentCorrect, sessionID: session.id) } }.disabled(session.assisted)
                        Button("提示后做对") { act(session.id) { store.grade(.assistedCorrect, sessionID: session.id) } }
                        Button("没做对") { act(session.id) { store.grade(.incorrect, sessionID: session.id) } }
                    }.buttonStyle(.borderedProminent)
                    Text(session.assisted ? "本题已求助：不能评价为独立做对。" : "独立做对 → Good；其余两档 → Again。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("看一条提示") { act(session.id) { store.hint(sessionID: session.id) } }.disabled(session.hintShown)
                        Button("揭晓答案") { act(session.id) { store.reveal(sessionID: session.id) } }.buttonStyle(.borderedProminent)
                    }.buttonStyle(.bordered)
                }
                Button("熟悉，跳过") { act(session.id) { store.familiar(sessionID: session.id) } }
                    .font(.subheadline)
                }.disabled(renderFailure != nil || !questionReady || store.currentPracticeBlockedReason != nil)
            }
        }.disabled(store.blocked).padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
    }
    private func configurePreview() {
        if previewCase == nil { fontSize = storedFontSize }
        #if DEBUG
        guard let selected = previewCase else { return }
        if let previewFont { fontSize = previewFont }
        inCourse = selected == "familiar"
        familiarExpanded = selected == "familiar"
        if selected == "card", let session = store.engine?.current, let id = store.guide?.cards.first?.id {
            store.openCard(id, sessionID: session.id)
            card = MathCardSelection(id: id, presentationID: session.id, recall: false)
        }
        if selected == "familiar" { reportPreview() }
        #endif
    }
    private func reportPreview() {
        #if DEBUG
        guard let selected = previewCase, !previewReported else { return }
        previewReported = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard ["familiar", "card"].contains(selected) || questionReady else { previewReported = false; return }
            print("MATH_EXPERIENCE_PREVIEW_RENDERED case=\(selected) font=\(Int(fontSize))")
        }
        #endif
    }
    private func pauseCurrent() { if let id = store.engine?.current?.id { store.pause(sessionID: id) } }
    private func resumeCurrent() { if let id = store.engine?.current?.id { store.resume(sessionID: id) } }
    private func syncVisibility() {
        guard store.engine?.current != nil else { return }
        if isVisible && !inCourse && scenePhase == .active { resumeCurrent() } else { pauseCurrent() }
    }
    private func effectiveQuestionCount(_ engine: MathExperienceEngine) -> Int {
        let undone = Set(engine.events.filter { $0.kind == "undo" }.compactMap(\.target))
        let fresh = Set(engine.events.filter { $0.kind == "grade" && !undone.contains($0.id) }.compactMap(\.questionID))
        let old = Set(engine.baseline.events.filter { $0.kind == "grade" }.map(\.questionID))
        return old.union(fresh).count
    }
    private func partKey(_ role: String, session: MathExperienceSession) -> String { "\(session.id)|\(fontSize)|\(role)" }
    private func setReady(_ ready: Bool, role: String, session: MathExperienceSession) {
        guard current(session.id) else { return }
        let key = partKey(role, session: session)
        if ready { readyParts.insert(key) } else { readyParts.remove(key) }
    }
    private func rich(_ blocks: [MathRichBlock], role: String, session: MathExperienceSession) -> some View {
        let key = partKey(role, session: session)
        return MathRichTextView(blocks: blocks, fontSize: fontSize, onFailure: { if current(session.id) { renderFailure = $0 } }, onReady: { ready in
            guard current(session.id) else { return }
            if ready { readyParts.insert(key) } else { readyParts.remove(key) }
        }).id(key)
    }
    private var questionReady: Bool {
        guard let session = store.engine?.current, let guide = store.guide?.questions.first(where: { $0.questionID == session.questionID }) else { return false }
        var roles = ["stem"] + guide.options.map { "option-\($0.label)" }
        if guide.requiresDiagram { roles += guide.diagramVisuals.indices.map { "diagram-\($0)" } }
        if session.hintShown { roles.append("hint") }
        if session.answerShown { roles += ["answer", "keyStep"] }
        if session.detailsExpanded { roles.append("details") }
        return roles.allSatisfy { readyParts.contains(partKey($0, session: session)) }
    }
    private func current(_ id: UUID) -> Bool { store.engine?.current?.id == id && !store.blocked }
    private func act(_ id: UUID, _ action: () -> Void) { guard current(id), isVisible, !inCourse, scenePhase == .active, renderFailure == nil, questionReady, store.currentPracticeBlockedReason == nil else { return }; action() }
    @ViewBuilder private func cardSheet(_ selection: MathCardSelection) -> some View {
        if let c = store.guide?.cards.first(where: { $0.id == selection.id }) {
            MathExperienceCardSheet(card: c, fontSize: fontSize, recall: selection.recall, revealed: store.engine?.currentCard?.id == selection.recallSessionID && store.engine?.currentCard?.answerShown == true, reveal: {
                guard let id = selection.recallSessionID, store.engine?.currentCard?.id == id else { return }; store.revealCard(sessionID: id)
            }, rendered: { if previewCase == "card" { reportPreview() } }, close: { card = nil }, queue: {
                guard selection.presentationID == store.engine?.current?.id else { return }; store.queueCard(c.id)
            }, grade: { remembered in
                guard selection.recall, selection.presentationID == store.engine?.current?.id, let id = selection.recallSessionID, store.engine?.currentCard?.id == id else { return false }; return store.gradeCard(c.id, remembered: remembered, sessionID: id)
            })
        }
    }
}

private struct MathExperienceCardSheet: View {
    let card: MathGuideCard; let fontSize: Double; let recall: Bool; let revealed: Bool; let reveal: () -> Void; let rendered: () -> Void
    let close: () -> Void; let queue: () -> Void; let grade: (Bool) -> Bool
    @State private var graded = false
    @State private var ready = Set<String>()
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(recall ? "卡片独立回忆" : "仅查知识，不记录会了").foregroundStyle(.secondary)
                    cardRich(card.prompt, role: "prompt")
                    if !recall || revealed {
                        cardRich(card.answer, role: "answer")
                        cardRich(card.detail, role: "detail")
                    }
                    if recall {
                        if graded { Text("卡片评价已提交；原题成绩不受影响。") }
                        else if !revealed { Button("揭晓卡片", action: reveal).disabled(failure != nil || !ready.contains("prompt")) }
                        else { HStack { Button("没记住") { if allReady { graded = grade(false) } }; Button("记住了") { if allReady { graded = grade(true) } } }.buttonStyle(.bordered).disabled(!allReady) }
                    } else { Button("加入独立卡片复习", action: queue).buttonStyle(.bordered) }
                    if let failure { Text("公式排版失败，暂停卡片评分：\(failure)").foregroundStyle(.red) }
                }.padding(20)
            }.navigationTitle(card.title).toolbar { Button("关闭", action: close) }
                .onChange(of: renderReady) { _, ready in if ready { failure = nil; rendered() } }
        }
    }
    private var renderReady: Bool {
        let visibleRoles = recall && !revealed ? ["prompt"] : ["prompt", "answer", "detail"]
        return visibleRoles.allSatisfy { ready.contains($0) }
    }
    private var allReady: Bool { failure == nil && ["prompt", "answer", "detail"].allSatisfy { ready.contains($0) } }
    private func cardRich(_ blocks: [MathRichBlock], role: String) -> some View {
        MathRichTextView(blocks: blocks, fontSize: fontSize, onFailure: { failure = $0 }, onReady: { value in
            if value { ready.insert(role) } else { ready.remove(role) }
        })
    }
}

private struct MathExperienceImage: View {
    let visual: MathVisual; let content: MathContent
    var onReady: (Bool) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    @State private var expanded = false
    private var image: UIImage? {
        guard let asset = content.assets.first(where: { $0.id == visual.assetID }), let data = Data(base64Encoded: asset.dataBase64), let cg = UIImage(data: data)?.cgImage else { return nil }
        let c = visual.normalizedCrop
        guard c.count == 4, let crop = cg.cropping(to: CGRect(x: c[0] * Double(cg.width), y: c[1] * Double(cg.height), width: c[2] * Double(cg.width), height: c[3] * Double(cg.height))) else { return nil }
        return UIImage(cgImage: crop)
    }
    var body: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("本题所需图示").onAppear { onReady(true) }.onTapGesture { expanded = true }
                .sheet(isPresented: $expanded) { NavigationStack { ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(width: 1400) }.toolbar { Button("关闭") { expanded = false } } } }
        } else { Text("题图无法读取，请停止本题并核对内容包。").foregroundStyle(.red).onAppear { onReady(false); onFailure("题图读取或裁剪失败") } }
    }
}

#if DEBUG
/// All content is newly written synthetic data; explicit directories never point at Documents.
@MainActor private final class MathExperiencePreviewFixture: ObservableObject {
    let legacy: MathStore
    let store: MathExperienceStore
    let selectedCase: String
    let font: Double
    let directory: URL
    init() {
        MathPreviewTrace.phase("fixture.init-enter")
        let args = ProcessInfo.processInfo.arguments
        func arg(_ name: String) -> String? { guard let i=args.firstIndex(of:name), i+1<args.count else { return nil }; return args[i+1] }
        let selected=arg("--math-experience-case") ?? "question"
        selectedCase=selected
        font=min(34,max(20,Double(arg("--math-experience-font") ?? "26") ?? 26))
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-math-preview-"+UUID().uuidString,isDirectory:true)
        let old=directory.appendingPathComponent("MathPractice",isDirectory:true)
        let fresh=directory.appendingPathComponent("MathExperience",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:fresh,withIntermediateDirectories:true)
            let format=UIGraphicsImageRendererFormat()
            format.scale=1
            let renderer=UIGraphicsImageRenderer(size:CGSize(width:600,height:360),format:format)
            let image=renderer.image { context in
                UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:600,height:360))
                let p=UIBezierPath(); p.move(to:CGPoint(x:100,y:280)); p.addLine(to:CGPoint(x:100,y:70)); p.addLine(to:CGPoint(x:420,y:280)); p.close(); UIColor.black.setStroke(); p.lineWidth=5; p.stroke()
                ("3" as NSString).draw(at:CGPoint(x:60,y:170),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
                ("4" as NSString).draw(at:CGPoint(x:250,y:290),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
            }
            guard let pixels=image.cgImage, let jpeg=image.jpegData(compressionQuality:0.9) else { fatalError("Synthetic preview image encoding failed") }
            print("MATH_EXPERIENCE_PREVIEW_IMAGE width=\(pixels.width) height=\(pixels.height) sha256=\(StudySHA256.hex(jpeg))")
            let asset=MathAsset(id:"synthetic-diagram",mimeType:"image/jpeg",width:pixels.width,height:pixels.height,dataBase64:jpeg.base64EncodedString())
            let visual=MathVisual(assetID:asset.id,normalizedCrop:[0,0,1,1])
            func text(_ v:String)->MathRichBlock { MathRichBlock(kind:.text,value:v) }
            func math(_ v:String)->MathRichBlock { MathRichBlock(kind:.math,value:v) }
            var stem=[text("设数列一般项如下，求第二项。"),math("a_n=\\frac{n^2+1}{n+2},\\quad n\\geq1")]
            var answer=[math("a_2=\\frac54")]
            var key=[text("把序号代入分子和分母，再分别计算。")]
            var detail=[math("a_2=\\frac{2^2+1}{2+2}=\\frac54")]
            var hint=[text("先用给定序号替换一般项中的字母，再计算分子和分母。")]
            if selected == "matrix" {
                stem=[text("设矩阵如下，求其平方。"),math("M=\\begin{pmatrix}2&1\\\\0&3\\end{pmatrix}")]
                answer=[math("M^2=\\begin{pmatrix}4&5\\\\0&9\\end{pmatrix}")]
                key=[text("行与列对应相乘后求和。")]; detail=[math("(M^2)_{12}=2\\cdot1+1\\cdot3=5")]; hint=[text("按矩阵乘法定义逐项计算。")]
            } else if selected == "piecewise" {
                stem=[text("求两个指定点的函数值。"),math("f(t)=\\begin{cases}t^2,&t\\geq0\\\\-t,&t<0\\end{cases}"),math("f(-3),\\quad f(2)")]
                answer=[math("f(-3)=3,\\quad f(2)=4")]; key=[text("先判断自变量所在区间。")]; detail=[math("f(-3)=-(-3)=3,\\quad f(2)=2^2=4")]; hint=[text("先选择与自变量符号对应的分支。")]
            } else if selected == "diagram" {
                stem=[text("如图，直角三角形的两条直角边分别为3和4，求斜边长。")]
                answer=[math("c=5")]; key=[text("直角边平方和等于斜边平方。")]; detail=[math("c^2=3^2+4^2=25\\Rightarrow c=5")]; hint=[text("使用直角三角形的边长关系。")]
            }
            let isChoice = !["matrix", "piecewise", "diagram"].contains(selected)
            let choices: [MathGuideOption] = isChoice ? [MathGuideOption(label:"A",blocks:[math("\\frac54")]),MathGuideOption(label:"B",blocks:[math("\\frac32")]),MathGuideOption(label:"C",blocks:[math("2")]),MathGuideOption(label:"D",blocks:[math("\\frac72")])] : []
            let q=MathQuestion(id:"synthetic-q-01",type:isChoice ? "单选题" : "计算题",syllabusIDs:[22],prompt:"Synthetic hidden method label",questionText:"Synthetic exercise",questionVisuals:[visual],answerVisuals:[],answerText:"Synthetic answer",solutionNote:"Synthetic original note",sourceRefs:["Synthetic source 01"],duplicateAliases:[],sourceKind:"foundation",reviewStatus:"verified")
            var second=q; second.id="synthetic-q-02"; second.sourceRefs=["Synthetic source 02"]
            let bank=MathContent(format:"xkl-math-v1",id:"synthetic-math-course",title:"合成数学预览",version:"preview-1",syllabus:[MathSyllabus(id:22,title:"合成考纲")],assets:[asset],questions:[q,second])
            let bytes=try JSONEncoder().encode(bank), hash=StudySHA256.hex(bytes)
            try bytes.write(to:old.appendingPathComponent(hash+".xklmath"))
            let disk=try JSONSerialization.data(withJSONObject:["format":"xkl-math-disk-v1","contentSHA256":hash,"events":[],"importedPackageSHA256":hash])
            try disk.write(to:old.appendingPathComponent("archive.json"))
            let c=MathGuideCard(id:"synthetic-card",title:"代入与运算顺序",prompt:[text("代入负数时，如何保留运算顺序？")],answer:[text("给负数加括号，再按幂、乘除、加减的顺序计算。")],detail:[math("(-2)^2=4,\\qquad -2^2=-4")],syllabusIDs:[22],sourceMethodIDs:["synthetic-method"])
            func guideQuestion(_ source:MathQuestion)->MathGuideQuestion {
                MathGuideQuestion(questionID:source.id,sourceTextSHA256:MathGuide.sourceDigest(source),stem:stem,options:choices,answer:answer,keyStep:key,details:detail,hint:hint,cardIDs:[c.id],requiresDiagram:selected == "diagram",diagramVisuals:selected == "diagram" ? [visual]:[],notes:["合成校勘示例：以题目给定条件为准；本例不含真实题库资料。"])
            }
            let guide=MathGuide(format:"xkl-math-guide-v1",id:"synthetic-guide",version:"preview-1",baseCourseID:bank.id,basePackageSHA256:hash,cards:[c],questions:[guideQuestion(q),guideQuestion(second)])
            try JSONEncoder().encode(guide).write(to:fresh.appendingPathComponent("guide.json"))
        } catch { fatalError("Synthetic preview setup failed: \(error)") }
        let previewNow=Date()
        legacy=MathStore(directory:old,clock:{ previewNow })
        let active=MathExperienceStore(directory:fresh,legacyDirectory:old,clock:{ previewNow })
        active.start()
        if let id=active.engine?.current?.id {
            if ["hint", "card"].contains(selected) { active.hint(sessionID:id) }
            if ["answer", "details", "undo"].contains(selected) { active.reveal(sessionID:id) }
            if selected == "details" { active.details(sessionID:id) }
            if selected == "familiar" { active.familiar(sessionID:id) }
            if selected == "undo" { active.grade(.independentCorrect,sessionID:id) }
            if selected == "resume" { active.pause(sessionID:id) }
        }
        store=selected == "resume" ? MathExperienceStore(directory:fresh,legacyDirectory:old,clock:{ previewNow }) : active
        let diagnostics="case=\(selected) legacyBlocked=\(legacy.blocked) legacyEngine=\(legacy.engine != nil) legacyError=\(legacy.error ?? "none") newBlocked=\(store.blocked) newEngine=\(store.engine != nil) guide=\(store.guide != nil) newError=\(store.error ?? "none")"
        print("MATH_EXPERIENCE_PREVIEW_VALIDATION \(diagnostics)")
        MathPreviewTrace.phase("fixture.init-validated",flag:store.engine != nil && legacy.engine != nil)
        precondition(legacy.engine != nil && !legacy.blocked && legacy.error == nil && store.engine != nil && store.guide != nil && !store.blocked && store.error == nil,"Synthetic fixture validation failed: \(diagnostics)")
    }
}

struct MathExperiencePreview: View {
    @StateObject private var fixture=MathExperiencePreviewFixture()
    var body: some View {
        let _ = MathPreviewTrace.phase("preview.body")
        MathExperienceView(store:fixture.store,legacy:fixture.legacy,previewCase:fixture.selectedCase,previewFont:fixture.font)
    }
}
#endif

