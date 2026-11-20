import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Answers belong to this offline reader; never opens the application's flashcard/word archives.
/// One app process can own several WKWebViews or scenes. Writes re-read disk under a common lock.
final class OriginalPracticeStorage {
    private struct Archive: Codable {
        let version: Int
        var entries: [String:String]
    }
    enum Failure: LocalizedError {
        case invalidKey, tooLarge, damaged, stale
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "此页面试图写入不属于原题练习的键。"
            case .tooLarge: return "原题练习记录超过保存上限，已有记录未动。"
            case .damaged: return "未能读取完整的原题练习记录，已停止写入。"
            case .stale: return "另一页面已更新这份练习记录。请重新打开当前页，再试一次。"
            }
        }
    }
    private static let lock = NSLock()
    private static let maxKeys = 8_192, maxKeyBytes = 1_024, maxValueBytes = 1_048_576, maxFileBytes = 12_582_912
    // Also used verbatim (as JSON data, not executable source) for the browser's whitelist.
    private static let keyPattern = #"^(?:real-bank-offline-v1:(?:browse(?::(?:circuit|mechanics))?|item/[^\s\x00-\x1F\x7F]+)|beici:corrected-practice:v1:[^\s\x00-\x1F\x7F]+:[^\s\x00-\x1F\x7F]+|course-methods-v1:(?:cir|mec):[a-f0-9]{64}/(?:pos|case/[^\s\x00-\x1F\x7F]+)|offline-workout-nov20-v1|original-course-v1:(?:circuit|mechanics)|original-course-step-v1:[^\s\x00-\x1F\x7F]+)$"#
    private static let keyRegex = try! NSRegularExpression(pattern: keyPattern)
    private let file: URL
    /// Exactly what this instance was shown; a stale read-modify-write must not erase another writer.
    private var known: [String:String] = [:]
    static let messageHandlerName = "originalPracticeStore"

    init(directory: URL? = nil) throws {
        let dir: URL
        if let directory { dir = directory }
        else {
            dir = try FileManager.default.url(for:.applicationSupportDirectory, in:.userDomainMask,
                                              appropriateFor:nil, create:true)
                .appendingPathComponent("OriginalPracticeProgress",isDirectory:true)
        }
        file = dir.appendingPathComponent("original-practice-v1.json")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let props = try dir.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard props.isDirectory == true && props.isSymbolicLink != true else { throw Failure.damaged }
        // directoryContents also refuses an unreadable folder instead of treating a read error as no archive.
        try locked {
            if try !FileManager.default.contentsOfDirectory(atPath:dir.path).contains(file.lastPathComponent) {
                try Self.persist([:], at:file)
            }
            known = try Self.read(file)
        }
    }

    // lockf covers cooperating processes; the mutex also serializes separate objects in one process.
    private func locked<T>(_ operation:() throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let path = file.deletingLastPathComponent().appendingPathComponent(".original-practice.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw Failure.damaged }
        defer { _ = close(fd) }
        while lockf(fd, F_LOCK, 0) != 0 {
            guard errno == EINTR else { throw Failure.damaged }
        }
        defer { _ = lockf(fd, F_ULOCK, 0) }
        return try operation()
    }

    var values: [String:String] {
        do {
            return try locked {
                if let latest = try? Self.read(file) { known = latest }
                return known
            }
        } catch {
            Self.lock.lock(); defer { Self.lock.unlock() }
            return known
        }
    }
    private static func allowed(_ key:String) -> Bool {
        guard !key.isEmpty && key.utf8.count <= maxKeyBytes else { return false }
        let r = NSRange(key.startIndex..<key.endIndex,in:key)
        return keyRegex.firstMatch(in:key,range:r)?.range == r
    }
    private static func read(_ file:URL) throws -> [String:String] {
        let props = try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard props.isRegularFile == true && props.isSymbolicLink != true,
              let sz=props.fileSize, sz>0 && sz<=maxFileBytes else { throw Failure.damaged }
        let raw = try Data(contentsOf:file)
        guard raw.count == sz, let a=try? JSONDecoder().decode(Archive.self,from:raw), a.version == 1,
              a.entries.count <= maxKeys, a.entries.allSatisfy({allowed($0.key) && $0.value.utf8.count <= maxValueBytes})
        else { throw Failure.damaged }
        return a.entries
    }
    private static func persist(_ map:[String:String],at url:URL) throws {
        guard map.count <= maxKeys else { throw Failure.tooLarge }
        let raw=try JSONEncoder().encode(Archive(version:1,entries:map))
        guard raw.count <= maxFileBytes else { throw Failure.tooLarge }
        try raw.write(to:url,options:.atomic)
    }

    func apply(key:String,value:String?) throws {
        guard Self.allowed(key) else { throw Failure.invalidKey }
        guard (value?.utf8.count ?? 0) <= Self.maxValueBytes else { throw Failure.tooLarge }
        try locked {
            var map = try Self.read(file)
            if map[key] != value {
                guard known[key] == map[key] else { throw Failure.stale }
                map[key] = value
                try Self.persist(map,at:file)
            }
            known[key] = value
        }
    }

    private static func literal(_ value:Any) throws -> String {
        let data=try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys])
        guard let text=String(data:data,encoding:.utf8) else {throw Failure.damaged}
        return text.replacingOccurrences(of:"<",with:"\\u003c")
            .replacingOccurrences(of:"\u{2028}",with:"\\u2028").replacingOccurrences(of:"\u{2029}",with:"\\u2029")
    }
    /// Inject once for each controlled main frame at documentStart; no networking or remote origin owns this bridge.
    func bootstrapScript() throws -> String {
        let map = try locked {
            let current = try Self.read(file)
            known = current
            return current
        }
        return #"""
        (function(){
          'use strict';
          if(window.top!==window || location.protocol!=='study-originals:' || location.host!=='bundle')return;
          const host=window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.originalPracticeStore;
          if(!host || typeof host.postMessage!=='function')return;
          const allowedRE=new RegExp(\#(try Self.literal(Self.keyPattern)));
          const m=new Map(Object.entries(\#(try Self.literal(map))));
          const encoder=new TextEncoder(), limit=\#(Self.maxKeyBytes), vlimit=\#(Self.maxValueBytes), max=\#(Self.maxKeys);
          const valid=k=>typeof k==='string' && k.length<=limit && encoder.encode(k).length<=limit &&
              !/[\u0000-\u001F\u007F]/.test(k) && allowedRE.exec(k)?.[0]===k;
          const err=(name,msg)=>new DOMException(msg,name);
          let failed=false;
          function write(k,v){
            if(failed)throw err('InvalidStateError','原题练习已暂停保存');
            if(!valid(k))throw err('SecurityError','不支持的练习记录键');
            if(v!==null&&(v.length>vlimit||encoder.encode(v).length>vlimit||(!m.has(k)&&m.size>=max)))
              throw err('QuotaExceededError','练习记录超过上限');
            if((m.has(k)?m.get(k):null)===v)return;
            host.postMessage({key:k,value:v});
            if(v===null)m.delete(k);else m.set(k,v);
          }
          const api=Object.create(null);
          Object.defineProperties(api,{
            length:{configurable:true,get:()=>m.size},
            key:{configurable:true,value:i=>{i=Number(i);return Number.isInteger(i)&&i>=0?(Array.from(m.keys())[i]??null):null}},
            getItem:{configurable:true,value:k=>m.get(String(k))??null},
            setItem:{configurable:true,value:(k,v)=>write(String(k),String(v))},
            removeItem:{configurable:true,value:k=>write(String(k),null)},
            clear:{configurable:true,value:()=>{throw err('NotSupportedError','不能在练习页批量清除记录')}}
          });
          const view=new Proxy(api,{
            ownKeys:()=>[...m.keys()],
            has:(t,k)=>Reflect.has(t,k)||m.has(k),
            get:(t,k)=>Reflect.has(t,k)?Reflect.get(t,k):m.get(k),
            set:(_,k,v)=>{write(String(k),String(v));return true},
            deleteProperty:(_,k)=>{write(String(k),null);return true},
            getOwnPropertyDescriptor:(t,k)=>m.has(k)?{value:m.get(k),writable:true,enumerable:true,configurable:true}:Reflect.getOwnPropertyDescriptor(t,k)
          });
          Object.defineProperty(window,'localStorage',{configurable:false,get:()=>view});
          Object.defineProperty(window,'__originalPracticeStorageAbort',{value:()=>{failed=true}});
          Object.defineProperty(window,'__originalPracticeStorageReady',{value:true});
        }());
        """#
    }
}
