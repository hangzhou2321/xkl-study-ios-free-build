import Foundation
import Combine
import StudyCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct RefinedMemoryCourse: Decodable {
    struct Mark: Decodable {
        let field, text, color: String
        let location, start: Int?
        func isValid(question: String, answer: String) -> Bool {
            guard field == "q" || field == "a", !text.isEmpty,
                  ["red","yellow","both","blue","green","cyan","teal"].contains(color) else { return false }
            let s = field == "q" ? question : answer
            if let location {
                let source = s as NSString, length = text.utf16.count
                guard location >= 0, length <= source.length, location <= source.length - length else { return false }
                return source.substring(with: NSRange(location:location,length:length)) == text
            }
            if let start {
                let chars = Array(s.unicodeScalars)
                guard start >= 0, start < chars.count else { return false }
                return String(String.UnicodeScalarView(chars[start...])).hasPrefix(text)
            }
            return s.range(of:text,options:.literal) != nil
        }
    }
    struct Evidence: Decodable { let label, detail: String }
    struct Row: Decodable, Identifiable {
        let ref, q, a, kind, how, note: String
        let colors: [Mark]
        let core: [String]?
        let recognize, editKind: String?
        var id: String { ref }
    }
    struct Group: Decodable, Identifiable {
        let key, title, chapter: String
        let evidence: Evidence
        let rows: [Row]
        var id: String { key }
    }
    let subject, baseSHA256: String
    let cards: [Group]

    func validatedDeck(for expected: ConceptSubject) throws -> RecallDeck {
        let wanted = expected == .computer ? "计算机" : "电力系统"
        guard [.computer,.power].contains(expected), subject == wanted || subject == expected.rawValue,
              ExamContent.isHash(baseSHA256), !cards.isEmpty, cards.count <= 5000,
              Set(cards.map(\.key)).count == cards.count else { throw ExamError.invalid("新版精讲课程身份无效。") }
        let namespace = "refined-" + expected.rawValue
        var refs = Set<String>()
        var items = [RecallDeck.Item]()
        for g in cards {
            guard !g.key.isEmpty, !g.key.contains("#"), !g.title.isEmpty, !g.chapter.isEmpty,
                  !g.evidence.label.isEmpty, !g.rows.isEmpty else { throw ExamError.invalid("新版精讲卡组信息不完整。") }
            for r in g.rows {
                guard r.ref.hasPrefix(g.key + "#"), r.ref.count > g.key.count + 1, refs.insert(r.ref).inserted,
                      ["A","B","C"].contains(r.how), !r.kind.isEmpty,
                      r.colors.allSatisfy({ $0.isValid(question:r.q,answer:r.a) }),
                      (r.core ?? []).allSatisfy({ !$0.isEmpty && r.a.range(of:$0,options:.literal) != nil }) else {
                    throw ExamError.invalid("新版精讲小问或标记不能核对。")
                }
                items.append(.init(conceptID:namespace, conceptTitle:g.title,
                                   card:.init(id:namespace+":"+r.ref,prompt:r.q,answer:r.a)))
            }
        }
        let deck = RecallDeck(subject:expected, bankID:expected.bankID, cards:items)
        try deck.validate()
        return deck
    }
}

/// The published engine is always a successfully committed state. A content identity
/// mismatch is an explicit migration requirement, never permission to reset the learner.
@MainActor
final class RefinedMemoryStore: ObservableObject {
    struct Entry: Identifiable {
        let group: RefinedMemoryCourse.Group, row: RefinedMemoryCourse.Row, position: Int
        var id: String { row.ref }
    }
    private struct Disk: Codable {
        let format: String, subject: ConceptSubject, courseSHA256: String
        let record: ProfessionalRecallRecord
    }
    private static let format = "refined-memory-pocket-v1"
    let subject: ConceptSubject
    @Published private(set) var course: RefinedMemoryCourse?
    @Published private(set) var engine: ProfessionalRecallEngine?
    @Published private(set) var blocked = false
    @Published var error: String?
    private(set) var entries: [Entry] = []
    private var index: [String:Int] = [:]
    private var courseSHA = "", committedSHA = ""
    private let directory: URL, currentURL: URL
    private let writer: (Data, URL) throws -> Void
    private var namespace: String { "refined-" + subject.rawValue + ":" }

    init(subject: ConceptSubject, baseDirectory: URL? = nil, courseData: Data? = nil,
         now: Date = Date(), writer: @escaping (Data,URL) throws -> Void = DurableFile.write) {
        self.subject = subject; self.writer = writer
        let base = baseDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        self.directory = base.appendingPathComponent("RefinedMemory",isDirectory:true)
            .appendingPathComponent(subject.rawValue,isDirectory:true)
        self.currentURL = directory.appendingPathComponent("current.json")
        do {
            guard subject == .computer || subject == .power else { throw ExamError.invalid("本科目不使用新版精讲背卡。") }
            let raw: Data
            if let courseData { raw = courseData }
            else {
                guard let url = Bundle.main.url(forResource:subject.rawValue,withExtension:"json",subdirectory:"RefinedMemory")
                else { throw ExamError.invalid("本机安装包未包含该科新版精讲课程。") }
                raw = try Self.read(url,limit:16*1024*1024)
            }
            guard raw.count <= 16*1024*1024 else { throw ExamError.invalid("课程文件过大。") }
            let parsed = try JSONDecoder().decode(RefinedMemoryCourse.self,from:raw)
            let deck = try parsed.validatedDeck(for:subject)
            courseSHA = StudySHA256.hex(raw)
            entries = parsed.cards.flatMap { group in group.rows.map { (group,$0) } }.enumerated()
                .map { Entry(group:$0.element.0,row:$0.element.1,position:$0.offset+1) }
            index = Dictionary(uniqueKeysWithValues:entries.enumerated().map { (namespace+$0.element.id,$0.offset) })
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            guard (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true,
                  (try directory.deletingLastPathComponent().resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true
            else { throw ExamError.invalid("精讲数据目录无效。") }
            // Main-actor stores share a process; every later commit also re-reads the file for stale writers.
            let names = try FileManager.default.contentsOfDirectory(atPath:directory.path)
            if names.contains(currentURL.lastPathComponent) {
                let existing = try Self.read(currentURL)
                let saved = try JSONDecoder().decode(Disk.self,from:existing)
                guard saved.format == Self.format, saved.subject == subject, saved.courseSHA256 == courseSHA else {
                    throw ExamError.invalid("现有新版精讲记录与课程不匹配；原记录已保留。")
                }
                engine = try ProfessionalRecallEngine(deck:deck,record:saved.record)
                committedSHA = StudySHA256.hex(existing)
            } else {
                guard names.isEmpty else { throw ExamError.invalid("已有新版学习目录但缺少完整记录，未新建或覆盖。") }
                let fresh = try ProfessionalRecallEngine.fresh(deck:deck,now:now)
                let bytes = try encode(fresh.record)
                try writer(bytes,currentURL)
                guard try Self.read(currentURL) == bytes else { throw ExamError.invalid("新版初始记录写后核验失败。") }
                committedSHA = StudySHA256.hex(bytes)
                engine = fresh
            }
            course = parsed
        } catch {
            self.error = error.localizedDescription; blocked = true
        }
    }
    var presentation: ProfessionalRecallPresentation? { engine?.record.presentation }
    var current: Entry? {
        guard let id = presentation?.cardID, let n = index[id] else { return nil }
        return entries[n]
    }
    var familiarRefs: Set<String> {
        guard let engine else { return [] }
        return Set(engine.familiarCardIndices.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
    }
    var firstPassRemaining: Int {
        guard let engine else { return 0 }
        let done = Set(engine.record.attempts.map(\.cardID))
        let familiar = Set(engine.familiarCardIndices)
        return entries.enumerated().reduce(0) { $0 + (familiar.contains($1.offset) || done.contains(namespace+$1.element.id) ? 0 : 1) }
    }
    var canPostpone: Bool { engine?.canPostpone ?? false }
    func stats(on date: Date = Date()) -> ProfessionalRecallStats? {
        try? engine?.stats(on:UInt32(ConceptCalendar.studyDay(date)))
    }

    private static func read(_ url:URL, limit:Int = 128*1024*1024) throws -> Data {
        let fd = open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard fd >= 0 else { throw ExamError.invalid("不能读取新版精讲文件，未覆盖。") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= limit else { throw ExamError.invalid("新版精讲文件长度异常。") }
        let data = try handle.readToEnd() ?? Data()
        guard data.count == info.st_size else { throw ExamError.invalid("新版精讲文件读取不完整。") }
        return data
    }
    private func encode(_ r: ProfessionalRecallRecord) throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try enc.encode(Disk(format:Self.format,subject:subject,courseSHA256:courseSHA,record:r))
    }
    @discardableResult private func change(_ action:(ProfessionalRecallEngine)throws->Void) -> Bool {
        guard !blocked, let live=engine else { return false }
        let old: Data
        do {
            old = try Self.read(currentURL)
            guard StudySHA256.hex(old) == committedSHA else { throw ExamError.invalid("精讲记录已被另一页面更新，请重新打开；未覆盖记录。") }
        } catch {
            blocked = true; self.error=error.localizedDescription; return false
        }
        do {
            let next = try live.fork()
            try action(next)
            guard next.record != live.record else { self.error=nil; return false }
            let bytes=try encode(next.record)
            do {
                try writer(bytes,currentURL)
                guard try Self.read(currentURL) == bytes else {throw ExamError.invalid("精讲记录写后核验失败。")}
            } catch {
                // A synchronized write may throw after rename. Restore only our exact failed candidate
                // (never a third party's file), without publishing a grade/novel/hourly event.
                if let observed=try? Self.read(currentURL), observed == bytes {
                    do { try DurableFile.write(old,to:currentURL); guard try Self.read(currentURL)==old else { throw ExamError.invalid("恢复核验失败") } }
                    catch { blocked=true; self.error="写入结果需要核查；请保留新版原学习档。"; return false }
                }
                blocked=true; self.error=error.localizedDescription; return false
            }
            committedSHA=StudySHA256.hex(bytes)
            engine=next; self.error=nil
            return true
        } catch {
            self.error=error.localizedDescription; return false
        }
    }
    func start(now: Date = Date()) { change { try $0.start(day:UInt32(ConceptCalendar.studyDay(now)),now:now) } }
    func reveal(token: UUID, now: Date = Date()) { change { try $0.reveal(token:token,now:now) } }
    func grade(remembered: Bool, token: UUID, now: Date = Date()) {
        guard let e=engine, let p=presentation, p.id == token else { return }
        let first = !e.record.attempts.contains(where:{$0.cardID == p.cardID}) && !familiarRefs.contains(current?.id ?? "")
        let count=e.record.attempts.count
        if change({ try $0.grade(remembered:remembered,token:token,now:now) }),
           let attempt=engine?.record.attempts.last, engine?.record.attempts.count==count+1, attempt.presentationID==token {
            HourlyStudyAnswer(area:subject.rawValue,itemID:attempt.cardID,at:attempt.at,firstPass:first).post()
        }
    }
    func markFamiliar(token: UUID, now: Date = Date()) { change { try $0.markFamiliar(token:token,now:now) } }
    func postpone(token: UUID, now: Date = Date()) {
        change { candidate in
            guard candidate.record.presentation?.id == token else { return }
            guard try candidate.postpone(token:token,now:now) else { throw ExamError.invalid("本轮没有其他小问可换，当前题仍保留。") }
        }
    }
    func requeue(ref: String, now: Date = Date()) {
        let id=namespace+ref
        guard index[id] != nil else { error="当前课程不存在这个小问。"; return }
        change { _ = try $0.requeue(cardID:id,now:now) }
    }
}
