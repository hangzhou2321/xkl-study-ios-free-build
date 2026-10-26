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
    var shownAt:Date?=nil
    var eligibleAtShow:Bool?=nil
    var familiarity:String?=nil
    var curriculumID:String?=nil
    var helpPointIDs:[String]?=nil
    var resumeAttemptID:UUID?=nil
    var probeForAttemptID:UUID?=nil
    var probeForStepID:String?=nil
    var hypothesisTag:String?=nil
    var reviewDueAt:Date?=nil
}
struct KnowledgeLearningEvent:Codable,Equatable {
    let id:UUID;let sequence:Int;let day:Int;let at:Date;let kind:String
    let pointID:String;let presentationID:UUID;let checkID:String?
    let selectedID:String?;let correct:Bool?;let assisted:Bool
    var definitionID:String?=nil
    var purpose:String?=nil
    var errorTag:String?=nil
    var evidenceVersion:Int?=nil
    var shownAt:Date?=nil
    var eligibleAtShow:Bool?=nil
    var familiarity:String?=nil
    var curriculumID:String?=nil
    var helpPointIDs:[String]?=nil
    var stepScores:[KnowledgeStepScore]?=nil
    var probeForAttemptID:UUID?=nil
    var probeForStepID:String?=nil
    var hypothesisTag:String?=nil
    var reviewDueAt:Date?=nil
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
struct KnowledgePracticeToken:Hashable {let skillID:String;let stage:String}
struct KnowledgeReturnFrame:Codable,Equatable {let returnPointID:String;let displacedPointID:String;let displaced:KnowledgePresentation?}
struct KnowledgeCurriculumVersion:Codable,Equatable {
    struct Requirement:Codable,Equatable {let skillID:String;let stages:[String]}
    let pointID:String;let requirements:[Requirement];let legacyFirstCheckID:String?
    var title:String?=nil;var goal:String?=nil
    var sections:[KnowledgeCourse.Section]?=nil
    var example:ProfessionalCardLesson.Example?=nil
    var keyFacts:[String]?=nil
    var prerequisites:[String]?=nil
    var sources:[KnowledgeCourse.Source]?=nil
    var skills:[KnowledgeCourse.Skill]?=nil
    var checkVersions:[String]?=nil
    var tokens:Set<KnowledgePracticeToken>{Set(requirements.flatMap{r in r.stages.map{KnowledgePracticeToken(skillID:r.skillID,stage:$0)}})}
    var identity:String{get throws{let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return StudySHA256.hex(try e.encode(self))}}
    static func current(_ p:KnowledgeCourse.Point)->Self {
        .init(pointID:p.id,requirements:p.skills?.map{.init(skillID:$0.id,stages:$0.practiceStages ?? ["practice"])} ?? [.init(skillID:p.id,stages:["practice"])],legacyFirstCheckID:p.skills==nil ? p.checks.first?.id:nil,
            title:p.title,goal:p.goal,sections:p.sections,example:p.example,keyFacts:p.keyFacts,prerequisites:p.prerequisites,sources:p.sources,skills:p.skills,
            checkVersions:p.checks.compactMap{try? KnowledgeQuestionVersion(pointID:p.id,check:$0).identity})
    }
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
    var curriculumVersions:[String:KnowledgeCurriculumVersion]?=nil
    var returnFrames:[KnowledgeReturnFrame]?=nil
    var presentationArchive:[String:KnowledgePresentation]?=nil
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
    var displayPoint:KnowledgeCourse.Point?{current.flatMap{displayPoint($0)}}
    private func displayPoint(_ presentation:KnowledgePresentation)->KnowledgeCourse.Point? {
        guard let p=course.point(presentation.pointID) else{return nil}
        if presentation.mode=="legacy",let b=p.legacyBaseline,let sections=b.sections,let example=b.example,let facts=b.keyFacts {
            return .init(id:p.id,title:p.title,goal:"旧版讲解断点保留；结束本段后接续新版方法。",prerequisites:b.prerequisites ?? p.prerequisites,sections:sections,keyFacts:facts,example:example,checks:b.checks,sources:p.sources,legacyEvidenceCardIDs:p.legacyEvidenceCardIDs)
        }
        guard let key=presentation.curriculumID,let d=record.curriculumVersions?[key],let sections=d.sections,let example=d.example,let facts=d.keyFacts else{return p}
        return .init(id:p.id,title:d.title ?? p.title,goal:d.goal ?? p.goal,prerequisites:d.prerequisites ?? p.prerequisites,sections:sections,keyFacts:facts,example:example,
            checks:d.checkVersions?.compactMap{record.questionVersions?[$0]?.check} ?? p.checks,sources:d.sources ?? p.sources,legacyEvidenceCardIDs:p.legacyEvidenceCardIDs,skills:d.skills)
    }
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
        var versions=old.questionVersions ?? [:],order=old.legacyOrder ?? [:],bookmarks=old.bookmarks,curricula=old.curriculumVersions ?? [:]
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
                    mark.definitionID=order[id]![mark.checkIndex];mark.mode="legacy";mark.familiarity="history-unknown"
                    if baseline?.sections==nil,let count=baseline?.sectionCount,mark.page>=count{mark.page=p.sections.count+(mark.page-count)}
                    bookmarks[id]=mark
                }
            }
        } else if old.questionVersions==nil || old.legacyOrder==nil{throw ExamError.invalid("题目版本档缺失，不能重建历史。")}
        if old.format=="knowledge-learning-v2" {
            for (id,stored) in bookmarks where stored.phase=="question" && stored.shownAt==nil {
                var mark=stored;mark.familiarity="history-unknown";mark.mode="legacy";bookmarks[id]=mark
            }
        }
        for p in course.points {
            if order[p.id]==nil {order[p.id]=try (p.legacyBaseline?.checks ?? p.checks).map{try register(p.id,$0)}}
            for q in p.allChecks{_=try register(p.id,q)}
            let definition=KnowledgeCurriculumVersion.current(p);curricula[try definition.identity]=definition
        }
        return .init(format:"knowledge-learning-v2",subject:old.subject,courseID:old.courseID,
            pointIDs:old.pointIDs+ids.filter{!old.pointIDs.contains($0)},pointDigests:old.pointDigests,
            currentID:old.currentID,bookmarks:bookmarks,events:old.events,deferredIDs:old.deferredIDs,
            questionVersions:versions,legacyOrder:order,exposures:old.exposures ?? [],returnPoints:old.returnPoints ?? [],curriculumVersions:curricula,returnFrames:old.returnFrames ?? [],presentationArchive:old.presentationArchive ?? [:])
    }
    static func fresh(_ course:KnowledgeCourse)throws->Self {
        let digests=try Dictionary(uniqueKeysWithValues:course.points.map{($0.id,try digest($0))})
        let empty=KnowledgeLearningRecord(format:"knowledge-learning-v2",subject:course.subject,courseID:course.id,
            pointIDs:course.points.map(\.id),pointDigests:digests,currentID:nil,bookmarks:[:],events:[],deferredIDs:[],questionVersions:[:],legacyOrder:[:],exposures:[],returnPoints:[])
        return try Self(course:course,record:appending(empty,to:course))
    }
    init(course:KnowledgeCourse,record:KnowledgeLearningRecord)throws {
        try course.validateTopics()
        self.course=course;self.record=record
        let pointIDs=Set(course.points.map(\.id))
        guard record.format=="knowledge-learning-v2",record.subject==course.subject,record.courseID==course.id,
              !pointIDs.isEmpty,record.pointIDs.count==pointIDs.count,Set(record.pointIDs)==pointIDs,
              record.currentID==nil || record.bookmarks[record.currentID!] != nil,
              Set(record.bookmarks.keys).isSubset(of:pointIDs),Set(record.deferredIDs).isSubset(of:pointIDs),
              Set(record.returnPoints ?? []).isSubset(of:pointIDs),let versions=record.questionVersions,let legacy=record.legacyOrder else{throw ExamError.invalid("知识点档案身份或版本表不一致。")}
        guard (record.returnFrames ?? []).allSatisfy({pointIDs.contains($0.returnPointID) && pointIDs.contains($0.displacedPointID) && ($0.displaced==nil || $0.displaced?.pointID==$0.displacedPointID)}) else{throw ExamError.invalid("前置探针返回断点不完整。")}
        guard (record.presentationArchive ?? [:]).allSatisfy({$0.key==$0.value.id.uuidString && pointIDs.contains($0.value.pointID) && $0.value.definitionID.map{record.questionVersions?[$0] != nil}==true}) else{throw ExamError.invalid("已替换断点归档不完整。")}
        var grading:[String:String]=[:]
        for (key,v) in versions {
            guard pointIDs.contains(v.pointID),try v.identity==key else{throw ExamError.invalid("历史题目版本校验失败。")}
            try v.check.validateResponse();let hash=try v.check.gradingDigest()
            if let prior=grading[v.check.id]{guard prior==hash else{throw ExamError.invalid("同题ID出现不同评分。")}}
            grading[v.check.id]=hash
        }
        for p in course.points {for q in p.allChecks{guard grading[q.id]==(try q.gradingDigest()) else{throw ExamError.invalid("活动题缺少可信版本。")}}}
        for (key,v) in record.curriculumVersions ?? [:] {
            guard pointIDs.contains(v.pointID),try v.identity==key,!v.requirements.isEmpty,Set(v.requirements.map(\.skillID)).count==v.requirements.count,
                  v.requirements.allSatisfy({!$0.stages.isEmpty && Set($0.stages).count==$0.stages.count}) else{throw ExamError.invalid("教学达标条件版本损坏。")}
            if let keys=v.checkVersions{guard !keys.isEmpty,keys.allSatisfy({versions[$0]?.pointID==v.pointID}) else{throw ExamError.invalid("旧讲解的题目目录缺失。")}}
        }
        let exposures=record.exposures ?? []
        guard Set(exposures.map(\.id)).count==exposures.count,exposures.allSatisfy({$0.courseID==course.id && !$0.pointIDs.isEmpty && Set($0.pointIDs).isSubset(of:pointIDs) && $0.at.timeIntervalSinceReferenceDate.isFinite}) else{throw ExamError.invalid("资料查阅事件不完整。")}
        let chronological=exposures.sorted{$0.at<$1.at};var exposureIndex=0
        var eventIDs=Set<UUID>(),answered=Set<UUID>(),hinted=Set<UUID>(),lastDay=18_000,lastTime=Date.distantPast
        var observedPresentations=Set<UUID>(),presentationDefinitions:[UUID:String]=[:]
        var displayed:[UUID:KnowledgeLearningEvent]=[:]
        var seenChecks=Set<String>(),seenAnswers=Set<String>(),sourceReferences=Set<String>()
        let curricula=record.curriculumVersions ?? [:],byPoint=Dictionary(grouping:Array(curricula),by:{$0.value.pointID})
        var practiceTokens:[String:Set<KnowledgePracticeToken>]=[:],trainedDefinitions:[String:Date]=[:]
        var helpAt:[String:Date]=[:],oldReads:[Int:Set<String>]=[:]
        for (index,e) in record.events.enumerated() {
            guard e.sequence==index+1,eventIDs.insert(e.id).inserted,e.day>=lastDay,(18_000...50_000).contains(e.day),e.at.timeIntervalSinceReferenceDate.isFinite,
                  (e.evidenceVersion ?? 0)<2 || e.at>=lastTime,let p=course.point(e.pointID),
                  ["read","hint","answer","defer","feedback-read","error-note","present"].contains(e.kind) else{throw ExamError.invalid("知识点事件链损坏。")}
            while exposureIndex<chronological.count,chronological[exposureIndex].at<=e.at {
                let exposure=chronological[exposureIndex]
                for id in exposure.pointIDs{helpAt[id]=max(helpAt[id] ?? .distantPast,exposure.at)}
                if exposure.kind=="source"{sourceReferences.insert(exposure.reference)}
                exposureIndex+=1
            }
            if let source=e.probeForAttemptID {
                guard source != e.presentationID,observedPresentations.contains(source),(e.hypothesisTag?.count ?? 0)<=80 else{throw ExamError.invalid("探针缺少原作答引用。")}
                if let step=e.probeForStepID{guard let key=presentationDefinitions[source],versions[key]?.check.steps?.contains(where:{$0.id==step})==true else{throw ExamError.invalid("探针原步骤不存在。")}}
            }
            if e.kind=="present" {
                guard [3,4].contains(e.evidenceVersion ?? 0),e.shownAt==e.at,displayed[e.presentationID]==nil,
                      let definition=e.definitionID,let v=versions[definition],v.pointID==p.id,v.check.id==e.checkID,
                      ["unseen-in-app","seen-question","seen-answer","source-exposed","history-unknown"].contains(e.familiarity ?? ""),let eligible=e.eligibleAtShow else{throw ExamError.invalid("题目首次展示事实不完整。")}
                let helpers:Set<String>
                if e.evidenceVersion==4 {
                    guard let ids=e.helpPointIDs,Set(ids).count==ids.count,Set(ids).isSubset(of:pointIDs),ids.contains(p.id),Set(v.check.relatedKnowledgeIDs ?? []).isSubset(of:Set(ids)) else{throw ExamError.invalid("首次展示缺少当时帮助范围。")}
                    helpers=Set(ids)
                } else{helpers=Set([p.id]+(v.check.relatedKnowledgeIDs ?? []))}
                let helped=helpers.contains{(helpAt[$0] ?? .distantPast)>e.at.addingTimeInterval(-86_400)}
                if e.evidenceVersion==4 {
                    guard let cid=e.curriculumID,let definition=curricula[cid],definition.pointID==p.id else{throw ExamError.invalid("首次展示缺少当时达标条件版本。")}
                    guard Set(definition.prerequisites ?? []).isSubset(of:helpers) else{throw ExamError.invalid("首次展示遗漏当时前置帮助范围。")}
                    let qualified=e.purpose=="review" && !helped && trainedDefinitions[cid].map{e.at.timeIntervalSince($0)>=86_400}==true
                    guard !eligible || qualified else{throw ExamError.invalid("首次展示的延迟资格不一致。")}
                }
                guard !eligible || !e.assisted else{throw ExamError.invalid("首次展示帮助标记不一致。")}
                if let due=e.reviewDueAt{guard !eligible || due<=e.at else{throw ExamError.invalid("首次展示尚未到安排的复核时间。")}}
                let sourceSeen=v.check.originalQuestionID.flatMap{id in course.questionMappings.first{$0.id==id}}.map{sourceReferences.contains($0.documentID+"/"+String($0.page))} ?? false
                let exposureIDs=v.check.exposureKeys
                let expected=(!seenAnswers.isDisjoint(with:exposureIDs)) ? "seen-answer":(!seenChecks.isDisjoint(with:exposureIDs) ? "seen-question":(sourceSeen ? "source-exposed":(v.check.originalQuestionID != nil ? "history-unknown":"unseen-in-app")))
                guard e.familiarity==expected || e.familiarity=="history-unknown" else{throw ExamError.invalid("题目熟悉度与历史展示事实不一致。")}
                seenChecks.formUnion(exposureIDs)
                displayed[e.presentationID]=e
            }
            if e.kind=="answer" {
                let key=e.definitionID ?? legacy[e.pointID]?.first(where:{versions[$0]?.check.id==e.checkID})
                guard let key,let v=versions[key],v.pointID==e.pointID,v.check.id==e.checkID,
                      answered.insert(e.presentationID).inserted,let response=e.selectedID,v.check.accepts(response),e.correct==v.check.correct(response) else{throw ExamError.invalid("历史作答与题目版本或判分不一致。")}
                let q=v.check
                guard e.stepScores==q.stepScores(response) else{throw ExamError.invalid("分步骤评分与保存的原始作答不一致。")}
                seenChecks.formUnion(q.exposureKeys);seenAnswers.formUnion(q.exposureKeys)
                if [3,4].contains(e.evidenceVersion ?? 0) {
                    guard let opened=displayed[e.presentationID],opened.definitionID==e.definitionID,e.shownAt==opened.at,
                          e.eligibleAtShow==opened.eligibleAtShow,e.familiarity==opened.familiarity,e.curriculumID==opened.curriculumID,e.helpPointIDs==opened.helpPointIDs,
                          e.purpose==opened.purpose,e.probeForAttemptID==opened.probeForAttemptID,e.probeForStepID==opened.probeForStepID,e.hypothesisTag==opened.hypothesisTag,e.reviewDueAt==opened.reviewDueAt else{throw ExamError.invalid("作答缺少相应首次展示事实。")}
                    let helpers=Set(opened.helpPointIDs ?? ([p.id]+(q.relatedKnowledgeIDs ?? [])))
                    let helpedSinceShow=hinted.contains(e.presentationID) || helpers.contains{(helpAt[$0] ?? .distantPast)>=opened.at}
                    guard e.assisted || (opened.eligibleAtShow==true && !opened.assisted && !helpedSinceShow && e.purpose=="review") else{throw ExamError.invalid("提前展示或作答期间用过帮助，不能改成延迟独立成绩。")}
                } else if e.evidenceVersion==2 {
                    let helpers=Set([p.id]+(q.relatedKnowledgeIDs ?? []))
                    let helped=hinted.contains(e.presentationID) || helpers.contains{(helpAt[$0] ?? .distantPast)>e.at.addingTimeInterval(-86_400)}
                    guard !(helped || e.purpose != "review") || e.assisted else{throw ExamError.invalid("查阅或练习后的回答不能标成独立。")}
                    if !e.assisted {guard p.purpose(q) != "guided" else{throw ExamError.invalid("即时练习不能冒充隔时检验。")}}
                } else {
                    let first=legacy[p.id]?.first.flatMap{versions[$0]?.check.id}
                    let helped=hinted.contains(e.presentationID) || !(oldReads[e.day] ?? []).isDisjoint(with:Set([p.id]+(p.legacyBaseline?.prerequisites ?? [])))
                    guard !(helped || e.checkID==first) || e.assisted else{throw ExamError.invalid("旧练习助力标记不一致。")}
                }
                if e.correct==true {
                    for (cid,definition) in byPoint[p.id] ?? [] {
                        if let token=Self.practiceToken(e,q:q,definition:definition){practiceTokens[cid,default:[]].insert(token)}
                        if trainedDefinitions[cid]==nil,definition.tokens.isSubset(of:practiceTokens[cid] ?? []){trainedDefinitions[cid]=e.at}
                    }
                }
            } else if e.correct != nil || e.selectedID != nil || e.stepScores != nil{throw ExamError.invalid("阅读和错因不能带答题分数。")}
            if ["read","hint","feedback-read"].contains(e.kind){helpAt[e.pointID]=e.at}
            if e.kind=="read"{oldReads[e.day,default:[]].insert(e.pointID)}
            if e.kind=="hint"{hinted.insert(e.presentationID)}
            observedPresentations.insert(e.presentationID);if let key=e.definitionID{presentationDefinitions[e.presentationID]=key}
            lastDay=e.day;lastTime=max(lastTime,e.at)
        }
        for (id,p) in record.bookmarks {
            guard id==p.pointID,let unit=displayPoint(p),["lesson","question","feedback","complete"].contains(p.phase),
                  (0..<unit.lessonPageCount).contains(p.page),let key=p.definitionID,let q=versions[key]?.check,
                  Set(p.order)==Set(q.choices.map(\.id)),p.order.count==q.choices.count else{throw ExamError.invalid("知识点断点或选项次序无效。")}
            if let shown=p.shownAt {
                guard let event=displayed[p.id],event.at==shown,event.definitionID==p.definitionID,event.familiarity==p.familiarity,event.eligibleAtShow==p.eligibleAtShow,event.purpose==p.mode,event.curriculumID==p.curriculumID,event.helpPointIDs==p.helpPointIDs,
                      event.probeForAttemptID==p.probeForAttemptID,event.probeForStepID==p.probeForStepID,event.hypothesisTag==p.hypothesisTag,event.reviewDueAt==p.reviewDueAt else{throw ExamError.invalid("断点首次展示信息不一致。")}
            } else if p.eligibleAtShow==true{throw ExamError.invalid("没有首次展示事实的断点不能声明延迟资格。")}
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
        guard let p=course.point(pointID) else{return []};let definition=KnowledgeCurriculumVersion.current(p);var tokens=Set<KnowledgePracticeToken>()
        for e in record.events where e.pointID==pointID && e.kind=="answer" && e.correct==true {
            guard let q=question(e,in:record) else{continue}
            if let token=practiceToken(e,q:q,definition:definition){tokens.insert(token)}
        }
        return Set(definition.requirements.filter{r in r.stages.allSatisfy{tokens.contains(.init(skillID:r.skillID,stage:$0))}}.map(\.skillID))
    }
    private static func trainingAt(record:KnowledgeLearningRecord,course:KnowledgeCourse,pointID:String)->Date? {
        guard let p=course.point(pointID) else{return nil}
        return trainingAt(record:record,definition:KnowledgeCurriculumVersion.current(p))
    }
    private static func trainingAt(record:KnowledgeLearningRecord,definition:KnowledgeCurriculumVersion)->Date? {
        var tokens=Set<KnowledgePracticeToken>()
        for e in record.events where e.pointID==definition.pointID && e.kind=="answer" && e.correct==true {
            guard let q=question(e,in:record) else{continue}
            if let token=practiceToken(e,q:q,definition:definition){tokens.insert(token)}
            if definition.tokens.isSubset(of:tokens){return e.at}
        }
        return nil
    }
    private static func practiceToken(_ e:KnowledgeLearningEvent,q:KnowledgeCourse.Check,definition:KnowledgeCurriculumVersion)->KnowledgePracticeToken? {
        guard e.pointID==definition.pointID,e.kind=="answer",e.correct==true else{return nil}
        if (e.evidenceVersion ?? 0)>=2,e.purpose=="practice"{return .init(skillID:q.skillID ?? definition.pointID,stage:q.practiceStage ?? "practice")}
        if (e.evidenceVersion ?? 0)<2,definition.legacyFirstCheckID==q.id{return .init(skillID:definition.pointID,stage:"practice")}
        return nil
    }
    func trainedDay(_ id:String)->Int?{trainedAt(id).flatMap{try? ConceptCalendar.studyDay($0)}}
    func trainedAt(_ id:String)->Date?{Self.trainingAt(record:record,course:course,pointID:id)}
    func learnedSkills(_ id:String)->Int{Self.practiceSkills(record:record,course:course,pointID:id).count}
    private static func helperIDs(course:KnowledgeCourse,pointID:String,check:KnowledgeCourse.Check?,extra:[String]=[])->Set<String> {
        var result=Set([pointID]+(check?.relatedKnowledgeIDs ?? [])+extra),todo=Array(result)
        while let id=todo.popLast(){for parent in course.point(id)?.prerequisites ?? []{if result.insert(parent).inserted{todo.append(parent)}}}
        return result
    }
    private static func hasHelp(record:KnowledgeLearningRecord,course:KnowledgeCourse,pointID:String,check:KnowledgeCourse.Check,at:Date,scope:Set<String>?=nil)->Bool {
        let ids=scope ?? helperIDs(course:course,pointID:pointID,check:check),cutoff=at.addingTimeInterval(-86_400)
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
        for e in record.events where e.pointID==id && e.kind=="answer" && e.purpose=="review" && (e.evidenceVersion ?? 0)>=2 {
            guard let q=Self.question(e,in:record) else{continue}
            if e.correct==false{level=1;last=e.at;families=[];skills=[];transfer=false;wrong=true}
            else if !e.assisted && evidenceQualifies(q,point:p) {
                level=min(10,max(1,level+1));last=e.at;families.insert(q.family ?? q.id);skills.insert(p.skill(q))
                transfer=transfer || (["transfer","mixed"].contains(p.purpose(q)) && e.familiarity=="unseen-in-app" && e.evidenceVersion==4);wrong=false
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
    private func evidenceQualifies(_ q:KnowledgeCourse.Check,point:KnowledgeCourse.Point)->Bool {
        let required=point.skills?.first{$0.id==point.skill(q)}?.independentEvidence ?? "concept"
        return required=="steps" ? q.evidence=="steps":["concept","steps"].contains(q.evidence)
    }
    private func day(_ now:Date)throws->Int {
        let day=try ConceptCalendar.studyDay(now)
        guard day >= (record.events.last?.day ?? day),now >= (record.events.last?.at ?? now),now >= ((record.exposures ?? []).map(\.at).max() ?? now) else{throw ExamError.invalid("日期早于已有事件，原进度保留。")}
        return day
    }
    private mutating func event(_ kind:String,_ p:KnowledgePresentation,_ now:Date,selected:String?=nil,tag:String?=nil)throws {
        let q=p.definitionID.flatMap{record.questionVersions?[$0]?.check}
        record.events.append(.init(id:UUID(),sequence:record.events.count+1,day:try day(now),at:now,kind:kind,pointID:p.pointID,presentationID:p.id,
            checkID:["answer","hint","error-note","feedback-read","present"].contains(kind) ? q?.id:nil,
            selectedID:selected,correct:selected.map{q!.correct($0)},assisted:p.assisted,definitionID:p.definitionID,purpose:p.mode,errorTag:tag,evidenceVersion:4,
            shownAt:p.shownAt,eligibleAtShow:p.eligibleAtShow,familiarity:p.familiarity,curriculumID:p.curriculumID,helpPointIDs:p.helpPointIDs,
            stepScores:selected.flatMap{q?.stepScores($0)},probeForAttemptID:p.probeForAttemptID,probeForStepID:p.probeForStepID,hypothesisTag:p.hypothesisTag,reviewDueAt:p.reviewDueAt))
    }
    private func version(_ pointID:String,_ q:KnowledgeCourse.Check)->String{(try? KnowledgeQuestionVersion(pointID:pointID,check:q).identity) ?? ""}
    private mutating func savePresentation(_ p:KnowledgePresentation) {
        if let previous=record.bookmarks[p.pointID],previous.id != p.id{var archive=record.presentationArchive ?? [:];archive[previous.id.uuidString]=previous;record.presentationArchive=archive}
        record.bookmarks[p.pointID]=p
    }
    private mutating func restoreFrame(_ frame:KnowledgeReturnFrame) {
        if let previous=frame.displaced{savePresentation(previous)}
        else {
            if let temporary=record.bookmarks[frame.displacedPointID]{var archive=record.presentationArchive ?? [:];archive[temporary.id.uuidString]=temporary;record.presentationArchive=archive}
            record.bookmarks.removeValue(forKey:frame.displacedPointID)
        }
    }
    private func presentation(_ id:String,q:KnowledgeCourse.Check?=nil,review:Bool=false)->KnowledgePresentation {
        let p=course.point(id)!,selected=q ?? p.checks[0]
        return .init(id:UUID(),pointID:id,phase:review ? "question":"lesson",page:0,
            checkIndex:p.checks.firstIndex{$0.id==selected.id} ?? 0,order:selected.choices.map(\.id).shuffled(),assisted:!review,hintVisible:false,selectedID:nil,
            definitionID:version(id,selected),mode:review ? "review":"practice",curriculumID:try? KnowledgeCurriculumVersion.current(p).identity)
    }
    private func selectCheck(_ p:KnowledgeCourse.Point,review:Bool,skillID:String?=nil)->KnowledgeCourse.Check {
        let pool=p.checks.filter{q in (review ? p.purpose(q) != "guided":p.purpose(q)=="guided") && (skillID==nil || p.skill(q)==skillID)}
        let qualified=review ? pool.filter{evidenceQualifies($0,point:p) || p.purpose($0)=="original"}:pool
        let eligible=qualified.isEmpty ? pool:qualified
        let candidates=eligible.isEmpty ? p.checks:eligible,answers=record.events.filter{$0.pointID==p.id && $0.kind=="answer"}
        let last=answers.last?.checkID,counts=Dictionary(grouping:answers,by:{$0.checkID ?? ""}).mapValues{$0.count}
        let passed=reviewStatus(p.id)?.passedSkills ?? []
        let definition=KnowledgeCurriculumVersion.current(p)
        let practiced=Set(answers.compactMap{e -> KnowledgePracticeToken? in guard let q=Self.question(e,in:record) else{return nil};return Self.practiceToken(e,q:q,definition:definition)})
        return candidates.enumerated().min{a,b in
            let pa=review ? (passed.contains(p.skill(a.element)) ? 1:0):(practiced.contains(.init(skillID:p.skill(a.element),stage:a.element.practiceStage ?? "practice")) ? 1:0)
            let pb=review ? (passed.contains(p.skill(b.element)) ? 1:0):(practiced.contains(.init(skillID:p.skill(b.element),stage:b.element.practiceStage ?? "practice")) ? 1:0)
            let ka=(pa,encounterCount(a.element.id)==0 ? 0:1,a.element.id==last ? 1:0,counts[a.element.id] ?? 0,a.offset)
            let kb=(pb,encounterCount(b.element.id)==0 ? 0:1,b.element.id==last ? 1:0,counts[b.element.id] ?? 0,b.offset)
            return ka<kb
        }!.element
    }
    private func practiced(_ q:KnowledgeCourse.Check,in p:KnowledgeCourse.Point)->Bool {
        let definition=KnowledgeCurriculumVersion.current(p),wanted=KnowledgePracticeToken(skillID:p.skill(q),stage:q.practiceStage ?? "practice")
        return record.events.contains{e in guard let old=Self.question(e,in:record) else{return false};return Self.practiceToken(e,q:old,definition:definition)==wanted}
    }
    mutating func start(now:Date=Date())throws {
        _=try day(now)
        if let current {
            if current.phase=="question"{try refreshAssistance(now:now);return}
            if current.phase != "complete"{return}
            if trainedAt(current.pointID)==nil,let unit=course.point(current.pointID) {
                let learned=Self.practiceSkills(record:record,course:course,pointID:unit.id)
                if let missing=unit.requiredSkillIDs.first(where:{!learned.contains($0)}){try beginUpdatedLesson(unit,skillID:missing,now:now)}
                return
            }
            if let due=reviewStatus(current.pointID),due.dueAt<=now{try open(current.pointID,review:true,now:now)}
            else{try next(now:now)}
            return
        }
        record.deferredIDs=[];try next(now:now)
    }
    mutating func open(_ id:String,review:Bool=false,restart:Bool=false,now:Date=Date())throws {
        _=try day(now);guard let unit=course.point(id) else{return}
        if var frames=record.returnFrames,let frame=frames.last,frame.returnPointID==id,record.currentID==frame.displacedPointID{frames.removeLast();record.returnFrames=frames;restoreFrame(frame)}
        var p=record.bookmarks[id] ?? presentation(id)
        if restart{p=presentation(id)}
        if review{guard trainedAt(id) != nil else{return};p=presentation(id,q:selectCheck(unit,review:true),review:true)}
        record.currentID=id;savePresentation(p)
        if p.phase=="lesson"{try event("read",p,now)}
        if p.phase=="question"{try refreshAssistance(now:now)}
    }
    private mutating func refreshAssistance(now:Date)throws {
        guard current?.phase=="question" else{return};_=try day(now)
        try presented(now:now)
        guard var p=current,let q=check,let shown=p.shownAt else{return}
        let ids=Set(p.helpPointIDs ?? [p.pointID])
        let helped=record.events.contains{ids.contains($0.pointID) && ["read","hint","feedback-read"].contains($0.kind) && $0.at>=shown && $0.at<=now}
            || (record.exposures ?? []).contains{!Set($0.pointIDs).isDisjoint(with:ids) && $0.at>=shown && $0.at<=now}
        p.assisted=p.assisted || p.eligibleAtShow != true || p.mode != "review" || p.hintVisible || helped
        savePresentation(p)
    }
    private mutating func presented(now:Date)throws {
        guard var p=current,p.phase=="question",p.shownAt==nil,let q=check else{return}
        let sourceSeen=q.originalQuestionID.flatMap{id in course.questionMappings.first{$0.id==id}}.map{m in
            (record.exposures ?? []).contains{$0.kind=="source" && $0.reference==m.documentID+"/"+String(m.page) && $0.at<=now}
        } ?? false
        if p.familiarity==nil {
            let answered=record.events.contains{e in guard e.kind=="answer",let old=Self.question(e,in:record) else{return false};return !old.exposureKeys.isDisjoint(with:q.exposureKeys)}
            p.familiarity=answered ? "seen-answer":(encounterCount(q.id)>0 ? "seen-question":(sourceSeen ? "source-exposed":(q.originalQuestionID != nil ? "history-unknown":"unseen-in-app")))
        }
        if p.curriculumID==nil{p.curriculumID=try KnowledgeCurriculumVersion.current(point!).identity}
        guard let cid=p.curriculumID,let definition=record.curriculumVersions?[cid] else{throw ExamError.invalid("本次展示缺少教学条件版本。")}
        p.helpPointIDs=Self.helperIDs(course:course,pointID:p.pointID,check:q,extra:definition.prerequisites ?? []).sorted()
        p.reviewDueAt=reviewStatus(p.pointID)?.dueAt
        p.shownAt=now;p.eligibleAtShow=p.mode=="review" && !p.hintVisible && p.reviewDueAt.map{now >= $0}==true && Self.trainingAt(record:record,definition:definition).map{now.timeIntervalSince($0)>=86_400}==true
            && !Self.hasHelp(record:record,course:course,pointID:p.pointID,check:q,at:now,scope:Set(p.helpPointIDs ?? [p.pointID]))
        p.assisted=p.eligibleAtShow != true
        savePresentation(p);try event("present",p,now)
    }
    private mutating func ask(_ q:KnowledgeCourse.Check,mode:String,resumePage:Int?=nil,now:Date)throws {
        guard let old=current else{return};var p=presentation(old.pointID,q:q,review:true)
        p.mode=mode;p.page=old.page;p.resumePage=resumePage;p.curriculumID=old.curriculumID ?? p.curriculumID
        p.probeForAttemptID=old.probeForAttemptID;p.probeForStepID=old.probeForStepID;p.hypothesisTag=old.hypothesisTag
        savePresentation(p);try refreshAssistance(now:now)
    }
    mutating func readNext(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="lesson",let unit=displayPoint else{return};_=try day(now)
        if p.mode=="probe-lesson"{try ask(selectCheck(unit,review:false,skillID:p.retrySkillID),mode:"probe",now:now);return}
        if p.page<unit.sections.count,let id=unit.sections[p.page].checkpointID,let q=unit.checks.first(where:{$0.id==id}) {
            if p.retrySkillID != nil || !practiced(q,in:unit) {
                let chosen=p.retrySkillID==unit.skill(q) ? selectCheck(unit,review:false,skillID:p.retrySkillID):q
                try ask(chosen,mode:"practice",resumePage:p.page+1,now:now);return
            }
        }
        if p.page<unit.lessonPageCount-1 {
            p.id=UUID();p.page+=1;p.selectedID=nil;savePresentation(p);try event("read",p,now)
        } else {
            let target=course.point(unit.id)!,passed=Self.practiceSkills(record:record,course:course,pointID:unit.id)
            if let missing=target.requiredSkillIDs.first(where:{!passed.contains($0)}) {
                let revision=try KnowledgeCurriculumVersion.current(target).identity
                if p.mode=="legacy" || p.curriculumID != revision{try beginUpdatedLesson(target,skillID:missing,now:now)}
                else{try ask(selectCheck(unit,review:false,skillID:missing),mode:"practice",now:now)}
            }
            else{p.phase="complete";p.selectedID=nil;savePresentation(p)}
        }
    }
    mutating func hint(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="question",!p.hintVisible else{return}
        p.assisted=true;p.hintVisible=true;savePresentation(p);try event("hint",p,now)
    }
    mutating func reference(now:Date=Date())throws {
        guard let p=current else{return};if p.phase=="question"{try hint(token:p.id,now:now)}else{try event("read",p,now)}
    }
    mutating func answer(_ response:String,token:UUID,now:Date=Date())throws {
        guard let p=current,p.id==token,p.phase=="question",let q=check else{return}
        guard q.accepts(response) else{throw ExamError.invalid(q.type=="number" ? "请输入有限数值，并按要求填写单位。":"请先选择完整答案。")}
        try refreshAssistance(now:now);var next=current!
        try event("answer",next,now,selected:response,tag:q.correct(response) ? nil:q.errorTag(response))
        next.phase="feedback";next.selectedID=response;savePresentation(next);try event("feedback-read",next,now)
    }
    mutating func noteError(_ tag:String,token:UUID,now:Date=Date())throws {
        guard let p=current,p.id==token,p.phase=="feedback",["meaning","conditions","method","calculation","units","code-flow"].contains(tag) else{return}
        try event("error-note",p,now,tag:tag)
    }
    mutating func saveDraft(_ text:String,token:UUID)throws {
        guard var p=current,p.id==token,p.phase=="question",text.utf8.count<=(check?.type=="structured" ? 16*1024:1200) else{return}
        p.draftResponse=text;savePresentation(p)
    }
    mutating func lessonPage(_ page:Int,now:Date=Date())throws {
        guard let old=current,let unit=displayPoint,(0..<unit.lessonPageCount).contains(page) else{return}
        var p=presentation(old.pointID);p.page=page;p.curriculumID=old.curriculumID;p.mode=old.mode=="legacy" ? "legacy":"practice";savePresentation(p);try event("read",p,now)
    }
    func encounterCount(_ checkID:String)->Int {
        let q=course.points.lazy.flatMap(\.allChecks).first{$0.id==checkID} ?? record.questionVersions?.values.first{$0.check.id==checkID}?.check
        let identities=q?.exposureKeys ?? [checkID]
        return Set(record.events.filter{e in guard ["present","answer"].contains(e.kind),let old=Self.question(e,in:record) else{return false};return !old.exposureKeys.isDisjoint(with:identities)}.map(\.presentationID)).count
    }
    func unseenTransferPoolEmpty(_ id:String)->Bool {
        guard let p=course.point(id),trainedAt(id) != nil,reviewStatus(id)?.hasTransfer != true else{return false}
        let pool=p.checks.filter{["transfer","mixed"].contains(p.purpose($0)) && evidenceQualifies($0,point:p)}
        return pool.isEmpty || pool.allSatisfy{encounterCount($0.id)>0}
    }
    func independentEvidenceGaps(_ id:String)->[String] {
        guard let p=course.point(id) else{return []}
        return p.requiredSkillIDs.compactMap{skill in
            let qualified=p.checks.filter{p.skill($0)==skill && p.purpose($0) != "guided" && evidenceQualifies($0,point:p)}
            guard qualified.isEmpty else{return nil}
            return p.skills?.first{$0.id==skill}?.title ?? p.title
        }
    }
    func evidenceCounts(_ id:String)->[String:Int] {
        var counts:[String:Int]=[:]
        for e in record.events where e.pointID==id && e.kind=="answer" && e.correct==true && !e.assisted && e.eligibleAtShow==true {
            guard let q=Self.question(e,in:record) else{continue}
            let kind:String
            if q.purpose=="original"{kind="original"}
            else if q.evidence=="result"{kind="result"}
            else if e.familiarity=="unseen-in-app"{kind=q.purpose ?? "independent"}
            else if ["seen-question","seen-answer"].contains(e.familiarity ?? ""){kind="retention"}
            else{kind="unknown"}
            counts[kind,default:0]+=1
        }
        return counts
    }
    mutating func explainAgain(now:Date=Date())throws {
        guard let old=current,let unit=displayPoint else{return};let q=check;var p=presentation(old.pointID,q:q);p.curriculumID=old.curriculumID
        p.page=unit.sectionIndex(old.selectedID.flatMap{q?.repairSection($0)} ?? q?.repairSectionID) ?? 0
        p.retrySkillID=q.map{unit.skill($0)};p.mode=(old.mode=="probe" || old.mode=="probe-lesson") ? "probe-lesson":"practice"
        p.probeForAttemptID=old.probeForAttemptID;p.probeForStepID=old.probeForStepID;p.hypothesisTag=old.hypothesisTag
        if old.phase=="question"{p.resumeAttemptID=old.id}
        savePresentation(p);try event("read",p,now)
    }
    mutating func repairPrerequisite(_ id:String,skillID:String?=nil,now:Date=Date())throws {
        guard let p=current,id != p.pointID,let unit=course.point(id) else{return};_=try day(now)
        guard skillID==nil || unit.requiredSkillIDs.contains(skillID!) else{throw ExamError.invalid("前置检查方法不属于目标知识点。")}
        let frame=KnowledgeReturnFrame(returnPointID:p.pointID,displacedPointID:id,displaced:record.bookmarks[id])
        record.returnFrames=(record.returnFrames ?? [])+[frame]
        let target=skillID ?? unit.requiredSkillIDs.first
        let pool=unit.checks.filter{unit.skill($0)==target && unit.purpose($0)=="guided"}
        let question=pool.first{$0.practiceStage=="scaffold-low"} ?? pool.first{$0.type=="structured" || $0.type=="expression"} ?? selectCheck(unit,review:false,skillID:target)
        var probe=presentation(id,q:question,review:true)
        probe.probeForAttemptID=p.id
        if let raw=p.selectedID{probe.probeForStepID=check?.stepScores(raw)?.first(where:{$0.status=="wrong"})?.id;probe.hypothesisTag=check?.errorTag(raw)}
        probe.mode="probe";record.currentID=id;savePresentation(probe);try refreshAssistance(now:now)
    }
    mutating func resumeAttempt(_ id:UUID,now:Date=Date())throws {
        guard var saved=record.presentationArchive?[id.uuidString],course.point(saved.pointID) != nil else{return};_=try day(now)
        if let answer=record.events.last(where:{$0.kind=="answer" && $0.presentationID==saved.id}) {
            saved.phase="feedback";saved.selectedID=answer.selectedID;saved.assisted=answer.assisted
        }
        record.currentID=saved.pointID;savePresentation(saved)
        if saved.phase=="question"{try refreshAssistance(now:now)}else{try event("read",saved,now)}
    }
    mutating func finish(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="feedback",let q=check,let response=p.selectedID else{return}
        guard q.correct(response) else{try explainAgain(now:now);return}
        if p.mode=="probe"{try next(now:now);return}
        if let nextPage=p.resumePage,let unit=displayPoint,nextPage<unit.lessonPageCount {
            p.id=UUID();p.phase="lesson";p.page=nextPage;p.selectedID=nil;p.resumePage=nil;p.assisted=true;p.mode="practice";p.hintVisible=false
            p.shownAt=nil;p.eligibleAtShow=nil;p.familiarity=nil
            p.helpPointIDs=nil
            savePresentation(p);try event("read",p,now);return
        }
        if p.mode != "review",let unit=point {
            let learned=Self.practiceSkills(record:record,course:course,pointID:p.pointID)
            if let missing=unit.requiredSkillIDs.first(where:{!learned.contains($0)}) {
                let revision=try KnowledgeCurriculumVersion.current(unit).identity
                if p.mode=="legacy" || p.curriculumID != revision{try beginUpdatedLesson(unit,skillID:missing,now:now)}
                else{try ask(selectCheck(unit,review:false,skillID:missing),mode:"practice",now:now)}
                return
            }
        }
        p.phase="complete";savePresentation(p)
    }
    private mutating func beginUpdatedLesson(_ p:KnowledgeCourse.Point,skillID:String,now:Date)throws {
        var next=presentation(p.id)
        if let section=p.skills?.first(where:{$0.id==skillID})?.lessonSectionID{next.page=p.sectionIndex(section) ?? 0}
        record.currentID=p.id;savePresentation(next);try event("read",next,now)
    }
    /// Enter the required route without deleting an archived point's draft or return frames.
    mutating func continueMainline(now:Date=Date())throws {
        _=try day(now)
        if let p=current,course.isRequired(p.pointID) {
            if ["probe","probe-lesson"].contains(p.mode ?? "") {
                // An explicit archive repair is not a mainline lesson. Archive its
                // presentation, retaining the frame and displaced draft for return.
                try open(p.pointID,restart:true,now:now)
            } else{try start(now:now)}
            return
        }
        let resumable=record.events.reversed().map(\.pointID).first{id in
            course.isRequired(id) && record.bookmarks[id].map{$0.phase != "complete"}==true
        }
        if let resumable{try open(resumable,now:now);return}
        record.currentID=nil;record.deferredIDs=[]
        try advanceMainline(now:now)
    }
    mutating func next(now:Date=Date())throws {
        _=try day(now);let excluded=Set(record.deferredIDs)
        if var frames=record.returnFrames,let frame=frames.last,course.isRequired(frame.returnPointID) || isArchiveRepair {
            frames.removeLast()
            record.returnFrames=frames
            restoreFrame(frame)
            try open(frame.returnPointID,now:now);return
        }
        if var stack=record.returnPoints,let id=stack.last,!excluded.contains(id),course.isRequired(id) || isArchiveRepair {
            stack.removeLast()
            record.returnPoints=stack;try open(id,now:now);return
        }
        try advanceMainline(now:now)
    }
    private mutating func advanceMainline(now:Date)throws {
        let excluded=Set(record.deferredIDs),candidates=course.requiredPoints
        let snapshot=self
        let ready:(KnowledgeCourse.Point)->Bool={p in !excluded.contains(p.id) && p.prerequisites.allSatisfy{snapshot.trainedAt($0) != nil}}
        let due=candidates.first{ready($0) && snapshot.reviewStatus($0.id).map{$0.dueAt<=now}==true}
        let fresh=candidates.first{ready($0) && snapshot.trainedAt($0.id)==nil}
        record.currentID=nil
        let accessible=candidates.first{!excluded.contains($0.id) && snapshot.trainedAt($0.id)==nil}
        if let p=due ?? fresh ?? accessible {
            let restart=fresh?.id==p.id && record.bookmarks[p.id]?.phase=="complete"
            if restart,let missing=p.requiredSkillIDs.first(where:{!Self.practiceSkills(record:record,course:course,pointID:p.id).contains($0)}){try beginUpdatedLesson(p,skillID:missing,now:now)}
            else{try open(p.id,review:due?.id==p.id,restart:restart,now:now)}
        }
    }
    private var isArchiveRepair:Bool { current.map{!course.isRequired($0.pointID) || ["probe","probe-lesson"].contains($0.mode ?? "")}==true }
    var hasPendingReturn:Bool {
        (record.returnFrames ?? []).contains{course.isRequired($0.returnPointID) || isArchiveRepair}
            || (record.returnPoints ?? []).contains{course.isRequired($0) || isArchiveRepair}
    }
    mutating func deferCurrent(now:Date=Date())throws {
        guard let p=current else{return};try event("defer",p,now)
        if ["probe","probe-lesson"].contains(p.mode ?? ""),hasPendingReturn{try next(now:now);return}
        if !record.deferredIDs.contains(p.pointID){record.deferredIDs.append(p.pointID)}
        record.currentID=nil;try next(now:now)
    }
}
