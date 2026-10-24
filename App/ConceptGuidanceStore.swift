import Foundation
import StudyCore

/// Subject-level storage deliberately lives outside bank-version directories.
/// An append-only course migration never rewrites guidance history.
final class ConceptGuidanceStore {
    struct Archive: Codable {
        var format = "xkl-guidance-content-v1"
        let subject: ConceptSubject
        let bankContent: Data
        let teachingContent: Data
        func unpack(hash: String, subject: ConceptSubject) throws -> (ConceptBank, ConceptTeaching) {
            guard format == "xkl-guidance-content-v1", self.subject == subject,
                  StudySHA256.hex(teachingContent) == hash else { throw ExamError.invalid("讲解历史内容身份无效。") }
            let (pack, bank) = try ConceptContent.load(bankContent)
            let teaching = try JSONDecoder().decode(ConceptTeaching.self, from: teachingContent)
            guard bank.id == subject.bankID else { throw ExamError.invalid("讲解历史科目无效。") }
            try teaching.validate(bank: bank, hash: pack.bankSHA256)
            return (bank, teaching)
        }
    }
    private(set) var record: ConceptGuidanceRecord
    private(set) var allEvents: [ConceptGuidanceEvent] = []
    private var archives: [String: Archive] = [:]
    private var teachings: [String: ConceptTeaching] = [:]
    private let directory: URL
    private let subject: ConceptSubject
    private let writer: (Data, URL) throws -> Void
    private var currentBytes: Data?
    private var currentURL: URL { directory.appendingPathComponent("guidance-current.json") }
    private var markerURL: URL { directory.appendingPathComponent("guidance-created.json") }

    init(directory: URL, subject: ConceptSubject, writer: @escaping (Data, URL) throws -> Void) throws {
        self.directory = directory; self.subject = subject; self.writer = writer
        record = ConceptGuidanceRecord(subject: subject)
        try reload()
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func read(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 64 * 1_024 * 1_024 else {
            throw ExamError.invalid("讲解档案大小或类型异常。")
        }
        return try Data(contentsOf: url)
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func writeVerified(_ data: Data, to url: URL, immutable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if immutable && exists(url) {
            guard try read(url) == data else { throw ExamError.invalid("不可变的讲解历史内容不同。") }
        } else { try writer(data, url) }
        guard try read(url) == data else { throw ExamError.invalid("讲解记录写入后核对失败。") }
    }
    private func contentURL(_ hash: String) -> URL { directory.appendingPathComponent("guidance-content/\(hash).json") }
    private func volumeURL(_ hash: String) -> URL { directory.appendingPathComponent("guidance-volumes/\(hash).json") }

    private func reload() throws {
        let contentFolder = directory.appendingPathComponent("guidance-content")
        if exists(contentFolder) {
            for url in try FileManager.default.contentsOfDirectory(at: contentFolder, includingPropertiesForKeys: nil) {
                let hash = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "json", ExamContent.isHash(hash) else { throw ExamError.invalid("未知讲解历史文件。") }
                let archive = try JSONDecoder().decode(Archive.self, from: read(url))
                let (_, teaching) = try archive.unpack(hash: hash, subject: subject)
                archives[hash] = archive
                teachings[hash] = teaching
            }
        }
        let volumesFolder = directory.appendingPathComponent("guidance-volumes")
        let volumeFiles = exists(volumesFolder) ? try FileManager.default.contentsOfDirectory(at: volumesFolder, includingPropertiesForKeys: nil) : []
        if !exists(currentURL) {
            guard !exists(markerURL), volumeFiles.isEmpty else {
                throw ExamError.invalid("讲解当前日志缺失，保留旧档案并暂停写入。")
            }
            return
        }
        guard exists(markerURL), try JSONDecoder().decode(ConceptSubject.self, from: read(markerURL)) == subject else {
            throw ExamError.invalid("讲解日志创建标识缺失或不一致。")
        }
        let bytes = try read(currentURL)
        let current = try JSONDecoder().decode(ConceptGuidanceRecord.self, from: bytes)
        try current.validateHeader()
        guard current.subject == subject else { throw ExamError.invalid("讲解日志科目无效。") }
        // Unreferenced sealed volumes can remain after a failed current write;
        // retain and verify them, never silently delete them or adopt their state.
        for url in volumeFiles {
            let hash = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", ExamContent.isHash(hash), StudySHA256.hex(try read(url)) == hash else {
                throw ExamError.invalid("讲解历史卷校验失败。")
            }
        }
        var snapshots: [ConceptGuidanceRecord] = []
        for (index, ref) in current.volumes.enumerated() {
            let data = try read(volumeURL(ref.sha256))
            guard StudySHA256.hex(data) == ref.sha256 else { throw ExamError.invalid("讲解历史卷损坏。") }
            let closed = try JSONDecoder().decode(ConceptGuidanceRecord.self, from: data)
            try closed.validateHeader()
            guard closed.subject == subject, closed.volumes == Array(current.volumes.prefix(index)),
                  closed.events.count == ref.count, closed.events.first?.sequence == ref.first,
                  closed.events.last?.sequence == ref.last else { throw ExamError.invalid("讲解历史卷边界无效。") }
            snapshots.append(closed)
        }
        snapshots.append(current)
        var replay = ConceptGuidanceRecord(subject: subject), identifiers = Set<UUID>()
        var all: [ConceptGuidanceEvent] = []
        for (index, snapshot) in snapshots.enumerated() {
            for event in snapshot.events {
                guard identifiers.insert(event.eventID).inserted else { throw ExamError.invalid("讲解事件标识重复。") }
                let (guide, hash) = try resolve(event.teachingSHA256, conceptID: event.conceptID)
                try replay.apply(event, guide: guide, bankHash: hash)
                all.append(event)
            }
            guard replay == snapshot else { throw ExamError.invalid("讲解断点与逐次学习日志不一致。") }
            if index < current.volumes.count {
                replay.events = []
                replay.volumes.append(current.volumes[index])
            }
        }
        record = current; currentBytes = bytes; allEvents = all
    }

    private func resolve(_ teachingHash: String, conceptID: String) throws -> (ConceptGuide, String) {
        guard let teaching = teachings[teachingHash] else { throw ExamError.invalid("讲解记录缺少对应内容版本。") }
        guard let guide = teaching.lessons.first(where: { $0.conceptID == conceptID })?.guide else {
            throw ExamError.invalid("讲解记录引用了不存在的考点步骤。")
        }
        return (guide, teaching.bankSHA256)
    }
    func lesson(for position: ConceptGuidancePosition) -> ConceptLesson? {
        guard let teaching = teachings[position.teachingSHA256] else { return nil }
        return teaching.lessons.first { $0.conceptID == position.conceptID }
    }

    func archive(bankContent: Data, teachingContent: Data, teachingHash: String) throws {
        let archive = Archive(subject: subject, bankContent: bankContent, teachingContent: teachingContent)
        let (_, teaching) = try archive.unpack(hash: teachingHash, subject: subject)
        try writeVerified(encode(archive), to: contentURL(teachingHash), immutable: true)
        archives[teachingHash] = archive
        teachings[teachingHash] = teaching
    }

    func open(conceptID: String, teachingHash: String, presentationID: UUID?) throws {
        let (guide, bankHash) = try resolve(teachingHash, conceptID: conceptID)
        let key = ConceptGuidancePosition.key(conceptID: conceptID, teaching: teachingHash)
        let previous = record.positions[key].flatMap { $0.completed ? nil : $0 }
        let position = previous ?? ConceptGuidancePosition(sessionID: UUID(), conceptID: conceptID,
            bankSHA256: bankHash, teachingSHA256: teachingHash, presentationID: presentationID, stepID: guide.steps[0].id)
        try append(kind: "open", position: position, stepID: position.stepID)
    }
    func act(_ kind: String, stepID: String? = nil, choiceID: String? = nil, recallIndex: Int? = nil) throws {
        guard let position = record.active else { throw ExamError.invalid("请先打开分步讲解。") }
        try append(kind: kind, position: position, stepID: stepID ?? position.stepID, choiceID: choiceID, recallIndex: recallIndex)
    }
    private func append(kind: String, position: ConceptGuidancePosition, stepID: String,
                        choiceID: String? = nil, recallIndex: Int? = nil) throws {
        // Refuse to overwrite externally changed or missing persisted state.
        if let currentBytes {
            guard try read(currentURL) == currentBytes,
                  try JSONDecoder().decode(ConceptSubject.self, from: read(markerURL)) == subject else {
                throw ExamError.invalid("讲解记录在操作前发生变化，已暂停覆盖。")
            }
        } else if exists(currentURL) || exists(markerURL) { throw ExamError.invalid("讲解记录身份已变化。") }
        guard let archive = archives[position.teachingSHA256],
              try read(contentURL(position.teachingSHA256)) == encode(archive) else {
            throw ExamError.invalid("讲解内容在操作前发生变化。")
        }
        let (guide, bankHash) = try resolve(position.teachingSHA256, conceptID: position.conceptID)
        let answerID = guide.steps.first(where: { $0.id == stepID })?.check?.answerID
        let event = ConceptGuidanceEvent(eventID: UUID(), sequence: record.nextSequence, kind: kind,
            sessionID: position.sessionID, conceptID: position.conceptID, bankSHA256: bankHash,
            teachingSHA256: position.teachingSHA256, stepID: stepID, choiceID: choiceID,
            correct: choiceID.map { $0 == answerID }, recallIndex: recallIndex,
            presentationID: position.presentationID, recordedAt: Date())
        var candidate = record
        if candidate.events.count >= 1_000 {
            let data = try encode(candidate), hash = StudySHA256.hex(data)
            try writeVerified(data, to: volumeURL(hash), immutable: true)
            candidate.volumes.append(ConceptVolume(sha256: hash, first: candidate.events[0].sequence,
                last: candidate.events[candidate.events.count - 1].sequence, count: candidate.events.count))
            candidate.events = []
        }
        try candidate.apply(event, guide: guide, bankHash: bankHash)
        try candidate.validateHeader()
        if !exists(markerURL) { try writeVerified(encode(subject), to: markerURL, immutable: true) }
        let data = try encode(candidate)
        try writeVerified(data, to: currentURL)
        record = candidate; currentBytes = data; allEvents.append(event)
    }

    func exportFiles() throws -> [String: Data] {
        // Reload verifies complete history, version references and checkpoints.
        _ = try ConceptGuidanceStore(directory: directory, subject: subject, writer: writer)
        var files: [String: Data] = [:]
        for name in ["guidance-current.json", "guidance-created.json"] {
            let url = directory.appendingPathComponent(name)
            if exists(url) { files[name] = try read(url) }
        }
        for name in ["guidance-content", "guidance-volumes"] {
            let folder = directory.appendingPathComponent(name)
            if exists(folder) {
                for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    files[name + "/" + url.lastPathComponent] = try read(url)
                }
            }
        }
        return files
    }
}
