import Foundation
import StudyCore

/// Every help route appends a fact here without overwriting another view's
/// assessment snapshot. The grading store ingests these facts before answering.
@MainActor enum KnowledgeExposureLedger {
    @discardableResult static func recordCard(course:KnowledgeCourse,cardID:String,now:Date=Date(),baseDirectory:URL?=nil)throws->KnowledgeExposure? {
        let ids=course.points.filter{$0.id+":knowledge-v1"==cardID}.map(\.id)
        guard !ids.isEmpty else{throw ExamError.invalid("知识卡不属于当前知识点课程。")}
        return try record(course:course,pointIDs:ids,kind:"recall",reference:"linked-card/"+cardID,now:now,baseDirectory:baseDirectory)
    }
    static func root(_ subject:ConceptSubject,baseDirectory:URL?=nil)->URL {
        (baseDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
            .appendingPathComponent("KnowledgeLearning",isDirectory:true).appendingPathComponent(subject.rawValue,isDirectory:true)
    }
    @discardableResult static func record(course:KnowledgeCourse,pointIDs:[String],kind:String,reference:String,
        now:Date=Date(),baseDirectory:URL?=nil,writer:(Data,URL)throws->Void=DurableFile.write)throws->KnowledgeExposure? {
        let ids=Array(Set(pointIDs)).sorted();if ids.isEmpty{return nil}
        guard Set(ids).isSubset(of:Set(course.points.map(\.id))),["source","recall","lesson","hint"].contains(kind),
              now.timeIntervalSinceReferenceDate.isFinite,!reference.isEmpty,reference.count<=400 else{throw ExamError.invalid("资料查阅身份无效。")}
        guard now >= (try read(course:course,baseDirectory:baseDirectory).map(\.at).max() ?? now) else{throw ExamError.invalid("日期早于已有查阅事实，原记录保留。")}
        let parent=root(course.subject,baseDirectory:baseDirectory),current=parent.appendingPathComponent("current.json")
        if FileManager.default.fileExists(atPath:current.path) {
            let prior=try JSONDecoder().decode(KnowledgeLearningRecord.self,from:Data(contentsOf:current))
            guard now >= (prior.events.last?.at ?? now) else{throw ExamError.invalid("日期早于已有学习，查阅未记分。")}
        }
        let dir=parent.appendingPathComponent("exposures",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let event=KnowledgeExposure(id:UUID(),courseID:course.id,at:now,pointIDs:ids,kind:kind,reference:reference)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let bytes=try encoder.encode(event)
        let target=dir.appendingPathComponent(event.id.uuidString.lowercased()+".json")
        guard !FileManager.default.fileExists(atPath:target.path) else{throw ExamError.invalid("查阅事件身份重复。")}
        try writer(bytes,target)
        guard try Data(contentsOf:target)==bytes else{throw ExamError.invalid("查阅事件未完整保存。")}
        return event
    }
    static func read(course:KnowledgeCourse,baseDirectory:URL?=nil)throws->[KnowledgeExposure] {
        let dir=root(course.subject,baseDirectory:baseDirectory).appendingPathComponent("exposures",isDirectory:true)
        guard FileManager.default.fileExists(atPath:dir.path) else{return []}
        let info=try dir.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard info.isDirectory==true,info.isSymbolicLink != true else{throw ExamError.invalid("查阅目录异常。")}
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard files.count<=100_000 else{throw ExamError.invalid("查阅日志已满，保留现有记录。")}
        var events:[KnowledgeExposure]=[]
        for file in files {
            let stat=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard stat.isRegularFile==true,stat.isSymbolicLink != true,(stat.fileSize ?? Int.max)<=64*1024,file.pathExtension=="json" else{throw ExamError.invalid("查阅日志文件异常。")}
            let event=try JSONDecoder().decode(KnowledgeExposure.self,from:Data(contentsOf:file))
            guard event.id.uuidString.lowercased()==file.deletingPathExtension().lastPathComponent,event.courseID==course.id else{throw ExamError.invalid("查阅日志身份不一致。")}
            events.append(event)
        }
        return events.sorted{$0.at == $1.at ? $0.id.uuidString<$1.id.uuidString:$0.at<$1.at}
    }
}
