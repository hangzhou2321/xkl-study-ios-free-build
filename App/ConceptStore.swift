import Foundation
import Combine
import StudyCore

@MainActor
final class ConceptStore: ObservableObject {
    let subject: ConceptSubject
    @Published private(set) var engine: ConceptEngine?
    @Published private(set) var teaching: ConceptTeaching?
    @Published private(set) var coachingEvents: [ConceptCoachingEvent] = []
    @Published private(set) var guidance: ConceptGuidanceRecord?
    private var guidanceStore: ConceptGuidanceStore?
    @Published private(set) var blocked = false
    @Published var error: String?
    private var teachingHash: String?
    private var coaching: ConceptCoachingRecord?
    private let directory: URL
    private let write: (Data, URL) throws -> Void
    private var activeURL: URL { directory.appendingPathComponent("active.json") }

    init(subject: ConceptSubject = .computer, baseDirectory: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.subject = subject
        self.write = writer
        directory = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent(subject.directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let guidance = try ConceptGuidanceStore(directory: directory, subject: subject, writer: writer)
            guidanceStore = guidance
            self.guidance = guidance.record
            if FileManager.default.fileExists(atPath: activeURL.path) {
                let hash = try JSONDecoder().decode(String.self, from: bounded(activeURL))
                var loaded = try load(hash).engine
                try loadSupport(loaded)
                try applyPracticeHolds(to: &loaded, persist: true)
                engine = loaded
            }
        } catch { fail(error) }
    }

    private func folder(_ hash: String) throws -> URL {
        guard ExamContent.isHash(hash) else { throw ExamError.invalid("考点档案路径标识无效。") }
        return directory.appendingPathComponent(hash, isDirectory: true)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func bounded(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 64 * 1_024 * 1_024 else {
            throw ExamError.invalid("考点档案大小异常。")
        }
        return try Data(contentsOf: url)
    }
    private func load(_ hash: String) throws -> (engine: ConceptEngine, volumes: [String: Data]) {
        let base = try folder(hash)
        let (pack, bank) = try ConceptContent.load(bounded(base.appendingPathComponent("content.xklconcepts")))
        guard pack.bankSHA256 == hash, bank.id == subject.bankID else {
            throw ExamError.invalid("考点题库版本或科目不一致。")
        }
        let record = try JSONDecoder().decode(ConceptRecord.self, from: bounded(base.appendingPathComponent("current.json")))
        let current = try ConceptEngine(bank: bank, hash: hash, record: record)
        var volumes: [String: Data] = [:], all: [ConceptAttempt] = []
        for (index, ref) in record.volumes.enumerated() {
            let bytes = try bounded(base.appendingPathComponent("volumes/\(ref.sha256).json"))
            guard StudySHA256.hex(bytes) == ref.sha256 else { throw ExamError.invalid("考点历史卷校验失败。") }
            let closed = try JSONDecoder().decode(ConceptRecord.self, from: bytes)
            try closed.validate(bank: bank, hash: hash)
            guard closed.volumes == Array(record.volumes.prefix(index)),
                  closed.attempts.count == ref.count,
                  closed.attempts.first?.sequence == ref.first,
                  closed.attempts.last?.sequence == ref.last else {
                throw ExamError.invalid("考点历史卷边界不一致。")
            }
            all += closed.attempts
            volumes[ref.sha256] = bytes
        }
        all += record.attempts
        var replay: [String: ConceptProgress] = [:]
        var identifiers = Set<UUID>()
        for (index, attempt) in all.enumerated() {
            guard attempt.sequence == index + 1, identifiers.insert(attempt.id).inserted,
                  attempt.before == (replay[attempt.presentation.conceptID] ?? ConceptProgress()) else {
                throw ExamError.invalid("考点逐次记录存在缺失或进度不连续。")
            }
            if attempt.mode == "undo" {
                guard index > 0, let previous = all.prefix(index).last,
                      previous.mode == "familiar", previous.id == attempt.undoTarget,
                      previous.presentation.conceptID == attempt.presentation.conceptID,
                      attempt.after == previous.before else { throw ExamError.invalid("考点撤销记录不一致。") }
            }
            replay[attempt.presentation.conceptID] = attempt.after
        }
        guard replay == record.progress else { throw ExamError.invalid("考点进度与保存的轨迹不一致。") }
        if let review = record.review {
            guard all.last == review else { throw ExamError.invalid("结果页与最近一次记录不一致。") }
        }
        if let undo = record.undoFamiliar {
            guard all.last == undo else { throw ExamError.invalid("熟悉撤销引用缺失。") }
        }
        let attemptsByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for suspended in record.scopeSuspensions ?? [] {
            for saved in [suspended.review, suspended.undoFamiliar].compactMap({ $0 }) {
                guard attemptsByID[saved.id] == saved else {
                    throw ExamError.invalid("停用考点保存的断点与历史作答不一致。")
                }
            }
        }
        return (current, volumes)
    }

    func importContent(_ url: URL) {
        guard !blocked else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var wrote = false
        do {
            let input = try bounded(url)
            struct Header: Decodable { let format: String }
            let header = try JSONDecoder().decode(Header.self, from: input)
            let bytes: Data
            let importedTeaching: ConceptTeaching?
            if ["xkl-course-v1", "xkl-course-v2", "xkl-course-v3", "xkl-course-v4", "xkl-course-v5", "xkl-course-v6", "xkl-course-v7"].contains(header.format) {
                let (course, _) = try ConceptCourse.load(input, subject: subject)
                bytes = course.bankContent
                importedTeaching = course.teaching
            } else {
                bytes = input
                importedTeaching = nil
            }
            let (pack, bank) = try ConceptContent.load(bytes)
            guard bank.id == subject.bankID else {
                throw ExamError.invalid("请在对应科目中导入题库。")
            }
            if let importedTeaching, importedTeaching.hasProfessionalExtension {
                if engine == nil {
                    // Missing active pointer is not proof of a fresh installation. Never guess a bank.
                    let children = try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey])
                    let evidenceNames = ["content.xklconcepts", "current.json", "migration.json",
                        "teaching-active.json", Self.professionalMarkerName]
                    for child in children where ExamContent.isHash(child.lastPathComponent) {
                        if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                           evidenceNames.contains(where: { FileManager.default.fileExists(atPath: child.appendingPathComponent($0).path) }) {
                            throw ExamError.invalid("已有课程内容或进度但当前课程索引缺失，停止导入并保留原档案；不会猜测版本或新建空进度。")
                        }
                    }
                }
                guard let primary = importedTeaching.primaryRecallDeck else {
                    throw ExamError.invalid("专业课v5缺少冻结主卡组，停止导入。")
                }
                // Read-only evidence check also applies when no Concept engine has been loaded.
                _ = try RecallStore.preflightPrimary(subject: subject, deck: primary,
                    baseDirectory: directory.deletingLastPathComponent())
            }
            if teaching?.hasProfessionalExtension == true && importedTeaching?.hasProfessionalExtension != true {
                throw ExamError.invalid("当前已是专业课v5，请导入完整v5课程；不能降级教学或单独替换题库，原进度保留。")
            }
            // Validate immutable primary recall identity BEFORE creating directories, migration or pointers.
            if let existing = engine, let importedTeaching, importedTeaching.hasProfessionalExtension {
                guard let oldTeaching = teaching else {
                    throw ExamError.invalid("当前课程缺少可核对的旧主卡组，停止升级，原记录保留。")
                }
                try importedTeaching.validateAppendOnlyRecall(from: oldTeaching, bank: existing.bank)
                let oldIDs = Set(existing.bank.concepts.flatMap(\.questions).map(\.id))
                let addedIDs = Set(bank.concepts.flatMap(\.questions).map(\.id)).subtracting(oldIDs)
                let presented = Set((importedTeaching.questionPresentations ?? []).map(\.questionID))
                guard addedIDs.isSubset(of: presented) else {
                    throw ExamError.invalid("新增题缺少核验后的题级呈现契约，停止升级。")
                }
            }
            let base = try folder(pack.bankSHA256)
            let content = base.appendingPathComponent("content.xklconcepts")
            let state = base.appendingPathComponent("current.json")
            if let existing = engine, existing.record.bankSHA256 != pack.bankSHA256 {
                try bank.validateAppendOnly(from: existing.bank)
                wrote = true
                try migrateAppendOnly(from: existing.record.bankSHA256, bytes: bytes,
                                      bank: bank, hash: pack.bankSHA256)
            }
            if FileManager.default.fileExists(atPath: content.path) {
                guard try bounded(content) == bytes else { throw ExamError.invalid("已有题库内容不一致。") }
            } else {
                try FileManager.default.createDirectory(at: base.appendingPathComponent("volumes"), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: state.path) {
                    let old = try JSONDecoder().decode(ConceptRecord.self, from: bounded(state))
                    _ = try ConceptEngine(bank: bank, hash: pack.bankSHA256, record: old)
                } else {
                    let fresh = try ConceptEngine(bank: bank, hash: pack.bankSHA256)
                    wrote = true
                    try write(encode(fresh.record), state)
                }
                wrote = true
                try write(bytes, content)
            }
            var loaded = try load(pack.bankSHA256).engine
            if let importedTeaching {
                let data = try encode(importedTeaching), hash = StudySHA256.hex(data)
                let teachingFolder = base.appendingPathComponent("teaching", isDirectory: true)
                try FileManager.default.createDirectory(at: teachingFolder, withIntermediateDirectories: true)
                let target = teachingFolder.appendingPathComponent(hash + ".json")
                wrote = true
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try bounded(target) == data else { throw ExamError.invalid("已有教学版本不同。") }
                } else { try write(data, target) }
                try write(encode(hash), base.appendingPathComponent("teaching-active.json"))
            }
            // Validate and persist the required marker before switching active bank or publishing support.
            let checkedSupport = try readSupport(loaded)
            try ensureProfessionalMarker(loaded, lesson: checkedSupport.lesson)
            wrote = true
            try write(encode(pack.bankSHA256), activeURL)
            try loadSupport(loaded)
            try applyPracticeHolds(to: &loaded, persist: true)
            engine = loaded
            error = nil
        } catch {
            if wrote { fail(error) } else { self.error = error.localizedDescription }
        }
    }

    private struct ProfessionalRequiredMarker: Codable {
        var format = "xkl-professional-v5-required-v1"
        let bankSHA256: String
    }
    private static let professionalMarkerName = "professional-v5-required.json"
    private func ensureProfessionalMarker(_ e: ConceptEngine, lesson: ConceptTeaching?) throws {
        guard lesson?.hasProfessionalExtension == true else { return }
        let path = try folder(e.record.bankSHA256).appendingPathComponent(Self.professionalMarkerName)
        if !FileManager.default.fileExists(atPath: path.path) {
            try write(encode(ProfessionalRequiredMarker(bankSHA256: e.record.bankSHA256)), path)
        }
        let marker = try JSONDecoder().decode(ProfessionalRequiredMarker.self, from: bounded(path))
        guard marker.format == "xkl-professional-v5-required-v1", marker.bankSHA256 == e.record.bankSHA256 else {
            throw ExamError.invalid("专业课v5保护标识不一致，已停止写入。")
        }
    }

    private struct UpgradeReceipt: Codable {
        var format = "xkl-concept-upgrade-v1"
        let fromBankSHA256: String
        let toBankSHA256: String
        let sourceFilesSHA256: [String: String]
        let targetStateSHA256: String
        let targetCoachingSHA256: String?
        let createdAt: Date
    }

    /// Copy-on-upgrade: the source directory is never changed or removed.
    private func migrateAppendOnly(from oldHash: String, bytes: Data, bank: ConceptBank, hash: String) throws {
        let oldBase = try folder(oldHash), target = try folder(hash)
        let old = try load(oldHash), support = try readSupport(old.engine)
        try bank.validateAppendOnly(from: old.engine.bank)
        let oldContent = try bounded(oldBase.appendingPathComponent("content.xklconcepts"))
        let oldState = try bounded(oldBase.appendingPathComponent("current.json"))
        var sourceFiles = support.files
        sourceFiles["content.xklconcepts"] = oldContent
        sourceFiles["current.json"] = oldState
        for (digest, data) in old.volumes { sourceFiles["volumes/\(digest).json"] = data }
        let sourceHashes = sourceFiles.mapValues { StudySHA256.hex($0) }
        if FileManager.default.fileExists(atPath: target.path) {
            let receipt = try JSONDecoder().decode(UpgradeReceipt.self,
                from: bounded(target.appendingPathComponent("migration.json")))
            guard receipt.format == "xkl-concept-upgrade-v1",
                  receipt.fromBankSHA256 == oldHash, receipt.toBankSHA256 == hash,
                  StudySHA256.hex(try bounded(target.appendingPathComponent("current.json"))) == receipt.targetStateSHA256,
                  try bounded(target.appendingPathComponent("content.xklconcepts")) == bytes else {
                throw ExamError.invalid("已有更新版本与当前进度不一致，两份档案均已保留。")
            }
            if let expected = receipt.targetCoachingSHA256 {
                guard StudySHA256.hex(try bounded(target.appendingPathComponent("coaching-current.json"))) == expected else {
                    throw ExamError.invalid("已有更新版本的教学记录已变化，暂停覆盖。")
                }
            } else if FileManager.default.fileExists(atPath: target.appendingPathComponent("coaching-current.json").path) {
                throw ExamError.invalid("已有更新版本产生了新的教学记录，两份档案均已保留。")
            }
            if receipt.sourceFilesSHA256 == sourceHashes {
                _ = try load(hash)
                return
            }
            // The source remained active and gained real study events after a pointer-write failure.
            // Retain the unused, unchanged target as evidence, then rebuild from the latest source.
            let retired = directory.appendingPathComponent(".upgrade-superseded-\(hash)-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: target, to: retired)
        }
        var generated: [String: Data] = [
            "content.xklconcepts": bytes,
            "ancestors/\(oldHash).xklconcepts": oldContent
        ]
        // Original teaching bytes and event teaching hashes remain unchanged.
        for (name, data) in support.files
        where name.hasPrefix("teaching/") || name.hasPrefix("ancestors/") || name == "teaching-active.json" {
            generated[name] = data
        }
        if support.lesson?.hasProfessionalExtension == true {
            generated[Self.professionalMarkerName] = try encode(ProfessionalRequiredMarker(bankSHA256: hash))
        }
        if let previousMigration = support.files["migration.json"] {
            generated["ancestors/migration-\(oldHash).json"] = previousMigration
        }
        var newVolumes: [ConceptVolume] = []
        for ref in old.engine.record.volumes {
            guard let data = old.volumes[ref.sha256] else { throw ExamError.invalid("原作答分卷缺失。") }
            var closed = try JSONDecoder().decode(ConceptRecord.self, from: data)
            closed.bankSHA256 = hash
            closed.volumes = newVolumes
            try closed.validate(bank: bank, hash: hash)
            let encoded = try encode(closed), digest = StudySHA256.hex(encoded)
            generated["volumes/\(digest).json"] = encoded
            newVolumes.append(ConceptVolume(sha256: digest, first: ref.first, last: ref.last, count: ref.count))
        }
        var current = old.engine.record
        current.bankSHA256 = hash
        current.volumes = newVolumes
        var scoped = try ConceptEngine(bank: bank, hash: hash, record: current)
        scoped.applyStudyScope()
        current = scoped.record
        try current.validate(bank: bank, hash: hash)
        let state = try encode(current)
        generated["current.json"] = state
        var coachingHash: String?
        if support.files["coaching-current.json"] != nil {
            var newCoachingVolumes: [ConceptVolume] = []
            for ref in support.record.volumes {
                guard let data = support.files["coaching-volumes/\(ref.sha256).json"] else {
                    throw ExamError.invalid("原教学分卷缺失。")
                }
                var closed = try JSONDecoder().decode(ConceptCoachingRecord.self, from: data)
                closed.bankSHA256 = hash
                closed.volumes = newCoachingVolumes
                try closed.validate(bank: bank, hash: hash)
                let encoded = try encode(closed), digest = StudySHA256.hex(encoded)
                generated["coaching-volumes/\(digest).json"] = encoded
                newCoachingVolumes.append(ConceptVolume(sha256: digest, first: ref.first, last: ref.last, count: ref.count))
            }
            var updated = support.record
            updated.bankSHA256 = hash
            updated.volumes = newCoachingVolumes
            try updated.validate(bank: bank, hash: hash)
            let data = try encode(updated)
            coachingHash = StudySHA256.hex(data)
            generated["coaching-current.json"] = data
            generated["coaching-created.json"] = try encode(hash)
        }
        generated["migration.json"] = try encode(UpgradeReceipt(
            fromBankSHA256: oldHash, toBankSHA256: hash, sourceFilesSHA256: sourceHashes,
            targetStateSHA256: StudySHA256.hex(state), targetCoachingSHA256: coachingHash, createdAt: Date()))
        let staging = directory.appendingPathComponent(".upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if FileManager.default.fileExists(atPath: staging.path) { try? FileManager.default.removeItem(at: staging) } }
        // Keep directories needed by later log rotations even for currently empty streams.
        for name in ["volumes", "coaching-volumes", "teaching", "ancestors"] {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in generated.keys.sorted() {
            guard !name.contains(".."), !name.hasPrefix("/") else { throw ExamError.invalid("更新路径无效。") }
            let path = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(generated[name]!, path)
            guard try bounded(path) == generated[name]! else { throw ExamError.invalid("更新副本校验失败。") }
        }
        try FileManager.default.moveItem(at: staging, to: target)
        // Active pointer is switched only by importContent after all validation and teaching writes succeed.
        _ = try load(hash)
    }

    private func applyPracticeHolds(to candidate: inout ConceptEngine, persist: Bool) throws {
        let before = try encode(candidate.record)
        let held = Set((teaching?.questionPracticeNotes ?? []).map(\.questionID))
        try candidate.applyQuestionHolds(held, revision: teachingHash ?? "no-editorial-holds")
        let after = try encode(candidate.record)
        if persist, before != after {
            try write(after, folder(candidate.record.bankSHA256).appendingPathComponent("current.json"))
        }
    }

    private func change(_ operation: (inout ConceptEngine) throws -> Void) {
        guard !blocked, var candidate = engine else { return }
        var wrote = false
        do {
            try applyPracticeHolds(to: &candidate, persist: false)
            if let teaching, teaching.hasProfessionalExtension {
                try ProfessionalQuestionPresentation.validatePracticeContent(teaching.questionPresentations ?? [], bank: candidate.bank)
            }
            let base = try folder(candidate.record.bankSHA256)
            if candidate.record.attempts.count >= 1_000 {
                let bytes = try encode(candidate.record), hash = StudySHA256.hex(bytes)
                let path = base.appendingPathComponent("volumes/\(hash).json")
                if FileManager.default.fileExists(atPath: path.path) {
                    guard try bounded(path) == bytes else { throw ExamError.invalid("已封存日志不同。") }
                } else {
                    wrote = true
                    try write(bytes, path)
                }
                try candidate.rotate(hash: hash)
            }
            try operation(&candidate)
            try validateQuestionPractice(candidate)
            try candidate.record.validate(bank: candidate.bank, hash: candidate.record.bankSHA256)
            wrote = true
            try write(encode(candidate.record), base.appendingPathComponent("current.json"))
            engine = candidate
            error = nil
        } catch {
            if wrote { fail(error) } else { self.error = error.localizedDescription }
        }
    }

    func start(newLimit: Int = 3) {
        if let reason = currentQuestionPracticeBlockedReason { error = reason; return }
        change { try $0.start(day: ConceptCalendar.studyDay(Date()), newLimit: newLimit) }
    }
    /// nil means an audited source question can be entered; non-nil is a read-only explanation.
    func sourceQuestionAvailability(_ questionID: String) -> String? {
        guard !blocked, let e = engine else { return "课程记录当前不可写。" }
        if let note = teaching?.questionPracticeNotes?.first(where: { $0.questionID == questionID }) {
            return "暂缓判分：" + note.reason
        }
        guard let concept = e.bank.concepts.first(where: { $0.questions.contains { $0.id == questionID } }),
              let question = concept.questions.first(where: { $0.id == questionID }) else { return "只有原图索引，尚未核验完整题目与答案。" }
        guard let presentation = teaching?.questionPresentations?.first(where: { $0.questionID == questionID }),
              presentation.sourceQuestionDigest == question.professionalDigest else { return "原题尚未完成逐题核验，仅可阅读。" }
        do { try ProfessionalQuestionPresentation.validateAll([presentation], bank: e.bank) }
        catch { return error.localizedDescription }
        guard e.bank.isActive(questionID) else { return "此题不在当前练习范围内，仅可阅读。" }
        if let shown = e.shown { return shown.questionID == questionID ? nil : "请先完成当前题或结果页，原断点会保留。" }
        let progress = e.record.progress[concept.id] ?? ConceptProgress()
        if progress.usedQuestionIDs.contains(questionID) { return "此题已作答，可查看历史记录，不重复评分。" }
        if progress.familiar { return "此考点已标熟悉，恢复复习后方可练习。" }
        return nil
    }
    func startQuestion(_ questionID: String, expectedCurrentToken: UUID?) {
        guard !blocked, engine?.shown?.id == expectedCurrentToken else {
            error = "当前题目已变化，请重新打开题源入口。"; return
        }
        if let reason = sourceQuestionAvailability(questionID) { error = reason; return }
        change { try $0.startQuestion(questionID: questionID, day: ConceptCalendar.studyDay(Date())) }
    }
    private func validateQuestionPractice(_ candidate: ConceptEngine, questionID: String? = nil) throws {
        guard let teaching, teaching.hasProfessionalExtension,
              let id = questionID ?? candidate.shown?.questionID else { return }
        if let note = teaching.questionPracticeNotes?.first(where: { $0.questionID == id }) {
            throw ExamError.invalid("暂缓判分：" + note.reason)
        }
        guard let presentation = teaching.questionPresentations?.first(where: { $0.questionID == id }) else {
            throw ExamError.invalid("原题尚缺核验后的题级呈现，不能作答评分。")
        }
        try ProfessionalQuestionPresentation.validateAll([presentation], bank: candidate.bank)
    }
    var currentQuestionPracticeBlockedReason: String? {
        guard let e = engine else { return nil }
        do { try validateQuestionPractice(e) }
        catch { return error.localizedDescription }
        return nil
    }
    var currentQuestionPresentation: ProfessionalQuestionPresentation? {
        guard let id = engine?.shown?.questionID else { return nil }
        return teaching?.questionPresentations?.first { $0.questionID == id }
    }
    var currentQuestionLinks: ProfessionalQuestionLinks? {
        guard let id = engine?.shown?.questionID else { return nil }
        return teaching?.questionLinks?.first { $0.questionID == id }
    }
    func sourceQuestionHistory(_ questionID: String) throws -> [ConceptAttempt] {
        guard let e = engine else { return [] }
        let loaded = try load(e.record.bankSHA256)
        var attempts = loaded.engine.record.attempts
        for (_, bytes) in loaded.volumes {
            attempts += try JSONDecoder().decode(ConceptRecord.self, from: bytes).attempts
        }
        return attempts.filter { $0.mode == "answer" && $0.presentation.questionID == questionID }
            .sorted { $0.sequence < $1.sequence }
    }
    func refreshStudyDate() {
        guard !blocked, let existing = engine else { return }
        do {
            let day = try ConceptCalendar.studyDay(Date())
            var candidate = existing
            try candidate.refreshDue(day: day)
            // No per-second or same-day no-op writes.
            guard try encode(candidate.record) != encode(existing.record) else { return }
            change { try $0.refreshDue(day: day) }
        } catch { self.error = error.localizedDescription }
    }
    func choose(_ id: String, token: UUID) {
        if let reason = currentQuestionPracticeBlockedReason { error = reason; return }
        change {
            if $0.question?.type == .multiple { $0.toggle(id, token: token) }
            else { try $0.answer(id, token: token, day: ConceptCalendar.studyDay(Date())) }
        }
    }
    func submit(token: UUID) {
        if let reason = currentQuestionPracticeBlockedReason { error = reason; return }
        change { try $0.answer(token: token, day: ConceptCalendar.studyDay(Date())) }
    }
    func next(token: UUID) {
        change { try $0.nextOnDay(token: token, day: ConceptCalendar.studyDay(Date())) }
    }
    func familiar(token: UUID) { change { try $0.familiar(token: token, day: ConceptCalendar.studyDay(Date())) } }
    func undo() {
        change {
            let day = try ConceptCalendar.studyDay(Date())
            try $0.refreshDue(day: day)
            $0.undo()
            try $0.refreshDue(day: day)
        }
    }

    var currentLesson: ConceptLesson? {
        teaching?.lessons.first { $0.conceptID == engine?.concept?.id }
    }

    var guidanceLesson: ConceptLesson? {
        guard let position = guidance?.active else { return nil }
        return guidanceStore?.lesson(for: position)
    }
    func guidanceLesson(for position: ConceptGuidancePosition) -> ConceptLesson? {
        guidanceStore?.lesson(for: position)
    }
    func shouldAutoShowGuidance(conceptID: String) -> Bool {
        guard teaching?.lessons.first(where: { $0.conceptID == conceptID })?.guide != nil,
              engine?.record.progress[conceptID]?.familiar != true,
              engine?.record.progress[conceptID]?.usedQuestionIDs.isEmpty ?? true else { return false }
        return !(guidanceStore?.allEvents.contains { $0.conceptID == conceptID && $0.kind == "open" } ?? false)
    }
    func openGuidance(conceptID: String, presentationID: UUID? = nil) {
        guard !blocked, let e = engine, let teaching, let teachingHash,
              e.activeConcepts.contains(where: { $0.id == conceptID }),
              teaching.lessons.first(where: { $0.conceptID == conceptID })?.guide != nil,
              presentationID == nil || presentationID == e.shown?.id,
              let guidanceStore else { return }
        do {
            let base = try folder(e.record.bankSHA256)
            let bankPath = teaching.bankSHA256 == e.record.bankSHA256 ? "content.xklconcepts" : "ancestors/\(teaching.bankSHA256).xklconcepts"
            try guidanceStore.archive(bankContent: bounded(base.appendingPathComponent(bankPath)),
                teachingContent: bounded(base.appendingPathComponent("teaching/\(teachingHash).json")), teachingHash: teachingHash)
            try guidanceStore.open(conceptID: conceptID, teachingHash: teachingHash, presentationID: presentationID)
            guidance = guidanceStore.record
            error = nil
        } catch { fail(error) }
    }
    func resumeGuidance(_ position: ConceptGuidancePosition) {
        guard !blocked, let guidanceStore,
              engine?.activeConcepts.contains(where: { $0.id == position.conceptID }) == true else { return }
        do {
            try guidanceStore.open(conceptID: position.conceptID, teachingHash: position.teachingSHA256,
                                   presentationID: position.presentationID)
            guidance = guidanceStore.record
            error = nil
        } catch { fail(error) }
    }
    func guidanceAction(_ kind: String, stepID: String? = nil, choiceID: String? = nil, recallIndex: Int? = nil) {
        guard !blocked, let guidanceStore else { return }
        do {
            try guidanceStore.act(kind, stepID: stepID, choiceID: choiceID, recallIndex: recallIndex)
            guidance = guidanceStore.record
            error = nil
        } catch { fail(error) }
    }

    func shouldAutoShowStory(conceptID: String) -> Bool {
        teaching?.lessons.contains { $0.conceptID == conceptID } == true &&
        ConceptCoachingRecord.shouldAutoShow(conceptID: conceptID,
            progress: engine?.record.progress[conceptID], events: coachingEvents)
    }

    func selectedReason(attemptID: UUID) -> ConceptMistakeReason? {
        ConceptCoachingRecord.selectedReason(attemptID: attemptID, events: coachingEvents)
    }

    func openStory(token: UUID, automatic: Bool) {
        guard !blocked, let e = engine, let p = e.shown, p.id == token,
              currentLesson != nil, let teachingHash else { return }
        if automatic && (e.record.review != nil || !shouldAutoShowStory(conceptID: p.conceptID)) { return }
        // Re-rendering the same display must not generate repeated observations.
        if coachingEvents.contains(where: {
            $0.kind == "story" && $0.presentationID == token &&
            $0.beforeAnswer == (e.record.review == nil) && $0.automatic == automatic
        }) { return }
        appendCoaching(kind: "story", p: p, attemptID: e.record.review?.id,
                       reason: nil, automatic: automatic, teachingHash: teachingHash)
    }

    /// Records actual pre-answer linked-card exposure; never writes Recall grades or question progress.
    /// An already-saved question can be resumed from the card screen too. Only
    /// a genuinely linked card marks assistance; re-rendering is idempotent.
    @discardableResult
    func recordRecallCardExposure(cardID: String, token: UUID) -> Bool {
        guard !blocked, let e = engine, let shown = e.shown, shown.id == token else { return false }
        if e.record.review != nil { return true }
        guard let links = teaching?.questionLinks?.first(where: { $0.questionID == shown.questionID }) else { return true }
        guard links.primaryCardIDs.contains(cardID) || links.supplementCardIDs.contains(cardID) else { return true }
        return openLinkedCardHelp(token: token)
    }

    @discardableResult
    func openLinkedCardHelp(token: UUID) -> Bool {
        guard !blocked, let e = engine, let p = e.record.presentation, p.id == token,
              e.record.review == nil, let teaching, let teachingHash,
              let links = teaching.questionLinks?.first(where: { $0.questionID == p.questionID }) else { return false }
        do {
            try ProfessionalQuestionLinks.validateAll([links], bank: e.bank, teaching: teaching)
            try validateQuestionPractice(e)
            guard !(links.primaryCardIDs + links.supplementCardIDs + links.guideConceptIDs).isEmpty else { return false }
        } catch { self.error = error.localizedDescription; return false }
        if coachingEvents.contains(where: {
            $0.kind == "linked-card-help" && $0.presentationID == token && $0.beforeAnswer &&
            $0.teachingSHA256 == teachingHash && $0.linkedPrimaryCardIDs == links.primaryCardIDs &&
            $0.linkedSupplementCardIDs == links.supplementCardIDs && $0.linkedGuideConceptIDs == links.guideConceptIDs
        }) { return true } // The exact exposure snapshot was already durably recorded.
        return appendCoaching(kind: "linked-card-help", p: p, attemptID: nil, reason: nil,
                              automatic: nil, teachingHash: teachingHash, links: links)
    }
    var currentQuestionUsedCardHelp: Bool {
        guard let p = engine?.shown else { return false }
        return coachingEvents.contains {
            $0.beforeAnswer && $0.questionID == p.questionID &&
            ($0.kind == "source-read" || ($0.kind == "linked-card-help" && $0.presentationID == p.id))
        }
    }

    /// Source scans may contain the printed solution. Persist a question-bound
    /// observation before displaying them, even without an active practice
    /// presentation, so navigating elsewhere cannot turn exposure into a blind test.
    @discardableResult
    func recordSourceExposure(questionID: String) -> Bool {
        guard let leaf = teaching?.sourceLeaves?.first(where: { $0.bankQuestionID == questionID }) else {
            error = "源题尚未绑定当前课程，暂不显示可能含答案的资料。"; return false
        }
        return recordSourceExposure(sourceQuestionID: leaf.sourceQuestionID)
    }

    /// A raw source image can contain several questions, and full-screen view
    /// exposes the whole image. Record every bound question sharing any shown
    /// image, including when the selected index leaf itself is unbound.
    @discardableResult
    func recordSourceExposure(sourceQuestionID: String) -> Bool {
        guard !blocked else { return false }
        guard let teaching, let leaves = teaching.sourceLeaves,
              let selected = leaves.first(where: { $0.sourceQuestionID == sourceQuestionID }) else {
            error = "来源资料与当前课程不匹配，暂不显示原页。"; return false
        }
        func hashes(_ leaf: ProfessionalSourceLeaf) -> Set<String> {
            Set(leaf.allVisuals.compactMap { $0.sourceFile?.sha256 ?? $0.raster?.sha256 })
        }
        let selectedHashes = hashes(selected)
        let exposed = Set(leaves.filter { leaf in
            if leaf.sourceQuestionID == selected.sourceQuestionID { return true }
            let other = hashes(leaf)
            if !selectedHashes.isDisjoint(with: other) { return true }
            // Vector-only fixtures/readers have no raw image identity.
            return selectedHashes.isEmpty && other.isEmpty && leaf.sourceID == selected.sourceID && leaf.page == selected.page
        }.compactMap(\.bankQuestionID))
        for id in exposed.sorted() {
            guard recordSingleSourceExposure(questionID: id) else { return false }
        }
        return true
    }

    private func recordSingleSourceExposure(questionID: String) -> Bool {
        guard !blocked else { return false }
        guard let e = engine, let teaching, let teachingHash,
              teaching.sourceLeaves?.contains(where: { $0.bankQuestionID == questionID }) == true,
              let concept = e.bank.concepts.first(where: { $0.questions.contains { $0.id == questionID } }),
              let question = concept.questions.first(where: { $0.id == questionID }) else {
            error = "源题尚未绑定当前课程，暂不显示可能含答案的资料。"; return false
        }
        if coachingEvents.contains(where: { $0.kind == "source-read" && $0.questionID == questionID }) { return true }
        let observation = ConceptPresentation(id: UUID(), conceptID: concept.id, questionID: questionID,
            order: question.options.map(\.id), selected: [], presentedAt: Date())
        let beforeAnswer = !(e.record.progress[concept.id]?.usedQuestionIDs.contains(questionID) ?? false)
        return appendCoaching(kind: "source-read", p: observation, attemptID: nil, reason: nil,
            automatic: nil, teachingHash: teachingHash, beforeAnswerOverride: beforeAnswer)
    }

    func setReason(_ reason: ConceptMistakeReason?, attemptID: UUID) {
        guard !blocked, let answer = engine?.record.review, answer.id == attemptID else { return }
        guard selectedReason(attemptID: attemptID) != reason else { return }
        appendCoaching(kind: "reason", p: answer.presentation, attemptID: attemptID,
                       reason: reason, automatic: nil, teachingHash: teachingHash)
    }

    @discardableResult
    private func appendCoaching(kind: String, p: ConceptPresentation, attemptID: UUID?,
                                reason: ConceptMistakeReason?, automatic: Bool?, teachingHash: String?,
                                links: ProfessionalQuestionLinks? = nil, beforeAnswerOverride: Bool? = nil) -> Bool {
        guard let e = engine, var candidate = coaching else { return false }
        do {
            let base = try folder(e.record.bankSHA256)
            let volumeFolder = base.appendingPathComponent("coaching-volumes", isDirectory: true)
            if candidate.events.count >= 1_000 {
                let data = try encode(candidate), hash = StudySHA256.hex(data)
                try FileManager.default.createDirectory(at: volumeFolder, withIntermediateDirectories: true)
                let target = volumeFolder.appendingPathComponent(hash + ".json")
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try bounded(target) == data else { throw ExamError.invalid("教学分卷内容不一致。") }
                } else { try write(data, target) }
                try candidate.rotate(hash: hash)
            }
            let event = ConceptCoachingEvent(id: UUID(), sequence: candidate.nextSequence, kind: kind,
                conceptID: p.conceptID, questionID: p.questionID, presentationID: p.id,
                attemptID: attemptID, reason: reason, automatic: automatic,
                beforeAnswer: beforeAnswerOverride ?? (e.record.review == nil), teachingSHA256: teachingHash, recordedAt: Date(),
                linkedPrimaryCardIDs: links?.primaryCardIDs, linkedSupplementCardIDs: links?.supplementCardIDs,
                linkedGuideConceptIDs: links?.guideConceptIDs)
            candidate.events.append(event)
            candidate.nextSequence += 1
            try candidate.validate(bank: e.bank, hash: e.record.bankSHA256)
            let marker = base.appendingPathComponent("coaching-created.json")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try write(encode(e.record.bankSHA256), marker)
            }
            try write(encode(candidate), base.appendingPathComponent("coaching-current.json"))
            coaching = candidate
            coachingEvents.append(event)
            return true
        } catch { fail(error); return false }
    }

    private func readSupport(_ e: ConceptEngine) throws -> (
        lesson: ConceptTeaching?, teachingHash: String?, record: ConceptCoachingRecord,
        allEvents: [ConceptCoachingEvent], files: [String: Data]) {
        let base = try folder(e.record.bankSHA256)
        var files: [String: Data] = [:]
        let professionalMarker = base.appendingPathComponent(Self.professionalMarkerName)
        if FileManager.default.fileExists(atPath: professionalMarker.path) {
            let data = try bounded(professionalMarker)
            let required = try JSONDecoder().decode(ProfessionalRequiredMarker.self, from: data)
            guard required.format == "xkl-professional-v5-required-v1", required.bankSHA256 == e.record.bankSHA256 else {
                throw ExamError.invalid("专业课v5保护标识损坏，不能退回无教学题库。")
            }
            files[Self.professionalMarkerName] = data
        }
        var teachingBanks = [e.record.bankSHA256: e.bank]
        let ancestors = base.appendingPathComponent("ancestors")
        if FileManager.default.fileExists(atPath: ancestors.path) {
            for url in try FileManager.default.contentsOfDirectory(at: ancestors, includingPropertiesForKeys: nil) {
                let data = try bounded(url)
                if url.pathExtension == "xklconcepts" {
                    let (pack, bank) = try ConceptContent.load(data)
                    guard pack.bankSHA256 == url.deletingPathExtension().lastPathComponent,
                          pack.bankSHA256 != e.record.bankSHA256 else { throw ExamError.invalid("历史题库身份无效。") }
                    try e.bank.validateAppendOnly(from: bank)
                    teachingBanks[pack.bankSHA256] = bank
                } else if url.pathExtension != "json" || !url.lastPathComponent.hasPrefix("migration-") {
                    throw ExamError.invalid("未知的历史题库文件。")
                }
                files["ancestors/" + url.lastPathComponent] = data
            }
        }
        let migration = base.appendingPathComponent("migration.json")
        if FileManager.default.fileExists(atPath: migration.path) {
            let bytes = try bounded(migration)
            let receipt = try JSONDecoder().decode(UpgradeReceipt.self, from: bytes)
            guard receipt.format == "xkl-concept-upgrade-v1", receipt.toBankSHA256 == e.record.bankSHA256,
                  teachingBanks[receipt.fromBankSHA256] != nil else {
                throw ExamError.invalid("题库继承凭据无效。")
            }
            files["migration.json"] = bytes
        } else if teachingBanks.count > 1 { throw ExamError.invalid("题库继承凭据缺失。") }
        func validateTeaching(_ value: ConceptTeaching) throws {
            guard let bank = teachingBanks[value.bankSHA256] else { throw ExamError.invalid("教学引用未知题库版本。") }
            try value.validate(bank: bank, hash: value.bankSHA256)
        }
        var lesson: ConceptTeaching?, selectedTeaching: String?
        let pointer = base.appendingPathComponent("teaching-active.json")
        if FileManager.default.fileExists(atPath: pointer.path) {
            let data = try bounded(pointer), hash = try JSONDecoder().decode(String.self, from: data)
            guard ExamContent.isHash(hash) else { throw ExamError.invalid("教学版本索引无效。") }
            files["teaching-active.json"] = data
            let bytes = try bounded(base.appendingPathComponent("teaching/\(hash).json"))
            guard StudySHA256.hex(bytes) == hash else { throw ExamError.invalid("教学内容校验失败。") }
            let decoded = try JSONDecoder().decode(ConceptTeaching.self, from: bytes)
            try validateTeaching(decoded)
            lesson = decoded
            selectedTeaching = hash
        }
        let teachingFolder = base.appendingPathComponent("teaching")
        if FileManager.default.fileExists(atPath: teachingFolder.path) {
            for url in try FileManager.default.contentsOfDirectory(at: teachingFolder, includingPropertiesForKeys: nil) {
                let hash = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "json", ExamContent.isHash(hash) else {
                    throw ExamError.invalid("未知的教学内容文件。")
                }
                let bytes = try bounded(url)
                guard StudySHA256.hex(bytes) == hash else { throw ExamError.invalid("教学内容历史损坏。") }
                try validateTeaching(JSONDecoder().decode(ConceptTeaching.self, from: bytes))
                files["teaching/" + url.lastPathComponent] = bytes
            }
        }
        if files[Self.professionalMarkerName] != nil {
            guard lesson?.hasProfessionalExtension == true, selectedTeaching != nil else {
                throw ExamError.invalid("专业课v5必要教学或索引缺失，已停止评分，原档案保留。")
            }
        }
        let stateURL = base.appendingPathComponent("coaching-current.json")
        let marker = base.appendingPathComponent("coaching-created.json")
        let volumeFolder = base.appendingPathComponent("coaching-volumes")
        if FileManager.default.fileExists(atPath: marker.path) {
            let bytes = try bounded(marker)
            guard try JSONDecoder().decode(String.self, from: bytes) == e.record.bankSHA256 else {
                throw ExamError.invalid("教学记录创建标识无效。")
            }
            files["coaching-created.json"] = bytes
        }
        let record: ConceptCoachingRecord
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try bounded(stateURL)
            files["coaching-current.json"] = data
            record = try JSONDecoder().decode(ConceptCoachingRecord.self, from: data)
        } else {
            var hasVolumes = false
            if FileManager.default.fileExists(atPath: volumeFolder.path) {
                hasVolumes = !(try FileManager.default.contentsOfDirectory(atPath: volumeFolder.path)).isEmpty
            }
            guard files["coaching-created.json"] == nil, !hasVolumes else {
                throw ExamError.invalid("教学当前日志缺失，已保留历史分卷并暂停写入。")
            }
            record = ConceptCoachingRecord(bankSHA256: e.record.bankSHA256)
        }
        try record.validate(bank: e.bank, hash: e.record.bankSHA256)
        var all: [ConceptCoachingEvent] = []
        for (index, ref) in record.volumes.enumerated() {
            let name = "coaching-volumes/\(ref.sha256).json"
            let bytes = try bounded(base.appendingPathComponent(name))
            guard StudySHA256.hex(bytes) == ref.sha256 else { throw ExamError.invalid("教学历史卷校验失败。") }
            let closed = try JSONDecoder().decode(ConceptCoachingRecord.self, from: bytes)
            try closed.validate(bank: e.bank, hash: e.record.bankSHA256)
            guard closed.volumes == Array(record.volumes.prefix(index)), closed.events.count == ref.count,
                  closed.events.first?.sequence == ref.first, closed.events.last?.sequence == ref.last else {
                throw ExamError.invalid("教学历史卷边界无效。")
            }
            all += closed.events
            files[name] = bytes
        }
        all += record.events
        var attempts = e.record.attempts
        for ref in e.record.volumes {
            let bytes = try bounded(base.appendingPathComponent("volumes/\(ref.sha256).json"))
            guard StudySHA256.hex(bytes) == ref.sha256 else { throw ExamError.invalid("作答历史校验失败。") }
            attempts += try JSONDecoder().decode(ConceptRecord.self, from: bytes).attempts
        }
        let byID = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0) })
        var ids = Set<UUID>()
        for (index, event) in all.enumerated() {
            guard event.sequence == index + 1, ids.insert(event.id).inserted,
                  event.teachingSHA256.map({ files["teaching/\($0).json"] != nil }) ?? true else {
                throw ExamError.invalid("教学记录缺失、重复或缺少对应教学版本。")
            }
            if event.kind == "linked-card-help" {
                guard let hash = event.teachingSHA256, let bytes = files["teaching/\(hash).json"] else {
                    throw ExamError.invalid("题内知识卡辅助记录缺少当时的教学快照。")
                }
                let snapshot = try JSONDecoder().decode(ConceptTeaching.self, from: bytes)
                guard let links = snapshot.questionLinks?.first(where: { $0.questionID == event.questionID }),
                      event.linkedPrimaryCardIDs == links.primaryCardIDs,
                      event.linkedSupplementCardIDs == links.supplementCardIDs,
                      event.linkedGuideConceptIDs == links.guideConceptIDs else {
                    throw ExamError.invalid("题内知识卡辅助记录与当时关联不一致。")
                }
            }
            if event.kind == "source-read" {
                guard let hash = event.teachingSHA256, let bytes = files["teaching/\(hash).json"] else {
                    throw ExamError.invalid("源题阅读观察缺少当时的教学快照。")
                }
                let snapshot = try JSONDecoder().decode(ConceptTeaching.self, from: bytes)
                guard snapshot.sourceLeaves?.contains(where: { $0.bankQuestionID == event.questionID }) == true else {
                    throw ExamError.invalid("源题阅读观察与当时题级绑定不一致。")
                }
            }
            if event.kind != "source-read" && (event.kind == "reason" || !event.beforeAnswer) {
                guard let id = event.attemptID, let answer = byID[id], answer.mode == "answer",
                      answer.presentation.id == event.presentationID,
                      answer.presentation.conceptID == event.conceptID,
                      answer.presentation.questionID == event.questionID else {
                    throw ExamError.invalid("错因或答后教学记录与实际作答不一致。")
                }
            }
        }
        return (lesson, selectedTeaching, record, all, files)
    }

    private func loadSupport(_ e: ConceptEngine) throws {
        let loaded = try readSupport(e)
        // Backfill only from an already-valid selected v5 teaching; never create/reset study state.
        try ensureProfessionalMarker(e, lesson: loaded.lesson)
        let guidance = try ConceptGuidanceStore(directory: directory, subject: subject, writer: write)
        teaching = loaded.lesson
        teachingHash = loaded.teachingHash
        coaching = loaded.record
        coachingEvents = loaded.allEvents
        guidanceStore = guidance
        self.guidance = guidance.record
    }
    private func fail(_ failure: Error) {
        blocked = true
        error = failure.localizedDescription + "\n已暂停考点写入，保留现有档案。"
    }

    func exportRecords() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Export: Codable {
            let format: String
            let exportedAt: Date
            let banks: [ConceptBank]
            let records: [ConceptRecord]
            let volumes: [String: [String: Data]]
            let teachingAndCoaching: [String: [String: Data]]
            let guidance: [String: Data]
        }
        var banks: [ConceptBank] = [], records: [ConceptRecord] = [], volumes: [String: [String: Data]] = [:]
        var teachingAndCoaching: [String: [String: Data]] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            if url.lastPathComponent.hasPrefix(".upgrade-") { continue }
            if ["guidance-content", "guidance-volumes"].contains(url.lastPathComponent) { continue }
            guard ExamContent.isHash(url.lastPathComponent) else { throw ExamError.invalid("考点目录存在未知版本。") }
            let loaded = try load(url.lastPathComponent)
            banks.append(loaded.engine.bank)
            records.append(loaded.engine.record)
            volumes[url.lastPathComponent] = loaded.volumes
            teachingAndCoaching[url.lastPathComponent] = try readSupport(loaded.engine).files
        }
        return try encoder.encode(Export(format: "xkl-concept-export-v2", exportedAt: Date(),
            banks: banks, records: records, volumes: volumes, teachingAndCoaching: teachingAndCoaching,
            guidance: try ConceptGuidanceStore(directory: directory, subject: subject, writer: write).exportFiles()))
    }
}
