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
struct ProfessionalRecallSubjectDisk: Codable {
    let format: String
    let subject: ConceptSubject
    let baselineSHA256: String
    var records: [String: ProfessionalRecallRecord]
    var revisionSHA256s: [String] = []
}
private struct ProfessionalRecallExport: Codable {
    let format: String
    let current: Data
    let initial: Data
    let legacyBaseline: Data
    let contentRevisionBackups: [String: Data]
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
    private var subjectDisk: ProfessionalRecallSubjectDisk?
    private var currentURL: URL { directory.appendingPathComponent("current.json") }
    private var initialURL: URL { directory.appendingPathComponent("initial.json") }
    private var baselineURL: URL { directory.appendingPathComponent("legacy-baseline.json") }
    private var revisionsURL: URL { directory.appendingPathComponent("revisions", isDirectory: true) }

    init(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching,
         scope: ProfessionalRecallScope = .mainline, baseDirectory: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.subject = subject; self.scope = scope; self.writer = writer
        self.base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent("ProfessionalRecall", isDirectory: true)
            .appendingPathComponent(subject.rawValue, isDirectory: true)
        do {
            var catalogs: [String: RecallDeck] = [:]
            for selection in ProfessionalRecallScope.allCases {
                catalogs[selection.rawValue] = try ProfessionalRecallCatalog.make(subject: subject, bank: bank,
                    teaching: teaching, scope: selection, allowEmpty: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fm = FileManager.default
            let hasCurrent = fm.fileExists(atPath: currentURL.path), hasInitial = fm.fileExists(atPath: initialURL.path)
            // Never treat an unrecognized earlier draft archive as an empty user.
            let hasScopedDraft = ProfessionalRecallScope.allCases.contains {
                let path = directory.appendingPathComponent($0.rawValue)
                return fm.fileExists(atPath: path.appendingPathComponent("current.json").path)
                    || fm.fileExists(atPath: path.appendingPathComponent("initial.json").path)
            }
            guard !hasScopedDraft else { throw ExamError.invalid("发现未发布格式的专业背卡档案，已保留；不能建立第二份空进度。") }
            let hasPriorEvidence = hasCurrent || hasInitial || fm.fileExists(atPath: revisionsURL.path)
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
                guard !hasPriorEvidence else { throw ExamError.invalid("迁移备份缺失，停止写入；不会重新初始化。") }
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
            let legacy = try baseline.files.filter { $0.path.hasSuffix("/recall.json") }.map {
                try JSONDecoder().decode(RecallArchive.self, from: $0.bytes).record
            }
            if hasCurrent {
                guard hasInitial else { throw ExamError.invalid("迁移初始快照缺失，停止写入。") }
                let initial = try decodeDisk(read(initialURL))
                try validateRevisions(initial)
                let data = try read(currentURL), disk = try decodeDisk(data)
                try validateRevisions(disk)
                try validateLineage(disk, retaining: initial)
                let restored = try reconcile(disk: disk, catalogs: catalogs, legacy: legacy)
                if disk.records != restored.records {
                    // Back up both sides together before a card moves scopes. A
                    // source log never disappears or becomes a fabricated answer.
                    let beforeHash = StudySHA256.hex(data)
                    guard StudySHA256.hex(try read(currentURL)) == beforeHash else {
                        throw ExamError.invalid("内容迁移期间出现更新的记录，请重新打开。")
                    }
                    try archiveRevision(data, hash: beforeHash)
                    var next = disk
                    next.records = restored.records
                    if !next.revisionSHA256s.contains(beforeHash) { next.revisionSHA256s.append(beforeHash) }
                    let bytes = try encode(next)
                    guard StudySHA256.hex(try read(currentURL)) == beforeHash else {
                        throw ExamError.invalid("内容迁移期间出现更新的记录；迁移副本已保留，未覆盖。")
                    }
                    try writer(bytes, currentURL)
                    guard try read(currentURL) == bytes else { throw ExamError.invalid("迁移后的记录未完整保存。") }
                    durableSHA256 = StudySHA256.hex(bytes); subjectDisk = next
                } else {
                    durableSHA256 = StudySHA256.hex(data); subjectDisk = disk
                }
                engine = restored.engines[scope.rawValue]
            } else {
                guard !hasInitial, !fm.fileExists(atPath: revisionsURL.path) else {
                    throw ExamError.invalid("已有迁移快照但当前记录缺失；不会从初始快照重置后续学习。")
                }
                var engines: [String: ProfessionalRecallEngine] = [:]
                for selection in ProfessionalRecallScope.allCases {
                    let catalog = catalogs[selection.rawValue]!
                    if !catalog.cards.isEmpty {
                        engines[selection.rawValue] = try ProfessionalRecallEngine.fresh(deck: catalog, legacy: legacy)
                    }
                }
                guard !engines.isEmpty else { throw ExamError.invalid("课程暂无可用背卡。") }
                let disk = ProfessionalRecallSubjectDisk(format: "xkl-professional-recall-subject-v1", subject: subject,
                    baselineSHA256: baselineSHA256, records: engines.mapValues(\.record))
                let data = try encode(disk)
                // Intent first: an ambiguous failure cannot silently restart.
                try writer(data, initialURL)
                guard try read(initialURL) == data else { throw ExamError.invalid("迁移初始快照未完整保存。") }
                try writer(data, currentURL)
                guard try read(currentURL) == data else { throw ExamError.invalid("专业背卡记录未完整保存。") }
                durableSHA256 = StudySHA256.hex(data)
                subjectDisk = disk; engine = engines[scope.rawValue]
            }
            if engine == nil { error = "本范围暂无卡片，其他范围与原记录均保留。" }
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
        guard !blocked, let current = engine, var disk = subjectDisk else { return }
        do {
            guard StudySHA256.hex(try read(currentURL)) == durableSHA256 else {
                throw ExamError.invalid("另一页面已保存新记录。请返回重新打开；不会覆盖较新的学习。")
            }
            let next = try current.fork()
            try action(next)
            disk.records[scope.rawValue] = next.record
            let bytes = try encode(disk)
            guard StudySHA256.hex(bytes) != durableSHA256 else { return }
            try writer(bytes, currentURL)
            guard try read(currentURL) == bytes else { throw ExamError.invalid("本次背卡记录未完整保存。") }
            durableSHA256 = StudySHA256.hex(bytes)
            subjectDisk = disk
            engine = next
        } catch { fail(error) }
    }

    func export() throws -> Data {
        let current = try read(currentURL), initial = try read(initialURL), baseline = try read(baselineURL)
        let disk = try decodeDisk(current), beginning = try decodeDisk(initial)
        try validateRevisions(disk); try validateRevisions(beginning)
        try validateLineage(disk, retaining: beginning)
        guard StudySHA256.hex(baseline) == baselineSHA256 else { throw ExamError.invalid("原始备份校验失败。") }
        var revisions: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: revisionsURL.path) {
            for path in try FileManager.default.contentsOfDirectory(at: revisionsURL, includingPropertiesForKeys: nil) where path.pathExtension == "json" {
                let hash = path.deletingPathExtension().lastPathComponent, bytes = try read(path)
                guard ExamContent.isHash(hash), StudySHA256.hex(bytes) == hash else { throw ExamError.invalid("内容迁移备份校验失败。") }
                _ = try decodeDisk(bytes)
                revisions[hash] = bytes
            }
        }
        return try encode(ProfessionalRecallExport(format: "xkl-professional-recall-export-v1", current: current,
            initial: initial, legacyBaseline: baseline, contentRevisionBackups: revisions))
    }

    private func decodeDisk(_ data: Data) throws -> ProfessionalRecallSubjectDisk {
        let disk = try JSONDecoder().decode(ProfessionalRecallSubjectDisk.self, from: data)
        guard disk.format == "xkl-professional-recall-subject-v1", disk.subject == subject,
              disk.baselineSHA256 == baselineSHA256, !disk.records.isEmpty,
              Set(disk.records.keys).isSubset(of: Set(ProfessionalRecallScope.allCases.map(\.rawValue))),
              disk.records.values.allSatisfy({ $0.subject == subject }),
              Set(disk.revisionSHA256s).count == disk.revisionSHA256s.count,
              disk.revisionSHA256s.allSatisfy(ExamContent.isHash) else {
            throw ExamError.invalid("背卡档案身份或迁移来源不一致。")
        }
        return disk
    }
    private func reconcile(disk: ProfessionalRecallSubjectDisk, catalogs: [String: RecallDeck], legacy: [RecallRecord]) throws
        -> (records: [String: ProfessionalRecallRecord], engines: [String: ProfessionalRecallEngine]) {
        var existing: [String: ProfessionalRecallEngine] = [:]
        for selection in ProfessionalRecallScope.allCases {
            if let record = disk.records[selection.rawValue] {
                existing[selection.rawValue] = try ProfessionalRecallEngine.restore(record: record, fallback: catalogs[selection.rawValue]!)
            }
        }
        let oldMainline = Set(existing[ProfessionalRecallScope.mainline.rawValue]?.activeCardIDs ?? [])
        let oldRelated = Set(existing[ProfessionalRecallScope.related.rawValue]?.activeCardIDs ?? [])
        guard oldMainline.isDisjoint(with: oldRelated) else { throw ExamError.invalid("主线与拓展存在重复活动身份，原档案保留待核对。") }
        var imports: [String: [String: ProfessionalRecallTransferState]] = [:]
        // Capture both old sides before either source is parked.
        for destination in ProfessionalRecallScope.allCases {
            let source: ProfessionalRecallScope = destination == .mainline ? .related : .mainline
            guard let sourceEngine = existing[source.rawValue] else { continue }
            let sourceIDs = Set(sourceEngine.activeCardIDs)
            for card in catalogs[destination.rawValue]!.cards where sourceIDs.contains(card.id) {
                if let state = try sourceEngine.transferState(for: card.id, sourceScope: source.rawValue) {
                    imports[destination.rawValue, default: [:]][card.id] = state
                }
            }
        }
        for selection in ProfessionalRecallScope.allCases {
            let key = selection.rawValue, catalog = catalogs[key]!
            if existing[key] == nil, !catalog.cards.isEmpty {
                existing[key] = try ProfessionalRecallEngine.fresh(deck: catalog, legacy: legacy,
                    initiallyActive: (imports[key] ?? [:]).isEmpty)
            }
            if let target = existing[key] { try target.reconcile(to: catalog, importing: imports[key] ?? [:]) }
        }
        return (existing.mapValues(\.record), existing)
    }
    private func archiveRevision(_ bytes: Data, hash: String) throws {
        guard ExamContent.isHash(hash), StudySHA256.hex(bytes) == hash else { throw ExamError.invalid("内容迁移快照校验失败。") }
        try FileManager.default.createDirectory(at: revisionsURL, withIntermediateDirectories: true)
        let path = revisionsURL.appendingPathComponent(hash + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            guard try read(path) == bytes else { throw ExamError.invalid("已有内容迁移快照不一致。") }
        } else { try writer(bytes, path) }
        guard try read(path) == bytes else { throw ExamError.invalid("内容迁移快照未完整持久保存。") }
    }
    private func validateRevisions(_ disk: ProfessionalRecallSubjectDisk) throws {
        for hash in disk.revisionSHA256s {
            let bytes = try read(revisionsURL.appendingPathComponent(hash + ".json"))
            guard StudySHA256.hex(bytes) == hash else { throw ExamError.invalid("内容迁移备份缺失或损坏，停止写入。") }
            try validateLineage(disk, retaining: decodeDisk(bytes))
        }
    }
    private func validateLineage(_ disk: ProfessionalRecallSubjectDisk, retaining prior: ProfessionalRecallSubjectDisk) throws {
        guard Set(prior.records.keys).isSubset(of: Set(disk.records.keys)),
              Array(disk.revisionSHA256s.prefix(prior.revisionSHA256s.count)) == prior.revisionSHA256s else {
            throw ExamError.invalid("专业背卡范围或迁移链缺失，不能重建已存在的进度。")
        }
        for (key, old) in prior.records {
            guard let current = disk.records[key],
                  Array(current.cardIDs.prefix(old.cardIDs.count)) == old.cardIDs,
                  Array(current.attempts.prefix(old.attempts.count)) == old.attempts,
                  current.migration == old.migration else {
                throw ExamError.invalid("专业背卡历史ID、自评或旧档迁移来源缺失，停止写入。")
            }
        }
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
        // Foundation may enumerate /private/var for a caller rooted at /var.
        // Resolve both sides and compare components before deriving a relative
        // archive path; character offsets can silently corrupt backup identity.
        let rootComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard let enumeration = FileManager.default.enumerator(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw ExamError.invalid("无法遍历旧背卡档案。") }
        var files: [ProfessionalRecallLegacyFile] = []
        var total = 0
        for case let url as URL in enumeration {
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true else { throw ExamError.invalid("旧背卡目录含链接，停止备份。") }
            if attributes.isDirectory == true { continue }
            let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else {
                throw ExamError.invalid("旧背卡档案路径超出原目录，停止备份。")
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            let bytes = try read(url); total += bytes.count
            guard total <= 128 * 1024 * 1024, files.count < 2000 else { throw ExamError.invalid("旧档案容量超出安全备份范围，停止迁移。") }
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
                      let folderHash = file.path.split(separator: "/").dropLast().last,
                      String(folderHash) == (try old.deck.hash) else {
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
