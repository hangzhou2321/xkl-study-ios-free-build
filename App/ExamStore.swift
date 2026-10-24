import Foundation
import Combine
import StudyCore

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
    @Published private(set) var partialPending = false
    @Published private(set) var conservativeEnabled = true
    @Published private(set) var examReductionEnabled = true
    @Published private(set) var unseenQuestionCount = 0
    @Published private(set) var newIntroducedToday = 0
    @Published private(set) var planningDay = 0

    private var record: ExamDiskRecord?
    private var priorAttempts: [ExamAttempt] = []
    private var needsClockResume = true
    private var requestedConservative = true
    private let directory: URL
    private var banksDirectory: URL { directory.appendingPathComponent("banks", isDirectory: true) }
    private var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var activeURL: URL { directory.appendingPathComponent("active-bank.json") }
    private struct ActiveBank: Codable { let format: Int; let bankSHA256: String }
    private struct LoadedVersion {
        let bank: ExamBank
        let engine: ExamLearningEngine
        let priorAttempts: [ExamAttempt]
        let volumes: [String: Data]
    }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
                try refresh(loaded.engine)
            }
        } catch { block(error) }
    }

    private func bankURL(_ hash: String) -> URL { banksDirectory.appendingPathComponent(hash + ".xklquestions") }
    private func versionURL(_ hash: String) -> URL { versionsDirectory.appendingPathComponent(hash, isDirectory: true) }
    private func stateURL(_ hash: String) -> URL { versionURL(hash).appendingPathComponent("current-state.json") }
    private func volumesURL(_ hash: String) -> URL { versionURL(hash).appendingPathComponent("volumes", isDirectory: true) }
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
            try loaded.engine.setPolicy(requestedConservative)
            try DurableFile.write(encoded(loaded.engine.record), to: stateURL(content.bankSHA256))
            try DurableFile.write(try JSONEncoder().encode(ActiveBank(format: 2, bankSHA256: content.bankSHA256)), to: activeURL)
            bank = loaded.bank; record = loaded.engine.record; priorAttempts = loaded.priorAttempts
            needsClockResume = true
            try refresh(loaded.engine); error = nil
        } catch { block(error) }
    }

    func start() {
        change {
            if try $0.info.has_task == 0 { try $0.start(day: Self.studyDay(Date())) }
        }
    }
    func toggleOption(_ id: String, presentationID token: UUID? = nil) {
        guard let token, token == presentationID, !isShowingResult else { return }
        change { try $0.toggle(id) }
    }
    func selectAndSubmit(_ id: String, presentationID token: UUID?) {
        guard let token, token == presentationID, !isShowingResult else { return }
        change { try $0.selectAndSubmit(id, presentationID: token) }
    }
    func submit(presentationID token: UUID? = nil) {
        guard let token, token == presentationID, !isShowingResult else { return }
        change { try $0.submitAutomatically(presentationID: token) }
    }
    func nextQuestion(presentationID token: UUID? = nil) {
        guard let token, token == presentationID, isShowingResult else { return }
        change { try $0.nextQuestion(presentationID: token) }
    }
    func markFamiliar() { change { try $0.familiar() } }
    func undoFamiliar() { change { try $0.undo() } }
    func setPolicy(conservative enabled: Bool) {
        requestedConservative = enabled
        guard record?.analysis.conservativeEnabled != enabled else { return }
        change { try $0.setPolicy(enabled) }
    }
    func setExamReduction(enabled: Bool) {
        guard record?.examReductionEnabled != enabled else { return }
        change { $0.setExamReduction(enabled) }
    }
    func refreshStudyDate() {
        guard !storageBlocked, let record else { return }
        do {
            let snapshot = try PocketEngine(snapshot: record.snapshot)
            let info = try snapshot.info, today = try Self.studyDay(Date())
            dueTodayCount = snapshot.dueCount(on: today, limit: bank?.questions.count ?? 0)
            guard today >= info.day else { throw ExamError.invalid("手机日期早于已有题库记录，请核对时间。") }
            if info.has_task != 0 && (today != info.day || today != info.selection_day) {
                change { _ in } // The existing candidate transaction reconciles the date.
            }
        } catch { self.error = error.localizedDescription }
        refreshPlanningCounts()
    }
    func displayLabel(for optionID: String) -> String {
        ExamPresentation.label(optionID,
            in: (record?.answerReview?.presentation ?? record?.presentation)?.optionOrder ?? [])
    }

    private func change(_ operation: (ExamLearningEngine) throws -> Void) {
        guard !storageBlocked, let bank, let record else { return }
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
            let today = try Self.studyDay(Date()), ready = try candidate.info
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
        if let day = try? Self.studyDay(Date()) {
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
        guard let bank, let record, let day = try? Self.studyDay(Date()) else { return }
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
        var versions: [ExamVersionExport] = []
        for file in files {
            guard file.pathExtension == "xklquestions", try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ExamError.invalid("题库目录存在无法核对的文件，未导出不完整记录。")
            }
            let hash = file.deletingPathExtension().lastPathComponent, loaded = try loadVersion(hash)
            versions.append(ExamVersionExport(bankSHA256: hash, bank: loaded.bank,
                attempts: loaded.priorAttempts + loaded.engine.record.attempts, activeRecord: loaded.engine.record, volumeBytes: loaded.volumes))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(ExamRecordsExport(format: "xkl-ios-question-records-v2",
            exportedAt: Date(), activeBankSHA256: record?.bankSHA256, versions: versions))
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
