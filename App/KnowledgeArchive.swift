import Foundation
import StudyCore

/// Lossless teaching-only archive. It never restores over any existing ledger.
struct KnowledgeArchive:Codable {
    struct File:Codable {let name:String;let sha256:String;let bytes:Data}
    let format:String;let courseID:String;let subject:ConceptSubject;let files:[File]
    static func make(course:KnowledgeCourse,root:URL)throws->Data {
        let fm=FileManager.default
        let active=try Data(contentsOf:root.appendingPathComponent("current.json"))
        guard let items=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[]) else{throw ExamError.invalid("无法读取教学归档目录。")}
        var files:[File]=[],size=0
        for case let path as URL in items {
            let info=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard info.isSymbolicLink != true else{throw ExamError.invalid("归档不读取符号链接。")}
            if info.isRegularFile != true{continue}
            let name=String(path.path.dropFirst(root.path.count+1));try valid(name)
            let data=try Data(contentsOf:path);size+=data.count
            guard size<=256*1024*1024,files.count<100_000 else{throw ExamError.invalid("教学归档过大；原文件保留。")}
            files.append(.init(name:name,sha256:StudySHA256.hex(data),bytes:data))
        }
        guard files.contains(where:{$0.name=="current.json"}),files.contains(where:{$0.name=="initial.json"}) else{throw ExamError.invalid("教学归档缺少当前档或初始档。")}
        guard files.first(where:{$0.name=="current.json"})?.bytes==active,try Data(contentsOf:root.appendingPathComponent("current.json"))==active else{throw ExamError.invalid("导出期间出现新记录，请再次导出；原档保留。")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(Self(format:"knowledge-learning-archive-v1",courseID:course.id,subject:course.subject,files:files.sorted{$0.name<$1.name}))
    }
    private static func valid(_ name:String)throws {
        let parts=name.split(separator:"/",omittingEmptySubsequences:false)
        guard !parts.isEmpty,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":")}),name.utf8.count<=500 else{throw ExamError.invalid("教学归档路径无效。")}
    }
    /// A clean, separate target is intentional: older backups cannot overwrite
    /// any newer answers, drafts, display facts, or helper exposures.
    static func restore(_ data:Data,course:KnowledgeCourse,baseDirectory:URL)throws {
        guard data.count<=350*1024*1024 else{throw ExamError.invalid("教学归档超过读取上限。")}
        let archive=try JSONDecoder().decode(Self.self,from:data)
        guard archive.format=="knowledge-learning-archive-v1",archive.courseID==course.id,archive.subject==course.subject,
              !archive.files.isEmpty,archive.files.count<=100_000,Set(archive.files.map(\.name)).count==archive.files.count else{throw ExamError.invalid("教学归档课程身份不匹配。")}
        for f in archive.files{try valid(f.name);guard StudySHA256.hex(f.bytes)==f.sha256 else{throw ExamError.invalid("教学归档字节校验失败。")}}
        guard let raw=archive.files.first(where:{$0.name=="current.json"})?.bytes,let initial=archive.files.first(where:{$0.name=="initial.json"})?.bytes else{throw ExamError.invalid("教学归档缺少活动指针或初始档。")}
        let record=try JSONDecoder().decode(KnowledgeLearningRecord.self,from:raw),begin=try JSONDecoder().decode(KnowledgeLearningRecord.self,from:initial)
        guard Array(record.events.prefix(begin.events.count))==begin.events else{throw ExamError.invalid("归档事件不连续。")}
        _=try KnowledgeLearningEngine(course:course,record:KnowledgeLearningEngine.appending(record,to:course))
        _=try KnowledgeLearningEngine(course:course,record:KnowledgeLearningEngine.appending(begin,to:course))
        let fm=FileManager.default,parent=baseDirectory.appendingPathComponent("KnowledgeLearning",isDirectory:true),root=parent.appendingPathComponent(course.subject.rawValue,isDirectory:true)
        guard !fm.fileExists(atPath:root.path) else{throw ExamError.invalid("目标已有教学记录；拒绝用归档覆盖。请恢复到独立空目录核对。")}
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let staging=parent.appendingPathComponent("restore-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        do {
            for f in archive.files {
                let path=staging.appendingPathComponent(f.name);try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
                try DurableFile.write(f.bytes,to:path);guard try Data(contentsOf:path)==f.bytes else{throw ExamError.invalid("教学归档恢复写入不完整。")}
            }
            guard !fm.fileExists(atPath:root.path) else{throw ExamError.invalid("恢复期间目标出现新档，原档保留。")}
            try fm.moveItem(at:staging,to:root)
        } catch{try? fm.removeItem(at:staging);throw error}
    }
}
