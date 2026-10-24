import Foundation
import StudyCore

@MainActor
enum StudyHistoryFiles {
    struct Loaded {
        var events: [StudyEvent]=[]
        var timing: StudyTimingJournal?
    }
    static func merge(_ old:StudyTimingJournal?,_ current:StudyTimingJournal) -> StudyTimingJournal {
        guard var result=old else { return current }
        result.events+=current.events;result.boundaries+=current.boundaries;result.forecasts+=current.forecasts
        result.boundaryLimitReached = result.boundaryLimitReached || current.boundaryLimitReached
        result.firstSequence=min(result.firstSequence,current.firstSequence)
        return result
    }
    static func load(_ index:StudyArchiveIndex,directory:URL) throws -> Loaded {
        var result=Loaded()
        for ref in index.volumes {
            let data=try Data(contentsOf:directory.appendingPathComponent(ref.filename),options:.mappedIfSafe)
            guard sha256(data)==ref.sha256 else { throw StudyError.persistence("历史日志分卷校验失败，已停止写入。") }
            let record=try JSONDecoder().decode(AppDiskRecord.self,from:data)
            let state=try JSONDecoder().decode(SyncState.self,from:record.syncStateJSON)
            let engine=try PocketEngine(snapshot:state.snapshot)
            guard try engine.streamID==index.streamID,engine.logBase+1==ref.firstSequence,
                  try engine.info.log_records==ref.lastSequence else { throw AnalysisError.invalidSettings }
            _ = try record.validatedAnalysis(engine:engine)
            let timing=try record.validatedTiming(engine:engine)
            let embedded=try record.validatedHistory(engine:engine)
            guard embedded.volumes==Array(index.volumes.prefix(ref.number-1)) else { throw AnalysisError.invalidSettings }
            result.events+=try engine.events(from:ref.firstSequence)
            result.timing=merge(result.timing,timing)
        }
        return result
    }
    /// Idempotent immutable write. A collision never overwrites a different file.
    static func seal(_ bytes:Data,number:Int,first:UInt32,last:UInt32,directory:URL,
                     write:(Data,URL)throws->Void) throws -> StudyVolumeReference {
        let ref=StudyVolumeReference(number:number,sha256:sha256(bytes),first:first,last:last)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=directory.appendingPathComponent(ref.filename)
        if FileManager.default.fileExists(atPath:target.path) {
            guard try Data(contentsOf:target)==bytes else { throw StudyError.persistence("历史日志文件不一致，未覆盖。") }
        } else { try write(bytes,target) }
        guard try sha256(Data(contentsOf:target))==ref.sha256 else { throw StudyError.persistence("历史日志分卷写入校验失败。") }
        return ref
    }
}
