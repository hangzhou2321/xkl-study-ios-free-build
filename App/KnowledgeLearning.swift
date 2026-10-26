import Foundation
import StudyCore
import CPocket

struct KnowledgePresentation:Codable,Equatable {
    var id:UUID;let pointID:String
    var phase:String;var page:Int;var checkIndex:Int;var order:[String]
    var assisted:Bool;var hintVisible:Bool;var selectedID:String?
    var definitionID:String?=nil
    var mode:String?=nil
    var resumePage:Int?=nil
    var retrySkillID:String?=nil
    var draftResponse:String?=nil
}
struct KnowledgeLearningEvent:Codable,Equatable {
    let id:UUID;let sequence:Int;let day:Int;let at:Date;let kind:String
    let pointID:String;let presentationID:UUID;let checkID:String?
    let selectedID:String?;let correct:Bool?;let assisted:Bool
    var definitionID:String?=nil
    var purpose:String?=nil
    var errorTag:String?=nil
    var evidenceVersion:Int?=nil
}
struct KnowledgeQuestionVersion:Codable,Equatable {
    let pointID:String;let check:KnowledgeCourse.Check
    var identity:String {get throws{
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return StudySHA256.hex(try encoder.encode(self))
    }}
}
struct KnowledgeExposure:Codable,Equatable,Identifiable {
    let id:UUID;let courseID:String;let at:Date;let pointIDs:[String];let kind:String;let reference:String
}
struct KnowledgeLearningRecord:Codable,Equatable {
    let format:String;let subject:ConceptSubject;let courseID:String
    let pointIDs:[String];let pointDigests:[String:String]
    var currentID:String?;var bookmarks:[String:KnowledgePresentation]
    var events:[KnowledgeLearningEvent];var deferredIDs:[String]
    var questionVersions:[String:KnowledgeQuestionVersion]?=nil
    var legacyOrder:[String:[String]]?=nil
    var exposures:[KnowledgeExposure]?=nil
    var returnPoints:[String]?=nil
}
struct KnowledgeReviewStatus:Equatable {
    let level:Int;let dueAt:Date;let qualifiedFamilies:Int;let passedSkills:Set<String>;let hasTransfer:Bool;let lastWrong:Bool
}

/// Teaching evidence is independent of card self-assessment and old bank
/// attempts. Only intervals are shared with the existing vocabulary model.
struct KnowledgeLearningEngine {
    let course:KnowledgeCourse
    private(set) var record:KnowledgeLearningRecord
    var current:KnowledgePresentation?{record.currentID.flatMap{record.bookmarks[$0]}}
    var point:KnowledgeCourse.Point?{current.flatMap{course.point($0.pointID)}}
    var check:KnowledgeCourse.Check?{
        guard let p=current else{return nil}
        if let id=p.definitionID{return record.questionVersions?[id]?.check}
        guard let unit=point,unit.checks.indices.contains(p.checkIndex) else{return nil}
        return unit.checks[p.checkIndex]
    }
    static func legacyDigest(pointID:String,checks:[KnowledgeCourse.Check])throws->String {
        let value:[String:Any]=["id":pointID,"checks":checks.map{q in
            ["id":q.id,"prompt":q.prompt,"answer":q.answerID,"choices":q.choices.sorted{$0.id<$1.id}.map{["id":$0.id,"text":$0.text]}] as [String:Any]}]
        return StudySHA256.hex(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]))
    }
    static func digest(_ point:KnowledgeCourse.Point)throws->String{try legacyDigest(pointID:point.id,checks:point.checks)}
    static func appending(_ old:KnowledgeLearningRecord,to course:KnowledgeCourse)throws->KnowledgeLearningRecord {
        let ids=course.points.map(\.id)
        guard !ids.isEmpty,Set(ids).count==ids.count,old.subject==course.subject,old.courseID==course.id,
              ["knowledge-learning-v1","knowledge-learning-v2"].contains(old.format),
              Set(old.pointIDs).count==old.pointIDs.count,Set(old.pointIDs).isSubset(of:Set(ids)) else{throw ExamError.invalid("知识点身份不一致，旧记录保留。")}
        var versions=old.questionVersions ?? [:],order=old.legacyOrder ?? [:],bookmarks=old.bookmarks
        var gradeMap:[String:(String,String)]=[:]
        for v in versions.values {
            let entry=(v.pointID,try v.check.gradingDigest())
            if let prior=gradeMap[v.check.id]{guard prior==entry else{throw ExamError.invalid("同题ID有冲突的旧评分定义。")}}
            gradeMap[v.check.id]=entry
        }
        func register(_ pointID:String,_ q:KnowledgeCourse.Check)throws->String {
            let v=KnowledgeQuestionVersion(pointID:pointID,check:q),key=try v.identity,grading=try q.gradingDigest()
            if let prior=gradeMap[q.id]{guard prior.0==pointID,prior.1==grading else{throw ExamError.invalid("旧题\(q.id)评分含义改变，请保留旧版本；不能清空进度。")}}
            gradeMap[q.id]=(pointID,grading)
            if let prior=versions[key]{guard prior==v else{throw ExamError.invalid("题目版本校验冲突。")}}else{versions[key]=v}
            return key
        }
        if old.format=="knowledge-learning-v1" {
            guard old.questionVersions==nil else{throw ExamError.invalid("旧档格式与题目版本表冲突。")}
            for id in old.pointIDs {
                let p=course.point(id)!,baseline=p.legacyBaseline,qs=baseline?.checks ?? p.checks
                guard old.pointDigests[id]==(try legacyDigest(pointID:id,checks:qs)) else{throw ExamError.invalid("无法找到旧诊断\(id)的原题版本，旧档保留。")}
                order[id]=try qs.map{try register(id,$0)}
                if var mark=bookmarks[id] {
                    guard qs.indices.contains(mark.checkIndex) else{throw ExamError.invalid("旧断点题号无效。")}
                    mark.definitionID=order[id]![mark.checkIndex];mark.mode="legacy"
                    if let count=baseline?.sectionCount,mark.page>=count{mark.page=p.sections.count+(mark.page-count)}
                    bookmarks[id]=mark
                }
            }
        } else if old.questionVersions==nil || old.legacyOrder==nil{throw ExamError.invalid("题目版本档缺失，不能重建历史。")}
        for p in course.points {
            if order[p.id]==nil {order[p.id]=try (p.legacyBaseline?.checks ?? p.checks).map{try register(p.id,$0)}}
            for q in p.allChecks{_=try register(p.id,q)}
        }
        return .init(format:"knowledge-learning-v2",subject:old.subject,courseID:old.courseID,
            pointIDs:old.pointIDs+ids.filter{!old.pointIDs.contains($0)},pointDigests:old.pointDigests,
            currentID:old.currentID,bookmarks:bookmarks,events:old.events,deferredIDs:old.deferredIDs,
            questionVersions:versions,legacyOrder:order,exposures:old.exposures ?? [],returnPoints:old.returnPoints ?? [])
    }
    static func fresh(_ course:KnowledgeCourse)throws->Self {
        let digests=try Dictionary(uniqueKeysWithValues:course.points.map{($0.id,try digest($0))})
        let empty=KnowledgeLearningRecord(format:"knowledge-learning-v2",subject:course.subject,courseID:course.id,
            pointIDs:course.points.map(\.id),pointDigests:digests,currentID:nil,bookmarks:[:],events:[],deferredIDs:[],questionVersions:[:],legacyOrder:[:],exposures:[],returnPoints:[])
        return try Self(course:course,record:appending(empty,to:course))
    }
    init(course:KnowledgeCourse,record:KnowledgeLearningRecord)throws {
        self.course=course;self.record=record
        let pointIDs=Set(course.points.map(\.id))
        guard record.format=="knowledge-learning-v2",record.subject==course.subject,record.courseID==course.id,
              !pointIDs.isEmpty,record.pointIDs.count==pointIDs.count,Set(record.pointIDs)==pointIDs,
              record.currentID==nil || record.bookmarks[record.currentID!] != nil,
              Set(record.bookmarks.keys).isSubset(of:pointIDs),Set(record.deferredIDs).isSubset(of:pointIDs),
              Set(record.returnPoints ?? []).isSubset(of:pointIDs),let versions=record.questionVersions,let legacy=record.legacyOrder else{throw ExamError.invalid("知识点档案身份或版本表不一致。")}
        var grading:[String:String]=[:]
        for (key,v) in versions {
            guard pointIDs.contains(v.pointID),try v.identity==key else{throw ExamError.invalid("历史题目版本校验失败。")}
            try v.check.validateResponse();let hash=try v.check.gradingDigest()
            if let prior=grading[v.check.id]{guard prior==hash else{throw ExamError.invalid("同题ID出现不同评分。")}}
            grading[v.check.id]=hash
        }
        for p in course.points {for q in p.allChecks{guard grading[q.id]==(try q.gradingDigest()) else{throw ExamError.invalid("活动题缺少可信版本。")}}}
        let exposures=record.exposures ?? []
        guard Set(exposures.map(\.id)).count==exposures.count,exposures.allSatisfy({$0.courseID==course.id && !$0.pointIDs.isEmpty && Set($0.pointIDs).isSubset(of:pointIDs) && $0.at.timeIntervalSinceReferenceDate.isFinite}) else{throw ExamError.invalid("资料查阅事件不完整。")}
        let chronological=exposures.sorted{$0.at<$1.at};var exposureIndex=0
        var eventIDs=Set<UUID>(),answered=Set<UUID>(),hinted=Set<UUID>(),lastDay=18_000,lastTime=Date.distantPast
        var helpAt:[String:Date]=[:],oldReads:[Int:Set<String>]=[:],learned:[String:Set<String>]=[:],trained:[String:Date]=[:]
        for (index,e) in record.events.enumerated() {
            guard e.sequence==index+1,eventIDs.insert(e.id).inserted,e.day>=lastDay,(18_000...50_000).contains(e.day),e.at.timeIntervalSinceReferenceDate.isFinite,
                  e.evidenceVersion != 2 || e.at>=lastTime,let p=course.point(e.pointID),
                  ["read","hint","answer","defer","feedback-read","error-note"].contains(e.kind) else{throw ExamError.invalid("知识点事件链损坏。")}
            while exposureIndex<chronological.count,chronological[exposureIndex].at<=e.at {
                let exposure=chronological[exposureIndex]
                for id in exposure.pointIDs{helpAt[id]=max(helpAt[id] ?? .distantPast,exposure.at)}
                exposureIndex+=1
            }
            if e.kind=="answer" {
                let key=e.definitionID ?? legacy[e.pointID]?.first(where:{versions[$0]?.check.id==e.checkID})
                guard let key,let v=versions[key],v.pointID==e.pointID,v.check.id==e.checkID,
                      answered.insert(e.presentationID).inserted,let response=e.selectedID,v.check.accepts(response),e.correct==v.check.correct(response) else{throw ExamError.invalid("历史作答与题目版本或判分不一致。")}
                let q=v.check
                if e.evidenceVersion==2 {
                    let helpers=Self.helperIDs(course:course,pointID:p.id,check:q)
                    let helped=hinted.contains(e.presentationID) || helpers.contains{(helpAt[$0] ?? .distantPast)>e.at.addingTimeInterval(-86_400)}
                    guard !(helped || e.purpose != "review") || e.assisted else{throw ExamError.invalid("查阅或练习后的回答不能标成独立。")}
                    if !e.assisted {guard p.purpose(q) != "guided",let prior=trained[p.id],e.at.timeIntervalSince(prior)>=86_400 else{throw ExamError.invalid("即时练习不能冒充隔时检验。")}}
                } else {
                    let first=legacy[p.id]?.first.flatMap{versions[$0]?.check.id}
                    let helped=hinted.contains(e.presentationID) || !(oldReads[e.day] ?? []).isDisjoint(with:Set([p.id]+p.prerequisites))
                    guard !(helped || e.checkID==first) || e.assisted else{throw ExamError.invalid("旧练习助力标记不一致。")}
                }
                if e.correct==true {
                    if p.skills==nil,q.id==p.checks.first?.id{learned[p.id,default:[]].insert(p.id)}
                    else if e.evidenceVersion==2,e.purpose=="practice"{learned[p.id,default:[]].insert(p.skill(q))}
                    if trained[p.id]==nil,Set(p.requiredSkillIDs).isSubset(of:learned[p.id] ?? []){trained[p.id]=e.at}
                }
            } else if e.correct != nil || e.selectedID != nil{throw ExamError.invalid("阅读和错因不能带答题分数。")}
            if ["read","hint","feedback-read"].contains(e.kind){helpAt[e.pointID]=e.at}
            if e.kind=="read"{oldReads[e.day,default:[]].insert(e.pointID)}
            if e.kind=="hint"{hinted.insert(e.presentationID)}
            lastDay=e.day;lastTime=max(lastTime,e.at)
        }
        for (id,p) in record.bookmarks {
            guard id==p.pointID,let unit=course.point(id),["lesson","question","feedback","complete"].contains(p.phase),
                  (0..<unit.lessonPageCount).contains(p.page),let key=p.definitionID,let q=versions[key]?.check,
                  Set(p.order)==Set(q.choices.map(\.id)),p.order.count==q.choices.count else{throw ExamError.invalid("知识点断点或选项次序无效。")}
            if p.phase=="feedback" || p.phase=="complete",let selected=p.selectedID {
                guard let e=record.events.last(where:{$0.presentationID==p.id && $0.kind=="answer"}),e.selectedID==selected,e.checkID==q.id,e.assisted==p.assisted else{throw ExamError.invalid("当前反馈与落盘作答不一致。")}
                if p.phase=="complete"{guard e.correct==true else{throw ExamError.invalid("错误回答不能显示为完成。")}}
            }
        }
    }
    private static func question(_ e:KnowledgeLearningEvent,in record:KnowledgeLearningRecord)->KnowledgeCourse.Check? {
        let key=e.definitionID ?? record.legacyOrder?[e.pointID]?.first(where:{record.questionVersions?[$0]?.check.id==e.checkID})
        return key.flatMap{record.questionVersions?[$0]?.check}
    }
    private static func practiceSkills(record:KnowledgeLearningRecord,course:KnowledgeCourse,pointID:String)->Set<String> {
        guard let p=course.point(pointID) else{return []};var skills=Set<String>()
        for e in record.events where e.pointID==pointID && e.kind=="answer" && e.correct==true {
            guard let q=question(e,in:record) else{continue}
            if p.skills==nil {if q.id==p.checks.first?.id{skills.insert(p.id)}}
            else if e.evidenceVersion==2,e.purpose=="practice"{skills.insert(p.skill(q))}
        }
        return skills
    }
    private static func trainingAt(record:KnowledgeLearningRecord,course:KnowledgeCourse,pointID:String)->Date? {
        guard let p=course.point(pointID) else{return nil};var skills=Set<String>()
        for e in record.events where e.pointID==pointID && e.kind=="answer" && e.correct==true {
            guard let q=question(e,in:record) else{continue}
            if p.skills==nil {if q.id==p.checks.first?.id{skills.insert(p.id)}}
            else if e.evidenceVersion==2,e.purpose=="practice"{skills.insert(p.skill(q))}
            if Set(p.requiredSkillIDs).isSubset(of:skills){return e.at}
        }
        return nil
    }
    func trainedDay(_ id:String)->Int?{trainedAt(id).flatMap{try? ConceptCalendar.studyDay($0)}}
    func trainedAt(_ id:String)->Date?{Self.trainingAt(record:record,course:course,pointID:id)}
    func learnedSkills(_ id:String)->Int{Self.practiceSkills(record:record,course:course,pointID:id).count}
    private static func helperIDs(course:KnowledgeCourse,pointID:String,check:KnowledgeCourse.Check?)->Set<String> {
        var result=Set([pointID]+(check?.relatedKnowledgeIDs ?? [])),todo=Array(result)
        while let id=todo.popLast(){for parent in course.point(id)?.prerequisites ?? []{if result.insert(parent).inserted{todo.append(parent)}}}
        return result
    }
    private static func hasHelp(record:KnowledgeLearningRecord,course:KnowledgeCourse,pointID:String,check:KnowledgeCourse.Check,at:Date)->Bool {
        let ids=helperIDs(course:course,pointID:pointID,check:check),cutoff=at.addingTimeInterval(-86_400)
        return record.events.contains{["read","hint","feedback-read"].contains($0.kind) && ids.contains($0.pointID) && $0.at>cutoff && $0.at<=at}
            || (record.exposures ?? []).contains{!Set($0.pointIDs).isDisjoint(with:ids) && $0.at>cutoff && $0.at<=at}
    }
    mutating func ingest(_ exposures:[KnowledgeExposure])throws {
        var existing=Dictionary(uniqueKeysWithValues:(record.exposures ?? []).map{($0.id,$0)})
        for e in exposures {
            guard e.courseID==course.id,Set(e.pointIDs).isSubset(of:Set(course.points.map(\.id))),!e.pointIDs.isEmpty else{throw ExamError.invalid("跨课程资料事件不可混入。")}
            if let old=existing[e.id]{guard old==e else{throw ExamError.invalid("查阅事件身份冲突。")}}else{existing[e.id]=e}
        }
        record.exposures=existing.values.sorted{$0.at == $1.at ? $0.id.uuidString<$1.id.uuidString:$0.at<$1.at}
    }
    func reviewStatus(_ id:String)->KnowledgeReviewStatus? {
        guard let trained=trainedAt(id),let p=course.point(id) else{return nil}
        var level=0,last=trained,families=Set<String>(),skills=Set<String>(),transfer=false,wrong=false
        for e in record.events where e.pointID==id && e.kind=="answer" && e.purpose=="review" && e.evidenceVersion==2 {
            guard let q=Self.question(e,in:record) else{continue}
            if e.correct==false{level=1;last=e.at;families=[];skills=[];transfer=false;wrong=true}
            else if !e.assisted {
                level=min(10,max(1,level+1));last=e.at;families.insert(q.family ?? q.id);skills.insert(p.skill(q))
                transfer=transfer || ["transfer","original"].contains(p.purpose(q));wrong=false
            } else{last=max(last,e.at)}
        }
        var due=last.addingTimeInterval(Double(xkl_word_review_interval_days(UInt32(max(1,level))))*86_400)
        let ids=Self.helperIDs(course:course,pointID:id,check:nil)
        for e in record.events where ids.contains(e.pointID) && ["read","hint","feedback-read"].contains(e.kind){due=max(due,e.at.addingTimeInterval(86_400))}
        for e in record.exposures ?? [] where !Set(e.pointIDs).isDisjoint(with:ids){due=max(due,e.at.addingTimeInterval(86_400))}
        return .init(level:level,dueAt:due,qualifiedFamilies:families.count,passedSkills:skills,hasTransfer:transfer,lastWrong:wrong)
    }
    func reviewPassed(_ id:String)->Bool {
        guard let p=course.point(id),let s=reviewStatus(id) else{return false}
        return !s.lastWrong && s.qualifiedFamilies>=2 && s.hasTransfer && Set(p.requiredSkillIDs).isSubset(of:s.passedSkills)
    }
    private func day(_ now:Date)throws->Int {
        let day=try ConceptCalendar.studyDay(now)
        guard day >= (record.events.last?.day ?? day),now >= (record.events.last?.at ?? now) else{throw ExamError.invalid("日期早于已有事件，原进度保留。")}
        return day
    }
    private mutating func event(_ kind:String,_ p:KnowledgePresentation,_ now:Date,selected:String?=nil,tag:String?=nil)throws {
        let q=p.definitionID.flatMap{record.questionVersions?[$0]?.check}
        record.events.append(.init(id:UUID(),sequence:record.events.count+1,day:try day(now),at:now,kind:kind,pointID:p.pointID,presentationID:p.id,
            checkID:["answer","hint","error-note","feedback-read"].contains(kind) ? q?.id:nil,
            selectedID:selected,correct:selected.map{q!.correct($0)},assisted:p.assisted,definitionID:p.definitionID,purpose:p.mode,errorTag:tag,evidenceVersion:2))
    }
    private func version(_ pointID:String,_ q:KnowledgeCourse.Check)->String{(try? KnowledgeQuestionVersion(pointID:pointID,check:q).identity) ?? ""}
    private func presentation(_ id:String,q:KnowledgeCourse.Check?=nil,review:Bool=false)->KnowledgePresentation {
        let p=course.point(id)!,selected=q ?? p.checks[0]
        return .init(id:UUID(),pointID:id,phase:review ? "question":"lesson",page:0,
            checkIndex:p.checks.firstIndex{$0.id==selected.id} ?? 0,order:selected.choices.map(\.id).shuffled(),assisted:!review,hintVisible:false,selectedID:nil,
            definitionID:version(id,selected),mode:review ? "review":"practice")
    }
    private func selectCheck(_ p:KnowledgeCourse.Point,review:Bool,skillID:String?=nil)->KnowledgeCourse.Check {
        let eligible=p.checks.filter{q in (review ? p.purpose(q) != "guided":true) && (skillID==nil || p.skill(q)==skillID)}
        let candidates=eligible.isEmpty ? p.checks:eligible,answers=record.events.filter{$0.pointID==p.id && $0.kind=="answer"}
        let last=answers.last?.checkID,counts=Dictionary(grouping:answers,by:{$0.checkID ?? ""}).mapValues{$0.count}
        let passed=reviewStatus(p.id)?.passedSkills ?? []
        return candidates.enumerated().min{a,b in
            let ka=(review && !passed.contains(p.skill(a.element)) ? 0:1,a.element.id==last ? 1:0,counts[a.element.id] ?? 0,a.offset)
            let kb=(review && !passed.contains(p.skill(b.element)) ? 0:1,b.element.id==last ? 1:0,counts[b.element.id] ?? 0,b.offset)
            return ka<kb
        }!.element
    }
    mutating func start(now:Date=Date())throws {
        _=try day(now)
        if let current {
            if current.phase=="question"{try refreshAssistance(now:now);return}
            if current.phase != "complete"{return}
            if trainedAt(current.pointID)==nil{try open(current.pointID,restart:true,now:now);return}
            if let due=reviewStatus(current.pointID),due.dueAt<=now{try open(current.pointID,review:true,now:now)}
            return
        }
        record.deferredIDs=[];try next(now:now)
    }
    mutating func open(_ id:String,review:Bool=false,restart:Bool=false,now:Date=Date())throws {
        _=try day(now);guard let unit=course.point(id) else{return}
        var p=record.bookmarks[id] ?? presentation(id)
        if restart{p=presentation(id)}
        if review{guard trainedAt(id) != nil else{return};p=presentation(id,q:selectCheck(unit,review:true),review:true)}
        record.currentID=id;record.bookmarks[id]=p
        if p.phase=="lesson"{try event("read",p,now)}
        if p.phase=="question"{try refreshAssistance(now:now)}
    }
    private mutating func refreshAssistance(now:Date)throws {
        guard var p=current,p.phase=="question",let q=check else{return};_=try day(now)
        let trained=trainedAt(p.pointID)
        p.assisted=p.mode != "review" || p.hintVisible || Self.hasHelp(record:record,course:course,pointID:p.pointID,check:q,at:now)
            || trained==nil || now.timeIntervalSince(trained!)<86_400
        record.bookmarks[p.pointID]=p
    }
    private mutating func ask(_ q:KnowledgeCourse.Check,mode:String,resumePage:Int?=nil,now:Date)throws {
        guard let old=current else{return};var p=presentation(old.pointID,q:q,review:true)
        p.mode=mode;p.page=old.page;p.resumePage=resumePage
        record.bookmarks[p.pointID]=p;try refreshAssistance(now:now)
    }
    mutating func readNext(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="lesson",let unit=point else{return};_=try day(now)
        if p.page<unit.sections.count,let id=unit.sections[p.page].checkpointID,let q=unit.checks.first(where:{$0.id==id}) {
            let chosen=p.retrySkillID==unit.skill(q) ? selectCheck(unit,review:false,skillID:p.retrySkillID):q
            try ask(chosen,mode:"practice",resumePage:p.page+1,now:now);return
        }
        if p.page<unit.lessonPageCount-1 {
            p.id=UUID();p.page+=1;p.selectedID=nil;record.bookmarks[p.pointID]=p;try event("read",p,now)
        } else {
            let passed=Self.practiceSkills(record:record,course:course,pointID:unit.id)
            if let missing=unit.requiredSkillIDs.first(where:{!passed.contains($0)}){try ask(selectCheck(unit,review:false,skillID:missing),mode:"practice",now:now)}
            else{p.phase="complete";p.selectedID=nil;record.bookmarks[p.pointID]=p}
        }
    }
    mutating func hint(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="question",!p.hintVisible else{return}
        p.assisted=true;p.hintVisible=true;record.bookmarks[p.pointID]=p;try event("hint",p,now)
    }
    mutating func reference(now:Date=Date())throws {
        guard let p=current else{return};if p.phase=="question"{try hint(token:p.id,now:now)}else{try event("read",p,now)}
    }
    mutating func answer(_ response:String,token:UUID,now:Date=Date())throws {
        guard let p=current,p.id==token,p.phase=="question",let q=check else{return}
        guard q.accepts(response) else{throw ExamError.invalid(q.type=="number" ? "请输入有限数值，并按要求填写单位。":"请先选择完整答案。")}
        try refreshAssistance(now:now);var next=current!
        try event("answer",next,now,selected:response,tag:q.correct(response) ? nil:q.errorTag(response))
        next.phase="feedback";next.selectedID=response;record.bookmarks[next.pointID]=next;try event("feedback-read",next,now)
    }
    mutating func noteError(_ tag:String,token:UUID,now:Date=Date())throws {
        guard let p=current,p.id==token,p.phase=="feedback",["meaning","conditions","method","calculation","units","code-flow"].contains(tag) else{return}
        try event("error-note",p,now,tag:tag)
    }
    mutating func saveDraft(_ text:String,token:UUID)throws {
        guard var p=current,p.id==token,p.phase=="question",text.count<=200 else{return}
        p.draftResponse=text;record.bookmarks[p.pointID]=p
    }
    mutating func lessonPage(_ page:Int,now:Date=Date())throws {
        guard let old=current,let unit=point,(0..<unit.lessonPageCount).contains(page) else{return}
        var p=presentation(old.pointID);p.page=page;record.bookmarks[p.pointID]=p;try event("read",p,now)
    }
    func encounterCount(_ checkID:String)->Int{record.events.filter{$0.kind=="answer" && $0.checkID==checkID}.count}
    mutating func explainAgain(now:Date=Date())throws {
        guard let old=current,let unit=point else{return};let q=check;var p=presentation(old.pointID,q:q)
        p.page=unit.sectionIndex(old.selectedID.flatMap{q?.repairSection($0)} ?? q?.repairSectionID) ?? 0
        p.retrySkillID=q.map{unit.skill($0)};p.mode="practice"
        record.bookmarks[p.pointID]=p;try event("read",p,now)
    }
    mutating func repairPrerequisite(_ id:String,now:Date=Date())throws {
        guard let p=current,id != p.pointID,course.point(id) != nil else{return}
        var stack=record.returnPoints ?? [];if !stack.contains(p.pointID){stack.append(p.pointID)};record.returnPoints=stack
        try open(id,restart:true,now:now)
    }
    mutating func finish(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="feedback",let q=check,let response=p.selectedID else{return}
        guard q.correct(response) else{try explainAgain(now:now);return}
        if let nextPage=p.resumePage,let unit=point,nextPage<unit.lessonPageCount {
            p.id=UUID();p.phase="lesson";p.page=nextPage;p.selectedID=nil;p.resumePage=nil;p.assisted=true;p.mode="practice";p.hintVisible=false
            record.bookmarks[p.pointID]=p;try event("read",p,now);return
        }
        if p.mode != "review",let unit=point {
            let learned=Self.practiceSkills(record:record,course:course,pointID:p.pointID)
            if let missing=unit.requiredSkillIDs.first(where:{!learned.contains($0)}){try ask(selectCheck(unit,review:false,skillID:missing),mode:"practice",now:now);return}
        }
        p.phase="complete";record.bookmarks[p.pointID]=p
    }
    mutating func next(now:Date=Date())throws {
        _=try day(now);let excluded=Set(record.deferredIDs)
        if var stack=record.returnPoints,let id=stack.popLast(),!excluded.contains(id) {
            record.returnPoints=stack;try open(id,now:now);try explainAgain(now:now);return
        }
        let snapshot=self
        let ready:(KnowledgeCourse.Point)->Bool={p in !excluded.contains(p.id) && p.prerequisites.allSatisfy{snapshot.trainedAt($0) != nil}}
        let due=course.points.first{ready($0) && snapshot.reviewStatus($0.id).map{$0.dueAt<=now}==true}
        let fresh=course.points.first{ready($0) && snapshot.trainedAt($0.id)==nil}
        record.currentID=nil
        if let p=due ?? fresh {
            let restart=fresh?.id==p.id && record.bookmarks[p.id]?.phase=="complete"
            try open(p.id,review:due?.id==p.id,restart:restart,now:now)
        }
    }
    mutating func deferCurrent(now:Date=Date())throws {
        guard let p=current else{return};try event("defer",p,now)
        if !record.deferredIDs.contains(p.pointID){record.deferredIDs.append(p.pointID)}
        record.currentID=nil;try next(now:now)
    }
}
