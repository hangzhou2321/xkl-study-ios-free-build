import Foundation
import CPocket
import StudyCore

struct ProfessionalRecallPresentation: Codable, Equatable {
    let id: UUID
    let cardID: String
    var revealed: Bool
}

/// A self-assessment, never an objective question-bank answer.
struct ProfessionalRecallAttempt: Codable, Equatable, Identifiable {
    let id: UUID
    let cardID: String
    let presentationID: UUID
    let remembered: Bool
    let at: Date
    let day: UInt32
    let engineSequence: UInt32
    let beforeRevision: UInt32
    let afterRevision: UInt32
}

struct ProfessionalRecallImportedCard: Codable, Equatable {
    let cardID: String
    let prior: RecallProgress
    let packed: UInt32
    let mapping: String
}

struct ProfessionalRecallMigration: Codable, Equatable {
    let format: String
    let at: Date
    /// The complete validated legacy records remain evidence, not new answers.
    let sourceRecords: [RecallRecord]
    let cards: [ProfessionalRecallImportedCard]
    let resumedCardID: String?
    let resumedAnswerVisible: Bool
}

struct ProfessionalRecallVolume: Codable, Equatable {
    let firstSequence: UInt32
    let lastSequence: UInt32
    let snapshot: Data
    let snapshotSHA256: String
    let analysis: StudyAnalysisSettings
}

struct ProfessionalRecallRecord: Codable, Equatable {
    var format = "xkl-professional-pocket-recall-v1"
    let subject: ConceptSubject
    /// This is the durable numeric-ID mapping. Content text and labels are not identity.
    let cardIDs: [String]
    var snapshot: Data
    var snapshotSHA256: String
    var analysis: StudyAnalysisSettings
    var presentation: ProfessionalRecallPresentation?
    var attempts: [ProfessionalRecallAttempt]
    var volumes: [ProfessionalRecallVolume]
    let migration: ProfessionalRecallMigration
}

struct ProfessionalRecallStats: Equatable {
    let total, introduced, unintroduced, due, firstKnown, scheduled: Int
    let recalled, forgotten, legacyRemembered, legacyForgotten: Int
}

/// Independent professional-card state using the SAME PocketEngine answer policy
/// as StudyStore. No exam experiment, math FSRS, or fabricated migration grades.
/// The host must persist the complete record atomically before publishing a mutation.
@MainActor
final class ProfessionalRecallEngine {
    let deck: RecallDeck
    private(set) var record: ProfessionalRecallRecord
    private var engine: PocketEngine
    private var started = false

    var info: xkl_info_t { get throws { try engine.info } }
    var currentItem: RecallDeck.Item? {
        guard let id = record.presentation?.cardID else { return nil }
        return deck.cards.first { $0.id == id }
    }
    var volumeRecords: UInt32 { engine.volumeRecords }
    var logBase: UInt32 { engine.logBase }

    /// An in-process transaction copy retains the monotonic-clock session.
    /// Restoring from disk still uses init and rebases at the first start.
    func fork() throws -> ProfessionalRecallEngine {
        let copy = try ProfessionalRecallEngine(deck: deck, record: record)
        copy.started = started
        return copy
    }

    init(deck: RecallDeck, record: ProfessionalRecallRecord) throws {
        try deck.validate()
        guard record.format == "xkl-professional-pocket-recall-v1", record.subject == deck.subject,
              record.cardIDs == deck.cards.map(\.id),
              record.snapshotSHA256 == StudySHA256.hex(record.snapshot),
              record.migration.format == "xkl-recall-to-pocket-import-v1",
              Set(record.migration.cards.map(\.cardID)).count == record.migration.cards.count,
              Set(record.migration.cards.map(\.cardID)).isSubset(of: Set(record.cardIDs)),
              record.migration.resumedCardID == nil || record.cardIDs.contains(record.migration.resumedCardID!) else {
            throw ExamError.invalid("专业背卡身份或迁移记录不一致，原档案已保留。")
        }
        self.deck = deck
        self.record = record
        engine = try PocketEngine(snapshot: record.snapshot)
        let info = try engine.info
        try record.analysis.validate(streamID: engine.streamID, logCount: info.log_records)
        var boundary: UInt32 = 0
        for volume in record.volumes {
            guard volume.snapshotSHA256 == StudySHA256.hex(volume.snapshot), volume.firstSequence == boundary + 1,
                  volume.lastSequence >= volume.firstSequence else {
                throw ExamError.invalid("专业背卡日志分卷缺失或损坏。")
            }
            let old = try PocketEngine(snapshot: volume.snapshot)
            guard old.logBase == boundary, try old.info.log_records == volume.lastSequence,
                  try old.streamID == engine.streamID else { throw ExamError.invalid("专业背卡日志分卷身份不一致。") }
            try volume.analysis.validate(streamID: old.streamID, logCount: old.info.log_records)
            boundary = volume.lastSequence
        }
        guard engine.logBase == boundary else { throw ExamError.invalid("专业背卡日志边界不连续。") }
        if info.has_task != 0 {
            guard Int(info.word) < record.cardIDs.count,
                  record.presentation?.cardID == record.cardIDs[Int(info.word)],
                  record.presentation?.revealed == (info.revealed != 0) else {
                throw ExamError.invalid("专业背卡断点与单词引擎不一致。")
            }
        } else if record.presentation != nil { throw ExamError.invalid("专业背卡存在无任务断点。") }
        let events = try allEvents()
        let graded = events.filter { $0.kind == 5 || $0.kind == 6 }
        guard graded.count == record.attempts.count,
              Set(record.attempts.map(\.id)).count == record.attempts.count,
              Set(record.attempts.map(\.presentationID)).count == record.attempts.count else {
            throw ExamError.invalid("专业背卡自评与原始事件数量不一致。")
        }
        for (attempt, event) in zip(record.attempts, graded) {
            guard Int(event.word) < record.cardIDs.count, attempt.cardID == record.cardIDs[Int(event.word)],
                  attempt.engineSequence == event.sequence, attempt.day == event.day,
                  attempt.beforeRevision == event.beforeRevision, attempt.afterRevision == event.afterRevision,
                  attempt.remembered == (event.kind == 5), attempt.at.timeIntervalSinceReferenceDate.isFinite else {
                throw ExamError.invalid("专业背卡自评与原始评分事件不一致。")
            }
        }
    }

    /// `legacy` must already have passed RecallEngine replay validation against
    /// each original deck. No legacy answer is replayed as a new Pocket answer.
    static func fresh(deck: RecallDeck, legacy: [RecallRecord] = [], now: Date = Date()) throws -> ProfessionalRecallEngine {
        try deck.validate()
        let day = UInt32(try ConceptCalendar.studyDay(now))
        let ids = deck.cards.map(\.id), allowed = Set(ids)
        guard ids.count <= Int(XKL_WORD_COUNT) else { throw ExamError.invalid("专业卡数量超出单词引擎容量。") }
        var progress: [String: (RecallProgress, Date)] = [:]
        let sources = legacy.sorted {
            let a = $0.events.last?.at ?? .distantPast, b = $1.events.last?.at ?? .distantPast
            if a != b { return a < b }
            if $0.events.count != $1.events.count { return $0.events.count < $1.events.count }
            return $0.deckSHA256 < $1.deckSHA256
        }
        var latestEvidence: [String: Int] = [:]
        for (index, source) in sources.enumerated() {
            let visible = [source.state.shown?.cardID, source.state.result?.presentation.cardID].compactMap { $0 }
            for id in Array(source.state.progress.keys) + source.state.queue + (source.state.parkedQueue ?? []) + visible {
                latestEvidence[id] = index
            }
        }
        for old in sources {
            guard old.format == "xkl-recall-record-v1", old.state.day <= Int(day) else {
                throw ExamError.invalid("旧背卡档案格式或日期异常，拒绝迁移。")
            }
            let timestamp = old.events.last?.at ?? .distantPast
            for (id, value) in old.state.progress where allowed.contains(id) {
                guard (0...10).contains(value.level), (18_000...50_180).contains(value.dueDay),
                      value.remembered >= 0, value.forgotten >= 0, let last = value.lastDay,
                      (18_000...Int(day)).contains(last) else { throw ExamError.invalid("旧背卡进度无效，拒绝推测历史。") }
                if let existing = progress[id], existing.1 == timestamp, existing.0 != value {
                    throw ExamError.invalid("同一专业卡有冲突的旧进度，原档案保留待核对。")
                }
                progress[id] = (value, timestamp)
            }
        }
        // An old shown card must not resurrect a newer already-graded result.
        let shown = sources.enumerated().reversed().compactMap { (index, source) -> RecallPresentation? in
            guard let shown = source.state.shown, allowed.contains(shown.cardID), latestEvidence[shown.cardID] == index else { return nil }
            return shown
        }.first
        var mapped: [ProfessionalRecallImportedCard] = []
        let packed: [UInt32] = ids.map { id in
            guard let (prior, _) = progress[id] else { return 0 }
            let level = max(1, prior.level)
            let pendingRepair = prior.level == 0 && shown?.cardID == id
            let value = UInt32(prior.dueDay) | (UInt32(level) << 16) | (1 << 20) | (pendingRepair ? (1 << 23) : 0)
            mapped.append(ProfessionalRecallImportedCard(cardID: id, prior: prior, packed: value,
                mapping: pendingRepair ? "legacy-forgotten-pending-repair;due-preserved;no-answer-event" :
                    (prior.level == 0 ? "legacy-forgotten-level0-to-review-level1;due-preserved;no-answer-event" : "legacy-level-and-due-preserved;no-answer-event")))
            return value
        }
        var stream = UUID().uuid
        let pointer = withUnsafeBytes(of: &stream) { streamBytes in
            packed.withUnsafeBufferPointer { cards in
                xkl_engine_import_cards(UInt32(ids.count), cards.baseAddress, day,
                    shown.flatMap { ids.firstIndex(of: $0.cardID) }.map(UInt32.init) ?? UInt32.max,
                    streamBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard let pointer else { throw ExamError.invalid("无法创建专业背卡迁移副本，原档案未改动。") }
        defer { xkl_engine_free(pointer) }
        var snapshot = Data(count: xkl_engine_snapshot_size(pointer))
        let written = snapshot.withUnsafeMutableBytes {
            xkl_engine_snapshot(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard written == snapshot.count else { throw ExamError.invalid("专业背卡迁移快照未完整生成。") }
        let temporary = try PocketEngine(snapshot: snapshot)
        let migration = ProfessionalRecallMigration(format: "xkl-recall-to-pocket-import-v1", at: now,
            sourceRecords: legacy, cards: mapped, resumedCardID: shown?.cardID, resumedAnswerVisible: shown?.revealed ?? false)
        let record = ProfessionalRecallRecord(subject: deck.subject, cardIDs: ids, snapshot: snapshot,
            snapshotSHA256: StudySHA256.hex(snapshot),
            analysis: StudyAnalysisSettings(streamID: try temporary.streamID, nextSequence: 1, now: now),
            presentation: shown.map { ProfessionalRecallPresentation(id: $0.id, cardID: $0.cardID, revealed: false) },
            attempts: [], volumes: [], migration: migration)
        return try Self(deck: deck, record: record)
    }

    func start(day: UInt32, now: Date = Date()) throws {
        let before = try engine.info
        guard day >= before.day else { throw ExamError.invalid("手机日期早于上次背卡日期，原记录已保留。") }
        if started, before.has_task != 0, before.day == day, before.selection_day == day { return }
        try transaction {
            let old = record.presentation
            let restoreImportedReveal = before.log_records == 0 && record.migration.resumedAnswerVisible
                && old?.cardID == record.migration.resumedCardID
            try engine.start(day: day, preservingRevealedAnswer: true, preservingShownStepAcrossDay: true)
            if restoreImportedReveal { try engine.reveal() }
            try present(keeping: before.has_task != 0 ? old : nil)
            started = true
        }
    }

    func reveal(token: UUID, now: Date = Date()) throws {
        guard record.presentation?.id == token, record.presentation?.revealed == false else { return }
        try startIfNeeded(now: now)
        try transaction {
            try engine.reveal()
            record.presentation?.revealed = true
        }
    }

    func grade(remembered: Bool, token: UUID, now: Date = Date()) throws {
        guard let shown = record.presentation, shown.id == token else { return }
        guard shown.revealed else { throw ExamError.invalid("请先主动回忆并翻开答案，再自评。") }
        try startIfNeeded(now: now)
        try transaction {
            let before = try engine.info
            if let decision = try engine.answer(remembered ? 0 : 1, policy: record.analysis) {
                record.analysis.reductions.append(decision)
            }
            guard let event = try engine.events(from: before.log_records + 1).first(where: { $0.kind == 5 || $0.kind == 6 }) else {
                throw ExamError.invalid("专业背卡自评事件未保存。")
            }
            record.attempts.append(ProfessionalRecallAttempt(id: UUID(), cardID: shown.cardID,
                presentationID: token, remembered: remembered, at: now, day: event.day,
                engineSequence: event.sequence, beforeRevision: event.beforeRevision, afterRevision: event.afterRevision))
            try present(keeping: nil)
        }
    }

    func dueCount(on day: UInt32) -> Int { engine.dueCount(on: day, limit: record.cardIDs.count) }

    /// Mirrors the user's current vocabulary switch into this independent
    /// stream. The vocabulary archive is never written by this adapter.
    func setConservativeEnabled(_ enabled: Bool, now: Date = Date()) throws {
        guard record.analysis.conservativeEnabled != enabled else { return }
        try transaction(rotateBefore: false) {
            record.analysis.setEnabled(enabled, nextSequence: try engine.info.log_records + 1, now: now)
        }
    }

    func packedCard(id: String) throws -> UInt32? {
        guard let index = record.cardIDs.firstIndex(of: id) else { return nil }
        return try cardValues()[index]
    }

    func stats(on day: UInt32) throws -> ProfessionalRecallStats {
        let values = try cardValues()
        let introduced = values.filter { $0 != 0 }.count
        return ProfessionalRecallStats(total: values.count, introduced: introduced, unintroduced: values.count - introduced,
            due: dueCount(on: day), firstKnown: values.filter { $0 & (1 << 20) != 0 && ($0 >> 16) & 15 == 0 && $0 & (1 << 22) == 0 }.count,
            scheduled: values.filter { ($0 >> 16) & 15 > 0 }.count,
            recalled: record.attempts.filter(\.remembered).count, forgotten: record.attempts.filter { !$0.remembered }.count,
            legacyRemembered: record.migration.cards.reduce(0) { $0 + $1.prior.remembered },
            legacyForgotten: record.migration.cards.reduce(0) { $0 + $1.prior.forgotten })
    }

    func allEvents() throws -> [StudyEvent] {
        var result: [StudyEvent] = []
        for volume in record.volumes {
            let archived = try PocketEngine(snapshot: volume.snapshot)
            result += try archived.events(from: archived.logBase + 1)
        }
        result += try engine.events(from: engine.logBase + 1)
        return result
    }

    /// Public for deterministic boundary tests; normally automatic before capacity.
    func rotateLog() throws {
        guard try engine.info.log_records > engine.logBase else { return }
        try transaction(rotateBefore: false) { try rotate() }
    }

    private func startIfNeeded(now: Date) throws {
        let day = UInt32(try ConceptCalendar.studyDay(now)), info = try engine.info
        if !started || info.day != day || info.selection_day != day { try start(day: day, now: now) }
    }

    private func present(keeping old: ProfessionalRecallPresentation?) throws {
        let info = try engine.info
        guard info.has_task != 0 else { record.presentation = nil; return }
        guard Int(info.word) < record.cardIDs.count else { throw ExamError.invalid("专业背卡引擎返回范围外卡片。") }
        let id = record.cardIDs[Int(info.word)]
        record.presentation = ProfessionalRecallPresentation(id: old?.cardID == id ? old!.id : UUID(),
            cardID: id, revealed: info.revealed != 0)
    }

    private func cardValues() throws -> [UInt32] {
        let pointer = record.snapshot.withUnsafeBytes {
            xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard let pointer else { throw ExamError.invalid("专业背卡快照无法读取。") }
        defer { xkl_engine_free(pointer) }
        return record.cardIDs.indices.map { xkl_engine_card(pointer, UInt32($0)) }
    }

    private func rotate() throws {
        let info = try engine.info
        guard info.log_records > engine.logBase else { return }
        let snapshot = try engine.snapshot()
        let volume = ProfessionalRecallVolume(firstSequence: engine.logBase + 1, lastSequence: info.log_records,
            snapshot: snapshot, snapshotSHA256: StudySHA256.hex(snapshot), analysis: record.analysis)
        let next = try engine.rotated(policyFirst: record.analysis.conservativeFirstSequence)
        record.volumes.append(volume)
        record.analysis.archivedSavedRepetitions = record.analysis.savedRepetitions
        record.analysis.reductions = []
        if let last = record.analysis.changes.last { record.analysis.changes = [last] }
        engine = next
    }

    private func transaction(rotateBefore: Bool = true, _ body: () throws -> Void) throws {
        let before = record, wasStarted = started
        do {
            if rotateBefore, engine.volumeRecords + 8 >= (try engine.info.log_capacity) { try rotate() }
            try body()
            record.snapshot = try engine.snapshot()
            record.snapshotSHA256 = StudySHA256.hex(record.snapshot)
        } catch {
            engine = try PocketEngine(snapshot: before.snapshot)
            record = before
            started = wasStarted
            throw error
        }
    }
}
