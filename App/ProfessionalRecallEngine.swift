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

struct ProfessionalRecallTransferState: Codable, Equatable {
    let cardID: String
    let subject: ConceptSubject
    let packed: UInt32
    let stageMask: UInt8
    let failedRound: UInt8
    let presentation: ProfessionalRecallPresentation?
    let sourceScope: String
    let sourceSnapshotSHA256: String
    let sourceSequence: UInt32
}

struct ProfessionalRecallContentBoundary: Codable, Equatable {
    let at: Date
    let beforeSnapshot: Data
    let beforeSnapshotSHA256: String
    let beforeCardIDs: [String]
    let beforeActiveCardIDs: [String]
    let beforeItems: [RecallDeck.Item]
    let parked: [ProfessionalRecallTransferState]
    let imported: [ProfessionalRecallTransferState]
    let afterActiveCardIDs: [String]
}

struct ProfessionalRecallRecord: Codable, Equatable {
    var format = "xkl-professional-pocket-recall-v1"
    let subject: ConceptSubject
    /// This is the durable numeric-ID mapping. Content text and labels are not identity.
    var cardIDs: [String]
    var snapshot: Data
    var snapshotSHA256: String
    var analysis: StudyAnalysisSettings
    var presentation: ProfessionalRecallPresentation?
    var attempts: [ProfessionalRecallAttempt]
    var volumes: [ProfessionalRecallVolume]
    let migration: ProfessionalRecallMigration
    var retainedItems: [RecallDeck.Item]? = nil
    var activeCardIDs: [String]? = nil
    var parkedCards: [String: ProfessionalRecallTransferState]? = nil
    var deferredCards: [String: ProfessionalRecallTransferState]? = nil
    var contentChanges: [ProfessionalRecallContentBoundary]? = nil
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
    private(set) var deck: RecallDeck
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
    var activeCardIDs: [String] { record.activeCardIDs ?? record.cardIDs }
    private static let inert: UInt32 = 0x50ffff

    /// An in-process transaction copy retains the monotonic-clock session.
    /// Restoring from disk still uses init and rebases at the first start.
    func fork() throws -> ProfessionalRecallEngine {
        let copy = try ProfessionalRecallEngine(deck: deck, record: record)
        copy.started = started
        return copy
    }

    static func restore(record: ProfessionalRecallRecord, fallback: RecallDeck) throws -> ProfessionalRecallEngine {
        let items = record.retainedItems ?? fallback.cards
        let registry = RecallDeck(subject: record.subject, bankID: record.subject.bankID, cards: items)
        return try Self(deck: registry, record: record)
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
        let active = record.activeCardIDs ?? record.cardIDs
        guard Set(active).count == active.count, Set(active).isSubset(of: Set(record.cardIDs)),
              record.retainedItems == nil || record.retainedItems?.map(\.id) == record.cardIDs,
              Set((record.parkedCards ?? [:]).keys).isSubset(of: Set(record.cardIDs)),
              Set((record.deferredCards ?? [:]).keys).isSubset(of: Set(active)) else {
            throw ExamError.invalid("专业背卡活动范围或保留映射损坏。")
        }
        let info = try engine.info
        for (id, saved) in (record.parkedCards ?? [:]).merging(record.deferredCards ?? [:], uniquingKeysWith: { _, current in current }) {
            guard saved.cardID == id, saved.subject == deck.subject, saved.failedRound <= 2,
                  saved.sourceSnapshotSHA256.count == 64, saved.sourceSnapshotSHA256.allSatisfy(\.isHexDigit),
                  saved.presentation == nil || saved.presentation?.cardID == id else { throw ExamError.invalid("保留的专业卡迁移凭据不一致。") }
        }
        let activeSet = Set(active), packedValues = try cardValues()
        for (index, id) in record.cardIDs.enumerated() {
            let parkedInEngine = !activeSet.contains(id) || record.deferredCards?[id] != nil
            guard (packedValues[index] == Self.inert) == parkedInEngine else {
                throw ExamError.invalid("专业卡保留状态与引擎停用槽不一致。")
            }
        }
        for change in record.contentChanges ?? [] {
            guard change.beforeSnapshotSHA256 == StudySHA256.hex(change.beforeSnapshot),
                  change.beforeItems.map(\.id) == change.beforeCardIDs,
                  Array(record.cardIDs.prefix(change.beforeCardIDs.count)) == change.beforeCardIDs,
                  Set(change.beforeActiveCardIDs).isSubset(of: Set(change.beforeCardIDs)),
                  Set(change.afterActiveCardIDs).isSubset(of: Set(record.cardIDs)) else {
                throw ExamError.invalid("课程范围变更的保留快照或ID链不一致。")
            }
            _ = try PocketEngine(snapshot: change.beforeSnapshot)
        }
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
        if let shown = record.presentation {
            guard active.contains(shown.cardID), record.deferredCards?[shown.cardID] == nil else {
                throw ExamError.invalid("专业背卡当前卡不属于活动队列。")
            }
        }
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
    static func fresh(deck: RecallDeck, legacy: [RecallRecord] = [], now: Date = Date(), initiallyActive: Bool = true) throws -> ProfessionalRecallEngine {
        try deck.validate()
        let day = UInt32(try ConceptCalendar.studyDay(now))
        let ids = deck.cards.map(\.id), allowed = Set(ids)
        guard ids.count <= Int(XKL_WORD_COUNT) else { throw ExamError.invalid("专业卡数量超出单词引擎容量。") }
        var progress: [String: (RecallProgress, RecallRecord)] = [:]
        // Event-chain continuation outranks wall-clock timestamps. A device
        // clock adjustment must not resurrect a shorter already-graded prefix.
        var effective: [RecallRecord] = []
        for candidate in legacy {
            let superseded = legacy.contains { other in
                other.deckSHA256 == candidate.deckSHA256 && other.events.count > candidate.events.count &&
                    Array(other.events.prefix(candidate.events.count)) == candidate.events
            }
            if !superseded && !effective.contains(candidate) { effective.append(candidate) }
        }
        let sources = effective.sorted {
            let a = $0.events.last?.at ?? .distantPast, b = $1.events.last?.at ?? .distantPast
            if a != b { return a < b }
            if $0.events.count != $1.events.count { return $0.events.count < $1.events.count }
            return $0.deckSHA256 < $1.deckSHA256
        }
        func evidenceIDs(_ source: RecallRecord) -> Set<String> {
            Set(Array(source.state.progress.keys) + source.state.queue + (source.state.parkedQueue ?? []) +
                [source.state.shown?.cardID, source.state.result?.presentation.cardID].compactMap { $0 })
        }
        for index in sources.indices {
            for previous in sources.prefix(index) where !evidenceIDs(previous).isDisjoint(with: evidenceIDs(sources[index])) {
                let current = sources[index]
                let chain = previous.deckSHA256 == current.deckSHA256 &&
                    (Array(previous.events.prefix(current.events.count)) == current.events ||
                     Array(current.events.prefix(previous.events.count)) == previous.events)
                guard chain else { throw ExamError.invalid("同一卡片有非同一事件链的旧断点，不能用另一张卡的活动覆盖。") }
            }
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
            for (id, value) in old.state.progress where allowed.contains(id) {
                guard (0...10).contains(value.level), (18_000...50_180).contains(value.dueDay),
                      value.remembered >= 0, value.forgotten >= 0, let last = value.lastDay,
                      (18_000...Int(day)).contains(last) else { throw ExamError.invalid("旧背卡进度无效，拒绝推测历史。") }
                if let existing = progress[id], existing.0 != value {
                    let previous = existing.1
                    guard previous.deckSHA256 == old.deckSHA256 else {
                        throw ExamError.invalid("同一专业卡有不同档案的分叉进度，不能按其他卡的最后操作时间覆盖。")
                    }
                    if Array(old.events.prefix(previous.events.count)) == previous.events {
                        // A proven append-only continuation may replace its prefix state.
                    } else if Array(previous.events.prefix(old.events.count)) == old.events { continue }
                    else { throw ExamError.invalid("同一专业卡的旧记录不是同一事件链，停止自动覆盖。") }
                }
                progress[id] = (value, old)
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
        let initialPacked = initiallyActive ? packed : [UInt32](repeating: Self.inert, count: ids.count)
        let pointer = withUnsafeBytes(of: &stream) { streamBytes in
            initialPacked.withUnsafeBufferPointer { cards in
                xkl_engine_import_cards(UInt32(ids.count), cards.baseAddress, day,
                    initiallyActive ? (shown.flatMap { ids.firstIndex(of: $0.cardID) }.map(UInt32.init) ?? UInt32.max) : UInt32.max,
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
        var record = ProfessionalRecallRecord(subject: deck.subject, cardIDs: ids, snapshot: snapshot,
            snapshotSHA256: StudySHA256.hex(snapshot),
            analysis: StudyAnalysisSettings(streamID: try temporary.streamID, nextSequence: 1, now: now),
            presentation: initiallyActive ? shown.map { ProfessionalRecallPresentation(id: $0.id, cardID: $0.cardID, revealed: false) } : nil,
            attempts: [], volumes: [], migration: migration)
        record.retainedItems = deck.cards
        record.activeCardIDs = initiallyActive ? ids : []
        record.parkedCards = [:]; record.deferredCards = [:]; record.contentChanges = []
        if !initiallyActive {
            for (index, id) in ids.enumerated() {
                let p = shown?.cardID == id ? ProfessionalRecallPresentation(id: shown!.id, cardID: id, revealed: shown!.revealed) : nil
                record.parkedCards?[id] = ProfessionalRecallTransferState(cardID: id, subject: deck.subject,
                    packed: packed[index], stageMask: p == nil ? 0 : 1,
                    failedRound: packed[index] & (1 << 23) != 0 ? 2 : 0, presentation: p,
                    sourceScope: "legacy-import", sourceSnapshotSHA256: record.snapshotSHA256, sourceSequence: 0)
            }
        }
        return try Self(deck: deck, record: record)
    }

    func start(day: UInt32, now: Date = Date()) throws {
        guard day >= (try engine.info.day) else { throw ExamError.invalid("手机日期早于上次背卡日期，原记录已保留。") }
        if try engine.info.has_task == 0, !(record.deferredCards ?? [:]).isEmpty {
            try transaction { try activateDeferred(now: now) }
        }
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

    func dueCount(on day: UInt32) -> Int {
        engine.dueCount(on: day, limit: record.cardIDs.count) + (record.deferredCards ?? [:]).values.filter {
            $0.packed & (1 << 20) != 0 && $0.packed & (1 << 21) == 0 &&
            (1...10).contains(($0.packed >> 16) & 15) && ($0.packed & 65_535) <= day
        }.count
    }

    func transferState(for cardID: String, sourceScope: String) throws -> ProfessionalRecallTransferState? {
        guard let index = record.cardIDs.firstIndex(of: cardID) else { return nil }
        let saved = record.deferredCards?[cardID] ?? (!activeCardIDs.contains(cardID) ? record.parkedCards?[cardID] : nil)
        if let saved { return saved }
        let bytes = try engine.snapshot()
        let pointer = bytes.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard let pointer else { throw ExamError.invalid("无法核对迁移前的专业卡状态。") }
        defer { xkl_engine_free(pointer) }
        var failed: UInt32 = 0
        let mask = xkl_engine_pending_stages(pointer, UInt32(index), &failed)
        return ProfessionalRecallTransferState(cardID: cardID, subject: deck.subject,
            packed: xkl_engine_card(pointer, UInt32(index)), stageMask: UInt8(mask), failedRound: UInt8(failed),
            presentation: record.presentation?.cardID == cardID ? record.presentation : nil,
            sourceScope: sourceScope, sourceSnapshotSHA256: StudySHA256.hex(bytes), sourceSequence: try engine.info.log_records)
    }

    /// Content boundaries preserve every ID and prior snapshot. Removed cards are
    /// parked, never graded as familiar. Incoming unfinished checks wait for a
    /// task boundary so the unchanged 25-new / 50-active limits remain valid.
    func reconcile(to catalog: RecallDeck, importing: [String: ProfessionalRecallTransferState] = [:], now: Date = Date()) throws {
        guard catalog.subject == deck.subject, catalog.bankID == deck.bankID,
              Set(catalog.cards.map(\.id)).count == catalog.cards.count else { throw ExamError.invalid("课程更新科目或卡片ID无效。") }
        if !catalog.cards.isEmpty { try catalog.validate() }
        let wanted = Set(catalog.cards.map(\.id)), oldActive = Set(activeCardIDs)
        let desiredByID = Dictionary(uniqueKeysWithValues: catalog.cards.map { ($0.id, $0) })
        var items = deck.cards.map { desiredByID[$0.id] ?? $0 }
        let known = Set(record.cardIDs)
        items += catalog.cards.filter { !known.contains($0.id) }
        try RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: items).validate()
        let updatedActive = items.map(\.id).filter { wanted.contains($0) }
        guard importing.allSatisfy({ id, value in id == value.cardID && wanted.contains(id) && value.subject == deck.subject }) else {
            throw ExamError.invalid("跨范围迁入卡片身份与课程不一致。")
        }
        let applicable = importing.filter { !oldActive.contains($0.key) }
        if items == deck.cards, updatedActive == activeCardIDs, applicable.isEmpty { return }
        try transaction {
            let beforeSnapshot = try engine.snapshot(), beforeIDs = record.cardIDs, beforeItems = deck.cards, beforeActive = activeCardIDs
            let oldPresentation = record.presentation
            var parked = record.parkedCards ?? [:], deferred = record.deferredCards ?? [:]
            var parkedNow: [ProfessionalRecallTransferState] = []
            for id in beforeActive where !wanted.contains(id) {
                if let state = try transferState(for: id, sourceScope: "scope-before-update") {
                    parked[id] = state; parkedNow.append(state)
                }
                deferred.removeValue(forKey: id)
            }
            let oldValues = try cardValues()
            var values = oldValues + [UInt32](repeating: 0, count: items.count - oldValues.count)
            var enabled = [UInt8](repeating: 0, count: items.count)
            for (index, item) in items.enumerated() where wanted.contains(item.id) {
                let id = item.id
                if !oldActive.contains(id) {
                    if let source = applicable[id] ?? parked[id] {
                        if source.stageMask != 0 {
                            deferred[id] = source
                            values[index] = Self.inert
                        } else { values[index] = source.packed; deferred.removeValue(forKey: id) }
                    } else { values[index] = 0 }
                }
                enabled[index] = deferred[id] == nil ? 1 : 0
            }
            record.parkedCards = parked; record.deferredCards = deferred
            try applyCollection(oldCount: beforeIDs.count, enabled: enabled, values: values,
                stages: [UInt8](repeating: 0, count: items.count), failures: [UInt8](repeating: 0, count: items.count))
            record.cardIDs = items.map(\.id); record.retainedItems = items; record.activeCardIDs = updatedActive
            deck = RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: items)
            record.contentChanges = (record.contentChanges ?? []) + [ProfessionalRecallContentBoundary(at: now,
                beforeSnapshot: beforeSnapshot, beforeSnapshotSHA256: StudySHA256.hex(beforeSnapshot),
                beforeCardIDs: beforeIDs, beforeActiveCardIDs: beforeActive, beforeItems: beforeItems,
                parked: parkedNow, imported: applicable.keys.sorted().compactMap { applicable[$0] }, afterActiveCardIDs: updatedActive)]
            try present(keeping: oldPresentation)
            if try engine.info.has_task == 0 { try activateDeferred(now: now) }
        }
    }

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
        if let deferred = record.deferredCards?[id] { return deferred.packed }
        if !activeCardIDs.contains(id), let parked = record.parkedCards?[id] { return parked.packed }
        return try cardValues()[index]
    }

    func stats(on day: UInt32) throws -> ProfessionalRecallStats {
        let raw = try cardValues(), allowed = Set(activeCardIDs)
        let values = record.cardIDs.enumerated().filter { allowed.contains($0.element) }.map {
            record.deferredCards?[$0.element]?.packed ?? raw[$0.offset]
        }
        let introduced = values.filter { $0 != 0 }.count
        return ProfessionalRecallStats(total: values.count, introduced: introduced, unintroduced: values.count - introduced,
            due: values.filter { $0 & (1 << 20) != 0 && $0 & (1 << 21) == 0 && (1...10).contains(($0 >> 16) & 15) && $0 & 65_535 <= day }.count,
            firstKnown: values.filter { $0 & (1 << 20) != 0 && ($0 >> 16) & 15 == 0 && $0 & (1 << 22) == 0 }.count,
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
        let snapshot = try engine.snapshot()
        let pointer = snapshot.withUnsafeBytes {
            xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard let pointer else { throw ExamError.invalid("专业背卡快照无法读取。") }
        defer { xkl_engine_free(pointer) }
        return record.cardIDs.indices.map { xkl_engine_card(pointer, UInt32($0)) }
    }

    private func applyCollection(oldCount: Int, enabled: [UInt8], values: [UInt32], stages: [UInt8], failures: [UInt8]) throws {
        let snapshot = try engine.snapshot()
        let pointer = snapshot.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard let pointer else { throw ExamError.invalid("课程范围迁移前快照校验失败。") }
        defer { xkl_engine_free(pointer) }
        let at = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        let success = enabled.withUnsafeBufferPointer { flags in values.withUnsafeBufferPointer { cards in
            stages.withUnsafeBufferPointer { stage in failures.withUnsafeBufferPointer { failure in
                xkl_engine_reconcile_collection(pointer, UInt32(oldCount), UInt32(values.count),
                    flags.baseAddress, cards.baseAddress, at, stage.baseAddress, failure.baseAddress)
            } }
        } }
        guard success else { throw ExamError.invalid("课程范围迁移未通过原引擎校验，原状态保持。") }
        var next = Data(count: xkl_engine_snapshot_size(pointer))
        let count = next.withUnsafeMutableBytes { xkl_engine_snapshot(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard count == next.count else { throw ExamError.invalid("课程范围迁移快照不完整。") }
        engine = try PocketEngine(snapshot: next)
    }

    private func activateDeferred(now: Date) throws {
        guard try engine.info.has_task == 0 else { return }
        var deferred = record.deferredCards ?? [:]
        guard !deferred.isEmpty else { return }
        let allowed = Set(activeCardIDs)
        var values = try cardValues(), enabled = record.cardIDs.map { UInt8(allowed.contains($0) && deferred[$0] == nil ? 1 : 0) }
        var stages = [UInt8](repeating: 0, count: values.count), failures = stages
        var selected: [ProfessionalRecallTransferState] = [], newCount = 0
        for (index, id) in record.cardIDs.enumerated() {
            guard allowed.contains(id), let state = deferred[id], selected.count < 50 else { continue }
            let isNew = state.packed & (1 << 20) == 0
            if isNew && newCount == 25 { continue }
            if isNew { newCount += 1 }
            selected.append(state); enabled[index] = 1; values[index] = state.packed
            stages[index] = state.stageMask; failures[index] = state.failedRound
        }
        guard !selected.isEmpty else { return }
        try applyCollection(oldCount: record.cardIDs.count, enabled: enabled, values: values, stages: stages, failures: failures)
        for state in selected { deferred.removeValue(forKey: state.cardID) }
        record.deferredCards = deferred
        let current = try engine.info
        let oldShown = Int(current.word) < record.cardIDs.count ? selected.first { $0.cardID == record.cardIDs[Int(current.word)] }?.presentation : nil
        if oldShown?.revealed == true { try engine.reveal() }
        try present(keeping: oldShown)
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
        let before = record, beforeDeck = deck, wasStarted = started
        do {
            if rotateBefore, engine.volumeRecords + 8 >= (try engine.info.log_capacity) { try rotate() }
            try body()
            record.snapshot = try engine.snapshot()
            record.snapshotSHA256 = StudySHA256.hex(record.snapshot)
        } catch {
            engine = try PocketEngine(snapshot: before.snapshot)
            record = before
            deck = beforeDeck
            started = wasStarted
            throw error
        }
    }
}
