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
        .sheet(isPresented:$outline){NavigationStack{outlineView}}
        .sheet(isPresented:$references){NavigationStack{
            KnowledgeSourcesView(course:course,pointID:store.engine?.point?.id).navigationTitle("讲义与题目对应")
                .toolbar{Button("关闭"){references=false}}
        }}
        .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:course.subject.shortTitle+"-知识点诊断记录"){_ in}
        .task{store.start()}
        .onChange(of:scenePhase){_,phase in if phase == .active,store.engine?.current != nil{store.start()}}
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
            Text("知识点 \(course.points.count) 个 · 当场练习通过 \(trained) · 隔日无提示复核 \(reviewed)").font(.subheadline)
            ProgressView(value:Double(trained),total:Double(course.points.count))
            Text("看过讲解不计通过；用过提示按有帮助练习记录。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func content(_ engine:KnowledgeLearningEngine,_ p:KnowledgePresentation,_ point:KnowledgeCourse.Point)->some View {
        if p.phase=="lesson" {
            if p.page<point.sections.count {
                Text(point.sections[p.page].title).font(.headline)
                Text(point.sections[p.page].body).font(.system(size:23)).textSelection(.enabled)
            } else if p.page==point.sections.count {
                Text("用一个完整例子串起来 · 新编讲解").font(.headline)
                Text(point.example.prompt).font(.system(size:23))
                ForEach(Array(point.example.steps.enumerated()),id:\.offset){i,step in Text("\(i+1). \(step)").font(.system(size:22))}
                Text("结论："+point.example.answer).font(.system(size:23).weight(.medium))
            } else {
                Text("现在再记这些结论").font(.headline)
                ForEach(Array(point.keyFacts.enumerated()),id:\.offset){_,fact in Text("• "+fact).font(.system(size:22))}
            }
            Text("第 \(p.page+1) / \(point.sections.count+2) 小步").font(.caption).foregroundStyle(.secondary)
            Button(p.page<point.sections.count+1 ? "明白这一小步，继续":"试一道小题，看看哪里没懂"){store.readNext(p.id)}
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("knowledge-next-step")
            Button("这会儿先学其他知识点"){store.deferCurrent()}.font(.subheadline)
        } else if let q=engine.check,p.phase=="question" || p.phase=="feedback" {
            Text(p.checkIndex==0 ? "当场诊断 · 刚学过，按练习记录":"隔日复核 · 先自己作答").font(.headline)
            Text(q.prompt).font(.system(size:24).weight(.medium)).accessibilityIdentifier("knowledge-check-prompt")
            ForEach(p.order,id:\.self){id in
                if let choice=q.choices.first(where:{$0.id==id}) {
                    Button{store.answer(id,token:p.id)}label:{
                        HStack(alignment:.top){Text(choice.text).font(.system(size:22));Spacer();if p.selectedID==id{Image(systemName:"checkmark.circle")}}
                            .padding(14).frame(maxWidth:.infinity,minHeight:48,alignment:.leading)
                            .background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).disabled(p.phase=="feedback" || store.blocked)
                }
            }
            if p.phase=="question" {
                if p.hintVisible {Text("提示："+(point.keyFacts.first ?? point.sections[0].body)).font(.system(size:21)).foregroundStyle(.secondary)}
                Button("给一点提示（会记录用过帮助）"){store.hint(p.id)}.disabled(p.hintVisible)
                Button("没读懂，回到这个知识点"){store.explain()}
                Button("暂时先学其他知识点"){store.deferCurrent()}
            } else {
                let correct=p.selectedID==q.answerID
                Label(correct ? "这道小题答对了":"先找出卡住的一步",systemImage:correct ? "checkmark.circle.fill":"arrow.uturn.backward.circle")
                    .font(.headline).foregroundStyle(correct ? .green:.orange)
                if let chosen=q.choices.first(where:{$0.id==p.selectedID}),chosen.feedback != q.explanation{Text(chosen.feedback).font(.system(size:22))}
                Text(q.explanation).font(.system(size:22)).accessibilityIdentifier("knowledge-check-feedback")
                Text(p.assisted ? "本次按有帮助练习保存，不计无提示复核。":"本次未在该诊断中使用系统提示；只代表这道小题的表现。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(correct ? "保存了，继续":"回到讲解，拆小一步再学"){store.finish(p.id)}.buttonStyle(.borderedProminent)
                if !correct {
                    ForEach(point.prerequisites,id:\.self){id in
                        if let prerequisite=course.point(id){Button("先补："+prerequisite.title){store.open(id);store.explain()}}
                    }
                    Button("先学其他知识点"){store.deferCurrent()}
                }
            }
        } else if p.phase=="complete" {
            Label(engine.reviewPassed(point.id) ? "本知识点有隔日无提示复核证据":"当场练习通过，隔日再复核",systemImage:"checkmark.circle").font(.headline)
            Text("这不是整套基础或强化题的掌握保证。可查看本知识点关联的原题，组合题还要一起用到其他知识点。")
            Button("继续下一个知识点"){store.next()}.buttonStyle(.borderedProminent)
            Button("再读一次这个知识点"){store.explain()}
        }
    }
    private var outlineView:some View {
        List {
            Section{Text("先讲懂，再做小题；错在哪里就回到哪里补。旧卡和旧分数没有参与这条新主线。").font(.footnote)}
            ForEach(course.points){point in
                Button{store.open(point.id);outline=false}label:{
                    VStack(alignment:.leading,spacing:5){Text(point.title);Text(store.engine?.reviewPassed(point.id)==true ? "有隔日无提示复核证据":(store.engine?.trainedDay(point.id) != nil ? "当场练习通过，待复核":"尚未通过小题诊断")).font(.caption).foregroundStyle(.secondary)}
                }
            }
            NavigationLink("查看全部基础／强化题对应与待校勘项"){KnowledgeSourcesView(course:course)}
        }.navigationTitle("知识点大纲").toolbar{Button("关闭"){outline=false}}
    }
    #if DEBUG
    @Environment(\.knowledgePreview) private var knowledgePreview
    #endif
}

struct KnowledgeSourcesView:View {
    let course:KnowledgeCourse
    var pointID:String?=nil
    var body:some View {
        List {
            if let id=pointID,let point=course.point(id) {
                Section("同一知识点的讲义出处"){
                    ForEach(Array(point.sources.enumerated()),id:\.offset){_,s in
                        NavigationLink("\(s.title) · PDF第\(s.page)页"){
                            KnowledgeSourcePageView(course:course,documentID:s.documentID,page:s.page)
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
                            KnowledgeSourcePageView(course:course,documentID:m.documentID,page:m.page)
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
    var body:some View {
        ScrollView {
            if let doc=course.sourceDocuments.first(where:{$0.id==documentID}),let source=doc.pages.first(where:{$0.number==page}) {
                VStack(alignment:.leading,spacing:12){
                    Text("\(doc.title) · PDF第\(page)页").font(.headline)
                    Text("这是原文资料页，可能包含相邻题目与答案；查阅资料不计做对。").font(.caption).foregroundStyle(.secondary)
                    ProfessionalSourceImageView(visual:.init(id:documentID+"-page-\(page)",kind:"sourceFile",sourceFile:source.asset),assetRoot:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("KnowledgeSources",isDirectory:true))
                }.padding()
            } else{Text("该资料页尚未配套放入手机。知识点学习与原记录保留，请检查新版资料页资产。").padding()}
        }.navigationTitle("资料原页")
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
