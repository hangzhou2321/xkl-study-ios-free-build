import SwiftUI
import UniformTypeIdentifiers
import StudyCore

struct KnowledgeLearningView:View {
    let course:KnowledgeCourse
    let priorities:[ProfessionalCardPriority]
    var baseDirectory:URL?=nil
    @StateObject private var store:KnowledgeLearningStore
    @State private var outline=false
    @State private var references=false
    @State private var exporting=false
    @State private var document=KnowledgeRecordDocument(data:Data())
    @State private var numberInput=""
    @State private var selectedChoices=Set<String>()
    @State private var stepInputs:[String:String]=[:]
    @State private var draftTask:Task<Void,Never>?
    @State private var inputToken:UUID?
    @Environment(\.scenePhase) private var scenePhase
    init(course:KnowledgeCourse,baseDirectory:URL?=nil,priorities:[ProfessionalCardPriority]=[]) {
        self.course=course;self.baseDirectory=baseDirectory;self.priorities=priorities
        _store=StateObject(wrappedValue:KnowledgeLearningStore(course:course,baseDirectory:baseDirectory))
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let engine=store.engine {
                    progress(engine)
                    if let p=engine.current,let point=engine.displayPoint {
                        Text(engine.check?.purpose=="mixed" && p.phase != "lesson" ? "组合问题":point.title).font(p.phase=="question" || p.phase=="feedback" ? .headline:.title2.bold()).accessibilityIdentifier("knowledge-point-title")
                        if p.phase=="lesson" || p.phase=="complete"{Text(point.goal).font(.subheadline).foregroundStyle(.secondary)}
                        if p.phase=="lesson",!point.inheritedPriorityTitles(priorities).isEmpty{Text("关联原标注："+point.inheritedPriorityTitles(priorities).joined(separator:"、")+" · 学习优先级，非考频").font(.caption).foregroundStyle(.secondary)}
                        content(engine,p,point)
                        Button("讲义、基础题与强化题对应") {store.reference();references=true}
                            .buttonStyle(.bordered).accessibilityIdentifier("knowledge-source-mapping")
                    } else {
                        Label("这一段先到这里",systemImage:"checkmark.circle").font(.title2.bold())
                        Text("断点已经保存。当天的小题练习不等于已经会做全部基础和强化题；隔日复核与对应原题继续分别检验。")
                        Button("继续已暂缓的知识点") {store.start()}.buttonStyle(.borderedProminent)
                        Button("查看知识点大纲") {outline=true}
                    }
                    if engine.current?.phase != "question" && engine.current?.phase != "feedback"{Text("旧版卡片和记录保留归档。知识卡自评与小题成绩分开。")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error=store.error {Text(error).foregroundStyle(.red)}
            }.padding(22).frame(maxWidth:720,alignment:.leading).frame(maxWidth:.infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("讲懂一个知识点").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarTrailing){Button("大纲"){if let p=store.engine?.current,p.phase=="question"{saveDraft(p)};outline=true}}
            ToolbarItem(placement:.topBarTrailing){Button("导出"){
                do{if let p=store.engine?.current,p.phase=="question"{saveDraft(p)};document=KnowledgeRecordDocument(data:try store.exportArchive());exporting=true}catch{}
            }.disabled(store.engine==nil)}
        }
        .sheet(isPresented:$outline,onDismiss:{store.start()}){NavigationStack{outlineView}}
        .sheet(isPresented:$references,onDismiss:{store.start()}){NavigationStack{
            KnowledgeSourcesView(course:course,pointID:store.engine?.point?.id,baseDirectory:baseDirectory).navigationTitle("讲义与题目对应")
                .toolbar{Button("关闭"){references=false}}
        }}
        .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:course.subject.shortTitle+"-教学完整归档"){_ in}
        .task{store.start()}
        .onChange(of:scenePhase){_,phase in
            if phase == .active,store.engine?.current != nil{store.start()}
            else if let p=store.engine?.current,p.phase=="question"{saveDraft(p)}
        }
        .task(id:store.engine?.current?.id){
            numberInput=store.engine?.current?.selectedID ?? store.engine?.current?.draftResponse ?? ""
            selectedChoices=Set((store.engine?.current?.selectedID ?? store.engine?.current?.draftResponse ?? "").split(separator:"|").map(String.init))
            stepInputs=store.engine?.check?.stepResponses(store.engine?.current?.selectedID ?? store.engine?.current?.draftResponse ?? "") ?? [:]
            inputToken=store.engine?.current?.id
            #if DEBUG
            if let p=store.engine?.current{knowledgePreview.didRender(p.pointID,p.phase)}
            #endif
        }
        .onChange(of:numberInput){_,_ in scheduleDraft()}
        .onChange(of:selectedChoices){_,_ in scheduleDraft()}
        .onChange(of:stepInputs){_,_ in scheduleDraft()}
        .onDisappear{draftTask?.cancel();if let p=store.engine?.current,p.phase=="question"{saveDraft(p)}}
    }
    private func progress(_ engine:KnowledgeLearningEngine)->some View {
        let trained=course.points.filter{engine.trainedDay($0.id) != nil}.count
        let reviewed=course.points.filter{engine.reviewPassed($0.id)}.count
        return VStack(alignment:.leading,spacing:6){
            Text("方法练习 \(trained)/\(course.points.count) 点 · 独立检验有证据 \(reviewed) 点").font(.caption).foregroundStyle(.secondary)
            if engine.current?.phase != "question" && engine.current?.phase != "feedback"{
                ProgressView(value:Double(trained),total:Double(course.points.count))
                Text("练习与独立检验分开；检验后仍安排复核。").font(.caption).foregroundStyle(.secondary)
            }
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
            Text("第 \(p.page+1) / \(point.lessonPageCount) 小步 · 本点方法练习 \(engine.learnedSkills(point.id)) / \(course.point(point.id)?.requiredSkillIDs.count ?? point.requiredSkillIDs.count)").font(.caption).foregroundStyle(.secondary)
            Button(p.page<point.sections.count && point.sections[p.page].checkpointID != nil ? "我来补上这一步":(p.page<point.lessonPageCount-1 ? "明白这一小步，继续":"检查本点方法练习")){store.readNext(p.id)}
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("knowledge-next-step")
            if p.page>0{Button("回看上一小步"){store.lessonPage(p.page-1)}}
            if let previous=p.resumeAttemptID{Button("回到刚才未提交的题（保留草稿）"){store.resumeAttempt(previous)}}
            if let other=point.sections.indices.first(where:{$0 != p.page && (point.sections[$0].id?.hasSuffix("-alt")==true)}) {
                Button("这段没懂，换个角度解释"){store.lessonPage(other)}
            }
            Button("这会儿先学其他知识点"){store.deferCurrent()}.font(.subheadline)
        } else if let q=engine.check,p.phase=="question" || p.phase=="feedback" {
            Text(p.mode=="review" ? (p.assisted ? "复核练习 · 本次不计独立成绩":"隔时小检验"):((p.mode=="probe") ? "先补一个小检查":"方法练习")).font(.headline)
            if let due=p.reviewDueAt,let shown=p.shownAt,shown<due{Text("本题首次打开尚未到期，之后等待也不改变本次资格。安排的复核时间："+due.formatted(date:.numeric,time:.shortened)).font(.caption).foregroundStyle(.secondary)}
            if point.purpose(q)=="guided",p.mode != "review",let id=q.skillID,let skill=point.skills?.first(where:{$0.id==id}){Text("练习方法："+skill.title).font(.subheadline).foregroundStyle(.secondary)}
            Text(familiarity(p))
                .font(.caption).foregroundStyle(.secondary)
            Text(q.prompt).font(.system(size:22).weight(.medium)).accessibilityIdentifier("knowledge-check-prompt")
            if p.phase=="question" {
            if q.type=="structured",let steps=q.steps {
                Text(q.distinctExpressionIDs==nil ? "逐步作答，最后一起提交。":"自行写出三条关系，顺序任意；相同关系重复填写不能补足过程。").font(.footnote).foregroundStyle(.secondary)
                ForEach(steps){step in
                    KnowledgeStepInputView(step:step,value:Binding(get:{stepInputs[step.id] ?? ""},set:{stepInputs[step.id]=$0}),disabled:p.phase=="feedback" || inputToken != p.id)
                }
                if p.phase=="question"{Button("提交整题过程"){store.answer(encodedSteps(),token:p.id)}.buttonStyle(.borderedProminent).disabled(inputToken != p.id)}
            } else if q.type=="expression" {
                KnowledgeStepInputView(step:q,value:$numberInput,disabled:p.phase=="feedback" || inputToken != p.id)
                if p.phase=="question"{Button("提交关系式"){store.answer(numberInput,token:p.id)}.buttonStyle(.borderedProminent).disabled(inputToken != p.id)}
            } else if q.type=="number" {
                Text(q.numeric?.requiresUnit==true ? "填写数值和单位。":"按题中指定单位填写数值：\(q.numeric?.unit ?? "")").font(.subheadline)
                TextField("先自己计算，再填写",text:$numberInput).textFieldStyle(.roundedBorder).font(.system(size:24))
                    .keyboardType(.numbersAndPunctuation).disabled(p.phase=="feedback" || inputToken != p.id)
                if p.phase=="question"{Button("提交计算结果"){store.answer(numberInput,token:p.id)}.buttonStyle(.borderedProminent).disabled(inputToken != p.id)}
            } else {ForEach(p.order,id:\.self){id in
                if let choice=q.choices.first(where:{$0.id==id}) {
                    Button{
                        guard inputToken==p.id else{return}
                        if q.type=="multiple"{if !selectedChoices.insert(id).inserted{selectedChoices.remove(id)}}else{store.answer(id,token:p.id)}
                    }label:{
                        HStack(alignment:.top){Text(choice.text).font(.system(size:22));Spacer();if p.selectedID==id || selectedChoices.contains(id){Image(systemName:"checkmark.circle")}}
                            .padding(14).frame(maxWidth:.infinity,minHeight:48,alignment:.leading)
                            .background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).disabled(p.phase=="feedback" || store.blocked)
                }
            }
                if q.type=="multiple",p.phase=="question"{Button("提交多选答案"){store.answer(selectedChoices.sorted().joined(separator:"|"),token:p.id)}.buttonStyle(.borderedProminent).disabled(inputToken != p.id)}
            }
            }
            if p.phase=="question" {
                if p.hintVisible {Text("提示："+(q.hint ?? point.keyFacts.first ?? point.sections[0].body)).font(.system(size:21)).foregroundStyle(.secondary)}
                Button("给一点提示（会记录用过帮助）"){store.hint(p.id)}.disabled(p.hintVisible)
                Button("没读懂，回到这个知识点"){saveDraft(p);store.explain()}
                Button("暂时先学其他知识点"){saveDraft(p);store.deferCurrent()}
            } else {
                let correct=p.selectedID.map{q.correct($0)} ?? false
                Label(correct ? "这道小题答对了":"先找出卡住的一步",systemImage:correct ? "checkmark.circle.fill":"arrow.uturn.backward.circle")
                    .font(.headline).foregroundStyle(correct ? .green:.orange)
                if let response=p.selectedID,q.feedback(response) != q.explanation{Text(q.feedback(response)).font(.system(size:22))}
                Text(q.explanation).font(.system(size:22)).accessibilityIdentifier("knowledge-check-feedback")
                if let raw=p.selectedID,let scores=q.stepScores(raw),let steps=q.steps {
                    ForEach(scores,id:\.id){score in
                        if let step=steps.first(where:{$0.id==score.id}) {
                            Text(step.prompt+" · "+(score.status=="correct" ? "本项核对相符":(score.status=="wrong" ? "本项需回看":"待确认"))).font(.headline)
                            Text("你的作答："+score.response).textSelection(.enabled)
                            if score.status != "correct"{Text(step.feedback(score.response)).font(.body)}
                        }
                    }
                    if !correct{Text("各步证据分别保留；条件或方法未通过时，即使最终数值正确，也不记整题或方法通过。").font(.footnote)}
                } else if q.evidence=="result"{Text("本题只核对最终结果，尚未检验列式过程，不作为完整方法通过。").font(.footnote).foregroundStyle(.secondary)}
                if let raw=p.selectedID,let parent=q.repairPoint(raw){Button("用一个前置小检查定位这一步"){store.repairPrerequisite(parent,skillID:q.probeSkill(raw))}}
                Text(p.assisted ? "本次按练习保存：可能刚学过、提前打开或使用过帮助，不计合格延迟检验。":"延迟资格在本题首次展示时已满足；此后未记录相关App内帮助。这里只说明本题表现，已见题保持不冒充未见迁移。")
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
            Button(engine.hasPendingReturn ? "回到刚才的学习位置":"继续下一个知识点"){store.next()}.buttonStyle(.borderedProminent)
            Button("再读一次这个知识点"){store.explain()}
            Button("再练一道（提前打开会成为已见练习题）"){store.practiceAgain()}
            if engine.unseenTransferPoolEmpty(point.id){Text("本点暂缺App内尚未展示的变式。仍可继续已见题保持或学习其他知识，不能据此新增未见迁移通过。").font(.footnote).foregroundStyle(.secondary)}
            let gaps=engine.independentEvidenceGaps(point.id)
            if !gaps.isEmpty{Text("仍缺可核对过程的独立任务："+gaps.joined(separator:"、")+"。现有最终数值练习不能替代方法证据，可先继续学习其他点。").font(.footnote).foregroundStyle(.secondary)}
            let evidence=engine.evidenceCounts(point.id)
            let labels=[("original","原题"),("independent","独立小题"),("transfer","换条件"),("mixed","组合"),("retention","已见保持"),("unknown","熟悉度未知"),("result","只核对结果")]
            let summary=labels.compactMap{key,title -> String? in let count=evidence[key,default:0];return count>0 ? title+" \(count)":nil}.joined(separator:" · ")
            Text(summary.isEmpty ? "尚无符合延迟与无帮助条件的正确记录。":"符合延迟与无帮助条件的正确记录："+summary+"。原题类型不代表首次见过，次数也不等于掌握或题库覆盖率。").font(.caption).foregroundStyle(.secondary)
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
                    VStack(alignment:.leading,spacing:5){Text(point.title);Text(store.engine?.reviewPassed(point.id)==true ? "有独立检验证据，仍会到期复核":(store.engine?.trainedDay(point.id) != nil ? "方法练习已完成，待独立检验":"方法小节仍待练习")).font(.caption).foregroundStyle(.secondary)
                        if !point.inheritedPriorityTitles(priorities).isEmpty{Text("原标注："+point.inheritedPriorityTitles(priorities).joined(separator:"、")).font(.caption).foregroundStyle(.secondary)}
                    }
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
        guard inputToken==p.id else{return}
        let type=store.engine?.check?.type
        store.saveDraft(type=="structured" ? encodedSteps():(type=="multiple" ? selectedChoices.sorted().joined(separator:"|"):numberInput),token:p.id)
    }
    private func encodedSteps()->String{let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return (try? e.encode(stepInputs)).flatMap{String(data:$0,encoding:.utf8)} ?? "{}"}
    private func scheduleDraft() {
        draftTask?.cancel()
        let token=inputToken
        draftTask=Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(350));guard !Task.isCancelled,let p=store.engine?.current,p.phase=="question",p.id==token else{return};saveDraft(p)
        }
    }
    private func familiarity(_ p:KnowledgePresentation)->String {
        switch p.familiarity {
        case "unseen-in-app":return "App内首次展示；App外是否见过未知。"
        case "seen-answer":return "已见题 · 检查是否还记得。"
        case "seen-question":return "此前展示过 · 按已见题记录。"
        case "source-exposed":return "已查过相关原页 · 按有资料经历记录。"
        default:return "旧展示历史不完整 · 熟悉度未知。"
        }
    }
}

private struct KnowledgeStepInputView:View {
    let step:KnowledgeCourse.Check
    @Binding var value:String
    var disabled=false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(step.prompt).font(.system(size:22).weight(.semibold))
            if step.type=="expression" {
                Text("可用变量："+(step.expression?.variables.joined(separator:"、") ?? "")+"；支持 + − * / ^、括号与sqrt(3)。").font(.footnote).foregroundStyle(.secondary)
                TextField("写出关系，不用先代入数值",text:$value,axis:.vertical).textFieldStyle(.roundedBorder).font(.system(size:22))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                LazyVGrid(columns:[GridItem(.adaptive(minimum:48))],spacing:6) {
                    ForEach((step.expression?.variables ?? [])+["=","+","−","√3","²","×","÷","(",")"],id:\.self){symbol in
                        Button(symbol){value+=symbol}.buttonStyle(.bordered).font(.system(size:17))
                    }
                }
            } else if step.type=="number" {
                Text("按题目填写数值"+((step.numeric?.unit.isEmpty==false) ? "与单位 "+step.numeric!.unit:"（本项无量纲）")).font(.footnote)
                TextField("你的计算结果",text:$value).textFieldStyle(.roundedBorder).font(.system(size:22)).keyboardType(.numbersAndPunctuation)
            } else {
                ForEach(step.choices){choice in
                    let selected=Set(value.split(separator:"|").map(String.init)).contains(choice.id)
                    Button {
                        if step.type=="multiple"{var ids=Set(value.split(separator:"|").map(String.init));if !ids.insert(choice.id).inserted{ids.remove(choice.id)};value=ids.sorted().joined(separator:"|")}
                        else{value=choice.id}
                    } label:{HStack{Text(choice.text).font(.system(size:21));Spacer();if selected{Image(systemName:"checkmark.circle.fill")}}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))}.buttonStyle(.plain)
                }
            }
        }.padding(14).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:12)).disabled(disabled)
    }
}

struct KnowledgeLinkedCardView:View {
    let course:KnowledgeCourse;let card:RecallCard;var baseDirectory:URL?=nil;let onClose:()->Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var exposureSaved=false
    @State private var wasBackground=false
    @State private var error:String?
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Text(card.prompt).font(.system(size:26).weight(.semibold))
                if exposureSaved {
                    Text(card.answer).font(.system(size:25))
                    if let detail=card.detail{DisclosureGroup("详细说明"){Text(detail).font(.system(size:22))}}
                    Text("本页只保存查阅事实，不提交自评，不改变原题或知识点答题成绩。").font(.footnote).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).foregroundStyle(.red);Button("重试保存查阅事件"){recordExposure()}
                } else{ProgressView("正在保存查阅事件…")}
            }.padding(22)
        }.navigationTitle("知识卡").toolbar{Button("关闭",action:onClose)}
        .task{recordExposure()}
        .onChange(of:scenePhase){_,phase in
            if phase == .background{wasBackground=true;exposureSaved=false}
            if phase == .active,wasBackground{wasBackground=false;recordExposure()}
        }
    }
    private func recordExposure() {
        do{try KnowledgeExposureLedger.recordCard(course:course,cardID:card.id,baseDirectory:baseDirectory);error=nil;exposureSaved=true}
        catch{exposureSaved=false;self.error="查阅事实未保存，答案暂未显示。"+error.localizedDescription}
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
