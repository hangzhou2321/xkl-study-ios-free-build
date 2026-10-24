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
                let loaded = try load(hash).engine
                try loadSupport(loaded)
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
            if ["xkl-course-v1", "xkl-course-v2", "xkl-course-v3", "xkl-course-v4"].contains(header.format) {
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
            let loaded = try load(pack.bankSHA256).engine
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
            try loadSupport(loaded)
            wrote = true
            try write(encode(pack.bankSHA256), activeURL)
            engine = loaded
            error = nil
        } catch {
            if wrote { fail(error) } else { self.error = error.localizedDescription }
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

    private func change(_ operation: (inout ConceptEngine) throws -> Void) {
        guard !blocked, var candidate = engine else { return }
        var wrote = false
        do {
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
            try candidate.record.validate(bank: candidate.bank, hash: candidate.record.bankSHA256)
            wrote = true
            try write(encode(candidate.record), base.appendingPathComponent("current.json"))
            engine = candidate
            error = nil
        } catch {
            if wrote { fail(error) } else { self.error = error.localizedDescription }
        }
    }

    func start(newLimit: Int = 3) { change { try $0.start(day: ConceptCalendar.studyDay(Date()), newLimit: newLimit) } }
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
        change {
            if $0.question?.type == .multiple { $0.toggle(id, token: token) }
            else { try $0.answer(id, token: token, day: ConceptCalendar.studyDay(Date())) }
        }
    }
    func submit(token: UUID) { change { try $0.answer(token: token, day: ConceptCalendar.studyDay(Date())) } }
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

    func setReason(_ reason: ConceptMistakeReason?, attemptID: UUID) {
        guard !blocked, let answer = engine?.record.review, answer.id == attemptID else { return }
        guard selectedReason(attemptID: attemptID) != reason else { return }
        appendCoaching(kind: "reason", p: answer.presentation, attemptID: attemptID,
                       reason: reason, automatic: nil, teachingHash: teachingHash)
    }

    private func appendCoaching(kind: String, p: ConceptPresentation, attemptID: UUID?,
                                reason: ConceptMistakeReason?, automatic: Bool?, teachingHash: String?) {
        guard let e = engine, var candidate = coaching else { return }
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
                beforeAnswer: e.record.review == nil, teachingSHA256: teachingHash, recordedAt: Date())
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
        } catch { fail(error) }
    }

    private func readSupport(_ e: ConceptEngine) throws -> (
        lesson: ConceptTeaching?, teachingHash: String?, record: ConceptCoachingRecord,
        allEvents: [ConceptCoachingEvent], files: [String: Data]) {
        let base = try folder(e.record.bankSHA256)
        var files: [String: Data] = [:]
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
            if event.kind == "reason" || !event.beforeAnswer {
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
