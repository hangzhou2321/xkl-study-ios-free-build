import SwiftUI
import UniformTypeIdentifiers
import StudyCore

struct KnowledgeLearningView:View {
    let course:KnowledgeCourse
    var baseDirectory:URL?=nil
    @StateObject private var store:KnowledgeLearningStore
    @State private var outline=false
    @State private var references=false
    @State private var exporting=false
    @State private var document=KnowledgeRecordDocument(data:Data())
    @State private var numberInput=""
    @State private var selectedChoices=Set<String>()
    @Environment(\.scenePhase) private var scenePhase
    init(course:KnowledgeCourse,baseDirectory:URL?=nil) {
        self.course=course;self.baseDirectory=baseDirectory
        _store=StateObject(wrappedValue:KnowledgeLearningStore(course:course,baseDirectory:baseDirectory))
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let engine=store.engine {
                    progress(engine)
                    if let p=engine.current,let point=engine.point {
                        Text(point.title).font(.title2.bold()).accessibilityIdentifier("knowledge-point-title")
                        Text(point.goal).font(.subheadline).foregroundStyle(.secondary)
                        content(engine,p,point)
                        Button("讲义、基础题与强化题对应") {store.reference();references=true}
                            .buttonStyle(.bordered).accessibilityIdentifier("knowledge-source-mapping")
                    } else {
                        Label("这一段先到这里",systemImage:"checkmark.circle").font(.title2.bold())
                        Text("断点已经保存。当天的小题练习不等于已经会做全部基础和强化题；隔日复核与对应原题继续分别检验。")
                        Button("继续已暂缓的知识点") {store.start()}.buttonStyle(.borderedProminent)
                        Button("查看知识点大纲") {outline=true}
                    }
                    Text("旧版卡片已撤下，旧学习记录保留归档，没有换算成新版成绩。知识卡自评仍与小题作答分开。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error=store.error {Text(error).foregroundStyle(.red)}
            }.padding(22).frame(maxWidth:720,alignment:.leading).frame(maxWidth:.infinity)
        }
        .navigationTitle("讲懂一个知识点").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarTrailing){Button("大纲"){outline=true}}
            ToolbarItem(placement:.topBarTrailing){Button("导出"){
                do{document=KnowledgeRecordDocument(data:try store.export());exporting=true}catch{}
            }.disabled(store.engine==nil)}
        }
        .sheet(isPresented:$outline,onDismiss:{store.start()}){NavigationStack{outlineView}}
        .sheet(isPresented:$references,onDismiss:{store.start()}){NavigationStack{
            KnowledgeSourcesView(course:course,pointID:store.engine?.point?.id,baseDirectory:baseDirectory).navigationTitle("讲义与题目对应")
                .toolbar{Button("关闭"){references=false}}
        }}
        .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:course.subject.shortTitle+"-知识点诊断记录"){_ in}
        .task{store.start()}
        .onChange(of:scenePhase){_,phase in
            if phase == .active,store.engine?.current != nil{store.start()}
            else if let p=store.engine?.current,p.phase=="question"{saveDraft(p)}
        }
        .task(id:store.engine?.current?.id){
            numberInput=store.engine?.current?.selectedID ?? store.engine?.current?.draftResponse ?? ""
            selectedChoices=Set((store.engine?.current?.selectedID ?? store.engine?.current?.draftResponse ?? "").split(separator:"|").map(String.init))
        }
        .onDisappear{if let p=store.engine?.current,p.phase=="question"{saveDraft(p)}}
        #if DEBUG
        .task(id:store.engine?.current?.id){
            if let p=store.engine?.current {knowledgePreview.didRender(p.pointID,p.phase)}
        }
        #endif
    }
    private func progress(_ engine:KnowledgeLearningEngine)->some View {
        let trained=course.points.filter{engine.trainedDay($0.id) != nil}.count
        let reviewed=course.points.filter{engine.reviewPassed($0.id)}.count
        return VStack(alignment:.leading,spacing:6){
            Text("知识点 \(course.points.count) 个 · 练习完成 \(trained) · 独立检验有证据 \(reviewed)").font(.subheadline)
            ProgressView(value:Double(trained),total:Double(course.points.count))
            Text("练习完成与独立解题分开；独立检验通过后仍继续安排到期复核。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func content(_ engine:KnowledgeLearningEngine,_ p:KnowledgePresentation,_ point:KnowledgeCourse.Point)->some View {
        if p.phase=="lesson" {
            if p.page<point.sections.count {
                let section=point.sections[p.page]
                Text(section.title).font(.headline)
                Text(section.body).font(.system(size:23)).textSelection(.enabled)
                if let diagram=section.diagram{ConceptDiagramView(diagram:diagram)}
                if let example=section.example{workedExample(example)}
            } else if p.page==point.sections.count {
                Text("用一个完整例子串起来 · 新编讲解").font(.headline)
                workedExample(point.example)
            } else {
                Text("现在再记这些结论").font(.headline)
                ForEach(Array(point.keyFacts.enumerated()),id:\.offset){_,fact in Text("• "+fact).font(.system(size:22))}
            }
            Text("第 \(p.page+1) / \(point.lessonPageCount) 小步 · 本点方法练习 \(engine.learnedSkills(point.id)) / \(point.requiredSkillIDs.count)").font(.caption).foregroundStyle(.secondary)
            Button(p.page<point.sections.count && point.sections[p.page].checkpointID != nil ? "我来补上这一步":(p.page<point.lessonPageCount-1 ? "明白这一小步，继续":"检查本点方法练习")){store.readNext(p.id)}
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("knowledge-next-step")
            if p.page>0{Button("回看上一小步"){store.lessonPage(p.page-1)}}
            if let other=point.sections.indices.first(where:{$0 != p.page && (point.sections[$0].id?.hasSuffix("-alt")==true)}) {
                Button("这段没懂，换个角度解释"){store.lessonPage(other)}
            }
            Button("这会儿先学其他知识点"){store.deferCurrent()}.font(.subheadline)
        } else if let q=engine.check,p.phase=="question" || p.phase=="feedback" {
            Text(p.mode=="review" ? (p.assisted ? "复核练习 · 本次已有帮助":"独立检验 · 未记录App内帮助"):"补步骤／方法练习 · 不冒充独立成绩").font(.headline)
            if let id=q.skillID,let skill=point.skills?.first(where:{$0.id==id}){Text("本题方法："+skill.title).font(.subheadline).foregroundStyle(.secondary)}
            Text(engine.encounterCount(q.id)==0 ? "这是本题首次作答。":"此前本题已作答\(engine.encounterCount(q.id))次；这次用于练习或保持复核。")
                .font(.caption).foregroundStyle(.secondary)
            Text(q.prompt).font(.system(size:24).weight(.medium)).accessibilityIdentifier("knowledge-check-prompt")
            if q.type=="number" {
                Text(q.numeric?.requiresUnit==true ? "填写数值和单位。":"按题中指定单位填写数值：\(q.numeric?.unit ?? "")").font(.subheadline)
                TextField("先自己计算，再填写",text:$numberInput).textFieldStyle(.roundedBorder).font(.system(size:24))
                    .keyboardType(.numbersAndPunctuation).disabled(p.phase=="feedback")
                if p.phase=="question"{Button("提交计算结果"){store.answer(numberInput,token:p.id)}.buttonStyle(.borderedProminent)}
            } else {ForEach(p.order,id:\.self){id in
                if let choice=q.choices.first(where:{$0.id==id}) {
                    Button{
                        if q.type=="multiple"{if !selectedChoices.insert(id).inserted{selectedChoices.remove(id)}}else{store.answer(id,token:p.id)}
                    }label:{
                        HStack(alignment:.top){Text(choice.text).font(.system(size:22));Spacer();if p.selectedID==id || selectedChoices.contains(id){Image(systemName:"checkmark.circle")}}
                            .padding(14).frame(maxWidth:.infinity,minHeight:48,alignment:.leading)
                            .background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).disabled(p.phase=="feedback" || store.blocked)
                }
            }
                if q.type=="multiple",p.phase=="question"{Button("提交多选答案"){store.answer(selectedChoices.sorted().joined(separator:"|"),token:p.id)}.buttonStyle(.borderedProminent)}
            }
            if p.phase=="question" {
                if p.hintVisible {Text("提示："+(q.hint ?? point.keyFacts.first ?? point.sections[0].body)).font(.system(size:21)).foregroundStyle(.secondary)}
                Button("给一点提示（会记录用过帮助）"){store.hint(p.id)}.disabled(p.hintVisible)
                Button("没读懂，回到这个知识点"){store.explain()}
                Button("暂时先学其他知识点"){store.deferCurrent()}
            } else {
                let correct=p.selectedID.map{q.correct($0)} ?? false
                Label(correct ? "这道小题答对了":"先找出卡住的一步",systemImage:correct ? "checkmark.circle.fill":"arrow.uturn.backward.circle")
                    .font(.headline).foregroundStyle(correct ? .green:.orange)
                if let response=p.selectedID,q.feedback(response) != q.explanation{Text(q.feedback(response)).font(.system(size:22))}
                Text(q.explanation).font(.system(size:22)).accessibilityIdentifier("knowledge-check-feedback")
                Text(p.assisted ? "本次按有帮助练习保存，不计独立检验。":"本次未记录相关App内帮助，且与学习或相关帮助至少间隔24小时；只代表本题表现。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(correct ? "保存了，继续":"回到讲解，拆小一步再学"){store.finish(p.id)}.buttonStyle(.borderedProminent)
                if !correct {
                    if let response=p.selectedID,let tag=q.errorTag(response){Text("可能卡在："+errorTitle(tag)).font(.subheadline)}
                    Menu("我卡在这里（只补充错因，不改判分）") {
                        ForEach(["meaning","conditions","method","calculation","units","code-flow"],id:\.self){tag in Button(errorTitle(tag)){store.errorNote(tag,token:p.id)}}
                    }
                    ForEach(point.prerequisites,id:\.self){id in
                        if let prerequisite=course.point(id){Button("先补："+prerequisite.title){store.repairPrerequisite(id)}}
                    }
                    Button("先学其他知识点"){store.deferCurrent()}
                }
            }
        } else if p.phase=="complete" {
            Label(engine.reviewPassed(point.id) ? "已有不同任务与迁移的独立检验证据":"方法练习已完成，独立检验继续安排",systemImage:"checkmark.circle").font(.headline)
            Text("这不是整套基础或强化题的掌握保证。可查看本知识点关联的原题，组合题还要一起用到其他知识点。")
            Button("继续下一个知识点"){store.next()}.buttonStyle(.borderedProminent)
            Button("再读一次这个知识点"){store.explain()}
            Button("再练一道（看过帮助会按练习记录）"){store.practiceAgain()}
            if let status=engine.reviewStatus(point.id) {
                Text("下次独立复核：\(status.dueAt.formatted(date:.numeric,time:.shortened)) · 当前复核级别\(status.level)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("复核间隔共用当前词引擎表；这里的练习和能力成绩独立保存，不改变英语或旧题库成绩。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var outlineView:some View {
        List {
            Section{Text("先讲懂，再做小题；错在哪里就回到哪里补。旧卡和旧分数没有参与这条新主线。").font(.footnote)}
            ForEach(course.points){point in
                Button{store.open(point.id);outline=false}label:{
                    VStack(alignment:.leading,spacing:5){Text(point.title);Text(store.engine?.reviewPassed(point.id)==true ? "有独立检验证据，仍会到期复核":(store.engine?.trainedDay(point.id) != nil ? "方法练习已完成，待独立检验":"方法小节仍待练习")).font(.caption).foregroundStyle(.secondary)}
                }
            }
            NavigationLink("查看全部基础／强化题对应与待校勘项"){KnowledgeSourcesView(course:course,baseDirectory:baseDirectory)}
        }.navigationTitle("知识点大纲").toolbar{Button("关闭"){outline=false}}
    }
    #if DEBUG
    @Environment(\.knowledgePreview) private var knowledgePreview
    #endif
    @ViewBuilder private func workedExample(_ example:ProfessionalCardLesson.Example)->some View {
        Text(example.prompt).font(.system(size:23))
        ForEach(Array(example.steps.enumerated()),id:\.offset){i,step in Text("\(i+1). \(step)").font(.system(size:22))}
        Text("结论："+example.answer).font(.system(size:23).weight(.medium))
    }
    private func errorTitle(_ tag:String)->String {
        ["meaning":"概念含义","conditions":"适用条件／审题","method":"选方法或列式","calculation":"计算过程","units":"量纲与单位","code-flow":"程序状态与顺序"][tag] ?? tag
    }
    private func saveDraft(_ p:KnowledgePresentation) {
        store.saveDraft(store.engine?.check?.type=="multiple" ? selectedChoices.sorted().joined(separator:"|"):numberInput,token:p.id)
    }
}

struct KnowledgeSourcesView:View {
    let course:KnowledgeCourse
    var pointID:String?=nil
    var baseDirectory:URL?=nil
    var body:some View {
        List {
            Section("原讲义与资料全文") {
                Text("可查看配套原页。原文可能有相邻内容和答案，打开会保存查阅事实，不计答题成绩。").font(.footnote)
                ForEach(course.sourceDocuments){doc in
                    DisclosureGroup(doc.title){
                        ForEach(doc.pages,id:\.number){page in
                            NavigationLink("PDF第\(page.number)页"){
                                KnowledgeSourcePageView(course:course,documentID:doc.id,page:page.number,baseDirectory:baseDirectory)
                            }
                        }
                    }
                }
            }
            if let id=pointID,let point=course.point(id) {
                Section("同一知识点的讲义出处"){
                    ForEach(Array(point.sources.enumerated()),id:\.offset){_,s in
                        NavigationLink("\(s.title) · PDF第\(s.page)页"){
                            KnowledgeSourcePageView(course:course,documentID:s.documentID,page:s.page,baseDirectory:baseDirectory)
                        }
                    }
                }
            }
            Section("基础题／强化题对应") {
                ForEach(course.questionMappings.filter{pointID==nil || $0.knowledgeIDs.contains(pointID!)}){m in
                    DisclosureGroup(m.label ?? "\(m.book) · PDF第\(m.page)页"){
                        Text(status(m.status)).font(.subheadline.weight(.medium))
                        Text(m.method).font(.body)
                        ForEach(m.knowledgeIDs,id:\.self){id in if let p=course.point(id){Text("相关知识点："+p.title)}}
                        if let text=m.questionText{Text(text).font(.footnote).textSelection(.enabled)}
                        Text("来源\(m.documentID)，PDF第\(m.page)页。对应关系不等于已经独立做对。").font(.caption).foregroundStyle(.secondary)
                        NavigationLink("打开原题所在页（含上下文）"){
                            KnowledgeSourcePageView(course:course,documentID:m.documentID,page:m.page,baseDirectory:baseDirectory)
                        }
                    }
                }
            }
        }.navigationTitle("讲义与题库对应")
    }
    private func status(_ s:String)->String {
        switch s{case "supported":return "新知识卡的解法支持已核对（不是个人成绩）";case "mapped":return "知识点关联已建立，尚未按新版逐题复核解法";case "source_pending":return "题源或答案待校勘，不能当可靠诊断";case "out_of_scope":return "不列入本轮国网主线";default:return "知识或方法对应仍有缺口"}
    }
}
private struct KnowledgeSourcePageView:View {
    let course:KnowledgeCourse;let documentID:String;let page:Int
    var baseDirectory:URL?=nil
    @State private var exposureSaved=false
    @State private var error:String?
    var body:some View {
        ScrollView {
            if let error{Text(error).foregroundStyle(.red).padding()}
            else if !exposureSaved{ProgressView("正在保存查阅事件…").padding()}
            else if let doc=course.sourceDocuments.first(where:{$0.id==documentID}),let source=doc.pages.first(where:{$0.number==page}) {
                VStack(alignment:.leading,spacing:12){
                    Text("\(doc.title) · PDF第\(page)页").font(.headline)
                    Text("这是原文资料页，可能包含相邻题目与答案；查阅资料不计做对。").font(.caption).foregroundStyle(.secondary)
                    ProfessionalSourceImageView(visual:.init(id:documentID+"-page-\(page)",kind:"sourceFile",sourceFile:source.asset),assetRoot:(baseDirectory ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]).appendingPathComponent("KnowledgeSources",isDirectory:true))
                }.padding()
            } else{Text("该资料页尚未配套放入手机。知识点学习与原记录保留，请检查新版资料页资产。").padding()}
        }.navigationTitle("资料原页")
        .task {
            do {
                try KnowledgeExposureLedger.record(course:course,pointIDs:course.affectedPoints(documentID:documentID,page:page),kind:"source",reference:documentID+"/"+String(page),baseDirectory:baseDirectory)
                exposureSaved=true
            } catch{self.error="查阅事件未保存，资料暂未打开；诊断记录保留。"+error.localizedDescription}
        }
    }
}
private struct KnowledgeRecordDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.json]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws{data=configuration.file.regularFileContents ?? Data()}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{FileWrapper(regularFileWithContents:data)}
}

#if DEBUG
struct KnowledgePreviewState {var didRender:(String,String)->Void={_,_ in}}
private struct KnowledgePreviewKey:EnvironmentKey {static let defaultValue=KnowledgePreviewState()}
extension EnvironmentValues {var knowledgePreview:KnowledgePreviewState{get{self[KnowledgePreviewKey.self]}set{self[KnowledgePreviewKey.self]=newValue}}}
#endif
