import Foundation
import StudyCore

struct KnowledgePresentation: Codable, Equatable {
    var id: UUID; let pointID: String
    var phase: String; var page: Int; var checkIndex: Int; var order: [String]
    var assisted: Bool; var hintVisible: Bool; var selectedID: String?
}
struct KnowledgeLearningEvent: Codable, Equatable, Identifiable {
    let id: UUID; let sequence: Int; let day: Int; let at: Date; let kind: String
    let pointID: String; let presentationID: UUID; let checkID: String?
    let selectedID: String?; let correct: Bool?; let assisted: Bool
}
struct KnowledgeLearningRecord: Codable, Equatable {
    let format: String; let subject: ConceptSubject; let courseID: String
    let pointIDs: [String]; let pointDigests: [String:String]
    var currentID: String?; var bookmarks: [String:KnowledgePresentation]
    var events: [KnowledgeLearningEvent]; var deferredIDs: [String]
}

/// Transparent lesson/diagnostic routing, separate from every legacy card/exam
/// archive. Reading and assisted practice never count as independent review.
struct KnowledgeLearningEngine {
    let course: KnowledgeCourse
    private(set) var record: KnowledgeLearningRecord
    var current: KnowledgePresentation? { record.currentID.flatMap { record.bookmarks[$0] } }
    var point: KnowledgeCourse.Point? { current.flatMap { course.point($0.pointID) } }
    var check: KnowledgeCourse.Check? {
        guard let p=current,let unit=point,unit.checks.indices.contains(p.checkIndex) else{return nil}
        return unit.checks[p.checkIndex]
    }
    static func digest(_ point:KnowledgeCourse.Point)throws->String {
        let value:[String:Any]=["id":point.id,"checks":point.checks.map { q in
            ["id":q.id,"prompt":q.prompt,"answer":q.answerID,"choices":q.choices.map { ["id":$0.id,"text":$0.text] }] as [String:Any]
        }]
        return StudySHA256.hex(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]))
    }
    static func appending(_ record:KnowledgeLearningRecord,to course:KnowledgeCourse)throws->KnowledgeLearningRecord {
        guard !course.points.isEmpty,Set(course.points.map(\.id)).count==course.points.count else{throw ExamError.invalid("知识点身份为空或重复。")}
        let ids=course.points.map(\.id),digests=try Dictionary(uniqueKeysWithValues:course.points.map { ($0.id,try digest($0)) })
        guard Array(ids.prefix(record.pointIDs.count))==record.pointIDs,record.pointDigests.allSatisfy({digests[$0.key]==$0.value}),record.courseID==course.id else {
            throw ExamError.invalid("已作答诊断的题干或答案发生变化，旧记录保留；不能套用旧成绩。")
        }
        return .init(format:record.format,subject:record.subject,courseID:record.courseID,pointIDs:ids,pointDigests:digests,
            currentID:record.currentID,bookmarks:record.bookmarks,events:record.events,deferredIDs:record.deferredIDs)
    }
    static func fresh(_ course:KnowledgeCourse)throws->Self {
        guard !course.points.isEmpty,Set(course.points.map(\.id)).count==course.points.count else{throw ExamError.invalid("知识点身份为空或重复。")}
        let digests=try Dictionary(uniqueKeysWithValues:course.points.map { ($0.id,try digest($0)) })
        return try Self(course:course,record:.init(format:"knowledge-learning-v1",subject:course.subject,courseID:course.id,
            pointIDs:course.points.map(\.id),pointDigests:digests,currentID:nil,bookmarks:[:],events:[],deferredIDs:[]))
    }
    init(course:KnowledgeCourse,record:KnowledgeLearningRecord)throws {
        guard !course.points.isEmpty,Set(course.points.map(\.id)).count==course.points.count else{throw ExamError.invalid("知识点身份为空或重复。")}
        guard record.format=="knowledge-learning-v1",record.subject==course.subject,record.courseID==course.id,
              record.pointIDs==course.points.map(\.id),record.pointDigests==Dictionary(uniqueKeysWithValues:try course.points.map { ($0.id,try Self.digest($0)) }),
              record.currentID==nil || record.bookmarks[record.currentID!] != nil,
              Set(record.bookmarks.keys).isSubset(of:Set(record.pointIDs)),Set(record.deferredIDs).isSubset(of:Set(record.pointIDs)) else {
            throw ExamError.invalid("新知识点课程与学习档案不一致，原记录保留；不会新建空进度。")
        }
        var ids=Set<UUID>(),answered=Set<UUID>(),lastDay=18_000
        var hinted=Set<UUID>(),reads:[Int:Set<String>]=[:],trained:[String:Int]=[:]
        for (index,e) in record.events.enumerated() {
            guard e.sequence==index+1,ids.insert(e.id).inserted,e.day>=lastDay,e.day<=50_000,e.at.timeIntervalSinceReferenceDate.isFinite,
                  let p=course.point(e.pointID),["read","hint","answer","defer"].contains(e.kind) else { throw ExamError.invalid("知识点事件链损坏，已保留原档案。") }
            if e.kind=="answer" {
                guard answered.insert(e.presentationID).inserted,let q=p.checks.first(where:{$0.id==e.checkID}),
                      let choice=e.selectedID,q.choices.contains(where:{$0.id==choice}),e.correct==(choice==q.answerID) else {
                    throw ExamError.invalid("诊断记录与实际题目不一致，不能推测成绩。")
                }
                let help=hinted.contains(e.presentationID) || !(reads[e.day] ?? []).isDisjoint(with:Set([p.id]+p.prerequisites))
                guard !(help || e.checkID==p.checks[0].id) || e.assisted else{throw ExamError.invalid("看过讲解或提示的作答不能标成无帮助。")}
                if e.checkID==p.checks[0].id,e.correct==true,trained[p.id]==nil{trained[p.id]=e.day}
                if e.checkID != p.checks[0].id,!e.assisted {
                    guard let earlier=trained[p.id],earlier<e.day else{throw ExamError.invalid("当场练习不能冒充隔日复核。")}
                }
            } else if e.correct != nil || e.selectedID != nil { throw ExamError.invalid("阅读或提示不能包含答题成绩。") }
            if e.kind=="hint"{hinted.insert(e.presentationID)}
            if e.kind=="read"{reads[e.day,default:[]].insert(e.pointID)}
            lastDay=e.day
        }
        for (id,p) in record.bookmarks {
            guard id==p.pointID,let unit=course.point(id),["lesson","question","feedback","complete"].contains(p.phase),
                  (0...unit.sections.count+1).contains(p.page),unit.checks.indices.contains(p.checkIndex),
                  Set(p.order)==Set(unit.checks[p.checkIndex].choices.map(\.id)),p.order.count==unit.checks[p.checkIndex].choices.count else {
                throw ExamError.invalid("知识点断点无效，原文件已保留。")
            }
            if p.phase=="feedback" || p.phase=="complete" {
                guard let e=record.events.last(where:{$0.presentationID==p.id && $0.kind=="answer"}),e.selectedID==p.selectedID,e.checkID==unit.checks[p.checkIndex].id,e.assisted==p.assisted else {
                    throw ExamError.invalid("诊断断点与已保存作答不一致。")
                }
                if p.phase=="complete",e.correct != true {throw ExamError.invalid("未答对的诊断不能显示为完成。")}
            }
        }
        self.course=course;self.record=record
    }
    func trainedDay(_ id:String)->Int? {
        guard let unit=course.point(id) else{return nil}
        return record.events.first {$0.pointID==id && $0.kind=="answer" && $0.checkID==unit.checks[0].id && $0.correct==true}?.day
    }
    func reviewPassed(_ id:String)->Bool {
        guard let unit=course.point(id),unit.checks.count>1,let trained=trainedDay(id) else{return false}
        guard let last=record.events.last(where:{$0.pointID==id && $0.kind=="answer" && $0.checkID==unit.checks[1].id}) else{return false}
        return last.correct==true && !last.assisted && last.day>trained
    }
    private func day(_ now:Date)throws->Int {
        let day=try ConceptCalendar.studyDay(now)
        guard day >= (record.events.last?.day ?? day) else {throw ExamError.invalid("日期早于上次学习，原进度保留。")}
        return day
    }
    private mutating func event(_ kind:String,_ p:KnowledgePresentation,_ now:Date,selected:String?=nil)throws {
        let q=course.point(p.pointID)!.checks[p.checkIndex]
        record.events.append(.init(id:UUID(),sequence:record.events.count+1,day:try day(now),at:now,kind:kind,pointID:p.pointID,
            presentationID:p.id,checkID:kind=="read" || kind=="defer" ? nil:q.id,selectedID:selected,
            correct:selected.map {$0==q.answerID},assisted:p.assisted))
    }
    private func presentation(_ id:String,review:Bool=false)->KnowledgePresentation {
        let unit=course.point(id)!,index=review ? 1:0
        return .init(id:UUID(),pointID:id,phase:review ? "question":"lesson",page:0,checkIndex:index,
            order:unit.checks[index].choices.map(\.id).shuffled(),assisted:!review,hintVisible:false,selectedID:nil)
    }
    mutating func start(now:Date=Date())throws {
        let today=try day(now)
        if let current, current.phase != "complete" {return}
        if let current,let trained=trainedDay(current.pointID),trained<today,!reviewPassed(current.pointID),course.point(current.pointID)!.checks.count>1,!reviewedToday(current.pointID,day:today) {
            try open(current.pointID,review:true,now:now);return
        }
        if current != nil {return}
        record.deferredIDs=[]
        try next(now:now)
    }
    mutating func open(_ id:String,review:Bool=false,now:Date=Date())throws {
        let today=try day(now);guard course.point(id) != nil else{return}
        var p=record.bookmarks[id] ?? presentation(id)
        if review {
            guard course.point(id)!.checks.count>1,let trained=trainedDay(id),trained < (try day(now)) else{return}
            p=presentation(id,review:true)
            let helpers=Set([id]+course.point(id)!.prerequisites)
            p.assisted=record.events.contains {$0.day==today && $0.kind=="read" && helpers.contains($0.pointID)}
        }
        record.currentID=id;record.bookmarks[id]=p
        if p.phase=="lesson" {try event("read",p,now)}
    }
    mutating func readNext(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="lesson",let unit=point else{return}
        _=try day(now)
        p.id=UUID()
        if p.page<unit.sections.count+1 {p.page+=1;record.bookmarks[p.pointID]=p;try event("read",p,now)}
        else {p.phase="question";record.bookmarks[p.pointID]=p}
    }
    mutating func hint(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="question",!p.hintVisible else{return}
        _=try day(now);p.assisted=true;p.hintVisible=true;record.bookmarks[p.pointID]=p;try event("hint",p,now)
    }
    mutating func reference(now:Date=Date())throws {
        guard let p=current else{return}
        if p.phase=="question" {try hint(token:p.id,now:now)}
        else {try event("read",p,now)}
    }
    mutating func answer(_ choice:String,token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="question",let q=check,q.choices.contains(where:{$0.id==choice}) else{return}
        try event("answer",p,now,selected:choice)
        p.phase="feedback";p.selectedID=choice;record.bookmarks[p.pointID]=p
    }
    mutating func explainAgain(now:Date=Date())throws {
        guard let old=current else{return}
        var p=presentation(old.pointID);p.checkIndex=old.checkIndex;p.order=course.point(p.pointID)!.checks[p.checkIndex].choices.map(\.id).shuffled()
        record.bookmarks[p.pointID]=p;try event("read",p,now)
    }
    mutating func finish(token:UUID,now:Date=Date())throws {
        guard var p=current,p.id==token,p.phase=="feedback",let q=check else{return}
        guard p.selectedID==q.answerID else{try explainAgain(now:now);return}
        p.phase="complete";record.bookmarks[p.pointID]=p
    }
    mutating func next(now:Date=Date())throws {
        let today=try day(now),excluded=Set(record.deferredIDs)
        let due=course.points.first {!excluded.contains($0.id) && $0.checks.count>1 && (trainedDay($0.id).map {$0<today} ?? false) && !reviewPassed($0.id) && !reviewedToday($0.id,day:today)}
        let fresh=course.points.first {!excluded.contains($0.id) && trainedDay($0.id)==nil}
        record.currentID=nil
        if let selected=due ?? fresh {try open(selected.id,review:due?.id==selected.id,now:now)}
    }
    mutating func deferCurrent(now:Date=Date())throws {
        guard let p=current else{return}
        try event("defer",p,now);if !record.deferredIDs.contains(p.pointID){record.deferredIDs.append(p.pointID)}
        record.currentID=nil;try next(now:now)
    }
    private func reviewedToday(_ id:String,day:Int)->Bool {
        guard let unit=course.point(id),unit.checks.count>1 else{return false}
        return record.events.contains {$0.pointID==id && $0.checkID==unit.checks[1].id && $0.kind=="answer" && $0.day==day}
    }
}
