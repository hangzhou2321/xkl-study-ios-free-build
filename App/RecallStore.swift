import Foundation
import Combine

struct RecallArchive: Codable {
    let format: String
    let deck: RecallDeck
    let record: RecallRecord
}

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
