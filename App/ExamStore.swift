import Foundation
import Combine
import StudyCore
import Darwin

@MainActor
final class ExamStore: ObservableObject {
    @Published private(set) var bank: ExamBank?
    @Published private(set) var currentQuestion: ExamQuestion?
    @Published private(set) var selectedOptionIDs = Set<String>()
    @Published private(set) var shuffledOptions: [ExamOption] = []
    @Published private(set) var presentationID: UUID?
    @Published private(set) var isRevealed = false
    @Published private(set) var isShowingResult = false
    @Published private(set) var latestAttempt: ExamAttempt?
    @Published private(set) var pendingGrade: Int32?
    @Published private(set) var supplementVisible = false
    @Published var error: String?
    @Published private(set) var storageBlocked = false
    @Published private(set) var sessionIsActive = false
    @Published private(set) var sessionIsComplete = false
    @Published private(set) var sessionPosition = 0
    @Published private(set) var sessionCount = 0
    @Published private(set) var sections: [String] = []
    @Published private(set) var totalAnsweredCount = 0
    @Published private(set) var wrongCount = 0
    @Published private(set) var canMarkFamiliar = false
    @Published private(set) var canUndo = false
    @Published private(set) var stage = 0
    @Published private(set) var newRemaining = 0
    @Published private(set) var reviewRemaining = 0
    @Published private(set) var dueTodayCount = 0
    @Published private(set) var totalRemaining = 0
    @Published private(set) var reinforcementRemaining = 0
    @Published private(set) var carryRemaining = 0
    @Published private(set) var retryAvailable = 0
    @Published private(set) var retryNextAvailableAt: Date?
    @Published private(set) var canStartRetry = false
    @Published private(set) var partialPending = false
    @Published private(set) var conservativeEnabled = true
    @Published private(set) var examReductionEnabled = true
    @Published private(set) var isDualFSRS = false
    @Published private(set) var unseenQuestionCount = 0
    @Published private(set) var newIntroducedToday = 0
    @Published private(set) var planningDay = 0

    private var record: ExamDiskRecord?
    private var priorAttempts: [ExamAttempt] = []
    private var needsClockResume = true
    private var requestedConservative = true
    private let directory: URL
    private let dualWriter: (Data, URL) throws -> Void
    private let clock: () -> Date
    private var dualDisk: PublicDualStoreDisk?
    private var dualDurableSHA256: String?
    private var dualLegacyAnchor: Data?
    private var dualVolumeBytes: [Data] = []
    private var dualDisplayPresentation: ExamPresentation?
    private var banksDirectory: URL { directory.appendingPathComponent("banks", isDirectory: true) }
    private var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var activeURL: URL { directory.appendingPathComponent("active-bank.json") }
    private struct ActiveBank: Codable { let format: Int; let bankSHA256: String }
    /// The old Pocket record remains untouched. A content-addressed anchor and
    /// this independently replayable state make each migration/rebase auditable.
    private struct PublicDualStoreDisk: Codable {
        var format = "xkl-ios-public-dual-store-v1"
        let bankSHA256: String
        let rootLegacySHA256: String
        var state: PublicQuestionDualState
        var priorDualRevisionSHA256s: [String] = []
    }
    private struct PublicDualMarker: Codable {
        let format: String
        let bankSHA256: String
    }
    private struct PublicDualExport: Codable {
        let bankSHA256: String
        let legacyCurrentBytes: Data
        let markerBytes: Data
        let dualCurrentBytes: Data
        let anchors: [String: Data]
        let revisions: [String: Data]
    }
    private struct PublicRecordsExportV3: Codable {
        let format: String
        let exportedAt: Date
        let activeBankSHA256: String?
        let versions: [ExamVersionExport]
        let dualVersions: [PublicDualExport]
    }
    private struct LoadedVersion {
        let bank: ExamBank
        let engine: ExamLearningEngine
        let priorAttempts: [ExamAttempt]
        let volumes: [String: Data]
    }

    init(baseDirectory: URL? = nil, dualWriter: @escaping (Data, URL) throws -> Void = DurableFile.write,
         clock: @escaping () -> Date = Date.init) {
        self.dualWriter = dualWriter
        self.clock = clock
        directory = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("QuestionBank", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: banksDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: activeURL.path) {
                let active = try JSONDecoder().decode(ActiveBank.self, from: Data(contentsOf: activeURL))
                guard active.format == 2, ExamContent.isHash(active.bankSHA256) else {
                    throw ExamError.invalid("当前题库索引无效；原记录已保留。")
                }
                let loaded = try loadVersion(active.bankSHA256)
                bank = loaded.bank; record = loaded.engine.record; priorAttempts = loaded.priorAttempts
                requestedConservative = loaded.engine.record.analysis.conservativeEnabled
                if try attachExistingDual(loaded) == false { try refresh(loaded.engine) }
            }
        } catch { block(error) }
    }

    private func bankURL(_ hash: String) -> URL { banksDirectory.appendingPathComponent(hash + ".xklquestions") }
    private func versionURL(_ hash: String) -> URL { versionsDirectory.appendingPathComponent(hash, isDirectory: true) }
    private func stateURL(_ hash: String) -> URL { versionURL(hash).appendingPathComponent("current-state.json") }
    private func volumesURL(_ hash: String) -> URL { versionURL(hash).appendingPathComponent("volumes", isDirectory: true) }
    private func dualRoot(_ hash: String) -> URL { versionURL(hash).appendingPathComponent("dual-fsrs", isDirectory: true) }
    private func dualURL(_ hash: String) -> URL { dualRoot(hash).appendingPathComponent("current.json") }
    // Keep the sentinel outside the dual-state directory: accidental removal
    // of that whole directory must not look like a never-migrated old bank.
    private func dualMarkerURL(_ hash: String) -> URL { versionURL(hash).appendingPathComponent("dual-fsrs-enabled.json") }
    private func anchorURL(_ hash: String, _ value: String) -> URL { dualRoot(hash).appendingPathComponent("anchors", isDirectory: true).appendingPathComponent(value + ".json") }
    private func dualRevisionURL(_ hash: String, _ value: String) -> URL { dualRoot(hash).appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(value + ".json") }
    private func encoded(_ record: ExamDiskRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }
    private func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count <= 64 * 1_024 * 1_024 else {
            throw ExamError.invalid("题库档案文件无效或异常过大。")
        }
        return try Data(contentsOf: url)
    }

    private func loadVersion(_ hash: String) throws -> LoadedVersion {
        guard ExamContent.isHash(hash) else { throw ExamError.invalid("题库版本标识无效。") }
        let (content, loadedBank) = try ExamContent.load(boundedData(bankURL(hash)))
        guard content.bankSHA256 == hash else { throw ExamError.invalid("题库内容与版本不一致。") }
        // Missing/corrupt state never becomes a fresh empty archive.
        let state = try JSONDecoder().decode(ExamDiskRecord.self, from: boundedData(stateURL(hash)))
        let current = try ExamLearningEngine(bank: loadedBank, hash: hash, record: state)
        var attempts: [ExamAttempt] = [], volumeBytes: [String: Data] = [:]
        for (index, reference) in state.volumes.enumerated() {
            let data = try boundedData(volumesURL(hash).appendingPathComponent(reference.filename))
            guard StudySHA256.hex(data) == reference.sha256 else {
                throw ExamError.invalid("题库历史分卷校验失败，原文件已保留。")
            }
            let closed = try JSONDecoder().decode(ExamDiskRecord.self, from: data)
            let engine = try ExamLearningEngine(bank: loadedBank, hash: hash, record: closed)
            guard closed.volumes == Array(state.volumes.prefix(index)),
                  engine.logBase + 1 == reference.firstSequence,
                  try engine.info.log_records == reference.lastSequence,
                  closed.attempts.count == reference.attemptCount else {
                throw ExamError.invalid("题库分卷顺序或记录数量不一致。")
            }
            attempts += closed.attempts
            if let review = closed.answerReview,
               !attempts.contains(where: { $0 == review.attempt }) {
                throw ExamError.invalid("历史题库结果页找不到对应的完整作答记录。")
            }
            volumeBytes[reference.filename] = data
        }
        let allIDs = (attempts + state.attempts).map(\.id)
        guard Set(allIDs).count == allIDs.count else {
            throw ExamError.invalid("题库逐次记录存在重复，未覆盖原档案。")
        }
        if let review = state.answerReview,
           !(attempts + state.attempts).contains(where: { $0 == review.attempt }) {
            throw ExamError.invalid("题库结果页找不到对应的完整作答记录。")
        }
        return LoadedVersion(bank: loadedBank, engine: current, priorAttempts: attempts, volumes: volumeBytes)
    }

    private func encodedDual(_ value: PublicDualStoreDisk) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Content-addressed archives are never replaced. A partial or conflicting
    /// archive stops migration instead of removing it or inventing a baseline.
    private func writeImmutable(_ bytes: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try boundedData(url) == bytes else { throw ExamError.invalid("题库历史锚点冲突，原记录已保留。") }
            return
        }
        let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) }
        guard fd >= 0 else { throw ExamError.invalid("无法创建题库历史锚点，原记录已保留。") }
        var opened = true
        defer { if opened { Darwin.close(fd) } }
        try bytes.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, ptr.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ExamError.invalid("题库历史锚点未写完整，原记录已保留。") }
                offset += count
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw ExamError.invalid("题库历史锚点未完成持久化。") }
        guard Darwin.close(fd) == 0 else { opened = false; throw ExamError.invalid("题库历史锚点关闭失败。") }
        opened = false
        let directoryFD = parent.path.withCString { Darwin.open($0, O_RDONLY) }
        guard directoryFD >= 0 else { throw ExamError.invalid("无法核对题库历史目录。") }
        defer { Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0, try boundedData(url) == bytes else {
            throw ExamError.invalid("题库历史锚点核验失败，原记录已保留。")
        }
    }

    private func orderedVolumes(_ loaded: LoadedVersion) throws -> [Data] {
        try loaded.engine.record.volumes.map { reference in
            guard let data = loaded.volumes[reference.filename], StudySHA256.hex(data) == reference.sha256 else {
                throw ExamError.invalid("题库历史分卷缺失，原记录已保留。")
            }
            return data
        }
    }

    private func verifyDual(_ disk: PublicDualStoreDisk, loaded: LoadedVersion) throws -> (PublicQuestionDualFSRS, Data, [Data]) {
        let hash = loaded.engine.record.bankSHA256
        guard disk.format == "xkl-ios-public-dual-store-v1", disk.bankSHA256 == hash,
              ExamContent.isHash(disk.rootLegacySHA256), ExamContent.isHash(disk.state.legacyAnchorSHA256),
              Set(disk.priorDualRevisionSHA256s).count == disk.priorDualRevisionSHA256s.count else {
            throw ExamError.invalid("双 FSRS 档案身份无效，原记录已保留。")
        }
        let root = try boundedData(stateURL(hash))
        guard StudySHA256.hex(root) == disk.rootLegacySHA256 else {
            throw ExamError.invalid("旧题库记录在切换后发生变化，已暂停写入并保留双方记录。")
        }
        let anchor = try boundedData(anchorURL(hash, disk.state.legacyAnchorSHA256))
        guard StudySHA256.hex(anchor) == disk.state.legacyAnchorSHA256 else {
            throw ExamError.invalid("旧题库迁移锚点不一致，原记录已保留。")
        }
        for revision in disk.priorDualRevisionSHA256s {
            guard ExamContent.isHash(revision), StudySHA256.hex(try boundedData(dualRevisionURL(hash, revision))) == revision else {
                throw ExamError.invalid("双 FSRS 旧修订档缺失，原记录已保留。")
            }
        }
        let volumes = try orderedVolumes(loaded)
        let model = try PublicQuestionDualFSRS(state: disk.state, bank: loaded.bank, hash: hash)
        try model.validateLegacy(recordBytes: anchor, priorVolumeBytes: volumes)
        return (model, anchor, volumes)
    }

    /// A durable marker distinguishes an intentionally enabled dual store
    /// from an incomplete or externally removed file. Never fall back silently.
    private func ensureDualMarker(_ hash: String) throws {
        let url = dualMarkerURL(hash)
        if FileManager.default.fileExists(atPath: url.path) {
            let marker = try JSONDecoder().decode(PublicDualMarker.self, from: boundedData(url))
            guard marker.format == "xkl-ios-public-dual-enabled-v1", marker.bankSHA256 == hash else {
                throw ExamError.invalid("题库双 FSRS 模式标记不一致，原记录已保留。")
            }
            return
        }
        let marker = PublicDualMarker(format: "xkl-ios-public-dual-enabled-v1", bankSHA256: hash)
        try writeImmutable(JSONEncoder().encode(marker), to: url)
    }

    @discardableResult private func attachExistingDual(_ loaded: LoadedVersion) throws -> Bool {
        let hash = loaded.engine.record.bankSHA256
        let currentExists = FileManager.default.fileExists(atPath: dualURL(hash).path)
        let markerExists = FileManager.default.fileExists(atPath: dualMarkerURL(hash).path)
        guard currentExists else {
            if markerExists { throw ExamError.invalid("双 FSRS 当前记录缺失，旧档和标记已保留，停止写入。") }
            return false
        }
        let raw = try boundedData(dualURL(hash))
        let disk = try JSONDecoder().decode(PublicDualStoreDisk.self, from: raw)
        let (model, anchor, volumes) = try verifyDual(disk, loaded: loaded)
        try ensureDualMarker(hash)
        dualDisk = disk; dualLegacyAnchor = anchor; dualVolumeBytes = volumes
        dualDurableSHA256 = StudySHA256.hex(raw); isDualFSRS = true
        try refreshDual(model)
        return true
    }

    /// Called when the public question bank is opened or started. It records no
    /// new answer; the actual current question, selection and old obligations
    /// are copied into the checked dual state by the migration model.
    func prepareDualFSRSIfNeeded() {
        guard !storageBlocked, !isDualFSRS, let hash = record?.bankSHA256 else { return }
        var attemptedWrite = false
        do {
            let loaded = try loadVersion(hash)
            if try attachExistingDual(loaded) { return }
            let rawLegacy = try boundedData(stateURL(hash))
            let reread = try JSONDecoder().decode(ExamDiskRecord.self, from: rawLegacy)
            guard try encoded(reread) == encoded(loaded.engine.record) else {
                throw ExamError.invalid("题库正在变化，请重新打开后再切换；原记录已保留。")
            }
            let volumes = try orderedVolumes(loaded)
            let now = clock()
            let capture = try PublicDualLegacyCapture.read(snapshot: reread.snapshot, bankCount: loaded.bank.questions.count, now: now)
            let model = try PublicQuestionDualFSRS(migrating: loaded.bank, hash: hash, record: reread,
                legacyRecordBytes: rawLegacy, priorVolumeBytes: volumes,
                legacyTokens: capture.tokens, legacyItems: capture.items, now: now)
            let rootHash = StudySHA256.hex(rawLegacy)
            guard model.state.legacyAnchorSHA256 == rootHash else { throw ExamError.invalid("题库迁移锚点不一致。") }
            let root = dualRoot(hash); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            attemptedWrite = true
            try writeImmutable(rawLegacy, to: anchorURL(hash, rootHash))
            let disk = PublicDualStoreDisk(bankSHA256: hash, rootLegacySHA256: rootHash, state: model.state)
            let bytes = try encodedDual(disk)
            guard !FileManager.default.fileExists(atPath: dualURL(hash).path) else {
                throw ExamError.invalid("题库切换状态已发生变化，请重新打开核对。")
            }
            try dualWriter(bytes, dualURL(hash))
            guard try boundedData(dualURL(hash)) == bytes else { throw ExamError.invalid("双 FSRS 当前记录核验失败。") }
            try ensureDualMarker(hash)
            let verified = try verifyDual(disk, loaded: loaded)
            dualDisk = disk; dualLegacyAnchor = verified.1; dualVolumeBytes = verified.2
            dualDurableSHA256 = StudySHA256.hex(bytes); isDualFSRS = true
            try refreshDual(verified.0); error = nil
        } catch {
            if attemptedWrite { block(error) }
            else { self.error = error.localizedDescription + "\n双 FSRS 尚未启用，原题库记录保留。" }
        }
    }

    func importContent(from url: URL) {
        guard !storageBlocked else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data: Data, content: ExamContent, loadedBank: ExamBank
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= ExamContent.maximumFileBytes else {
                throw ExamError.invalid("题库包超过 20MB 或无法读取。")
            }
            data = try Data(contentsOf: url)
            (content, loadedBank) = try ExamContent.load(data)
        } catch { self.error = error.localizedDescription; return }
        do {
            let destination = bankURL(content.bankSHA256)
            if FileManager.default.fileExists(atPath: destination.path) {
                let (existing, _) = try ExamContent.load(boundedData(destination))
                guard existing.bankBytes == content.bankBytes else {
                    throw ExamError.invalid("同一题库版本存在不同内容。")
                }
            } else {
                try FileManager.default.createDirectory(at: volumesURL(content.bankSHA256), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: stateURL(content.bankSHA256).path) {
                    let old = try JSONDecoder().decode(ExamDiskRecord.self, from: boundedData(stateURL(content.bankSHA256)))
                    _ = try ExamLearningEngine(bank: loadedBank, hash: content.bankSHA256, record: old)
                } else {
                    let fresh = try ExamLearningEngine.fresh(bank: loadedBank, hash: content.bankSHA256)
                    try fresh.setPolicy(requestedConservative)
                    try DurableFile.write(encoded(fresh.record), to: stateURL(content.bankSHA256))
                }
                try DurableFile.write(data, to: destination)
            }
            let loaded = try loadVersion(content.bankSHA256)
            let dualExists = FileManager.default.fileExists(atPath: dualURL(content.bankSHA256).path)
            let markerExists = FileManager.default.fileExists(atPath: dualMarkerURL(content.bankSHA256).path)
            if dualExists {
                let disk = try JSONDecoder().decode(PublicDualStoreDisk.self, from: boundedData(dualURL(content.bankSHA256)))
                _ = try verifyDual(disk, loaded: loaded)
            } else if markerExists {
                throw ExamError.invalid("双 FSRS 当前记录缺失，拒绝用旧题库覆盖。")
            }
            // Reimport of the currently active bank is a verified no-op.
            if isDualFSRS, record?.bankSHA256 == content.bankSHA256 {
                guard dualExists, StudySHA256.hex(try boundedData(dualURL(content.bankSHA256))) == dualDurableSHA256 else {
                    throw ExamError.invalid("题库记录已变化，未覆盖较新的记录。")
                }
                error = nil; return
            }
            try DurableFile.write(try JSONEncoder().encode(ActiveBank(format: 2, bankSHA256: content.bankSHA256)), to: activeURL)
            bank = loaded.bank; record = loaded.engine.record; priorAttempts = loaded.priorAttempts
            needsClockResume = true
            isDualFSRS = false; dualDisk = nil; dualDurableSHA256 = nil
            dualLegacyAnchor = nil; dualVolumeBytes = []; dualDisplayPresentation = nil
            if dualExists { _ = try attachExistingDual(loaded) }
            else { try refresh(loaded.engine) }
            error = nil
            if !isDualFSRS { prepareDualFSRSIfNeeded() }
        } catch { block(error) }
    }

    func start() {
        if !isDualFSRS { prepareDualFSRSIfNeeded() }
        guard isDualFSRS else { return }
        changeDual { try $0.start(now: clock()) }
    }
    func startRetry() {
        guard isDualFSRS, canStartRetry else { return }
        changeDual { try $0.startRetry(now: clock()) }
    }
    func toggleOption(_ id: String, presentationID token: UUID? = nil) {
        guard let token, token == presentationID, !isShowingResult else { return }
        if isDualFSRS { changeDual { try $0.toggle(id, token: token) } }
    }
    func selectAndSubmit(_ id: String, presentationID token: UUID?) {
        guard let token, token == presentationID, !isShowingResult else { return }
        if isDualFSRS { changeDual { try $0.selectAndSubmit(id, presentationID: token, now: clock()) } }
    }
    func submit(presentationID token: UUID? = nil) {
        guard let token, token == presentationID, !isShowingResult else { return }
        if isDualFSRS { changeDual { try $0.submitAutomatically(presentationID: token, now: clock()) } }
    }
    func nextQuestion(presentationID token: UUID? = nil) {
        guard let token, token == presentationID, isShowingResult else { return }
        if isDualFSRS { changeDual { try $0.nextQuestion(presentationID: token, now: clock()) } }
    }
    func markFamiliar() { if isDualFSRS { changeDual { try $0.familiar(now: clock()) } } }
    func undoFamiliar() {
        guard isDualFSRS, let disk = dualDisk, let bank, let anchor = dualLegacyAnchor else { return }
        do {
            let model = try PublicQuestionDualFSRS(state: disk.state, bank: bank, hash: disk.bankSHA256)
            if model.canUndo { changeDual { try $0.undo(now: clock()) } }
            else if model.canUndoLegacy { try rebaseLegacyUndo(disk: disk, bank: bank, anchor: anchor) }
        } catch { self.error = error.localizedDescription }
    }
    func setPolicy(conservative enabled: Bool) {
        requestedConservative = enabled
        // RootView may synchronize settings before opening the bank. Migrate
        // first and never alter the original scheduler as a side effect.
        if !isDualFSRS { prepareDualFSRSIfNeeded() }
    }
    func setExamReduction(enabled: Bool) {
        if !isDualFSRS { prepareDualFSRSIfNeeded() }
    }
    func refreshStudyDate() {
        guard !storageBlocked, record != nil else { return }
        if !isDualFSRS { prepareDualFSRSIfNeeded() }
        guard isDualFSRS, let disk = dualDisk, let bank else { return }
        do { try refreshDual(PublicQuestionDualFSRS(state: disk.state, bank: bank, hash: disk.bankSHA256)) }
        catch { self.error = error.localizedDescription }
    }
    func displayLabel(for optionID: String) -> String {
        ExamPresentation.label(optionID,
            in: (isDualFSRS ? dualDisplayPresentation : (record?.answerReview?.presentation ?? record?.presentation))?.optionOrder ?? [])
    }

    /// A dual operation starts from the last durable, validated state. A stale
    /// writer is stopped rather than replacing newer progress from another view.
    private func changeDual(_ operation: (PublicQuestionDualFSRS) throws -> Void) {
        guard !storageBlocked, let disk = dualDisk, let bank, let expected = dualDurableSHA256 else { return }
        var attemptedWrite = false
        do {
            let current = try boundedData(dualURL(disk.bankSHA256))
            guard StudySHA256.hex(current) == expected,
                  StudySHA256.hex(try boundedData(stateURL(disk.bankSHA256))) == disk.rootLegacySHA256 else {
                throw ExamError.invalid("题库记录已在别处变化，未覆盖较新的记录。")
            }
            let candidate = try PublicQuestionDualFSRS(state: disk.state, bank: bank, hash: disk.bankSHA256)
            try operation(candidate)
            _ = try candidate.stats(now: clock())
            var next = disk; next.state = candidate.state
            let bytes = try encodedDual(next)
            if bytes != current {
                guard StudySHA256.hex(try boundedData(dualURL(disk.bankSHA256))) == expected,
                      StudySHA256.hex(try boundedData(stateURL(disk.bankSHA256))) == disk.rootLegacySHA256 else {
                    throw ExamError.invalid("题库记录已在别处变化，未覆盖较新的记录。")
                }
                attemptedWrite = true
                try dualWriter(bytes, dualURL(disk.bankSHA256))
                guard try boundedData(dualURL(disk.bankSHA256)) == bytes else {
                    throw ExamError.invalid("题库新记录核验失败，已暂停写入。")
                }
            }
            dualDisk = next; dualDurableSHA256 = StudySHA256.hex(bytes)
            try refreshDual(candidate); error = nil
        } catch {
            if attemptedWrite { block(error) } else { self.error = error.localizedDescription }
        }
    }

    /// Only before a dual answer/familiar action, undo the real old action on
    /// a clone; archive both the new Pocket anchor and previous dual revision.
    /// The original current-state.json and old volumes are never overwritten.
    private func rebaseLegacyUndo(disk: PublicDualStoreDisk, bank: ExamBank, anchor: Data) throws {
        guard !storageBlocked, let expected = dualDurableSHA256 else { return }
        let current = try boundedData(dualURL(disk.bankSHA256))
        guard StudySHA256.hex(current) == expected,
              StudySHA256.hex(try boundedData(stateURL(disk.bankSHA256))) == disk.rootLegacySHA256 else {
            throw ExamError.invalid("题库记录已在别处变化，未覆盖较新的记录。")
        }
        let model = try PublicQuestionDualFSRS(state: disk.state, bank: bank, hash: disk.bankSHA256)
        try model.validateLegacy(recordBytes: anchor, priorVolumeBytes: dualVolumeBytes)
        guard model.canUndoLegacy else { return }
        let oldRecord = try JSONDecoder().decode(ExamDiskRecord.self, from: anchor)
        let old = try ExamLearningEngine(bank: bank, hash: disk.bankSHA256, record: oldRecord)
        guard try old.info.can_undo != 0, old.record.lastUndoableAttemptID != nil else {
            throw ExamError.invalid("旧题库的撤销状态无法核对，原记录已保留。")
        }
        let now = clock()
        // A result already closed in the dual view may still be present in the
        // immutable original anchor. Close it only in this private clone; the
        // old engine does not allow undo while its result page remains open.
        if let review = old.record.answerReview {
            try old.nextQuestion(presentationID: review.presentation.id, now: now)
            guard old.record.answerReview == nil else { throw ExamError.invalid("无法关闭旧题库结果页，原记录已保留。") }
        }
        try old.undo(now: now)
        guard old.record.lastUndoableAttemptID == nil else { throw ExamError.invalid("旧题库撤销未生效。") }
        let newAnchor = try encoded(old.record), anchorHash = StudySHA256.hex(newAnchor)
        let capture = try PublicDualLegacyCapture.read(snapshot: old.record.snapshot, bankCount: bank.questions.count, now: now)
        let rebased = try PublicQuestionDualFSRS(migrating: bank, hash: disk.bankSHA256, record: old.record,
            legacyRecordBytes: newAnchor, priorVolumeBytes: dualVolumeBytes,
            legacyTokens: capture.tokens, legacyItems: capture.items, now: now)
        guard rebased.state.legacyAnchorSHA256 == anchorHash else { throw ExamError.invalid("撤销后的迁移锚点不一致。") }
        try writeImmutable(newAnchor, to: anchorURL(disk.bankSHA256, anchorHash))
        let revisionHash = StudySHA256.hex(current)
        try writeImmutable(current, to: dualRevisionURL(disk.bankSHA256, revisionHash))
        var next = disk; next.state = rebased.state
        if !next.priorDualRevisionSHA256s.contains(revisionHash) { next.priorDualRevisionSHA256s.append(revisionHash) }
        let bytes = try encodedDual(next)
        guard StudySHA256.hex(try boundedData(dualURL(disk.bankSHA256))) == expected,
              StudySHA256.hex(try boundedData(stateURL(disk.bankSHA256))) == disk.rootLegacySHA256 else {
            throw ExamError.invalid("题库记录已在别处变化，未覆盖较新的记录。")
        }
        do {
            try dualWriter(bytes, dualURL(disk.bankSHA256))
            guard try boundedData(dualURL(disk.bankSHA256)) == bytes else {
                throw ExamError.invalid("撤销后的双 FSRS 记录核验失败。")
            }
            let verified = try verifyDual(next, loaded: loadVersion(disk.bankSHA256))
            dualDisk = next; dualLegacyAnchor = verified.1; dualVolumeBytes = verified.2
            dualDurableSHA256 = StudySHA256.hex(bytes)
            try refreshDual(verified.0); error = nil
        } catch { block(error) }
    }

    private func refreshDual(_ model: PublicQuestionDualFSRS) throws {
        let now = clock(), stats = try model.stats(now: now), p = model.displayPresentation
        bank = model.bank; dualDisplayPresentation = p
        currentQuestion = model.displayQuestion; presentationID = p?.id
        selectedOptionIDs = Set(p?.selectedOptionIDs ?? [])
        let options = Dictionary(uniqueKeysWithValues: (currentQuestion?.options ?? []).map { ($0.id, $0) })
        shuffledOptions = (p?.optionOrder ?? []).compactMap { options[$0] }
        latestAttempt = model.displayAttempt
        pendingGrade = model.displayAttempt.map { $0.isCorrect ? 0 : 1 }
        isShowingResult = model.isShowingResult; isRevealed = isShowingResult
        supplementVisible = p?.supplementVisible ?? false
        sessionIsActive = model.presentation != nil || isShowingResult
        sessionCount = stats.sessionCount; sessionPosition = stats.sessionPosition
        sessionIsComplete = !sessionIsActive && stats.sessionCount > 0
        sections = model.bank.sections; stage = 0; partialPending = false
        newRemaining = stats.newRemaining; reviewRemaining = stats.reviewRemaining
        totalRemaining = stats.totalRemaining; dueTodayCount = stats.dueTodayCount
        reinforcementRemaining = stats.reinforcementRemaining
        carryRemaining = stats.carryRemaining
        retryAvailable = stats.retryAvailable; retryNextAvailableAt = stats.retryNextAvailableAt
        canStartRetry = stats.retryAvailable > 0 && model.state.queue.isEmpty &&
            model.presentation == nil && !isShowingResult && !storageBlocked
        canMarkFamiliar = model.presentation != nil && !isShowingResult && !storageBlocked
        canUndo = (model.canUndo || model.canUndoLegacy) && !storageBlocked
        totalAnsweredCount = stats.totalAnsweredCount; wrongCount = stats.wrongCount
        unseenQuestionCount = stats.unseenQuestionCount; newIntroducedToday = stats.newIntroducedToday
        planningDay = Int(try Self.studyDay(now))
    }

    private func change(_ operation: (ExamLearningEngine) throws -> Void) {
        guard !storageBlocked, !isDualFSRS, let bank, let record else { return }
        var didWrite = false
        do {
            let candidate = try ExamLearningEngine(bank: bank, hash: record.bankSHA256, record: record)
            var newlyArchived: [ExamAttempt] = []
            let info = try candidate.info
            if candidate.volumeRecords >= info.log_capacity - 64 ||
                (candidate.record.attempts.count >= 5_000 && candidate.volumeRecords > 0) {
                let bytes = try encoded(candidate.record), hash = StudySHA256.hex(bytes)
                let destination = volumesURL(record.bankSHA256).appendingPathComponent(hash + ".json")
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard try boundedData(destination) == bytes else { throw ExamError.invalid("历史题库分卷校验失败。") }
                } else {
                    didWrite = true
                    try DurableFile.write(bytes, to: destination)
                }
                newlyArchived = candidate.record.attempts
                try candidate.rotate(reference: ExamVolumeReference(filename: hash + ".json", sha256: hash,
                    firstSequence: candidate.logBase + 1, lastSequence: info.log_records, attemptCount: newlyArchived.count))
            }
            let today = try Self.studyDay(clock()), ready = try candidate.info
            if ready.has_task != 0 &&
                (needsClockResume || ready.day != today || ready.selection_day != today) {
                try candidate.start(day: today)
            }
            try operation(candidate)
            _ = try ExamLearningEngine(bank: bank, hash: record.bankSHA256, record: candidate.record)
            didWrite = true
            try DurableFile.write(encoded(candidate.record), to: stateURL(record.bankSHA256))
            self.record = candidate.record; priorAttempts += newlyArchived; needsClockResume = false
            try refresh(candidate); error = nil
        } catch {
            if didWrite { block(error) } else { self.error = error.localizedDescription }
        }
    }

    private func refresh(_ engine: ExamLearningEngine) throws {
        let info = try engine.info, p = engine.displayPresentation
        carryRemaining = 0; retryAvailable = 0; retryNextAvailableAt = nil; canStartRetry = false
        if let day = try? Self.studyDay(clock()) {
            dueTodayCount = engine.dueCount(on: day)
        }
        bank = engine.bank; currentQuestion = engine.displayQuestion; presentationID = p?.id
        selectedOptionIDs = Set(p?.selectedOptionIDs ?? [])
        let options = Dictionary(uniqueKeysWithValues: (currentQuestion?.options ?? []).map { ($0.id, $0) })
        shuffledOptions = (p?.optionOrder ?? []).compactMap { options[$0] }
        latestAttempt = engine.displayAttempt; pendingGrade = engine.pendingGrade
        isShowingResult = engine.isShowingResult; isRevealed = isShowingResult
        supplementVisible = p?.supplementVisible ?? false
        sessionIsActive = info.has_task != 0 || isShowingResult; sessionCount = Int(info.completed + info.total_remaining)
        sessionIsComplete = !sessionIsActive && sessionCount > 0
        sessionPosition = sessionCount == 0 ? 0 : min(max(1, Int(info.completed) + (isShowingResult ? 0 : 1)), sessionCount)
        sections = engine.bank.sections
        stage = isShowingResult ? 0 : Int(info.stage)
        newRemaining = Int(info.new_remaining); reviewRemaining = Int(info.review_remaining)
        totalRemaining = Int(info.total_remaining); partialPending = !isShowingResult && info.partial_pending != 0
        if isShowingResult { reinforcementRemaining = 0 }
        else { reinforcementRemaining = try engine.reinforcementRemaining }
        canMarkFamiliar = sessionIsActive && !isRevealed && !storageBlocked
        canUndo = info.can_undo != 0 && !isShowingResult && engine.record.lastUndoableAttemptID != nil && !storageBlocked
        conservativeEnabled = engine.record.analysis.conservativeEnabled; examReductionEnabled = engine.record.examReductionEnabled
        let all = priorAttempts + engine.record.attempts, undone = Set((priorAttempts + engine.record.attempts).compactMap(\.undoneAttemptID))
        var latest: [String: ExamAttempt] = [:]
        for attempt in all where attempt.mode != "undo" && !undone.contains(attempt.id) { latest[attempt.questionID] = attempt }
        totalAnsweredCount = latest.count
        wrongCount = latest.values.filter { $0.mode == "answer" && !$0.isCorrect }.count
        refreshPlanningCounts()
    }

    /// Coverage is not mastery: a first graded answer or explicit familiar
    /// action covers a question. Undone actions are excluded. No card is edited.
    private func refreshPlanningCounts() {
        guard let bank, let record, let day = try? Self.studyDay(clock()) else { return }
        let all = priorAttempts + record.attempts
        let undone = Set(all.compactMap(\.undoneAttemptID))
        var first: [String: ExamAttempt] = [:]
        for attempt in all where attempt.mode != "undo" && !undone.contains(attempt.id) {
            if first[attempt.questionID] == nil { first[attempt.questionID] = attempt }
        }
        planningDay = Int(day)
        unseenQuestionCount = max(0, bank.questions.count - first.count)
        newIntroducedToday = first.values.filter {
            (try? Self.studyDay($0.answeredAt)) == day
        }.count
    }
    private func block(_ failure: Error) {
        storageBlocked = true; canMarkFamiliar = false; canUndo = false
        error = failure.localizedDescription + "\n题库写入已暂停。请重新打开应用核对；不会重置题库记录，也不会影响背词记录。"
    }

    func exportRecords() throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(at: banksDirectory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { !$0.lastPathComponent.hasPrefix(".pending-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var versions: [ExamVersionExport] = [], dualVersions: [PublicDualExport] = []
        for file in files {
            guard file.pathExtension == "xklquestions", try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ExamError.invalid("题库目录存在无法核对的文件，未导出不完整记录。")
            }
            let hash = file.deletingPathExtension().lastPathComponent, loaded = try loadVersion(hash)
            versions.append(ExamVersionExport(bankSHA256: hash, bank: loaded.bank,
                attempts: loaded.priorAttempts + loaded.engine.record.attempts, activeRecord: loaded.engine.record, volumeBytes: loaded.volumes))
            let hasCurrent = FileManager.default.fileExists(atPath: dualURL(hash).path)
            let hasMarker = FileManager.default.fileExists(atPath: dualMarkerURL(hash).path)
            guard hasCurrent == hasMarker else { throw ExamError.invalid("双 FSRS 记录不完整，未导出不完整档案。") }
            if hasCurrent {
                let current = try boundedData(dualURL(hash))
                let disk = try JSONDecoder().decode(PublicDualStoreDisk.self, from: current)
                _ = try verifyDual(disk, loaded: loaded)
                let marker = try boundedData(dualMarkerURL(hash))
                let decodedMarker = try JSONDecoder().decode(PublicDualMarker.self, from: marker)
                guard decodedMarker.format == "xkl-ios-public-dual-enabled-v1", decodedMarker.bankSHA256 == hash else {
                    throw ExamError.invalid("双 FSRS 标记不一致，未导出不完整档案。")
                }
                var anchors: [String: Data] = [:], revisions: [String: Data] = [:]
                for revisionHash in disk.priorDualRevisionSHA256s {
                    let bytes = try boundedData(dualRevisionURL(hash, revisionHash))
                    guard StudySHA256.hex(bytes) == revisionHash else { throw ExamError.invalid("题库历史修订校验失败。") }
                    revisions[revisionHash] = bytes
                    let oldDisk = try JSONDecoder().decode(PublicDualStoreDisk.self, from: bytes)
                    guard oldDisk.bankSHA256 == hash, oldDisk.rootLegacySHA256 == disk.rootLegacySHA256 else {
                        throw ExamError.invalid("题库历史修订身份不一致。")
                    }
                    let anchorHash = oldDisk.state.legacyAnchorSHA256
                    guard ExamContent.isHash(anchorHash) else { throw ExamError.invalid("题库历史锚点无效。") }
                    let archivedAnchor = try boundedData(anchorURL(hash, anchorHash))
                    guard StudySHA256.hex(archivedAnchor) == anchorHash else { throw ExamError.invalid("题库历史锚点校验失败。") }
                    anchors[anchorHash] = archivedAnchor
                }
                let anchorHash = disk.state.legacyAnchorSHA256
                let anchor = try boundedData(anchorURL(hash, anchorHash))
                guard StudySHA256.hex(anchor) == anchorHash else { throw ExamError.invalid("题库迁移锚点校验失败。") }
                anchors[anchorHash] = anchor
                let legacyCurrent = try boundedData(stateURL(hash))
                dualVersions.append(PublicDualExport(bankSHA256: hash, legacyCurrentBytes: legacyCurrent,
                    markerBytes: marker, dualCurrentBytes: current, anchors: anchors, revisions: revisions))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if !dualVersions.isEmpty {
            return try encoder.encode(PublicRecordsExportV3(format: "xkl-ios-question-records-v3",
                exportedAt: clock(), activeBankSHA256: record?.bankSHA256, versions: versions, dualVersions: dualVersions))
        }
        return try encoder.encode(ExamRecordsExport(format: "xkl-ios-question-records-v2",
            exportedAt: clock(), activeBankSHA256: record?.bankSHA256, versions: versions))
    }
    static func studyDay(_ date: Date) throws -> UInt32 {
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = utc.date(from: local.dateComponents([.year, .month, .day], from: date)) else {
            throw ExamError.invalid("无法解析学习日期。")
        }
        let day = Int(midnight.timeIntervalSince1970 / 86_400)
        guard (18_000...50_000).contains(day) else { throw ExamError.invalid("请检查手机日期。") }
        return UInt32(day)
    }
}
