import Foundation
import Combine
import StudyCore

struct ProfessionalRecallLegacyFile: Codable, Equatable {
    let path: String
    let sha256: String
    let bytes: Data
}
struct ProfessionalRecallBaseline: Codable, Equatable {
    let format: String
    let subject: ConceptSubject
    let files: [ProfessionalRecallLegacyFile]
}
struct ProfessionalRecallDisk: Codable {
    let format: String
    let scope: ProfessionalRecallScope
    let baselineSHA256: String
    let record: ProfessionalRecallRecord
}
private struct ProfessionalRecallExport: Codable {
    let format: String
    let current: Data
    let initial: Data
    let legacyBaseline: Data
}

/// New namespaced store; original English, math, questions and RecallCards are
/// read-only. A complete byte backup is durable before migration activation.
@MainActor
final class ProfessionalRecallStore: ObservableObject {
    @Published private(set) var engine: ProfessionalRecallEngine?
    @Published private(set) var blocked = false
    @Published var error: String?
    let scope: ProfessionalRecallScope
    private let subject: ConceptSubject
    private let base: URL
    private let directory: URL
    private let writer: (Data, URL) throws -> Void
    private var baselineSHA256 = ""
    private var durableSHA256 = ""
    private var currentURL: URL { directory.appendingPathComponent("current.json") }
    private var initialURL: URL { directory.appendingPathComponent("initial.json") }
    private var baselineURL: URL { directory.deletingLastPathComponent().appendingPathComponent("legacy-baseline.json") }

    init(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching,
         scope: ProfessionalRecallScope = .mainline, baseDirectory: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.subject = subject; self.scope = scope; self.writer = writer
        self.base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent("ProfessionalRecall", isDirectory: true)
            .appendingPathComponent(subject.rawValue, isDirectory: true).appendingPathComponent(scope.rawValue, isDirectory: true)
        do {
            let catalog = try ProfessionalRecallCatalog.make(subject: subject, bank: bank, teaching: teaching, scope: scope)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fm = FileManager.default
            let hasCurrent = fm.fileExists(atPath: currentURL.path), hasInitial = fm.fileExists(atPath: initialURL.path)
            let hasAnyScope = ProfessionalRecallScope.allCases.contains {
                let path = directory.deletingLastPathComponent().appendingPathComponent($0.rawValue)
                return fm.fileExists(atPath: path.appendingPathComponent("current.json").path) || fm.fileExists(atPath: path.appendingPathComponent("initial.json").path)
            }
            let baseline: ProfessionalRecallBaseline
            if fm.fileExists(atPath: baselineURL.path) {
                let bytes = try read(baselineURL)
                baseline = try JSONDecoder().decode(ProfessionalRecallBaseline.self, from: bytes)
                baselineSHA256 = StudySHA256.hex(bytes)
                guard baseline.format == "xkl-professional-recall-baseline-v1", baseline.subject == subject else {
                    throw ExamError.invalid("迁移备份身份不一致，原文件保留。")
                }
                try verifyBaseline(baseline)
                // An app downgrade may have added legacy grades. Never replace
                // the newer archive with either the original or a stale backup.
                guard try scanLegacy() == baseline.files else {
                    throw ExamError.invalid("旧背卡档案在迁移后发生变化。两个版本均已保留，请先合并新增记录；不会用旧备份覆盖。")
                }
            } else {
                guard !hasAnyScope else { throw ExamError.invalid("迁移备份缺失，停止写入；不会重新初始化。") }
                let files = try scanLegacy()
                baseline = ProfessionalRecallBaseline(format: "xkl-professional-recall-baseline-v1", subject: subject, files: files)
                try verifyBaseline(baseline)
                let data = try encode(baseline)
                try writer(data, baselineURL)
                guard try read(baselineURL) == data, try scanLegacy() == files else {
                    throw ExamError.invalid("旧记录在备份期间变化，停止迁移并保留双方文件。")
                }
                baselineSHA256 = StudySHA256.hex(data)
            }
            if hasCurrent {
                guard hasInitial else { throw ExamError.invalid("迁移初始快照缺失，停止写入。") }
                _ = try decodeDisk(read(initialURL))
                let data = try read(currentURL), disk = try decodeDisk(data)
                let deck = try ProfessionalRecallCatalog.usingStoredOrder(catalog, cardIDs: disk.record.cardIDs)
                engine = try ProfessionalRecallEngine(deck: deck, record: disk.record)
                durableSHA256 = StudySHA256.hex(data)
            } else {
                guard !hasInitial else { throw ExamError.invalid("已有迁移快照但当前记录缺失；不会从初始快照重置后续学习。") }
                let legacy = try baseline.files.filter { $0.path.hasSuffix("/recall.json") }.map {
                    try JSONDecoder().decode(RecallArchive.self, from: $0.bytes).record
                }
                let fresh = try ProfessionalRecallEngine.fresh(deck: catalog, legacy: legacy)
                let data = try encodeDisk(fresh)
                // Intent first: an ambiguous failure cannot silently restart.
                try writer(data, initialURL)
                try writer(data, currentURL)
                durableSHA256 = StudySHA256.hex(data)
                engine = fresh
            }
        } catch { fail(error) }
    }

    func start(now: Date = Date()) {
        change {
            try $0.setConservativeEnabled(vocabularyPolicyEnabled(), now: now)
            try $0.start(day: UInt32(ConceptCalendar.studyDay(now)), now: now)
        }
    }
    func reveal(token: UUID) { change { try $0.reveal(token: token) } }
    func grade(remembered: Bool, token: UUID) { change { try $0.grade(remembered: remembered, token: token) } }

    private func vocabularyPolicyEnabled() throws -> Bool {
        let path = base.appendingPathComponent("Study", isDirectory: true).appendingPathComponent("study-state-v1.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return true }
        let english = try JSONDecoder().decode(AppDiskRecord.self, from: read(path))
        let state = try JSONDecoder().decode(SyncState.self, from: english.syncStateJSON)
        let snapshot = try PocketEngine(snapshot: state.snapshot)
        return try english.validatedAnalysis(engine: snapshot).conservativeEnabled
    }

    private func change(_ action: (ProfessionalRecallEngine) throws -> Void) {
        guard !blocked, let current = engine else { return }
        do {
            guard StudySHA256.hex(try read(currentURL)) == durableSHA256 else {
                throw ExamError.invalid("另一页面已保存新记录。请返回重新打开；不会覆盖较新的学习。")
            }
            let next = try current.fork()
            try action(next)
            let bytes = try encodeDisk(next)
            guard StudySHA256.hex(bytes) != durableSHA256 else { return }
            try writer(bytes, currentURL)
            durableSHA256 = StudySHA256.hex(bytes)
            engine = next
        } catch { fail(error) }
    }

    func export() throws -> Data {
        let current = try read(currentURL), initial = try read(initialURL), baseline = try read(baselineURL)
        _ = try decodeDisk(current); _ = try decodeDisk(initial)
        guard StudySHA256.hex(baseline) == baselineSHA256 else { throw ExamError.invalid("原始备份校验失败。") }
        return try encode(ProfessionalRecallExport(format: "xkl-professional-recall-export-v1", current: current,
            initial: initial, legacyBaseline: baseline))
    }

    private func decodeDisk(_ data: Data) throws -> ProfessionalRecallDisk {
        let disk = try JSONDecoder().decode(ProfessionalRecallDisk.self, from: data)
        guard disk.format == "xkl-professional-recall-disk-v1", disk.scope == scope,
              disk.baselineSHA256 == baselineSHA256 else { throw ExamError.invalid("背卡档案身份或迁移来源不一致。") }
        return disk
    }
    private func encodeDisk(_ value: ProfessionalRecallEngine) throws -> Data {
        try encode(ProfessionalRecallDisk(format: "xkl-professional-recall-disk-v1", scope: scope,
            baselineSHA256: baselineSHA256, record: value.record))
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 256 * 1024 * 1024 else { throw ExamError.invalid("档案容量需核查，已有日志不会截断。") }
        return data
    }
    private func read(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
              size <= 256 * 1024 * 1024 else { throw ExamError.invalid("档案类型或容量异常，停止写入。") }
        return try Data(contentsOf: url)
    }
    private func scanLegacy() throws -> [ProfessionalRecallLegacyFile] {
        let parent = base.appendingPathComponent("RecallCards", isDirectory: true).appendingPathComponent(subject.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        let rootInfo = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else { throw ExamError.invalid("旧背卡目录类型异常。") }
        guard let enumeration = FileManager.default.enumerator(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw ExamError.invalid("无法遍历旧背卡档案。") }
        var files: [ProfessionalRecallLegacyFile] = []
        var total = 0
        for case let url as URL in enumeration {
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true else { throw ExamError.invalid("旧背卡目录含链接，停止备份。") }
            if attributes.isDirectory == true { continue }
            let bytes = try read(url); total += bytes.count
            guard total <= 128 * 1024 * 1024, files.count < 2000 else { throw ExamError.invalid("旧档案容量超出安全备份范围，停止迁移。") }
            let relative = String(url.path.dropFirst(parent.path.count + 1))
            files.append(ProfessionalRecallLegacyFile(path: relative, sha256: StudySHA256.hex(bytes), bytes: bytes))
        }
        return files.sorted { $0.path < $1.path }
    }
    private func verifyBaseline(_ baseline: ProfessionalRecallBaseline) throws {
        guard Set(baseline.files.map(\.path)).count == baseline.files.count else { throw ExamError.invalid("旧档案路径重复。") }
        for file in baseline.files {
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                  StudySHA256.hex(file.bytes) == file.sha256 else { throw ExamError.invalid("旧档案备份校验失败。") }
            if file.path.hasSuffix("/recall.json") {
                let old = try JSONDecoder().decode(RecallArchive.self, from: file.bytes)
                guard old.format == "xkl-recall-archive-v1", old.deck.subject == subject,
                      file.path.split(separator: "/").dropLast().last == (try old.deck.hash) else {
                    throw ExamError.invalid("旧背卡档案与目录身份不一致。")
                }
                _ = try RecallEngine(deck: old.deck, record: old.record)
            }
            if file.path.hasSuffix("/created.json") {
                let archivePath = String(file.path.dropLast("created.json".count)) + "recall.json"
                guard let archive = baseline.files.first(where: { $0.path == archivePath }) else {
                    throw ExamError.invalid("旧档案创建标记存在但学习记录缺失；不会创建空进度。")
                }
                let old = try JSONDecoder().decode(RecallArchive.self, from: archive.bytes)
                guard try JSONDecoder().decode(String.self, from: file.bytes) == old.deck.hash else {
                    throw ExamError.invalid("旧档案标记不一致，停止迁移。")
                }
            }
        }
    }
    private func fail(_ value: Error) {
        blocked = true; error = value.localizedDescription + " 原记录保留，请重新打开或导出核对。"
    }
}
