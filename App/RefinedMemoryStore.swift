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

    struct Supplement: Decodable {
        struct Revision: Decodable {
            let ref, oldQ, oldA, q, a, source: String

            func applied(to original: Row) throws -> Row {
                guard ref == original.ref, oldQ == original.q, oldA == original.a, q != oldQ || a != oldA,
                      !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
                    throw ExamError.invalid("精简修订与原问不一致。")
                }
                let colors = try original.colors.map { mark -> Mark in
                    if mark.isValid(question:q,answer:a) { return mark }
                    let field = (mark.field == "q" ? q : a) as NSString
                    let found = field.range(of:mark.text,options:.literal)
                    guard found.location != NSNotFound, found == field.range(of:mark.text,options:[.literal,.backwards]) else {
                        throw ExamError.invalid("精简修订的原书颜色不能唯一定位。")
                    }
                    return Mark(field:mark.field,text:mark.text,color:mark.color,location:found.location,start:nil)
                }
                return Row(ref:ref,q:q,a:a,kind:original.kind,how:original.how,note:original.note,colors:colors,
                           core:original.core,recognize:original.recognize,editKind:original.editKind)
            }
        }
        struct Addition: Decodable {
            let group: String
            let row: Row
            let source: String?
        }
        let subject, baseSHA256: String
        let additions: [Addition]
        let revisions: [Revision]?
    }

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
    private(set) var supplementRefs = Set<String>()
    private var index: [String:Int] = [:]
    private var teachingSlots: [UInt16]?
    private var courseSHA = "", committedSHA = ""
    private let directory: URL, currentURL: URL
    private let writer: (Data, URL) throws -> Void
    private var namespace: String { "refined-" + subject.rawValue + ":" }

    init(subject: ConceptSubject, baseDirectory: URL? = nil, courseData: Data? = nil, supplementData: Data? = nil,
         previousSupplementData: Data? = nil,
         earlierSupplementData: Data? = nil,
         wordingData: Data? = nil,
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
            let original = try JSONDecoder().decode(RefinedMemoryCourse.self,from:raw)
            let originalDeck = try original.validatedDeck(for:subject)
            let originalSHA = StudySHA256.hex(raw)
            courseSHA = originalSHA
            var parsed = original, deck = originalDeck, appendOrder = originalDeck
            var ordered = original.cards.flatMap { group in group.rows.map { (group,$0) } }
            var extra = supplementData
            var previous = previousSupplementData
            var earlier = earlierSupplementData
            var previousRegistries: [String:RecallDeck] = [:]
            if courseData == nil, extra == nil,
               let url = Bundle.main.url(forResource:subject.rawValue+"-additions",withExtension:"json",subdirectory:"RefinedMemory") {
                extra = try Self.read(url,limit:4*1024*1024)
            }
            if courseData == nil, previous == nil,
               let url = Bundle.main.url(forResource:subject.rawValue+"-previous-additions",withExtension:"json",subdirectory:"RefinedMemory") {
                previous = try Self.read(url,limit:4*1024*1024)
            }
            if courseData == nil, earlier == nil,
               let url = Bundle.main.url(forResource:subject.rawValue+"-earlier-additions",withExtension:"json",subdirectory:"RefinedMemory") {
                earlier = try Self.read(url,limit:4*1024*1024)
            }
            guard (previous == nil && earlier == nil) || extra != nil else {
                throw ExamError.invalid("缺少新版本增补课程。")
            }
            if let extra {
                let supplement = try JSONDecoder().decode(RefinedMemoryCourse.Supplement.self,from:extra)
                let revisions = supplement.revisions ?? []
                guard supplement.subject == subject.rawValue, supplement.baseSHA256 == originalSHA,
                      !supplement.additions.isEmpty || !revisions.isEmpty else { throw ExamError.invalid("增补小问与本机原课程不符。") }
                let groups = Dictionary(uniqueKeysWithValues:original.cards.map { ($0.key,$0) })
                let additions = Dictionary(grouping:supplement.additions,by:\.group)
                guard additions.keys.allSatisfy({ groups[$0] != nil }) else { throw ExamError.invalid("增补小问的原卡组不存在。") }
                let unique = Set(revisions.map(\.ref))
                let available = Set(ordered.map { $0.1.ref }).union(supplement.additions.map { $0.row.ref })
                guard unique.count == revisions.count, unique.isSubset(of:available) else {
                    throw ExamError.invalid("精简修订含重复编号或找不到原问。")
                }
                let edits = Dictionary(uniqueKeysWithValues:revisions.map { ($0.ref,$0) })
                ordered = try original.cards.flatMap { group in
                    try group.rows.map { row -> (RefinedMemoryCourse.Group,RefinedMemoryCourse.Row) in
                        guard let edit = edits[row.ref] else { return (group,row) }
                        let display = try edit.applied(to:row)
                        let evidence = RefinedMemoryCourse.Evidence(label:"本次修订",detail:edit.source)
                        return (.init(key:group.key,title:group.title,chapter:group.chapter,evidence:evidence,rows:[display]),display)
                    } + (additions[group.key] ?? []).map { addition in
                        let edit = edits[addition.row.ref]
                        let display = try edit?.applied(to:addition.row) ?? addition.row
                        let source = RefinedMemoryCourse.Evidence(label:edit == nil ? "新增考点" : "本次修订",
                            detail:edit?.source ?? addition.source ?? "本次基础、强化增补。")
                        let displayGroup = RefinedMemoryCourse.Group(key:group.key,title:group.title,chapter:group.chapter,
                                                                     evidence:source,rows:[display])
                        return (displayGroup,display)
                    }
                }
                let displayed = Dictionary(grouping:ordered,by: { $0.0.key })
                parsed = RefinedMemoryCourse(subject:original.subject,baseSHA256:original.baseSHA256,cards:original.cards.map { group in
                    .init(key:group.key,title:group.title,chapter:group.chapter,evidence:group.evidence,
                          rows:(displayed[group.key] ?? []).map { $0.1 })
                })
                // Validate the whole catalogue (including old/new ref collisions) before assigning numeric slots.
                let merged = try parsed.validatedDeck(for:subject)
                let appended = supplement.additions.map { value -> RecallDeck.Item in
                    let row = value.row
                    return .init(conceptID:"refined-"+subject.rawValue,conceptTitle:groups[value.group]?.title ?? "",
                                 card:.init(id:namespace+row.ref,prompt:row.q,answer:row.a))
                }
                appendOrder = RecallDeck(subject:subject,bankID:originalDeck.bankID,cards:originalDeck.cards+appended)
                let stableItems = Dictionary(uniqueKeysWithValues:appendOrder.cards.map { ($0.id,$0) })
                deck = RecallDeck(subject:subject,bankID:originalDeck.bankID,cards:merged.cards.compactMap { stableItems[$0.id] })
                for prior in [previous,earlier].compactMap({ $0 }) {
                    let count = try Self.validatePrevious(prior, current:extra, subject:subject, base:originalSHA,
                                                          revisionRefs:unique)
                    previousRegistries[StudySHA256.hex(prior)] = RecallDeck(subject:subject,bankID:originalDeck.bankID,
                        cards:originalDeck.cards + appended.prefix(count))
                }
                supplementRefs = Set(supplement.additions.map { $0.row.ref }).union(unique)
                courseSHA = StudySHA256.hex(extra)
            }
            var wording = wordingData
            if courseData == nil, wording == nil,
               let url = Bundle.main.url(forResource:subject.rawValue+"-wording",withExtension:"json",subdirectory:"RefinedMemory") {
                wording = try Self.read(url,limit:4*1024*1024)
            }
            if let wording {
                // These edits clarify existing prompts. A learner's proven slot, grade, and due date
                // belong to that prompt and must not change when textbook wording becomes more precise.
                let patch = try JSONDecoder().decode(RefinedMemoryCourse.Supplement.self,from:wording)
                let fixes = patch.revisions ?? []
                let refs = Set(fixes.map(\.ref))
                guard patch.subject == subject.rawValue, patch.baseSHA256 == courseSHA, patch.additions.isEmpty,
                      !fixes.isEmpty, refs.count == fixes.count,
                      refs.isSubset(of:Set(ordered.map { $0.1.ref })) else {
                    throw ExamError.invalid("卡面修订与本机课程不匹配。")
                }
                let byRef = Dictionary(uniqueKeysWithValues:fixes.map { ($0.ref,$0) })
                ordered = try ordered.map { group, row in
                    guard let edit = byRef[row.ref] else { return (group,row) }
                    let display = try edit.applied(to:row)
                    let evidence = RefinedMemoryCourse.Evidence(label:"本次修订",detail:edit.source)
                    return (.init(key:group.key,title:group.title,chapter:group.chapter,evidence:evidence,rows:[display]),display)
                }
                let rowsByGroup = Dictionary(grouping:ordered,by: { $0.0.key })
                parsed = RefinedMemoryCourse(subject:parsed.subject,baseSHA256:parsed.baseSHA256,cards:parsed.cards.map { group in
                    .init(key:group.key,title:group.title,chapter:group.chapter,evidence:group.evidence,
                          rows:(rowsByGroup[group.key] ?? []).map { $0.1 })
                })
                _ = try parsed.validatedDeck(for:subject)
                supplementRefs.formUnion(refs)
            }
            entries = ordered.enumerated()
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
                guard saved.format == Self.format, saved.subject == subject else {
                    throw ExamError.invalid("现有新版精讲记录与课程不匹配；原记录已保留。")
                }
                if saved.courseSHA256 == courseSHA {
                    let savedDeck = try Self.inSavedOrder(deck, record:saved.record)
                    engine = try ProfessionalRecallEngine(deck:savedDeck,record:saved.record)
                    committedSHA = StudySHA256.hex(existing)
                } else {
                    let oldDeck: RecallDeck
                    if extra != nil, saved.courseSHA256 == originalSHA { oldDeck = originalDeck }
                    else if let prior = previousRegistries[saved.courseSHA256] { oldDeck = prior }
                    else { throw ExamError.invalid("现有新版精讲记录与课程不匹配；原记录已保留。") }
                    let savedDeck = try Self.inSavedOrder(oldDeck, record:saved.record)
                    let updated = try ProfessionalRecallEngine(deck:savedDeck,record:saved.record)
                    try updated.reconcile(to:appendOrder,now:now)
                    let backup = directory.appendingPathComponent("before-additions-"+StudySHA256.hex(existing)+".json")
                    if !names.contains(backup.lastPathComponent) { try writer(existing,backup) }
                    guard try Self.read(backup) == existing, try Self.read(currentURL) == existing else {
                        throw ExamError.invalid("增补前的精讲记录未能核对。")
                    }
                    let bytes = try encode(updated.record)
                    try replaceCurrent(with:bytes,previous:existing)
                    committedSHA = StudySHA256.hex(bytes)
                    engine = updated
                }
            } else {
                guard names.isEmpty else { throw ExamError.invalid("已有新版学习目录但缺少完整记录，未新建或覆盖。") }
                let fresh = try ProfessionalRecallEngine.fresh(deck:deck,now:now)
                let bytes = try encode(fresh.record)
                try writer(bytes,currentURL)
                guard try Self.read(currentURL) == bytes else { throw ExamError.invalid("新版初始记录写后核验失败。") }
                committedSHA = StudySHA256.hex(bytes)
                engine = fresh
            }
            if let slots = engine?.record.cardIDs, slots != deck.cards.map(\.id) {
                let byID = Dictionary(uniqueKeysWithValues:slots.enumerated().map { ($0.element,UInt16($0.offset)) })
                teachingSlots = try deck.cards.map { item in
                    guard let slot = byID[item.id] else { throw ExamError.invalid("原学习记录和教学小问不能对应。") }
                    return slot
                }
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
        return Set(engine.familiarCardIndices.compactMap { slot in
            index[engine.record.cardIDs[slot]].map { entries[$0].id }
        })
    }
    var firstPassRemaining: Int {
        guard let engine else { return 0 }
        let done = Set(engine.record.attempts.map(\.cardID))
        let familiar = familiarRefs
        return entries.reduce(0) { $0 + (familiar.contains($1.id) || done.contains(namespace+$1.id) ? 0 : 1) }
    }
    var canPostpone: Bool { engine?.canPostpone ?? false }
    func stats(on date: Date = Date()) -> ProfessionalRecallStats? {
        try? engine?.stats(on:UInt32(ConceptCalendar.studyDay(date)))
    }

    private static func inSavedOrder(_ catalogue:RecallDeck, record:ProfessionalRecallRecord) throws -> RecallDeck {
        let byID = Dictionary(uniqueKeysWithValues:catalogue.cards.map { ($0.id,$0) })
        guard record.cardIDs.count == byID.count, Set(record.cardIDs) == Set(byID.keys) else {
            throw ExamError.invalid("原学习记录与对应版本的全部小问不一致。")
        }
        return RecallDeck(subject:catalogue.subject,bankID:catalogue.bankID,cards:record.cardIDs.compactMap { byID[$0] })
    }

    private static func validatePrevious(_ previous:Data, current:Data, subject:ConceptSubject, base:String,
                                         revisionRefs:Set<String>) throws -> Int {
        // Compare entire private rows, including any provenance fields unknown to this binary.
        // Formatting is immaterial here. The saved journal must separately match the exact
        // hash of the previous resource, and its stable slot sequence is verified on restore.
        let document = try JSONDecoder().decode(RefinedMemoryCourse.Supplement.self,from:previous)
        guard document.subject == subject.rawValue, document.baseSHA256 == base,
              !(document.additions.isEmpty && (document.revisions ?? []).isEmpty),
              Set((document.revisions ?? []).map(\.ref)).isSubset(of:revisionRefs),
              let before = try JSONSerialization.jsonObject(with:previous) as? [String:Any],
              let after = try JSONSerialization.jsonObject(with:current) as? [String:Any],
              let old = before["additions"] as? [NSDictionary], let next = after["additions"] as? [NSDictionary],
              next.starts(with:old,by:{ $0.isEqual($1) }) else {
            throw ExamError.invalid("上版增补与本版原有小问不逐项相符。")
        }
        return old.count
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
    private func replaceCurrent(with bytes:Data,previous:Data) throws {
        do {
            try writer(bytes,currentURL)
            guard try Self.read(currentURL) == bytes else { throw ExamError.invalid("精讲记录写后核验失败。") }
        } catch {
            // A synchronized write may fail after rename. Only roll back our exact candidate.
            if let observed = try? Self.read(currentURL), observed == bytes {
                try DurableFile.write(previous,to:currentURL)
                guard try Self.read(currentURL) == previous else { throw ExamError.invalid("精讲记录恢复核验失败。") }
            }
            throw error
        }
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
                try replaceCurrent(with:bytes,previous:old)
            } catch {
                blocked=true; self.error=error.localizedDescription; return false
            }
            committedSHA=StudySHA256.hex(bytes)
            engine=next; self.error=nil
            return true
        } catch {
            self.error=error.localizedDescription; return false
        }
    }
    func start(now: Date = Date()) {
        change { try $0.start(day:UInt32(ConceptCalendar.studyDay(now)),now:now,teachingSlots:teachingSlots) }
    }
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
