import Foundation
import Combine
import StudyCore

private struct HandbookWordDisk: Codable {
    var format = "xkl-handbook-word-store-v1"
    let subject: ConceptSubject
    let baselineSHA256: String
    let initialSHA256: String
    var state: HandbookWordState
    var rawImports: [String]
    var revisions: [String]
}
private struct HandbookWordBaseline: Codable {
    var format = "xkl-handbook-word-baseline-v1"
    let subject: ConceptSubject
    let mappingPolicy: String
    let legacyFiles: [String: Data]
}
private struct HandbookWordExport: Codable {
    var format = "xkl-handbook-word-export-v1"
    let files: [String: Data]
    let currentLegacyFiles: [String: Data]
}

/// Independent English-engine namespace. Existing handbook self-ratings are backed up,
/// never replayed as English answers, and never deleted or overwritten.
@MainActor final class HandbookWordStore: ObservableObject {
    let subject: ConceptSubject
    @Published private(set) var engine: HandbookWordEngine?
    @Published private(set) var blocked = false
    @Published var error: String?
    private let base: URL, directory: URL, documents: URL
    private let writer: (Data, URL) throws -> Void
    private let creationDate: Date?
    private var disk: HandbookWordDisk?
    private var durableSHA256 = ""
    private var currentURL: URL { directory.appendingPathComponent("current.json") }
    init(subject: ConceptSubject = .computer, baseDirectory: URL? = nil, documentsDirectory: URL? = nil,
         now: Date? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.subject = subject; self.writer = writer
        creationDate = now
        base = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).standardizedFileURL.resolvingSymlinksInPath()
        directory = base.appendingPathComponent("HandbookWordRecall/\(subject.rawValue)", isDirectory: true)
        documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try ensure(directory)
            if FileManager.default.fileExists(atPath: currentURL.path) {
                let raw = try read(currentURL), saved = try JSONDecoder().decode(HandbookWordDisk.self, from: raw)
                try validate(saved); disk = saved; durableSHA256 = StudySHA256.hex(raw); engine = try HandbookWordEngine(state: saved.state)
            } else {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw ExamError.invalid("宝典单词调度已有档案但当前指针缺失；原文件保留，不从初始档重置。")
                }
                let old = base.appendingPathComponent("HandbookCards/\(subject.rawValue)/current.json")
                if FileManager.default.fileExists(atPath: old.path) {
                    let object = try JSONSerialization.jsonObject(with: read(old)) as! [String: Any]
                    guard let content = object["package"] else { throw ExamError.invalid("旧宝典内容缺失，原记录保留。") }
                    var rawPackage = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
                    let package = try HandbookCardPackage.load(rawPackage)
                    for hash in (object["importedRawSHA256s"] as? [String] ?? []).reversed() where ExamContent.isHash(hash) {
                        let candidate = try read(old.deletingLastPathComponent().appendingPathComponent("imports/\(hash).xklflashcards"))
                        guard StudySHA256.hex(candidate) == hash else { throw ExamError.invalid("旧宝典原包归档不一致，停止切换。") }
                        if try HandbookCardPackage.load(candidate) == package { rawPackage = candidate; break }
                    }
                    try create(package, raw: rawPackage)
                }
            }
        } catch { fail(error) }
    }
    var package: HandbookCardPackage? { engine?.package }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func read(_ url: URL) throws -> Data {
        let meta = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard meta.isSymbolicLink != true, meta.isRegularFile == true, (meta.fileSize ?? Int.max) <= 256 * 1_024 * 1_024 else {
            throw ExamError.invalid("宝典记录文件类型或大小异常，原文件保留。")
        }
        return try Data(contentsOf: url)
    }
    private func ensure(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(base.path + "/") else { throw ExamError.invalid("宝典保存路径异常。") }
        var p = base
        for part in url.path.dropFirst(base.path.count + 1).split(separator: "/") {
            p.appendPathComponent(String(part), isDirectory: true)
            if FileManager.default.fileExists(atPath: p.path) {
                let info = try p.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard info.isSymbolicLink != true, info.isDirectory == true else { throw ExamError.invalid("宝典目录不能使用符号链接。") }
            } else { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true) }
        }
    }
    private func scan(_ root: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ExamError.invalid("旧宝典目录不能是符号链接。") }
        var files: [String: Data] = [:]
        if let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in iterator {
                let meta = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard meta.isSymbolicLink != true else { throw ExamError.invalid("宝典档案包含符号链接，停止写入。") }
                if meta.isRegularFile == true { files[String(url.path.dropFirst(root.path.count + 1))] = try read(url) }
            }
        }
        return files
    }
    private func immutable(_ bytes: Data, _ url: URL) throws {
        try ensure(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(url) == bytes else { throw ExamError.invalid("宝典已有不可变档案不一致，停止覆盖。") }
        } else { try writer(bytes, url) }
        guard try read(url) == bytes else { throw ExamError.invalid("宝典档案没有完整保存。") }
    }
    private func legacyFiles() throws -> [String: Data] { try scan(base.appendingPathComponent("HandbookCards/\(subject.rawValue)")) }
    private func create(_ package: HandbookCardPackage, raw: Data) throws {
        guard package.subject == subject, try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw ExamError.invalid("已有宝典单词调度不能重新初始化。")
        }
        let legacy = try legacyFiles(), baseline = try encode(HandbookWordBaseline(subject: subject,
            mappingPolicy: "new-English-queue-at-user-request;legacy-self-ratings-retained-not-replayed", legacyFiles: legacy))
        try immutable(baseline, directory.appendingPathComponent("legacy-baseline.json"))
        guard try legacyFiles() == legacy else { throw ExamError.invalid("备份时旧记录出现新增，请重新打开；不会覆盖。") }
        let candidate = try HandbookWordEngine(package: package, now: creationDate ?? Date()), initial = try encode(candidate.state)
        try immutable(initial, directory.appendingPathComponent("initial.json"))
        let hash = StudySHA256.hex(raw); try immutable(raw, directory.appendingPathComponent("imports/\(hash).xklflashcards"))
        let next = HandbookWordDisk(subject: subject, baselineSHA256: StudySHA256.hex(baseline), initialSHA256: StudySHA256.hex(initial),
            state: candidate.state, rawImports: [hash], revisions: [])
        let bytes = try encode(next); try writer(bytes, currentURL)
        guard try read(currentURL) == bytes else { throw ExamError.invalid("宝典新调度档案未完整保存。") }
        engine = candidate; disk = next; durableSHA256 = StudySHA256.hex(bytes)
    }
    private func validate(_ saved: HandbookWordDisk) throws {
        guard saved.format == "xkl-handbook-word-store-v1", saved.subject == subject, saved.state.package.subject == subject,
              StudySHA256.hex(try read(directory.appendingPathComponent("legacy-baseline.json"))) == saved.baselineSHA256,
              StudySHA256.hex(try read(directory.appendingPathComponent("initial.json"))) == saved.initialSHA256 else {
            throw ExamError.invalid("宝典单词调度的初始备份或科目不一致。")
        }
        _ = try HandbookWordEngine(state: JSONDecoder().decode(HandbookWordState.self, from: read(directory.appendingPathComponent("initial.json"))))
        for hash in saved.rawImports {
            guard ExamContent.isHash(hash), StudySHA256.hex(try read(directory.appendingPathComponent("imports/\(hash).xklflashcards"))) == hash else { throw ExamError.invalid("宝典原始导入归档缺失。") }
        }
        for hash in saved.revisions {
            guard ExamContent.isHash(hash), StudySHA256.hex(try read(directory.appendingPathComponent("revisions/\(hash).json"))) == hash else { throw ExamError.invalid("宝典内容历史缺失。") }
        }
    }
    private func guardCurrent() throws {
        guard try StudySHA256.hex(read(currentURL)) == durableSHA256 else { throw ExamError.invalid("另一页面已保存更新记录，请重新打开，不会覆盖。") }
    }
    private func policy() throws -> Bool {
        let url = base.appendingPathComponent("Study/study-state-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let english = try JSONDecoder().decode(AppDiskRecord.self, from: read(url))
        let sync = try JSONDecoder().decode(SyncState.self, from: english.syncStateJSON)
        return try english.validatedAnalysis(engine: PocketEngine(snapshot: sync.snapshot)).conservativeEnabled
    }
    private func change(_ action: (HandbookWordEngine) throws -> Void) {
        guard !blocked, let current = engine, var next = disk else { return }
        do {
            try guardCurrent(); let candidate = try current.fork()
            try action(candidate); next.state = candidate.state
            let bytes = try encode(next); if StudySHA256.hex(bytes) == durableSHA256 { return }
            try guardCurrent()
            do { try writer(bytes, currentURL); guard try read(currentURL) == bytes else { throw ExamError.invalid("本次背卡未完整保存。") } }
            catch { fail(error); return }
            engine = candidate; disk = next; durableSHA256 = StudySHA256.hex(bytes); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func start(now: Date = Date()) { change { try $0.start(now: now, conservative: policy()) } }
    func reveal(token: UUID, now: Date = Date()) { change { try $0.reveal(token: token, now: now) } }
    func rate(remembered: Bool, token: UUID, now: Date = Date()) { change { try $0.rate(remembered: remembered, token: token, now: now) } }
    func postpone(token: UUID, now: Date = Date()) { change { try $0.postpone(token: token, now: now) } }
    func importContent(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { importData(try read(url)) } catch { self.error = error.localizedDescription }
    }
    func importData(_ raw: Data) {
        guard !blocked else { return }
        do {
            let incoming = try HandbookCardPackage.load(raw)
            guard incoming.subject == subject else { throw ExamError.invalid("请在对应科目导入宝典卡。") }
            if let current = engine, var next = disk {
                try guardCurrent(); let candidate = try current.fork(); try candidate.updatePackage(incoming)
                let hash = StudySHA256.hex(raw)
                if candidate.state == next.state && next.rawImports.contains(hash) { error = nil; return }
                if candidate.package != current.package {
                    let previous = try read(currentURL), oldHash = StudySHA256.hex(previous)
                    try immutable(previous, directory.appendingPathComponent("revisions/\(oldHash).json"));next.revisions.append(oldHash)
                }
                try immutable(raw, directory.appendingPathComponent("imports/\(hash).xklflashcards"))
                if !next.rawImports.contains(hash) { next.rawImports.append(hash) };next.state = candidate.state
                try guardCurrent();let bytes = try encode(next)
                do { try writer(bytes, currentURL); guard try read(currentURL) == bytes else { throw ExamError.invalid("宝典导入指针未完整保存。") } }
                catch { fail(error);return }
                engine = candidate;disk = next;durableSHA256 = StudySHA256.hex(bytes);error = nil
            } else { try create(incoming, raw: raw);error = nil }
        } catch { if engine == nil { fail(error) } else { self.error = error.localizedDescription } }
    }
    func stagedFiles() -> [URL] {
        let root = documents.appendingPathComponent("HandbookCards")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])) ?? []).filter {
            let meta = try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            return meta?.isSymbolicLink != true && meta?.isRegularFile == true && ["xklflashcards", "xklcards", "json"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.lowercased().contains(subject.rawValue)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func exportRecords() throws -> Data { try encode(HandbookWordExport(files: scan(directory), currentLegacyFiles: legacyFiles())) }
    private func fail(_ failure: Error) { blocked = true;error = failure.localizedDescription + " 原记录保留。" }
}
