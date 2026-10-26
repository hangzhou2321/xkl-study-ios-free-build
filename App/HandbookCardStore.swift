import Foundation
import Combine
import StudyCore

private struct HandbookCardInitialDisk: Codable {
    let format: String
    let subject: ConceptSubject
    let package: HandbookCardPackage
    let record: HandbookCardRecord
}

private struct HandbookCardDisk: Codable {
    let format: String
    let subject: ConceptSubject
    let initialSHA256: String
    let package: HandbookCardPackage
    let record: HandbookCardRecord
    var previousArchiveSHA256s: [String]
    var importedContentSHA256s: [String]
    var importedRawSHA256s: [String]
    var retainedRawSHA256s: [String]
}

private struct HandbookCardExport: Codable {
    let format: String
    let subject: ConceptSubject
    let current: Data
    let initial: Data
    let contentImports: [String: Data]
    let contentRevisions: [String: Data]
    let retainedRawArchives: [String: Data]
}

/// Self-assessed handbook recall has its own durable namespace. Nothing
/// here opens or migrates English, public-bank, math, or prior professional logs.
@MainActor
final class HandbookCardStore: ObservableObject {
    let subject: ConceptSubject
    @Published private(set) var engine: HandbookRecallEngine?
    @Published private(set) var blocked = false
    @Published var error: String?

    var package: HandbookCardPackage? { engine?.package }
    private let storageBase: URL
    private let directory: URL
    private let documents: URL
    private let writer: (Data, URL) throws -> Void
    private var disk: HandbookCardDisk?
    private var durableSHA256 = ""
    private var currentURL: URL { directory.appendingPathComponent("current.json") }
    private var initialURL: URL { directory.appendingPathComponent("initial.json") }

    init(subject: ConceptSubject = .computer, baseDirectory: URL? = nil, documentsDirectory: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.subject = subject
        self.writer = writer
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let canonicalBase = base.standardizedFileURL.resolvingSymlinksInPath()
        storageBase = canonicalBase
        directory = canonicalBase.appendingPathComponent("HandbookCards", isDirectory: true)
            .appendingPathComponent(subject.rawValue, isDirectory: true)
        documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try ensureDirectory(directory)
            if FileManager.default.fileExists(atPath: currentURL.path) {
                let raw = try read(currentURL)
                let saved = try JSONDecoder().decode(HandbookCardDisk.self, from: raw)
                let restored = try validate(saved)
                disk = saved
                durableSHA256 = StudySHA256.hex(raw)
                engine = restored
            } else {
                // A missing pointer must never be treated as an empty learner
                // when an initial archive or a partially committed import exists.
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw ExamError.invalid("宝典卡片存在已有档案但当前记录缺失，停止新建，原文件已保留。")
                }
            }
        } catch { fail(error) }
    }

    func importContent(_ url: URL) {
        guard !blocked else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { importData(try read(url, limit: 64 * 1_024 * 1_024)) }
        catch { self.error = error.localizedDescription }
    }

    /// Kept separate from the file picker so import transactions are testable.
    /// The whole incoming package is checked before any archive is written.
    func importData(_ raw: Data) {
        guard !blocked else { return }
        var touchedCurrent = false
        do {
            let incoming = try HandbookCardPackage.load(raw)
            guard incoming.subject == subject else { throw ExamError.invalid("请在对应专业科目中导入宝典卡题库。") }
            let contentHash = StudySHA256.hex(try encode(incoming))
            let rawHash = StudySHA256.hex(raw)
            if var candidate = engine, var next = disk {
                try guardCurrentUnchanged()
                let oldContent = StudySHA256.hex(try encode(candidate.package))
                if contentHash == oldContent {
                    // Preserve differing raw serialization/unknown source fields
                    // without creating a new grade or modifying the active log.
                    try immutable(raw, at: archiveURL("imports", rawHash, suffix: ".xklflashcards"))
                    guard !next.importedRawSHA256s.contains(rawHash) else { error = nil; return }
                    // The raw import must join the durable export index as part
                    // of the same atomic envelope, even when its typed content
                    // is unchanged. The engine record and content versions stay
                    // exactly as they were before this import.
                    let previous = try read(currentURL)
                    let decoded = try JSONDecoder().decode(HandbookCardDisk.self, from: previous)
                    let known = try JSONSerialization.jsonObject(with: encode(decoded)) as! [String: Any]
                    let original = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
                    if !NSDictionary(dictionary: known).isEqual(to: original) {
                        let previousHash = StudySHA256.hex(previous)
                        try immutable(previous, at: archiveURL("raw", previousHash))
                        if !next.retainedRawSHA256s.contains(previousHash) { next.retainedRawSHA256s.append(previousHash) }
                    }
                    next.importedRawSHA256s.append(rawHash)
                    try guardCurrentUnchanged()
                    let bytes = try encode(next)
                    touchedCurrent = true
                    try writer(bytes, currentURL)
                    guard try read(currentURL) == bytes else { throw ExamError.invalid("宝典卡原包归档索引没有完整保存。") }
                    disk = next; durableSHA256 = StudySHA256.hex(bytes)
                    error = nil
                    return
                }
                guard !next.importedContentSHA256s.contains(contentHash) else {
                    throw ExamError.invalid("这是已经归档的旧题库版本，不会覆盖后来内容或学习记录。")
                }
                try candidate.updatePackage(incoming)
                _ = try HandbookRecallEngine(package: candidate.package, record: candidate.record)
                let previous = try read(currentURL)
                let previousHash = StudySHA256.hex(previous)
                try immutable(previous, at: archiveURL("revisions", previousHash))
                try immutable(raw, at: archiveURL("imports", rawHash, suffix: ".xklflashcards"))
                next = HandbookCardDisk(format: next.format, subject: subject,
                    initialSHA256: next.initialSHA256, package: candidate.package, record: candidate.record,
                    previousArchiveSHA256s: next.previousArchiveSHA256s + [previousHash],
                    importedContentSHA256s: next.importedContentSHA256s + [contentHash],
                    importedRawSHA256s: next.importedRawSHA256s + [rawHash],
                    retainedRawSHA256s: next.retainedRawSHA256s)
                try guardCurrentUnchanged()
                let bytes = try encode(next)
                touchedCurrent = true
                try writer(bytes, currentURL)
                guard try read(currentURL) == bytes else { throw ExamError.invalid("宝典卡题库更新没有完整保存。") }
                disk = next; engine = candidate; durableSHA256 = StudySHA256.hex(bytes); error = nil
            } else {
                guard disk == nil, !FileManager.default.fileExists(atPath: currentURL.path),
                      try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw ExamError.invalid("已有宝典卡片档案不能按新用户重新建立。")
                }
                let candidate = try HandbookRecallEngine.fresh(incoming)
                let initial = HandbookCardInitialDisk(format: "xkl-handbook-cards-initial-v1",
                    subject: subject, package: incoming, record: candidate.record)
                let initialBytes = try encode(initial)
                let next = HandbookCardDisk(format: "xkl-handbook-cards-store-v1", subject: subject,
                    initialSHA256: StudySHA256.hex(initialBytes), package: incoming, record: candidate.record,
                    previousArchiveSHA256s: [], importedContentSHA256s: [contentHash],
                    importedRawSHA256s: [rawHash], retainedRawSHA256s: [])
                try immutable(raw, at: archiveURL("imports", rawHash, suffix: ".xklflashcards"))
                try immutable(initialBytes, at: initialURL)
                let bytes = try encode(next)
                touchedCurrent = true
                try writer(bytes, currentURL)
                guard try read(currentURL) == bytes else { throw ExamError.invalid("宝典卡片初始记录未完整保存。") }
                disk = next; engine = candidate; durableSHA256 = StudySHA256.hex(bytes); error = nil
            }
        } catch {
            // A write may have replaced current.json before fsync failed. Never
            // roll it back to this process's older, already stale memory state.
            if touchedCurrent { fail(error) } else { self.error = error.localizedDescription }
        }
    }

    func start(now: Date = Date()) { change { try $0.start(now: now) } }
    func reveal(token: UUID, now: Date = Date()) { change { try $0.reveal(token: token, now: now) } }
    func rate(remembered: Bool, token: UUID, now: Date = Date()) {
        change { try $0.rate(remembered: remembered, token: token, now: now) }
    }
    func postpone(token: UUID, now: Date = Date()) { change { try $0.postpone(token: token, now: now) } }

    /// Discovery is read-only. A staged file is never silently activated.
    func stagedFiles() -> [URL] {
        let root = documents.appendingPathComponent("HandbookCards", isDirectory: true)
        guard let values = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        return values.filter { url in
            guard ["xklflashcards", "xklcards", "json"].contains(url.pathExtension.lowercased()),
                  let meta = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  meta.isRegularFile == true, meta.isSymbolicLink != true else { return false }
            return url.lastPathComponent.lowercased().contains(subject.rawValue)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func exportRecords() throws -> Data {
        guard let saved = disk else { throw ExamError.invalid("请先导入宝典卡片题库。") }
        try guardCurrentUnchanged()
        let current = try read(currentURL)
        var imports: [String: Data] = [:], revisions: [String: Data] = [:], retained: [String: Data] = [:]
        for hash in saved.importedRawSHA256s { imports[hash] = try checkedArchive("imports", hash, suffix: ".xklflashcards") }
        for hash in saved.previousArchiveSHA256s { revisions[hash] = try checkedArchive("revisions", hash) }
        for hash in saved.retainedRawSHA256s { retained[hash] = try checkedArchive("raw", hash) }
        return try encode(HandbookCardExport(format: "xkl-handbook-cards-export-v1", subject: subject,
            current: current, initial: read(initialURL), contentImports: imports,
            contentRevisions: revisions, retainedRawArchives: retained))
    }
    func export() throws -> Data { try exportRecords() }

    private func change(_ body: (inout HandbookRecallEngine) throws -> Void) {
        guard !blocked, var candidate = engine, var next = disk else { return }
        do { try guardCurrentUnchanged() }
        catch { fail(error); return }
        // Invalid or incomplete user input changes only the isolated candidate;
        // it must not lock an otherwise intact durable study record.
        do { try body(&candidate) }
        catch { self.error = error.localizedDescription; return }
        do {
            _ = try HandbookRecallEngine(package: candidate.package, record: candidate.record)
            if candidate.record == next.record { error = nil; return }
            let raw = try read(currentURL)
            // Preserve future/unknown fields before a typed writer can omit them.
            let decoded = try JSONDecoder().decode(HandbookCardDisk.self, from: raw)
            let known = try JSONSerialization.jsonObject(with: encode(decoded)) as! [String: Any]
            let original = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            if !NSDictionary(dictionary: known).isEqual(to: original) {
                let hash = StudySHA256.hex(raw)
                try immutable(raw, at: archiveURL("raw", hash))
                if !next.retainedRawSHA256s.contains(hash) { next.retainedRawSHA256s.append(hash) }
            }
            next = HandbookCardDisk(format: next.format, subject: subject, initialSHA256: next.initialSHA256,
                package: candidate.package, record: candidate.record, previousArchiveSHA256s: next.previousArchiveSHA256s,
                importedContentSHA256s: next.importedContentSHA256s, importedRawSHA256s: next.importedRawSHA256s,
                retainedRawSHA256s: next.retainedRawSHA256s)
            try guardCurrentUnchanged()
            let bytes = try encode(next)
            try writer(bytes, currentURL)
            guard try read(currentURL) == bytes else { throw ExamError.invalid("这次宝典卡作答没有完整保存。") }
            disk = next; engine = candidate; durableSHA256 = StudySHA256.hex(bytes); error = nil
        } catch { fail(error) }
    }

    private func validate(_ saved: HandbookCardDisk) throws -> HandbookRecallEngine {
        guard saved.format == "xkl-handbook-cards-store-v1", saved.subject == subject,
              saved.package.subject == subject, ExamContent.isHash(saved.initialSHA256),
              !saved.importedContentSHA256s.isEmpty,
              Set(saved.previousArchiveSHA256s).count == saved.previousArchiveSHA256s.count,
              Set(saved.importedContentSHA256s).count == saved.importedContentSHA256s.count,
              Set(saved.importedRawSHA256s).count == saved.importedRawSHA256s.count,
              Set(saved.retainedRawSHA256s).count == saved.retainedRawSHA256s.count,
              (saved.previousArchiveSHA256s + saved.importedContentSHA256s + saved.importedRawSHA256s + saved.retainedRawSHA256s).allSatisfy(ExamContent.isHash),
              saved.importedContentSHA256s.last == StudySHA256.hex(try encode(saved.package)) else {
            throw ExamError.invalid("宝典卡片档案身份或内容版本链不一致。")
        }
        let initialRaw = try read(initialURL)
        guard StudySHA256.hex(initialRaw) == saved.initialSHA256 else { throw ExamError.invalid("宝典卡片初始档缺失或校验失败，不会重建。") }
        let initial = try JSONDecoder().decode(HandbookCardInitialDisk.self, from: initialRaw)
        guard initial.format == "xkl-handbook-cards-initial-v1", initial.subject == subject else {
            throw ExamError.invalid("宝典卡片初始档科目不一致。")
        }
        _ = try HandbookRecallEngine(package: initial.package, record: initial.record)
        for hash in saved.importedRawSHA256s { _ = try checkedArchive("imports", hash, suffix: ".xklflashcards") }
        for hash in saved.retainedRawSHA256s { _ = try checkedArchive("raw", hash) }
        for (index, hash) in saved.previousArchiveSHA256s.enumerated() {
            let prior = try JSONDecoder().decode(HandbookCardDisk.self, from: checkedArchive("revisions", hash))
            guard prior.subject == subject, prior.initialSHA256 == saved.initialSHA256,
                  prior.previousArchiveSHA256s == Array(saved.previousArchiveSHA256s.prefix(index)) else {
                throw ExamError.invalid("宝典卡片内容更新的旧档案链不连续。")
            }
            _ = try HandbookRecallEngine(package: prior.package, record: prior.record)
        }
        return try HandbookRecallEngine(package: saved.package, record: saved.record)
    }
    private func archiveURL(_ folder: String, _ hash: String, suffix: String = ".json") -> URL {
        directory.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(hash + suffix)
    }
    private func checkedArchive(_ folder: String, _ hash: String, suffix: String = ".json") throws -> Data {
        guard ExamContent.isHash(hash) else { throw ExamError.invalid("宝典卡归档路径标识无效。") }
        let url = archiveURL(folder, hash, suffix: suffix)
        try ownedDirectories(to: url.deletingLastPathComponent(), create: false)
        let data = try read(url)
        guard StudySHA256.hex(data) == hash else { throw ExamError.invalid("宝典卡片归档字节校验失败。") }
        return data
    }
    private func immutable(_ data: Data, at url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(url) == data else { throw ExamError.invalid("宝典卡片已有归档与待保存内容不同，停止覆盖。") }
        } else { try writer(data, url) }
        guard try read(url) == data else { throw ExamError.invalid("宝典卡片归档没有完整保存。") }
    }
    private func guardCurrentUnchanged() throws {
        try ownedDirectories(to: directory, create: false)
        guard !durableSHA256.isEmpty, StudySHA256.hex(try read(currentURL)) == durableSHA256 else {
            throw ExamError.invalid("另一页面已保存新记录，请重新打开；不会用旧页面覆盖。")
        }
    }
    private func ensureDirectory(_ url: URL) throws {
        try ownedDirectories(to: url, create: true)
    }
    private func ownedDirectories(to url: URL, create: Bool) throws {
        let fm = FileManager.default
        let parentComponents = storageBase.pathComponents, components = url.standardizedFileURL.pathComponents
        let expected = parentComponents + ["HandbookCards", subject.rawValue]
        guard components.count >= expected.count, Array(components.prefix(expected.count)) == expected else {
            throw ExamError.invalid("宝典卡片档案路径越出独立目录。")
        }
        if !fm.fileExists(atPath: storageBase.path) {
            guard create else { throw ExamError.invalid("宝典卡片档案根目录缺失。") }
            try fm.createDirectory(at: storageBase, withIntermediateDirectories: true)
        }
        var cursor = storageBase
        for component in components.dropFirst(parentComponents.count) {
            cursor.appendPathComponent(component, isDirectory: true)
            if fm.fileExists(atPath: cursor.path) {
                let value = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard value.isDirectory == true, value.isSymbolicLink != true else {
                    throw ExamError.invalid("宝典卡片档案目录类型异常。")
                }
            } else {
                guard create else { throw ExamError.invalid("宝典卡片已有归档目录缺失。") }
                try fm.createDirectory(at: cursor, withIntermediateDirectories: false)
            }
        }
    }
    private func read(_ url: URL, limit: Int = 256 * 1_024 * 1_024) throws -> Data {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true,
              let size = value.fileSize, size >= 0, size <= limit else { throw ExamError.invalid("宝典卡片文件类型或大小异常。") }
        return try Data(contentsOf: url)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 256 * 1_024 * 1_024 else { throw ExamError.invalid("宝典卡片完整档案过大，历史不会被截断。") }
        return bytes
    }
    private func fail(_ value: Error) { blocked = true; error = value.localizedDescription + " 原记录已保留。" }
}
