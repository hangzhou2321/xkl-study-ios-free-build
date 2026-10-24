import Foundation

public struct StudyVolumeReference: Codable, Equatable, Sendable {
    public var number: Int
    public var sha256: String
    public var firstSequence,lastSequence: UInt32
    public var filename: String { "volume-\(number)-\(sha256).json" }
    public init(number: Int,sha256: String,first: UInt32,last: UInt32) {
        self.number=number;self.sha256=sha256;firstSequence=first;lastSequence=last
    }
}
public struct StudyArchiveIndex: Codable, Equatable, Sendable {
    public var version=1
    public var streamID: String
    public var volumes: [StudyVolumeReference]=[]
    public var activeBase: UInt32 { volumes.last?.lastSequence ?? 0 }
    public init(streamID: String) { self.streamID=streamID }
    public func validate(streamID: String,activeBase: UInt32,logCount: UInt32) throws {
        guard version==1,self.streamID==streamID,self.activeBase==activeBase,activeBase<=logCount else { throw AnalysisError.invalidSettings }
        var end: UInt32=0
        for (i,v) in volumes.enumerated() {
            guard end<UInt32.max,v.number==i+1,v.firstSequence==end+1,v.lastSequence>=end,
                  v.sha256.count==64,v.sha256.allSatisfy({$0.isHexDigit}) else { throw AnalysisError.invalidSettings }
            end=v.lastSequence
        }
    }
}
public struct MeaningOmission: Codable, Equatable, Sendable {
    public var answerSequence,word: UInt32
    public var deckVersion: String
    public var contentSHA256: String? = nil
    public var coreMeaningCount: Int
    /// nil means unreported, not zero omissions. IDs are word:index within deckVersion.
    public var omittedIndices: [Int]?
    public var omittedIDs: [String]? { omittedIndices?.map { "\(word):\($0)" } }
    public var reportedCount: Int? { omittedIndices?.count }
    public init(sequence: UInt32,word: UInt32,deckVersion: String,coreCount: Int,indices: [Int]?) {
        answerSequence=sequence;self.word=word;self.deckVersion=deckVersion;coreMeaningCount=coreCount
        omittedIndices=indices.map { Array(Set($0)).sorted() }.flatMap { $0.isEmpty ? nil:$0 }
    }
}
public struct StudyFeedbackPrompt: Codable, Equatable, Sendable {
    public var taskID: String
    public var completedAtSequence,day,lesson: UInt32
    public init(taskID:String,sequence:UInt32,day:UInt32,lesson:UInt32) {
        self.taskID=taskID;completedAtSequence=sequence;self.day=day;self.lesson=lesson
    }
}
public struct StudyTaskFeedback: Codable, Equatable, Sendable {
    public var task: StudyFeedbackPrompt
    public var annoyance,fatigue: Int?
    public var submittedAt: Date
    public init(task:StudyFeedbackPrompt,annoyance:Int?,fatigue:Int?,date:Date=Date()) {
        self.task=task;self.annoyance=annoyance;self.fatigue=fatigue;submittedAt=date
    }
}
public struct StudyAnnotations: Codable, Equatable, Sendable {
    public var version=1
    public var omissions: [MeaningOmission]=[]
    public var feedback: [StudyTaskFeedback]=[]
    public init() {}
    public func validate(logCount:UInt32) throws {
        guard version==1,
              omissions.allSatisfy({ o in o.answerSequence>0 && o.answerSequence<=logCount && o.word<25_644 &&
                  o.coreMeaningCount>0 &&
                  (o.contentSHA256 == nil || (o.contentSHA256!.count==64 && o.contentSHA256!.allSatisfy({$0.isHexDigit}))) &&
                  (o.omittedIndices == nil || (!o.omittedIndices!.isEmpty &&
                  Set(o.omittedIndices!).count==o.omittedIndices!.count && o.omittedIndices!.allSatisfy({ (0..<o.coreMeaningCount).contains($0) }))) }),
              Set(omissions.map(\.answerSequence)).count==omissions.count,
              feedback.allSatisfy({ f in f.task.completedAtSequence<=logCount &&
                  [f.annoyance,f.fatigue].allSatisfy({ $0 == nil || (0...10).contains($0!) }) }),
              Set(feedback.map { $0.task.taskID }).count==feedback.count else { throw AnalysisError.invalidSettings }
    }
}

/// Standard uncompressed ZIP, streamed in bounded chunks. Closed volumes are
/// never loaded into one base64 JSON. ZIP32 size limits fail without deleting data.
public enum StudyZIP {
    public struct Entry {
        public var name:String
        public var file:URL?
        public var data:Data?
        public init(name:String,file:URL) { self.name=name;self.file=file;data=nil }
        public init(name:String,data:Data) { self.name=name;self.data=data;file=nil }
    }
    private static let table: [UInt32]=(0..<256).map { value in
        var c=UInt32(value);for _ in 0..<8 { c=(c>>1)^(0xedb88320 & (0 &- (c&1))) };return c
    }
    public static func write(_ entries:[Entry],to url:URL) throws {
        guard entries.count<65_535,Set(entries.map(\.name)).count==entries.count,
              entries.allSatisfy({ !$0.name.hasPrefix("/") && !$0.name.split(separator:"/").contains("..") && $0.name.utf8.count<65_535 }) else { throw AnalysisError.invalidSettings }
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        let out=try FileHandle(forWritingTo:url);var complete=false
        defer { try? out.close();if !complete { try? FileManager.default.removeItem(at:url) } }
        var offset:UInt64=0
        func write(_ data:Data) throws {
            guard offset+UInt64(data.count)<UInt64(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
            try out.write(contentsOf:data);offset+=UInt64(data.count)
        }
        func le(_ values:[(UInt32,Int)]) -> Data {
            var data=Data();for (v,n) in values { for i in 0..<n { data.append(UInt8(truncatingIfNeeded:v >> (i*8))) } };return data
        }
        var central=Data()
        for entry in entries {
            let name=Data(entry.name.utf8),start=UInt32(offset)
            try write(le([(0x04034b50,4),(20,2),(0x0808,2),(0,2),(0,2),(0x21,2),(0,4),(0,4),(0,4),(UInt32(name.count),2),(0,2)]))
            try write(name);var crc:UInt32=UInt32.max;var size:UInt64=0
            func chunk(_ data:Data) throws {
                for b in data { crc=(crc>>8)^table[Int((crc^UInt32(b))&255)] }
                size+=UInt64(data.count);guard size<UInt64(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
                try write(data)
            }
            if let file=entry.file {
                let input=try FileHandle(forReadingFrom:file);defer { try? input.close() }
                while let bytes=try input.read(upToCount:65_536),!bytes.isEmpty { try chunk(bytes) }
            } else { try chunk(entry.data ?? Data()) }
            crc = ~crc;let count=UInt32(size)
            try write(le([(0x08074b50,4),(crc,4),(count,4),(count,4)]))
            central.append(le([(0x02014b50,4),(20,2),(20,2),(0x0808,2),(0,2),(0,2),(0x21,2),(crc,4),(count,4),(count,4),
                               (UInt32(name.count),2),(0,2),(0,2),(0,2),(0,2),(0,4),(start,4)]));central.append(name)
        }
        let centralStart=UInt32(offset);try write(central)
        try write(le([(0x06054b50,4),(0,2),(0,2),(UInt32(entries.count),2),(UInt32(entries.count),2),
                      (UInt32(central.count),4),(centralStart,4),(0,2)]))
        try out.synchronize();complete=true
    }
}
