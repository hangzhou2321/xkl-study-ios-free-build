import Foundation
import Combine

struct RecallArchive: Codable {
    let format: String
    let deck: RecallDeck
    let record: RecallRecord
}

enum RecallPrimaryIdentityEvidence: String, Codable { case freshNoLocalRecord, existingMatchingArchive }

@MainActor
final class RecallStore: ObservableObject {
    @Published private(set) var engine: RecallEngine?
    @Published private(set) var blocked = false
    @Published var error: String?
    private let directory: URL
    private let writer: (Data, URL) throws -> Void
    private var archiveURL: URL { directory.appendingPathComponent("recall.json") }
    private var markerURL: URL { directory.appendingPathComponent("created.json") }

    init(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching,
         baseDirectory: URL? = nil, supplementGroup: SupplementRecallGroup? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.writer = writer
        var target = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("RecallCards", isDirectory: true)
            .appendingPathComponent(subject.rawValue, isDirectory: true)
        var prepared: RecallDeck?
        do {
            guard !teaching.hasProfessionalExtension || teaching.hasCompleteProfessionalExtension else { throw ExamError.invalid("专业课v5扩展不完整，拒绝创建背诵档案。") }
            if let supplementGroup {
                guard teaching.recallGroups?.contains(supplementGroup) == true else {
                    throw ExamError.invalid("补充知识卡不属于当前课程。")
                }
                prepared = try RecallDeck.makeSupplement(subject: subject, bank: bank, group: supplementGroup)
                target = target.appendingPathComponent("supplement", isDirectory: true)
            } else {
                prepared = try RecallDeck.make(subject: subject, bank: bank, teaching: teaching)
            }
            target = target.appendingPathComponent(try prepared!.hash, isDirectory: true)
        } catch {
            self.directory = target; self.error = error.localizedDescription; self.blocked = true
            return
        }
        self.directory = target
        do {
            let deck = prepared!
            if supplementGroup == nil, teaching.primaryRecallDeck != nil { _ = try Self.preflightPrimary(subject:subject,deck:deck,baseDirectory:baseDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                let bytes = try readArchive()
                let archive = try JSONDecoder().decode(RecallArchive.self, from: bytes)
                guard archive.format == "xkl-recall-archive-v1", archive.deck == deck else {
                    throw ExamError.invalid("背诵档案版本不一致，原记录已保留。")
                }
                engine = try RecallEngine(deck: deck, record: archive.record)
            } else {
                guard !FileManager.default.fileExists(atPath: markerURL.path) else {
                    throw ExamError.invalid("背诵记录缺失，已停止写入；不会新建空进度覆盖。")
                }
                let initial = try RecallEngine(deck: deck)
                try writer(encode(initial), archiveURL)
                engine = initial
            }
            if !FileManager.default.fileExists(atPath: markerURL.path) {
                try writer(JSONEncoder().encode(try deck.hash), markerURL)
            } else {
                let markerSize = try markerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard markerSize <= 1024 else { throw ExamError.invalid("背诵档案创建标记大小异常。") }
                let marker = try JSONDecoder().decode(String.self, from: Data(contentsOf: markerURL))
                guard marker == (try deck.hash) else { throw ExamError.invalid("背诵档案创建标记不一致。") }
            }
        } catch { fail(error) }
    }

    /// Read-only identity check shared by course import and the Recall entry point.
    /// A fresh result proves only absence of local archive/creation-marker evidence.
    static func preflightPrimary(subject: ConceptSubject, deck: RecallDeck, baseDirectory: URL) throws -> RecallPrimaryIdentityEvidence {
        try deck.validate()
        guard deck.subject == subject else { throw ExamError.invalid("冻结主卡组科目不匹配。") }
        let hash=try deck.hash
        let parent=baseDirectory.appendingPathComponent("RecallCards",isDirectory:true).appendingPathComponent(subject.rawValue,isDirectory:true)
        let target=parent.appendingPathComponent(hash,isDirectory:true), archiveURL=target.appendingPathComponent("recall.json"), markerURL=target.appendingPathComponent("created.json")
        func read(_ url: URL, limit: Int) throws -> Data {
            let info=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let count=info.fileSize, count <= limit else { throw ExamError.invalid("已有背诵身份文件无效，停止导入并保留原文件。") }
            return try Data(contentsOf:url)
        }
        if FileManager.default.fileExists(atPath:archiveURL.path) {
            let archive=try JSONDecoder().decode(RecallArchive.self,from:read(archiveURL,limit:64*1024*1024))
            guard archive.format == "xkl-recall-archive-v1", archive.deck == deck else { throw ExamError.invalid("已有背诵主卡组与冻结快照逐值不一致，停止导入。") }
            _ = try RecallEngine(deck:deck,record:archive.record)
            if FileManager.default.fileExists(atPath:markerURL.path) {
                let marker=try JSONDecoder().decode(String.self,from:read(markerURL,limit:1024))
                guard marker == hash else { throw ExamError.invalid("已有背诵创建标记不匹配，停止导入。") }
            }
            return .existingMatchingArchive
        }
        guard !FileManager.default.fileExists(atPath:markerURL.path) else { throw ExamError.invalid("已有背诵创建标记但档案缺失，拒绝新建空进度。") }
        if FileManager.default.fileExists(atPath:parent.path) {
            let siblings=try FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:[.isDirectoryKey])
            let evidence=siblings.contains { url in
                url.lastPathComponent != "supplement" && url != target && (FileManager.default.fileExists(atPath:url.appendingPathComponent("recall.json").path) || FileManager.default.fileExists(atPath:url.appendingPathComponent("created.json").path))
            }
            guard !evidence else { throw ExamError.invalid("发现另一主卡组已有档案或创建标记，冻结身份不匹配；停止导入，不新建空进度。") }
        }
        return .freshNoLocalRecord
    }

    private func readArchive() throws -> Data {
        let info = try archiveURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let bytes = info.fileSize, bytes <= 64 * 1_024 * 1_024 else {
            throw ExamError.invalid("背诵档案大小异常，已保留原文件。")
        }
        return try Data(contentsOf: archiveURL)
    }
    private func encode(_ engine: RecallEngine) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RecallArchive(format: "xkl-recall-archive-v1", deck: engine.deck, record: engine.record))
        guard data.count <= 64 * 1_024 * 1_024 else { throw ExamError.invalid("背诵档案需要归档，原记录未截断。") }
        return data
    }
    func act(_ kind: String, token: UUID? = nil, newLimit: Int? = nil, remembered: Bool? = nil,
             now: Date = Date()) {
        guard !blocked, var next = engine else { return }
        do {
            let before = next.record
            try next.act(kind, day: ConceptCalendar.studyDay(now), token: token,
                         newLimit: newLimit, remembered: remembered, now: now)
            guard next.record != before else { return }
            try writer(encode(next), archiveURL)
            engine = next
        } catch { fail(error) }
    }
    func applySelection(planID: String, cardIDs: [String], expectedDeckSHA256: String, now: Date = Date()) {
        guard !blocked, var next=engine else { return }
        do {
            let before=next.record
            try next.act("select-plan",day:ConceptCalendar.studyDay(now),selectionID:planID,selectedCardIDs:cardIDs,expectedDeckSHA256:expectedDeckSHA256,now:now)
            guard next.record != before else { return }
            try writer(encode(next),archiveURL); engine=next; error=nil
        } catch { self.error=error.localizedDescription }
    }
    func export() throws -> Data {
        let data = try readArchive()
        let archive = try JSONDecoder().decode(RecallArchive.self, from: data)
        guard archive.format == "xkl-recall-archive-v1" else { throw ExamError.invalid("背诵档案格式无效。") }
        _ = try RecallEngine(deck: archive.deck, record: archive.record)
        return data
    }
    private func fail(_ error: Error) {
        blocked = true
        self.error = error.localizedDescription + " 请保留档案并重新打开核对。"
    }
}
