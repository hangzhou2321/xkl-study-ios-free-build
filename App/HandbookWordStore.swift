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
    /// Only a genuine v1->v2 cutover has a source that may be restored.
    var cutoverV1SHA256: String? = nil
    /// Explicit re-enablement is tied to the immutable legacy-mode marker.
    var reenabledFromLegacyMarkerSHA256: String? = nil
}
private struct HandbookWordBaseline: Codable {
    var format = "xkl-handbook-word-baseline-v1"
    let subject: ConceptSubject
    let mappingPolicy: String
    let legacyFiles: [String: Data]
}
private struct HandbookWordExport: Encodable {
    var format = "xkl-handbook-word-export-v1"
    let files: [String: Data]
    let currentLegacyFiles: [String: Data]
    let legacyBaselineMappingPolicy = "read-only-index;original-baseline-bytes-and-stored-keys-retained;unique-path-suffix-and-exact-bytes-only"
    let legacyBaselineIndex: [HandbookWordLegacyArchiveEntry]
}
private struct HandbookWordLegacyArchiveEntry: Encodable {
    let storedKey: String
    let sha256: String
    let originalRelativePath: String?
    let candidateRelativePaths: [String]
    let resolution: String
}
private struct HandbookLegacyModePayload: Codable {
    var format = "xkl-handbook-legacy-mode-v1"
    let subject: ConceptSubject
    let v1SHA256: String
    let v2SHA256: String
}
private struct HandbookLegacyModeMarker: Codable {
    let payload: HandbookLegacyModePayload
    let payloadSHA256: String
}
private struct HandbookLegacyModeWitness: Codable {
    var format = "xkl-handbook-legacy-mode-witness-v1"
    let subject: ConceptSubject
    let markerSHA256: String
}

/// Foundation can enumerate /var through its /private/var alias. Compare canonical
/// components, never character offsets from the caller's spelling of the root.
enum HandbookWordArchivePath {
    static func isSafeRelativeKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains("\\") && !key.contains(":") &&
        !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func relativeKey(for file: URL, within root: URL) throws -> String {
        guard file.isFileURL, root.isFileURL else { throw ExamError.invalid("宝典归档必须使用本地文件路径。") }
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard fileParts.count > rootParts.count, Array(fileParts.prefix(rootParts.count)) == rootParts else {
            throw ExamError.invalid("宝典归档文件超出所属目录。")
        }
        let key = fileParts.dropFirst(rootParts.count).joined(separator: "/")
        guard isSafeRelativeKey(key) else { throw ExamError.invalid("宝典归档相对路径无效。") }
        return key
    }
}

/// Independent professional-card namespace. The old Pocket record and its
/// immutable cutover archive remain intact; only actual self-ratings seed FSRS.
@MainActor final class HandbookWordStore: ObservableObject {
    let subject: ConceptSubject
    @Published private(set) var engine: HandbookWordEngine?
    @Published private(set) var blocked = false
    /// A valid old transfer queue must be allowed to finish before cutover.
    @Published private(set) var isDualMigrationPending = false
    @Published var error: String?
    private let base: URL, directory: URL, documents: URL
    private let writer: (Data, URL) throws -> Void
    private let creationDate: Date?
    private var disk: HandbookWordDisk?
    private var durableSHA256 = ""
    private var durableMarkerSHA256: String?
    private var durableWitnessSHA256: String?
    private var rollbackEligible = false
    private var currentURL: URL { directory.appendingPathComponent("current.json") }
    private var legacyMarkerURL: URL { directory.appendingPathComponent("legacy-mode.json") }
    private var legacyWitnessURL: URL { directory.appendingPathComponent("legacy-mode-witness.json") }
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
                try validate(saved)
                let restored = try HandbookWordEngine(state: saved.state)
                if let (marker, old, oldRaw) = try checkedLegacyMarker() {
                    if saved.format == "xkl-handbook-word-store-v1" {
                        try validateLegacyContinuation(saved, of: old)
                        disk = saved; durableSHA256 = StudySHA256.hex(raw); engine = restored
                    } else if saved.reenabledFromLegacyMarkerSHA256 == durableMarkerSHA256 {
                        // Explicit re-enablement uses the latest valid v1 head,
                        // not the older v1 that was present at initial rollback.
                        guard let hash = saved.cutoverV1SHA256 else { throw ExamError.invalid("重新启用缺少旧调度切换档案。") }
                        let resumedRaw = try read(directory.appendingPathComponent("revisions/\(hash).json"))
                        let resumed = try JSONDecoder().decode(HandbookWordDisk.self, from: resumedRaw)
                        try validate(resumed); try validateLegacyContinuation(resumed, of: old)
                        disk = saved; durableSHA256 = StudySHA256.hex(raw); engine = restored
                    } else {
                        // A valid marker is a durable, explicit rollback request.
                        // Finish it on restart only while the exact v2 head remains.
                        guard StudySHA256.hex(raw) == marker.payload.v2SHA256 else {
                            throw ExamError.invalid("撤回过程中出现新的双FSRS记录，停止并保留两份档案。")
                        }
                        guard try StudySHA256.hex(read(currentURL)) == StudySHA256.hex(raw),
                              let markerHash = durableMarkerSHA256,
                              let witnessHash = durableWitnessSHA256,
                              try StudySHA256.hex(read(legacyMarkerURL)) == markerHash,
                              try StudySHA256.hex(read(legacyWitnessURL)) == witnessHash else {
                            throw ExamError.invalid("恢复撤回前记录或标记有新变化，原记录保留。")
                        }
                        try writer(oldRaw, currentURL)
                        guard try read(currentURL) == oldRaw else { throw ExamError.invalid("撤回断点未完整保存。") }
                        disk = old; durableSHA256 = StudySHA256.hex(oldRaw)
                        engine = try HandbookWordEngine(state: old.state)
                    }
                } else if saved.format == "xkl-handbook-word-store-v1" {
                    if !(saved.state.word.deferredCards ?? [:]).isEmpty {
                        // These are genuine unfinished C-queue obligations; the
                        // FSRS migration cannot safely reconstruct them yet.
                        // Publish the validated v1 unchanged so study can resume.
                        disk = saved; durableSHA256 = StudySHA256.hex(raw); engine = restored
                        isDualMigrationPending = true
                    } else {
                        try migrateToDualFSRS(saved, raw: raw, restored: restored)
                    }
                } else {
                    guard saved.reenabledFromLegacyMarkerSHA256 == nil else {
                        throw ExamError.invalid("重新启用双FSRS所需的旧调度标记缺失，原记录保留。")
                    }
                    disk = saved; durableSHA256 = StudySHA256.hex(raw); engine = restored
                    rollbackEligible = (try? rollbackSource(for: saved)) != nil
                }
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
        let rootInfo = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootInfo.isSymbolicLink != true, rootInfo.isDirectory == true else { throw ExamError.invalid("旧宝典目录必须是真实目录，不能是符号链接。") }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        _ = try HandbookWordArchivePath.relativeKey(for: canonicalRoot, within: base)
        var files: [String: Data] = [:]
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw ExamError.invalid("宝典档案目录无法完整读取。") }
        for case let url as URL in iterator {
            let meta = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard meta.isSymbolicLink != true else { throw ExamError.invalid("宝典档案包含符号链接，停止写入。") }
            let key = try HandbookWordArchivePath.relativeKey(for: url, within: canonicalRoot)
            if meta.isRegularFile == true {
                guard files[key] == nil else { throw ExamError.invalid("宝典档案相对路径重复，停止导出。") }
                files[key] = try read(url)
            }
        }
        if let enumerationError { throw enumerationError }
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
            mappingPolicy: "professional-dual-fsrs;older-handbook-self-ratings-retained-not-fabricated", legacyFiles: legacy))
        try immutable(baseline, directory.appendingPathComponent("legacy-baseline.json"))
        guard try legacyFiles() == legacy else { throw ExamError.invalid("备份时旧记录出现新增，请重新打开；不会覆盖。") }
        let now = creationDate ?? Date()
        let candidate = try HandbookWordEngine(package: package, now: now)
        try candidate.enableDualFSRS(now: now)
        let initial = try encode(candidate.state)
        try immutable(initial, directory.appendingPathComponent("initial.json"))
        let hash = StudySHA256.hex(raw); try immutable(raw, directory.appendingPathComponent("imports/\(hash).xklflashcards"))
        var next = HandbookWordDisk(subject: subject, baselineSHA256: StudySHA256.hex(baseline), initialSHA256: StudySHA256.hex(initial),
            state: candidate.state, rawImports: [hash], revisions: [])
        next.format = "xkl-handbook-word-store-v2-dual-fsrs"
        let bytes = try encode(next); try writer(bytes, currentURL)
        guard try read(currentURL) == bytes else { throw ExamError.invalid("宝典新调度档案未完整保存。") }
        engine = candidate; disk = next; durableSHA256 = StudySHA256.hex(bytes)
    }
    /// Archive the complete old pointer byte-for-byte before the one-time switch.
    /// Old clients reject the v2 envelope instead of silently discarding FSRS.
    private func migrateToDualFSRS(_ saved: HandbookWordDisk, raw: Data, restored: HandbookWordEngine,
                                   reenabledFrom markerHash: String? = nil, now: Date? = nil) throws {
        let oldHash = StudySHA256.hex(raw)
        try guardMigrationHead(oldHash, marker: markerHash)
        try immutable(raw, directory.appendingPathComponent("revisions/\(oldHash).json"))
        try guardMigrationHead(oldHash, marker: markerHash)
        try restored.enableDualFSRS(now: now ?? creationDate ?? Date())
        var next = saved
        next.format = "xkl-handbook-word-store-v2-dual-fsrs"
        if !next.revisions.contains(oldHash) { next.revisions.append(oldHash) }
        next.cutoverV1SHA256 = oldHash
        next.reenabledFromLegacyMarkerSHA256 = markerHash
        next.state = restored.state
        try validate(next)
        let bytes = try encode(next)
        try guardMigrationHead(oldHash, marker: markerHash)
        try writer(bytes, currentURL)
        guard try read(currentURL) == bytes else { throw ExamError.invalid("双 FSRS 切换没有完整保存。") }
        engine = restored; disk = next; durableSHA256 = StudySHA256.hex(bytes)
        rollbackEligible = markerHash == nil
    }
    private func validate(_ saved: HandbookWordDisk) throws {
        let old = saved.format == "xkl-handbook-word-store-v1"
        let dual = saved.format == "xkl-handbook-word-store-v2-dual-fsrs"
        guard (old && saved.state.dualFSRS == nil && saved.cutoverV1SHA256 == nil && saved.reenabledFromLegacyMarkerSHA256 == nil) ||
              (dual && saved.state.dualFSRS != nil) else {
            throw ExamError.invalid("宝典调度版本和状态不一致，原记录保留。")
        }
        if let hash = saved.cutoverV1SHA256 {
            guard dual, ExamContent.isHash(hash), saved.revisions.contains(hash) else {
                throw ExamError.invalid("双FSRS原始切换档案索引无效，原记录保留。")
            }
        }
        if let marker = saved.reenabledFromLegacyMarkerSHA256 {
            guard dual, saved.cutoverV1SHA256 != nil, ExamContent.isHash(marker) else {
                throw ExamError.invalid("重新启用双FSRS的标记无效，原记录保留。")
            }
        }
        guard saved.subject == subject, saved.state.package.subject == subject,
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
    private func guardMigrationHead(_ hash: String, marker: String?) throws {
        guard try StudySHA256.hex(read(currentURL)) == hash else { throw ExamError.invalid("切换时记录有新变化，请重新打开。") }
        if let marker {
            guard try StudySHA256.hex(read(legacyMarkerURL)) == marker,
                  let witness = durableWitnessSHA256,
                  try StudySHA256.hex(read(legacyWitnessURL)) == witness else { throw ExamError.invalid("旧调度标记有变化，请重新打开。") }
        } else if FileManager.default.fileExists(atPath: legacyMarkerURL.path) || FileManager.default.fileExists(atPath: legacyWitnessURL.path) {
            throw ExamError.invalid("另一页面已开始撤回，请重新打开。")
        }
    }

    /// Only a zero-activity v2 whose complete legacy content still exactly
    /// matches the archived v1 can be rolled back without losing new data.
    private func rollbackSource(for current: HandbookWordDisk) throws -> (HandbookWordDisk, Data) {
        guard current.format == "xkl-handbook-word-store-v2-dual-fsrs",
              current.reenabledFromLegacyMarkerSHA256 == nil,
              let fsrs = current.state.dualFSRS, fsrs.events.isEmpty,
              let hash = current.cutoverV1SHA256, ExamContent.isHash(hash) else {
            throw ExamError.invalid("已有双FSRS活动或没有原始切换档案，不能安全撤回。")
        }
        let raw = try read(directory.appendingPathComponent("revisions/\(hash).json"))
        guard StudySHA256.hex(raw) == hash else { throw ExamError.invalid("旧调度归档校验失败。") }
        let old = try JSONDecoder().decode(HandbookWordDisk.self, from: raw)
        try validate(old); _ = try HandbookWordEngine(state: old.state)
        var stripped = current.state; stripped.dualFSRS = nil
        var expectedRevisions = old.revisions
        if !expectedRevisions.contains(hash) { expectedRevisions.append(hash) }
        guard old.format == "xkl-handbook-word-store-v1", current.subject == old.subject,
              current.baselineSHA256 == old.baselineSHA256, current.initialSHA256 == old.initialSHA256,
              current.rawImports == old.rawImports, current.revisions == expectedRevisions,
              stripped == old.state else {
            throw ExamError.invalid("课程、导入或旧学习状态在切换后变化，不能安全撤回。")
        }
        return (old, raw)
    }

    private func oldEvents(_ record: ProfessionalRecallRecord) throws -> [StudyEvent] {
        var events: [StudyEvent] = []
        for volume in record.volumes {
            let e = try PocketEngine(snapshot: volume.snapshot)
            events += try e.events(from: e.logBase + 1)
        }
        let e = try PocketEngine(snapshot: record.snapshot)
        events += try e.events(from: e.logBase + 1)
        return events
    }

    /// After an explicit rollback, the old app may legitimately add answers.
    /// Only an append-only, same-stream continuation of the archived v1 is
    /// eligible for legacy mode or subsequent explicit re-enablement.
    private func validateLegacyContinuation(_ current: HandbookWordDisk, of original: HandbookWordDisk) throws {
        guard current.format == "xkl-handbook-word-store-v1", original.format == "xkl-handbook-word-store-v1",
              current.subject == original.subject, current.baselineSHA256 == original.baselineSHA256,
              current.initialSHA256 == original.initialSHA256,
              Array(current.rawImports.prefix(original.rawImports.count)) == original.rawImports,
              Array(current.revisions.prefix(original.revisions.count)) == original.revisions,
              current.state.package.id == original.state.package.id,
              current.state.package.revision.compare(original.state.package.revision, options: .numeric) != .orderedAscending,
              Array(current.state.originalCardIDs.prefix(original.state.originalCardIDs.count)) == original.state.originalCardIDs,
              Array(current.state.word.cardIDs.prefix(original.state.word.cardIDs.count)) == original.state.word.cardIDs,
              current.state.word.migration == original.state.word.migration,
              Array(current.state.word.attempts.prefix(original.state.word.attempts.count)) == original.state.word.attempts,
              Array((current.state.word.postponements ?? []).prefix((original.state.word.postponements ?? []).count)) == (original.state.word.postponements ?? []),
              Array((current.state.word.contentChanges ?? []).prefix((original.state.word.contentChanges ?? []).count)) == (original.state.word.contentChanges ?? []) else {
            throw ExamError.invalid("旧调度不是撤回前档案的连续更新，停止并保留记录。")
        }
        _ = try HandbookWordEngine(state: current.state)
        let a = try PocketEngine(snapshot: original.state.word.snapshot)
        let b = try PocketEngine(snapshot: current.state.word.snapshot)
        let before = try oldEvents(original.state.word), after = try oldEvents(current.state.word)
        guard try a.streamID == b.streamID, Array(after.prefix(before.count)) == before else {
            throw ExamError.invalid("旧调度事件链出现分叉，停止并保留记录。")
        }
    }

    /// Marker contains only subject and two content hashes, plus a checksum.
    /// Its v2 archive and archived v1 are validated before either is selected.
    private func checkedLegacyMarker() throws -> (HandbookLegacyModeMarker, HandbookWordDisk, Data)? {
        guard FileManager.default.fileExists(atPath: legacyMarkerURL.path) else {
            if FileManager.default.fileExists(atPath: legacyWitnessURL.path) {
                throw ExamError.invalid("旧调度标记缺失，原记录保留。")
            }
            return nil
        }
        let bytes = try read(legacyMarkerURL)
        let marker = try JSONDecoder().decode(HandbookLegacyModeMarker.self, from: bytes)
        let payload = marker.payload
        guard payload.format == "xkl-handbook-legacy-mode-v1", payload.subject == subject,
              ExamContent.isHash(payload.v1SHA256), ExamContent.isHash(payload.v2SHA256),
              payload.v1SHA256 != payload.v2SHA256,
              StudySHA256.hex(try encode(payload)) == marker.payloadSHA256 else {
            throw ExamError.invalid("旧调度标记损坏，原记录保留。")
        }
        let v2Raw = try read(directory.appendingPathComponent("revisions/\(payload.v2SHA256).json"))
        guard StudySHA256.hex(v2Raw) == payload.v2SHA256 else { throw ExamError.invalid("双FSRS撤回归档损坏。") }
        let v2 = try JSONDecoder().decode(HandbookWordDisk.self, from: v2Raw)
        try validate(v2); _ = try HandbookWordEngine(state: v2.state)
        guard v2.cutoverV1SHA256 == payload.v1SHA256 else { throw ExamError.invalid("旧调度标记与切换档案不一致。") }
        let (old, raw) = try rollbackSource(for: v2)
        guard StudySHA256.hex(raw) == payload.v1SHA256 else { throw ExamError.invalid("旧调度标记与原档案不一致。") }
        let markerHash = StudySHA256.hex(bytes)
        let witness = try encode(HandbookLegacyModeWitness(subject: subject, markerSHA256: markerHash))
        // A crash immediately after the marker write can safely finish this
        // immutable witness on reopen; a missing marker with witness blocks.
        try immutable(witness, legacyWitnessURL)
        durableMarkerSHA256 = markerHash
        durableWitnessSHA256 = StudySHA256.hex(witness)
        return (marker, old, raw)
    }

    /// A single safe rollback is available only before any new FSRS activity.
    var canRollbackToLegacy: Bool {
        !blocked && rollbackEligible && durableMarkerSHA256 == nil &&
        disk?.format == "xkl-handbook-word-store-v2-dual-fsrs" &&
        disk?.cutoverV1SHA256 != nil && disk?.state.dualFSRS?.events.isEmpty == true
    }
    func rollbackToLegacy() {
        guard canRollbackToLegacy, let current = disk else {
            error = "已有双FSRS活动或课程变化，不能安全撤回；原记录保留。"; return
        }
        do {
            try guardCurrent()
            let (old, oldRaw) = try rollbackSource(for: current)
            let oldEngine = try HandbookWordEngine(state: old.state)
            let currentRaw = try read(currentURL), currentHash = StudySHA256.hex(currentRaw)
            guard currentHash == durableSHA256 else { throw ExamError.invalid("撤回前记录有新变化。") }
            try immutable(currentRaw, directory.appendingPathComponent("revisions/\(currentHash).json"))
            try guardCurrent()
            let payload = HandbookLegacyModePayload(subject: subject, v1SHA256: StudySHA256.hex(oldRaw), v2SHA256: currentHash)
            let marker = HandbookLegacyModeMarker(payload: payload, payloadSHA256: StudySHA256.hex(try encode(payload)))
            let markerRaw = try encode(marker)
            try immutable(markerRaw, legacyMarkerURL)
            durableMarkerSHA256 = StudySHA256.hex(markerRaw)
            let witnessRaw = try encode(HandbookLegacyModeWitness(subject: subject, markerSHA256: durableMarkerSHA256!))
            try immutable(witnessRaw, legacyWitnessURL)
            durableWitnessSHA256 = StudySHA256.hex(witnessRaw)
            try guardCurrent()
            try writer(oldRaw, currentURL)
            guard try read(currentURL) == oldRaw else { throw ExamError.invalid("旧调度撤回未完整保存。") }
            disk = old; durableSHA256 = StudySHA256.hex(oldRaw); engine = oldEngine; rollbackEligible = false; error = nil
        } catch { fail(error) }
    }

    /// The marker intentionally remains. A v2 created here identifies it and
    /// takes precedence on reopen; another rollback is deliberately disabled.
    var canEnableDualFSRS: Bool {
        !blocked && durableMarkerSHA256 != nil && disk?.format == "xkl-handbook-word-store-v1" && engine?.usesDualFSRS == false
    }
    func reenableDualFSRS(now: Date = Date()) {
        guard canEnableDualFSRS, let saved = disk, let markerHash = durableMarkerSHA256 else {
            error = "旧调度状态无法安全切换，原记录保留。"; return
        }
        do {
            try guardCurrent()
            guard let (_, original, _) = try checkedLegacyMarker() else { throw ExamError.invalid("旧调度标记缺失。") }
            try validateLegacyContinuation(saved, of: original)
            // The old head can change while the marker and archived chain are
            // being verified. Never combine newly-read bytes with stale `saved`.
            try guardCurrent()
            let raw = try read(currentURL)
            guard StudySHA256.hex(raw) == durableSHA256 else { throw ExamError.invalid("重新启用前旧记录有新变化。") }
            let restored = try HandbookWordEngine(state: saved.state)
            try migrateToDualFSRS(saved, raw: raw, restored: restored, reenabledFrom: markerHash, now: now)
            error = nil
        } catch { fail(error) }
    }
    private func guardCurrent() throws {
        guard try StudySHA256.hex(read(currentURL)) == durableSHA256 else { throw ExamError.invalid("另一页面已保存更新记录，请重新打开，不会覆盖。") }
        if let marker = durableMarkerSHA256 {
            guard try StudySHA256.hex(read(legacyMarkerURL)) == marker,
                  let witness = durableWitnessSHA256,
                  try StudySHA256.hex(read(legacyWitnessURL)) == witness else {
                throw ExamError.invalid("旧调度标记发生变化，请重新打开，原记录保留。")
            }
        } else if FileManager.default.fileExists(atPath: legacyMarkerURL.path) || FileManager.default.fileExists(atPath: legacyWitnessURL.path) {
            throw ExamError.invalid("另一页面已开始撤回，请重新打开，原记录保留。")
        }
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
            engine = candidate; disk = next; durableSHA256 = StudySHA256.hex(bytes)
            if next.state.dualFSRS?.events.isEmpty == false { rollbackEligible = false }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func start(now: Date = Date()) {
        if isDualMigrationPending, !blocked, let saved = disk, let current = engine,
           (saved.state.word.deferredCards ?? [:]).isEmpty {
            do {
                try guardCurrent()
                let raw = try read(currentURL)
                guard StudySHA256.hex(raw) == durableSHA256 else { throw ExamError.invalid("切换前旧记录有新变化。") }
                let candidate = try current.fork()
                try migrateToDualFSRS(saved, raw: raw, restored: candidate, now: now)
                isDualMigrationPending = false
            } catch { fail(error); return }
        }
        change { if $0.usesDualFSRS { try $0.start(now: now) } else { try $0.start(now: now, conservative: policy()) } }
    }
    func startRetry(now: Date = Date()) { change { try $0.startRetry(now: now) } }
    func reveal(token: UUID, now: Date = Date()) { change { try $0.reveal(token: token, now: now) } }
    func rate(remembered: Bool, token: UUID, now: Date = Date()) { change { try $0.rate(remembered: remembered, token: token, now: now) } }
    func markFamiliar(token: UUID, now: Date = Date()) { change { try $0.markFamiliar(token: token, now: now) } }
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
                engine = candidate;disk = next;durableSHA256 = StudySHA256.hex(bytes);rollbackEligible = false;error = nil
            } else { try create(incoming, raw: raw);error = nil }
        } catch { if engine == nil { fail(error) } else { self.error = error.localizedDescription } }
    }
    func stagedFiles() -> [URL] {
        let root = documents.appendingPathComponent("HandbookCards")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])) ?? []).filter {
            let meta = try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            return meta?.isSymbolicLink != true && meta?.isRegularFile == true && ["xklflashcards", "xklcards", "json"].contains($0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// Inspect staged packages without changing the saved learning state. Ambiguity
    /// is left to the file picker, including conflicting packages at the top version.
    func recommendedStagedFile() -> URL? {
        let candidates: [(url: URL, package: HandbookCardPackage)] = stagedFiles().compactMap { url in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size >= 0, size <= 40 * 1_024 * 1_024,
                  let raw = try? read(url), let package = try? HandbookCardPackage.load(raw), package.subject == subject else { return nil }
            return (url, package)
        }
        let eligible: [(url: URL, package: HandbookCardPackage)]
        if let current = package {
            eligible = candidates.filter { $0.package.id == current.id && $0.package.revision.compare(current.revision, options: .numeric) != .orderedAscending }
        } else {
            guard Set(candidates.map { $0.package.id }).count == 1 else { return nil }
            eligible = candidates
        }
        guard let highest = eligible.max(by: { $0.package.revision.compare($1.package.revision, options: .numeric) == .orderedAscending }) else { return nil }
        let top = eligible.filter { $0.package.revision.compare(highest.package.revision, options: .numeric) == .orderedSame }
        guard top.allSatisfy({ $0.package == highest.package }) else { return nil }
        if let current = engine, !Set(current.state.originalCardIDs).isSubset(of: Set(highest.package.cards.map(\.id))) { return nil }
        return top.first?.url
    }
    func exportRecords() throws -> Data {
        let files = try scan(directory), legacy = try legacyFiles()
        var index: [HandbookWordLegacyArchiveEntry] = []
        if let raw = files["legacy-baseline.json"] {
            // Older baselines may contain keys such as omputer/current.json. Keep
            // the hashed baseline verbatim; this index is evidence, not a rewrite.
            let baseline = try JSONDecoder().decode(HandbookWordBaseline.self, from: raw)
            index = baseline.legacyFiles.keys.sorted().map { key in
                let bytes = baseline.legacyFiles[key]!
                let safe = HandbookWordArchivePath.isSafeRelativeKey(key)
                let exact = safe && legacy[key] == bytes
                let candidates = safe ? legacy.keys.filter { (key == $0 || key.hasSuffix("/" + $0)) && legacy[$0] == bytes }.sorted() : []
                let resolved = exact ? key : (candidates.count == 1 ? candidates[0] : nil)
                let resolution = !safe ? "unsafe-stored-key-retained" : exact ? "exact-path-and-bytes" :
                    candidates.count == 1 ? "unique-suffix-and-bytes" : candidates.isEmpty ? "unresolved-retained" : "ambiguous-retained"
                return .init(storedKey: key, sha256: StudySHA256.hex(bytes), originalRelativePath: resolved,
                             candidateRelativePaths: candidates, resolution: resolution)
            }
        }
        return try encode(HandbookWordExport(files: files, currentLegacyFiles: legacy, legacyBaselineIndex: index))
    }
    private func fail(_ failure: Error) { blocked = true;error = failure.localizedDescription + " 原记录保留。" }
}
