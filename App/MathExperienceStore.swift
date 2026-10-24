import Foundation
import Combine
import StudyCore

private struct MathExperienceLegacyDisk: Codable { var format: String; var contentSHA256: String; var events: [MathEvent]; var importedPackageSHA256: String? }
private struct MathExperienceDisk: Codable { var format = "xkl-math-experience-v2"; var legacySHA256: String; var contentSHA256: String; var events: [MathExperienceEvent] }
@MainActor final class MathExperienceStore: ObservableObject {
    @Published private(set) var engine: MathExperienceEngine?
    @Published private(set) var guide: MathGuide?
    @Published var error: String?
    @Published private(set) var blocked = false
    private let directory: URL; private let legacyDirectory: URL; private let clock: () -> Date
    private let writeData: (Data,URL) throws -> Void
    private var baselineManifestHash=""
    private var pendingInterruption=false
    private var legacyHash=""; private var contentHash=""; private var packageHash=""
    private var archiveURL: URL { directory.appendingPathComponent("events.json") }
    var practiceQuestionCount: Int {
        guard let engine, let guide else { return 0 }
        let ids=Set(guide.questions.filter(\.practiceAllowed).map(\.questionID))
        return engine.baseline.content.questions.filter { $0.eligible && ids.contains($0.id) }.count
    }
    func practiceBlockedReason(for id: String) -> String? { guide?.questions.first(where: { $0.questionID == id && !$0.practiceAllowed })?.practiceBlockedReason }
    var currentPracticeBlockedReason: String? { engine?.current.flatMap { practiceBlockedReason(for:$0.questionID) } }
    var canUndo: Bool {
        guard let e=engine?.events.last(where: { ["grade","familiar"].contains($0.kind) }), clock().timeIntervalSince(e.timestamp) <= 15 else { return false }
        return !(engine?.events.filter { $0.sequence > e.sequence }.contains { !["present","pause","resume","return"].contains($0.kind) } ?? true)
    }
    init(directory: URL? = nil, legacyDirectory: URL? = nil, clock: @escaping () -> Date = { Date() }, write: @escaping (Data,URL) throws -> Void = { try DurableFile.write($0,to:$1) }) {
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        self.directory=directory ?? docs.appendingPathComponent("MathExperience",isDirectory:true)
        self.legacyDirectory=legacyDirectory ?? docs.appendingPathComponent("MathPractice",isDirectory:true)
        self.clock=clock; self.writeData=write
        guard FileManager.default.fileExists(atPath:self.legacyDirectory.appendingPathComponent("archive.json").path) else { return }
        do {
            let old=try Data(contentsOf:self.legacyDirectory.appendingPathComponent("archive.json"))
            let disk=try JSONDecoder().decode(MathExperienceLegacyDisk.self,from:old)
            guard disk.format == "xkl-math-disk-v1" else { throw MathFailure.invalid("旧数学档案格式无效。") }
            let content=try Data(contentsOf:self.legacyDirectory.appendingPathComponent(disk.contentSHA256+".xklmath"))
            guard StudySHA256.hex(content) == disk.contentSHA256 else { throw MathFailure.invalid("旧数学内容校验失败。") }
            legacyHash=StudySHA256.hex(old); contentHash=disk.contentSHA256; packageHash=disk.importedPackageSHA256 ?? ""
            try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
            try immutable(old,name:"baseline-archive.json"); try immutable(content,name:"baseline-content.xklmath")
            let manifest=try JSONSerialization.data(withJSONObject:["format":"xkl-math-experience-baseline-v1","archiveSHA256":legacyHash,"contentSHA256":contentHash,"importedPackageSHA256":packageHash],options:[.sortedKeys])
            try immutable(manifest,name:"baseline.json"); baselineManifestHash=StudySHA256.hex(manifest)
            var events: [MathExperienceEvent]=[]
            if FileManager.default.fileExists(atPath:archiveURL.path) {
                let state=try JSONDecoder().decode(MathExperienceDisk.self,from:Data(contentsOf:archiveURL))
                guard state.format == "xkl-math-experience-v2", state.legacySHA256 == legacyHash, state.contentSHA256 == contentHash else { throw MathFailure.invalid("旧基线意外变化，已停止新体验。") }; events=state.events
            }
            let bank=try MathContent.load(content)
            if let bytes=try? Data(contentsOf:self.directory.appendingPathComponent("guide.json")) {
                do { let g=try JSONDecoder().decode(MathGuide.self,from:bytes); try g.validate(content:bank,packageSHA256:packageHash); guide=g } catch { self.error=error.localizedDescription }
            }
            engine=try MathExperienceEngine(baseline:MathArchive(content:bank,events:disk.events),events:events,cardIDs:Set(guide?.cards.map(\.id) ?? []),blockedQuestionIDs:Set(guide?.questions.filter { !$0.practiceAllowed }.map(\.questionID) ?? []))
            if engine?.current != nil { pendingInterruption=true; _ = change { _ in }; if let reason=currentPracticeBlockedReason { self.error=reason } }
        } catch { blocked=true; self.error=error.localizedDescription }
        if !blocked { processGuideInbox() }
    }
    private func immutable(_ bytes: Data,name: String) throws {
        let url=directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath:url.path) { guard try Data(contentsOf:url) == bytes else { throw MathFailure.invalid("不可变基线已改变，原文件保留。") } }
        else { try writeData(bytes,url) }
    }
    private func validateBaseline() throws {
        guard StudySHA256.hex(try Data(contentsOf:directory.appendingPathComponent("baseline.json"))) == baselineManifestHash,
              StudySHA256.hex(try Data(contentsOf:legacyDirectory.appendingPathComponent("archive.json"))) == legacyHash,
              StudySHA256.hex(try Data(contentsOf:legacyDirectory.appendingPathComponent(contentHash+".xklmath"))) == contentHash,
              StudySHA256.hex(try Data(contentsOf:directory.appendingPathComponent("baseline-archive.json"))) == legacyHash,
              StudySHA256.hex(try Data(contentsOf:directory.appendingPathComponent("baseline-content.xklmath"))) == contentHash else { blocked=true; throw MathFailure.invalid("数学基线发生变化，停止写入并保留现场。") }
    }
    @discardableResult private func change(_ action: (inout MathExperienceEngine) throws -> Void) -> Bool {
        guard !blocked, var candidate=engine else { return false }
        do { try validateBaseline(); if pendingInterruption { try candidate.interrupted(now:clock()) }; try action(&candidate); try writeData(try JSONEncoder().encode(MathExperienceDisk(legacySHA256:legacyHash,contentSHA256:contentHash,events:candidate.events)),archiveURL); engine=candidate; pendingInterruption=false; error=nil; return true }
        catch { self.error=error.localizedDescription; return false }
    }
    private func advance() {
        guard engine?.current == nil else { return }
        if engine?.suspended.isEmpty == false { _ = change { try $0.returnToSuspended(now:clock()) }; return }
        guard let q=engine?.queue(now:clock()).first(where: { q in guide?.questions.contains(where: { $0.questionID == q.id && $0.practiceAllowed }) == true }) else { return }
        _ = change { try $0.present(questionID:q.id,now:clock()) }
    }
    @discardableResult private func sessionChange(_ sessionID: UUID, _ action: (inout MathExperienceEngine) throws -> Void) -> Bool {
        guard engine?.current?.id == sessionID else { error="题目会话已改变，请继续当前题。"; return false }; return change(action)
    }
    func start() { guard guide != nil else { error="尚未导入已验证的数学导学包。"; return }; if let id=engine?.current?.id { resume(sessionID:id) } else { advance() } }
    func hint(sessionID: UUID) { sessionChange(sessionID) { try $0.hint(now:clock()) } }
    func reveal(sessionID: UUID) { sessionChange(sessionID) { try $0.reveal(now:clock()) } }
    func details(sessionID: UUID) { sessionChange(sessionID) { try $0.details(now:clock()) } }
    func setExpanded(_ value: Bool, sessionID: UUID) { sessionChange(sessionID) { try $0.setExpanded(value,now:clock()) } }
    func openCard(_ id: String, sessionID: UUID?) {
        guard engine?.current?.id == sessionID else { error="题目会话已改变。"; return }
        guard guide?.cards.contains(where: { $0.id == id }) == true else { error="未知知识卡。"; return }; change { try $0.openCard(id,now:clock()) }
    }
    private func currentPracticeAllowed() -> Bool {
        guard let q=engine?.current?.questionID, guide?.questions.contains(where: { $0.questionID == q && $0.practiceAllowed }) == true else { error=currentPracticeBlockedReason ?? "当前题缺少可练习的已验证导学。"; return false }; return true
    }
    func grade(_ outcome: MathOutcome, sessionID: UUID) { guard currentPracticeAllowed() else { return }; if let reason=currentPracticeBlockedReason { error=reason; return }; if sessionChange(sessionID,{ try $0.grade(outcome,now:clock()) }) { advance() } }
    func familiar(sessionID: UUID) { guard currentPracticeAllowed() else { return }; if let reason=currentPracticeBlockedReason { error=reason; return }; if sessionChange(sessionID,{ try $0.markFamiliar(now:clock()) }) { advance() } }
    func restore(_ id: String) { if let reason=practiceBlockedReason(for:id) { error=reason; return }; change { try $0.restore(questionID:id,now:clock()) } }
    func spotCheck(_ id: String) {
        if let reason=practiceBlockedReason(for:id) { error=reason; return }
        guard guide?.questions.contains(where: { $0.questionID == id && $0.practiceAllowed }) == true else { error="此题缺少已验证导学。"; return }
        change { if $0.current != nil { try $0.suspend(now:clock()) }; try $0.present(questionID:id,now:clock(),spotCheck:true) }
    }
    func undo() { change { try $0.undo(now:clock()) } }
    func pause(sessionID: UUID) { sessionChange(sessionID) { try $0.pause(now:clock()) } }
    func resume(sessionID: UUID) { sessionChange(sessionID) { try $0.resume(now:clock()) } }
    func queueCard(_ id: String) { guard guide?.cards.contains(where: { $0.id == id }) == true else { error="未知知识卡。"; return }; change { try $0.queueCard(id,now:clock()) } }
    @discardableResult func startCardRecall(_ id: String, questionSessionID: UUID?) -> Bool {
        guard engine?.current?.id == questionSessionID else { error="题目会话已改变。"; return false }
        return change {
            if $0.current != nil { try $0.openCard(id,now:clock()) }
            if $0.currentCard?.cardID != id { if let previous=$0.currentCard { try $0.closeCard(sessionID:previous.id,now:clock()) }; try $0.startCardRecall(id,now:clock()) }
        }
    }
    @discardableResult func revealCard(sessionID: UUID) -> Bool { change { if let c=$0.currentCard, $0.current != nil { try $0.openCard(c.cardID,now:clock()) }; try $0.revealCard(sessionID:sessionID,now:clock()) } }
    @discardableResult func gradeCard(_ id: String, remembered: Bool, sessionID: UUID) -> Bool { change { if $0.current != nil { try $0.openCard(id,now:clock()) }; try $0.gradeCard(id,remembered:remembered,sessionID:sessionID,now:clock()) } }
    func exportCardRecords() throws -> URL {
        let url=directory.appendingPathComponent("card-records-export.json")
        guard let engine else { throw MathFailure.invalid("没有可导出的知识卡记录。") }
        struct CardExport: Encodable { var format="xkl-math-card-records-v1"; var courseID: String; var cardIDs: [String]; var events: [MathExperienceEvent] }
        try writeData(try JSONEncoder().encode(CardExport(courseID:engine.baseline.content.id,cardIDs:engine.knownCardIDs.sorted(),events:engine.events.filter { $0.kind.hasPrefix("card-") && $0.kind != "card-open" })),url); return url
    }
    struct InboxRequest: Codable { var contentFile: String; var expectedSHA256: String; var courseID: String; var guideID: String? = nil; var guideVersion: String? = nil }
    struct InboxReceipt: Codable { var format="xkl-math-guide-inbox-receipt-v1"; var requestSHA256: String; var contentSHA256: String; var courseID: String; var success: Bool; var createdAt: Date }
    func processGuideInbox(directory inboxOverride: URL? = nil) {
        guard !blocked, let engine else { return }
        let inbox=inboxOverride ?? directory.deletingLastPathComponent().appendingPathComponent("MathGuideInbox",isDirectory:true)
        let requestURL=inbox.appendingPathComponent("request.json"), receiptURL=inbox.appendingPathComponent("receipt.json")
        guard FileManager.default.fileExists(atPath:requestURL.path) else { return }
        do {
            try validateBaseline()
            func read(_ url: URL, limit: Int) throws -> Data {
                let v=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]); guard v.isRegularFile == true, v.isSymbolicLink != true, let size=v.fileSize, size <= limit else { throw MathFailure.invalid("导学收件必须是受限普通文件。") }; return try Data(contentsOf:url)
            }
            let iv=try inbox.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]); guard iv.isDirectory == true, iv.isSymbolicLink != true else { throw MathFailure.invalid("收件目录不可为链接。") }
            let requestBytes=try read(requestURL,limit:65536), request=try JSONDecoder().decode(InboxRequest.self,from:requestBytes), requestHash=StudySHA256.hex(requestBytes)
            guard !request.contentFile.hasPrefix("."), !request.contentFile.isEmpty, request.contentFile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }), request.expectedSHA256.count == 64, request.expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), request.courseID == engine.baseline.content.id else { throw MathFailure.invalid("导学收件请求无效。") }
            let bytes=try read(inbox.appendingPathComponent(request.contentFile),limit:32*1024*1024)
            guard StudySHA256.hex(bytes) == request.expectedSHA256 else { throw MathFailure.invalid("导学收件摘要不匹配。") }
            let candidate=try JSONDecoder().decode(MathGuide.self,from:bytes)
            guard request.guideID == nil || request.guideID == candidate.id, request.guideVersion == nil || request.guideVersion == candidate.version else { throw MathFailure.invalid("导学收件标识或版本不匹配。") }
            try candidate.validate(content:engine.baseline.content,packageSHA256:packageHash)
            if let receiptBytes=try? Data(contentsOf:receiptURL), let receipt=try? JSONDecoder().decode(InboxReceipt.self,from:receiptBytes), receipt.success, receipt.requestSHA256 == requestHash, let active=try? Data(contentsOf:directory.appendingPathComponent("guide.json")), active == bytes { var configured=engine; try configured.configureCards(Set(candidate.cards.map(\.id))); configured.configureBlockedQuestions(Set(candidate.questions.filter { !$0.practiceAllowed }.map(\.questionID))); self.engine=configured; guide=candidate; error=currentPracticeBlockedReason; return }
            var configured=engine; try configured.configureCards(Set(candidate.cards.map(\.id))); configured.configureBlockedQuestions(Set(candidate.questions.filter { !$0.practiceAllowed }.map(\.questionID)))
            try writeData(bytes,directory.appendingPathComponent("guide.json"))
            try writeData(try JSONEncoder().encode(InboxReceipt(requestSHA256:requestHash,contentSHA256:request.expectedSHA256,courseID:request.courseID,success:true,createdAt:clock())),receiptURL)
            self.engine=configured; guide=candidate; error=currentPracticeBlockedReason
        } catch { self.error=error.localizedDescription }
    }
}
