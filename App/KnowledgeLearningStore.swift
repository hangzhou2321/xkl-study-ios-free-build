import Foundation
import Combine
import StudyCore

@MainActor final class KnowledgeLearningStore:ObservableObject {
    @Published private(set) var engine:KnowledgeLearningEngine?
    @Published private(set) var blocked=false
    @Published private(set) var error:String?
    private let course:KnowledgeCourse
    private let root:URL
    private let writer:(Data,URL)throws->Void
    private var hash=""
    private var current:URL { root.appendingPathComponent("current.json") }
    private var initial:URL { root.appendingPathComponent("initial.json") }
    init(course:KnowledgeCourse,baseDirectory:URL?=nil,writer:@escaping(Data,URL)throws->Void=DurableFile.write) {
        self.course=course;self.writer=writer
        root=(baseDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
            .appendingPathComponent("KnowledgeLearning",isDirectory:true).appendingPathComponent(course.subject.rawValue,isDirectory:true)
        do {
            let fm=FileManager.default;try fm.createDirectory(at:root,withIntermediateDirectories:true)
            if fm.fileExists(atPath:current.path) {
                guard fm.fileExists(atPath:initial.path) else{throw ExamError.invalid("知识点初始档缺失，不会重建进度。")}
                let data=try read(current),prior=try JSONDecoder().decode(KnowledgeLearningRecord.self,from:data)
                let beginning=try JSONDecoder().decode(KnowledgeLearningRecord.self,from:read(initial))
                _=try KnowledgeLearningEngine(course:course,record:KnowledgeLearningEngine.appending(beginning,to:course))
                guard Array(prior.events.prefix(beginning.events.count))==beginning.events else{throw ExamError.invalid("知识点初始事件与当前历史不连续。")}
                let next=try KnowledgeLearningEngine.appending(prior,to:course)
                let restored=try KnowledgeLearningEngine(course:course,record:next)
                hash=StudySHA256.hex(data)
                if next != prior {
                    let backup=root.appendingPathComponent("before-append-"+hash+".json")
                    if fm.fileExists(atPath:backup.path) {guard try read(backup)==data else{throw ExamError.invalid("追加前备份不一致。")}}
                    else{try writer(data,backup)}
                    guard try read(backup)==data,StudySHA256.hex(try read(current))==hash else{throw ExamError.invalid("追加期间出现新记录，原文件保留。")}
                    let bytes=try encode(next);try writer(bytes,current);guard try read(current)==bytes else{throw ExamError.invalid("追加记录未保存完整。")}
                    hash=StudySHA256.hex(bytes)
                }
                engine=restored
            } else {
                guard try fm.contentsOfDirectory(atPath:root.path).isEmpty else{throw ExamError.invalid("发现旧知识点档案但当前档缺失，不会清空重建。")}
                let fresh=try KnowledgeLearningEngine.fresh(course),data=try encode(fresh.record)
                try writer(data,initial);guard try read(initial)==data else{throw ExamError.invalid("新教学初始档未保存。")}
                try writer(data,current);guard try read(current)==data else{throw ExamError.invalid("新教学当前档未保存。")}
                hash=StudySHA256.hex(data);engine=fresh
            }
        } catch{fail(error)}
    }
    func start(now:Date=Date()){change{try $0.start(now:now)}}
    func open(_ id:String,now:Date=Date()){change{try $0.open(id,now:now)}}
    func readNext(_ id:UUID){change{try $0.readNext(token:id)}}
    func hint(_ id:UUID){change{try $0.hint(token:id)}}
    func answer(_ answer:String,token:UUID){change{try $0.answer(answer,token:token)}}
    func finish(_ id:UUID){change{try $0.finish(token:id)}}
    func explain(){change{try $0.explainAgain()}}
    func next(){change{try $0.next()}}
    func deferCurrent(){change{try $0.deferCurrent()}}
    func reference(){change{try $0.reference()}}
    private func change(_ body:(inout KnowledgeLearningEngine)throws->Void) {
        guard !blocked,var next=engine else{return}
        do {
            guard StudySHA256.hex(try read(current))==hash else{throw ExamError.invalid("另一页面已保存新记录，请重新打开；不会覆盖。")}
            try body(&next);let bytes=try encode(next.record)
            guard StudySHA256.hex(bytes) != hash else{return}
            try writer(bytes,current);guard try read(current)==bytes else{throw ExamError.invalid("本次记录未完整落盘。")}
            hash=StudySHA256.hex(bytes);engine=next
        } catch{fail(error)}
    }
    func export()throws->Data {try read(current)}
    private func encode<T:Encodable>(_ v:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(v);guard data.count<=256*1024*1024 else{throw ExamError.invalid("档案过大，已有事件不会截断。")};return data
    }
    private func read(_ path:URL)throws->Data {
        let v=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard v.isRegularFile==true,v.isSymbolicLink != true,(v.fileSize ?? Int.max)<=256*1024*1024 else{throw ExamError.invalid("档案类型或大小异常。")}
        return try Data(contentsOf:path)
    }
    private func fail(_ e:Error){blocked=true;error=e.localizedDescription+" 原档已保留。"}
}
