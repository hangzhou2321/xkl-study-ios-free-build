import Foundation
import StudyCore

/// The immutable import contains actual old self-ratings, including retracted
/// ones as evidence. Only unretracted ratings are replayed into either model.
struct HandbookDualHistoricalRating: Codable, Equatable {
    let sourceAttemptID: UUID
    let sourceSequence: UInt32
    let sourceRevision: UInt32
    let cardID: String
    let remembered: Bool
    let at: Date
    let day: UInt32
    let retracted: Bool
}

struct HandbookDualFrozen: Codable, Equatable {
    var presentation: HandbookCardPresentation
    let card: HandbookCard
    let guide: HandbookCardPackage.MemoryGuide?
}

/// This event stream is independent of both the old word stream and exam grades.
struct HandbookDualEvent: Codable, Equatable {
    let id: UUID
    let sequence: Int
    let kind: String
    let at: Date
    let day: UInt32
    let utcOffsetSeconds: Int
    let cardID: String?
    let presentationID: UUID?
    let remembered: Bool?
    let round: [String]?
    let next: HandbookDualFrozen?
}

struct HandbookDualLastRating: Codable, Equatable {
    let day: UInt32
    let at: Date
    let remembered: Bool
}

struct HandbookDualFSRSState: Codable, Equatable {
    var format = "xkl-handbook-dual-fsrs-v1"
    let subject: ConceptSubject
    let packageID: String
    /// C slots already issued by the old engine; later content may only append IDs.
    let legacyIDs: [String]
    /// Previously inactive slots stay parked; new content appends as active.
    let legacyActiveIDs: [String]
    let legacyAnchorSHA256: String
    let legacyPacked: [String: UInt32]
    let legacyRatings: [HandbookDualHistoricalRating]
    let legacySeen: [String]
    let initialShown: HandbookDualFrozen?
    /// Carries the old frozen head and selects the rest without marking them viewed.
    var initialQueue: [String]
    let migratedAt: Date
    let migratedDay: UInt32
    var ids: [String]
    var events: [HandbookDualEvent] = []
    var daily: [String: FSRS6Shadow.Memory] = [:]
    var all: [String: FSRS6Shadow.Memory] = [:]
    var familiar: [String] = []
    /// Cached projection, validated against a complete replay on restore.
    var seen: [String] = []
    var lastRating: [String: HandbookDualLastRating] = [:]
    var queue: [String] = []
    /// The kind is frozen for the entire selected round, even across midnight.
    var roundKind: String?
    var shown: HandbookDualFrozen?
}

/// Professional handbook recall only. The original word engine remains an
/// immutable source and English, mathematics and question-bank stores are not
/// touched. Daily-first controls due dates; all-ratings is a parallel model.
@MainActor final class HandbookDualFSRS {
    private(set) var package: HandbookCardPackage
    private(set) var state: HandbookDualFSRSState

    private struct LegacyAnchor: Encodable {
        let word: ProfessionalRecallRecord
        let ids: [String]
        let frozenCard: HandbookCard?
        let frozenToken: UUID?
        let frozenGuide: HandbookCardPackage.MemoryGuide?
    }
    private struct Derived {
        var daily: [String: FSRS6Shadow.Memory] = [:]
        var all: [String: FSRS6Shadow.Memory] = [:]
        var familiar = Set<String>()
        var seen = Set<String>()
        var queue: [String] = []
        var roundKind: String?
        var shown: HandbookDualFrozen?
        /// Derived only from unretracted genuine ratings; never from a reveal,
        /// familiar mark, postponed presentation, or selection into a round.
        var lastRating: [String: HandbookDualLastRating] = [:]
    }

    var presentation: HandbookCardPresentation? { state.shown?.presentation }
    var currentCard: HandbookCard? { state.shown?.card }
    var currentMemoryGuide: HandbookCardPackage.MemoryGuide? { state.shown?.guide }
    var inactiveCount: Int { state.legacyIDs.count - state.legacyActiveIDs.count }

    private static func anchor(_ legacy: HandbookWordState, count: Int) throws -> String {
        guard count >= 0, legacy.originalCardIDs.count >= count else { throw ExamError.invalid("旧卡映射长度异常，原记录保留。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return StudySHA256.hex(try encoder.encode(LegacyAnchor(word: legacy.word,
            ids: Array(legacy.originalCardIDs.prefix(count)), frozenCard: legacy.frozenCard,
            frozenToken: legacy.frozenToken, frozenGuide: legacy.frozenGuide)))
    }

    private static func finite(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (1_555_027_200...4_320_172_800).contains(date.timeIntervalSince1970)
    }
    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
    private static func day(_ date: Date) throws -> UInt32 {
        guard finite(date) else { throw ExamError.invalid("请检查手机日期；旧记录已保留。") }
        return UInt32(try ConceptCalendar.studyDay(date))
    }
    private static func catalog(_ package: HandbookCardPackage, ids: [String]) -> RecallDeck {
        .init(subject: package.subject, bankID: package.subject.bankID, cards: ids.indices.map { index in
            .init(conceptID: "handbook", conceptTitle: "Handbook slot",
                  card: .init(id: "handbook:\(index)", prompt: "slot \(index)", answer: "slot \(index)"))
        })
    }
    private static func retractedRevisions(_ events: [StudyEvent]) throws -> Set<UInt32> {
        var retracted = Set<UInt32>()
        for undo in events where undo.kind == 8 {
            guard undo.undoRevision != UInt32.max else { throw ExamError.invalid("旧调度存在无法确定目标的撤销，停止迁移并保留原记录。") }
            let matches = events.filter { $0.sequence < undo.sequence && $0.word == undo.word &&
                ($0.kind == 5 || $0.kind == 7) && $0.afterRevision == undo.undoRevision }
            guard matches.count == 1, retracted.insert(undo.undoRevision).inserted else {
                throw ExamError.invalid("旧调度撤销目标不唯一或重复，停止迁移。")
            }
        }
        return retracted
    }

    init(legacy: HandbookWordState, now: Date = Date()) throws {
        let today = try Self.day(now)
        // The old adapter performs its complete snapshot/log/mapping validation.
        _ = try HandbookWordEngine(state: legacy)
        let ids = legacy.originalCardIDs, record = legacy.word
        guard (record.deferredCards ?? [:]).isEmpty else {
            throw ExamError.invalid("旧档仍有未完成的暂存卡，暂不切换双FSRS；旧进度和原档已保留。")
        }
        guard record.subject == legacy.package.subject, record.cardIDs.count == ids.count,
              Set(ids).count == ids.count, Set(ids) == Set(legacy.package.cards.map(\.id)) else {
            throw ExamError.invalid("旧宝典卡片ID与调度槽不一致，停止迁移。")
        }
        let core = try ProfessionalRecallEngine(deck: Self.catalog(legacy.package, ids: ids), record: record)
        let clock = try core.info
        let observedTimes = [record.migration.at, record.analysis.activatedAt] +
            record.analysis.changes.map(\.changedAt) + (record.postponements ?? []).map(\.at) +
            (record.contentChanges ?? []).map(\.at)
        guard clock.day <= today, clock.selection_day <= today,
              observedTimes.allSatisfy({ Self.finite($0) && $0 <= now }) else {
            throw ExamError.invalid("旧卡调度日期晚于手机日期，停止迁移并保留原记录。")
        }
        let retracted = try Self.retractedRevisions(core.allEvents())
        var packed: [String: UInt32] = [:], byAlias: [String: String] = [:]
        for index in ids.indices {
            let alias = record.cardIDs[index], id = ids[index]
            guard let value = try core.packedCard(id: alias) else { throw ExamError.invalid("旧卡进度槽缺失，停止迁移。") }
            packed[id] = value; byAlias[alias] = id
        }
        let oldActive = Set(record.activeCardIDs ?? record.cardIDs)
        let activeIDs = ids.indices.filter { oldActive.contains(record.cardIDs[$0]) }.map { ids[$0] }
        var oldRatings: [HandbookDualHistoricalRating] = [], lastDate: Date?, lastDay: UInt32?
        for item in record.attempts {
            guard let id = byAlias[item.cardID], Self.finite(item.at), item.at <= now,
                  (18_000...50_000).contains(item.day), item.day <= today,
                  lastDate == nil || item.at >= lastDate!, lastDay == nil || item.day >= lastDay! else {
                throw ExamError.invalid("旧自评时间或映射异常，停止迁移并保留原记录。")
            }
            oldRatings.append(.init(sourceAttemptID: item.id, sourceSequence: item.engineSequence,
                sourceRevision: item.afterRevision, cardID: id, remembered: item.remembered,
                at: item.at, day: item.day, retracted: retracted.contains(item.afterRevision)))
            lastDate = item.at; lastDay = item.day
        }
        var seen = Set(record.attempts.compactMap { byAlias[$0.cardID] })
        seen.formUnion((record.postponements ?? []).compactMap { byAlias[$0.cardID] })
        // Imported learned slots are real prior progress even if the newer
        // word stream has no actual attempt to replay into either FSRS model.
        seen.formUnion(packed.filter { $0.value & ((1 << 20) | (1 << 21)) != 0 }.map(\.key))
        var shown: HandbookDualFrozen?
        if let old = record.presentation {
            guard let card = legacy.frozenCard, let id = byAlias[old.cardID], card.id == id,
                  legacy.frozenToken == old.id else { throw ExamError.invalid("旧卡中断断点缺失，停止迁移。") }
            // The old presentation UI used migration.at, which is not evidence
            // of its true show time. This is the transfer time, not a new view.
            shown = .init(presentation: .init(id: old.id, cardID: id, definitionID: card.definitionID,
                                              revealed: old.revealed, shownAt: now),
                          card: card, guide: legacy.frozenGuide)
            seen.insert(id)
        }
        self.package = legacy.package
        var initial = HandbookDualFSRSState(subject: legacy.package.subject, packageID: legacy.package.id,
            legacyIDs: ids, legacyActiveIDs: activeIDs, legacyAnchorSHA256: try Self.anchor(legacy, count: ids.count), legacyPacked: packed,
            legacyRatings: oldRatings, legacySeen: seen.sorted(), initialShown: shown,
            initialQueue: shown.map { [$0.presentation.cardID] } ?? [], migratedAt: now, migratedDay: today, ids: ids)
        var derived = try Self.replay(initial)
        if let id = shown?.presentation.cardID {
            initial.initialQueue = Self.select(ids: Self.activeIDs(initial), daily: derived.daily, packed: packed,
                familiar: derived.familiar, now: now, today: today, retainedHead: id)
            derived = try Self.replay(initial)
        }
        Self.assign(derived, to: &initial)
        self.state = initial
    }

    init(state: HandbookDualFSRSState, package: HandbookCardPackage, ids: [String]) throws {
        try package.validate()
        guard state.format == "xkl-handbook-dual-fsrs-v1", state.subject == package.subject,
              state.packageID == package.id, state.ids == ids, Set(ids).count == ids.count,
              Set(ids) == Set(package.cards.map(\.id)), Array(ids.prefix(state.legacyIDs.count)) == state.legacyIDs,
              Set(state.legacyPacked.keys) == Set(state.legacyIDs),
              state.legacyActiveIDs == state.legacyIDs.filter({ Set(state.legacyActiveIDs).contains($0) }),
              state.legacyAnchorSHA256.count == 64, state.legacyAnchorSHA256.allSatisfy(\.isHexDigit) else {
            throw ExamError.invalid("双FSRS卡片身份与原档案不一致，原记录保留。")
        }
        let derived = try Self.replay(state)
        guard derived.daily == state.daily, derived.all == state.all,
              derived.familiar.sorted() == state.familiar, derived.queue == state.queue,
              derived.seen.sorted() == state.seen, derived.lastRating == state.lastRating,
              derived.roundKind == state.roundKind,
              derived.shown == state.shown else { throw ExamError.invalid("双FSRS状态与事件回放不一致，原记录保留。") }
        self.package = package; self.state = state
    }

    /// The host retains `legacy.word` and the initial frozen content byte for
    /// byte. New package IDs may appear only after the old prefix.
    func validateLegacy(_ legacy: HandbookWordState) throws {
        guard legacy.package.id == state.packageID, legacy.package.subject == state.subject,
              Array(legacy.originalCardIDs.prefix(state.legacyIDs.count)) == state.legacyIDs,
              try Self.anchor(legacy, count: state.legacyIDs.count) == state.legacyAnchorSHA256 else {
            throw ExamError.invalid("双FSRS关联的旧记录已变化，停止写入并保留原档。")
        }
        let old = legacy.word
        guard old.cardIDs.count == state.legacyIDs.count, old.attempts.count == state.legacyRatings.count,
              (old.deferredCards ?? [:]).isEmpty else {
            throw ExamError.invalid("双FSRS历史条数与旧档不一致。")
        }
        let activeAliases = Set(old.activeCardIDs ?? old.cardIDs)
        let activeIDs = state.legacyIDs.indices.filter { activeAliases.contains(old.cardIDs[$0]) }.map { state.legacyIDs[$0] }
        guard activeIDs == state.legacyActiveIDs else { throw ExamError.invalid("双FSRS活动范围与旧档不一致。") }
        let core = try ProfessionalRecallEngine(deck: Self.catalog(legacy.package, ids: state.legacyIDs), record: old)
        let retracted = try Self.retractedRevisions(core.allEvents())
        let aliases = Dictionary(uniqueKeysWithValues: zip(old.cardIDs, state.legacyIDs))
        for (index, id) in state.legacyIDs.enumerated() {
            guard try core.packedCard(id: old.cardIDs[index]) == state.legacyPacked[id] else {
                throw ExamError.invalid("双FSRS旧卡槽与原快照不一致。")
            }
        }
        for (source, migrated) in zip(old.attempts, state.legacyRatings) {
            guard migrated.sourceAttemptID == source.id, migrated.sourceSequence == source.engineSequence,
                  migrated.sourceRevision == source.afterRevision, migrated.cardID == aliases[source.cardID],
                  migrated.remembered == source.remembered, migrated.at == source.at, migrated.day == source.day,
                  migrated.retracted == retracted.contains(source.afterRevision) else {
                throw ExamError.invalid("双FSRS历史自评与旧档不一致。")
            }
        }
        var seen = Set(old.attempts.compactMap { aliases[$0.cardID] })
        seen.formUnion((old.postponements ?? []).compactMap { aliases[$0.cardID] })
        seen.formUnion(state.legacyPacked.filter { $0.value & ((1 << 20) | (1 << 21)) != 0 }.map(\.key))
        if let shown = old.presentation {
            guard let initial = state.initialShown, let id = aliases[shown.cardID],
                  initial.presentation.id == shown.id, initial.presentation.cardID == id,
                  initial.presentation.revealed == shown.revealed,
                  initial.presentation.shownAt == state.migratedAt,
                  initial.card == legacy.frozenCard, initial.guide == legacy.frozenGuide,
                  legacy.frozenToken == shown.id else { throw ExamError.invalid("双FSRS继承的旧断点不一致。") }
            seen.insert(id)
        } else if state.initialShown != nil { throw ExamError.invalid("双FSRS存在多余旧断点。") }
        guard seen.sorted() == state.legacySeen else { throw ExamError.invalid("双FSRS旧卡已见状态与原档不一致。") }
    }
    func fork() throws -> HandbookDualFSRS { try .init(state: state, package: package, ids: state.ids) }

    private static func assign(_ value: Derived, to state: inout HandbookDualFSRSState) {
        state.daily = value.daily; state.all = value.all; state.familiar = value.familiar.sorted()
        state.seen = value.seen.sorted(); state.lastRating = value.lastRating
        state.queue = value.queue; state.roundKind = value.roundKind; state.shown = value.shown
    }
    private static func validShown(_ value: HandbookDualFrozen, head: String, at: Date? = nil) -> Bool {
        let p = value.presentation
        return p.cardID == head && p.cardID == value.card.id && p.definitionID == value.card.definitionID &&
            (value.guide == nil || (value.guide?.cardID == head && value.guide?.isValid == true)) &&
            (at == nil || (p.shownAt == at! && !p.revealed)) && finite(p.shownAt)
    }
    private static func replay(_ state: HandbookDualFSRSState) throws -> Derived {
        guard finite(state.migratedAt), (18_000...50_000).contains(state.migratedDay), Set(state.ids).count == state.ids.count,
              Set(state.legacyIDs).count == state.legacyIDs.count,
              state.legacyActiveIDs == state.legacyIDs.filter({ Set(state.legacyActiveIDs).contains($0) }),
              Array(state.ids.prefix(state.legacyIDs.count)) == state.legacyIDs,
              Set(state.legacyPacked.keys) == Set(state.legacyIDs),
              Set(state.legacySeen).count == state.legacySeen.count,
              Set(state.legacySeen).isSubset(of: Set(state.legacyIDs)),
              Set(state.legacyRatings.map(\.sourceAttemptID)).count == state.legacyRatings.count,
              Set(state.legacyRatings.map(\.sourceSequence)).count == state.legacyRatings.count else {
            throw ExamError.invalid("双FSRS迁移凭据无效，原档保留。")
        }
        let ids = Set(state.ids), active = Set(activeIDs(state))
        var d = Derived(), previous: Date?, previousDay: UInt32?, previousSequence: UInt32 = 0
        d.seen = Set(state.legacySeen)
        for (id, value) in state.legacyPacked where value & (1 << 21) != 0 { d.familiar.insert(id) }
        for item in state.legacyRatings {
            guard ids.contains(item.cardID), state.legacyIDs.contains(item.cardID), finite(item.at),
                  item.at <= state.migratedAt, (18_000...50_000).contains(item.day),
                  item.sourceSequence > previousSequence, previous == nil || item.at >= previous!,
                  previousDay == nil || item.day >= previousDay! else { throw ExamError.invalid("旧自评顺序或时间无效。") }
            previous = item.at; previousDay = item.day; previousSequence = item.sourceSequence
            d.seen.insert(item.cardID)
            if item.retracted { continue }
            let rating = item.remembered ? 3 : 1
            if d.daily[item.cardID]?.lastDay != item.day {
                d.daily[item.cardID] = try FSRS6Shadow.review(d.daily[item.cardID], day: item.day,
                    rating: rating, timestampMs: milliseconds(item.at)).memory
            }
            d.all[item.cardID] = try FSRS6Shadow.review(d.all[item.cardID], day: item.day,
                rating: rating, timestampMs: milliseconds(item.at)).memory
            d.lastRating[item.cardID] = .init(day: item.day, at: item.at, remembered: item.remembered)
        }
        var tokens = Set<UUID>()
        if let initial = state.initialShown {
            let id = initial.presentation.cardID
            guard active.contains(id), !d.familiar.contains(id), validShown(initial, head: id),
                  state.initialQueue.first == id, (1...20).contains(state.initialQueue.count),
                  Set(state.initialQueue).count == state.initialQueue.count,
                  Set(state.initialQueue).isSubset(of: active),
                  Set(state.initialQueue).isDisjoint(with: d.familiar),
                  tokens.insert(initial.presentation.id).inserted else { throw ExamError.invalid("旧卡冻结断点无效。") }
            for other in state.initialQueue.dropFirst() {
                if let due = dueDay(id: other, daily: d.daily, packed: state.legacyPacked) {
                    guard due <= state.migratedDay, isDue(id: other, daily: d.daily, packed: state.legacyPacked,
                        now: state.migratedAt, day: state.migratedDay) else { throw ExamError.invalid("迁移队列包含未到期卡。") }
                } else if !isNew(id: other, daily: d.daily, packed: state.legacyPacked) {
                    throw ExamError.invalid("迁移队列错误重建已会卡。")
                }
            }
            d.queue = state.initialQueue; d.roundKind = "legacy"; d.shown = initial; d.seen.insert(id)
        } else if !state.initialQueue.isEmpty { throw ExamError.invalid("迁移队列缺少旧断点。") }
        previous = state.migratedAt; previousDay = state.migratedDay
        var eventIDs = Set<UUID>()
        func acceptNext(_ next: HandbookDualFrozen?, _ queue: [String], _ at: Date) throws -> HandbookDualFrozen? {
            guard let head = queue.first else {
                guard next == nil else { throw ExamError.invalid("空队列存在多余断点。") }; return nil
            }
            guard let next, validShown(next, head: head, at: at), tokens.insert(next.presentation.id).inserted else {
                throw ExamError.invalid("双FSRS新卡断点无效或重复。")
            }
            d.seen.insert(head); return next
        }
        for (index, event) in state.events.enumerated() {
            guard event.sequence == index + 1, eventIDs.insert(event.id).inserted, finite(event.at),
                  event.at >= previous!, (18_000...50_000).contains(event.day),
                  (-50_400...50_400).contains(event.utcOffsetSeconds),
                  Int(floor((event.at.timeIntervalSince1970 + Double(event.utcOffsetSeconds)) / 86_400)) == Int(event.day),
                  previousDay == nil || event.day >= previousDay! else { throw ExamError.invalid("双FSRS事件时间或顺序异常。") }
            previous = event.at; previousDay = event.day
            switch event.kind {
            case "start", "retry":
                guard d.queue.isEmpty, d.shown == nil, let round = event.round,
                      !round.isEmpty, round.count <= 20, Set(round).count == round.count,
                      Set(round).isSubset(of: active), Set(round).isDisjoint(with: d.familiar),
                      event.cardID == nil, event.presentationID == nil, event.remembered == nil else { throw ExamError.invalid("双FSRS新轮无效。") }
                if event.kind == "retry" {
                    let eligible = Set(retryCandidates(ids: activeIDs(state), lastRating: d.lastRating,
                        familiar: d.familiar, queued: Set(d.queue), now: event.at, day: event.day))
                    guard Set(round).isSubset(of: eligible) else { throw ExamError.invalid("补练包含未满等待时间或不符合条件的卡。") }
                } else {
                    for id in round {
                        if let due = dueDay(id: id, daily: d.daily, packed: state.legacyPacked) {
                            guard due <= event.day, isDue(id: id, daily: d.daily, packed: state.legacyPacked,
                                now: event.at, day: event.day) else { throw ExamError.invalid("未到期卡片进入复习。") }
                        } else if !isNew(id: id, daily: d.daily, packed: state.legacyPacked) {
                            throw ExamError.invalid("原已会卡片不可重建为新卡。")
                        }
                    }
                }
                d.queue = round; d.roundKind = event.kind == "retry" ? "retry" : "main"
                d.shown = try acceptNext(event.next, d.queue, event.at)
            case "reveal":
                guard event.round == nil, event.next == nil, event.remembered == nil,
                      let shown = d.shown, shown.presentation.id == event.presentationID,
                      shown.presentation.cardID == event.cardID, !shown.presentation.revealed else { throw ExamError.invalid("翻面事件无效。") }
                var next = shown; next.presentation.revealed = true; d.shown = next
            case "grade", "familiar", "postpone":
                guard event.round == nil, let shown = d.shown, d.queue.first == shown.presentation.cardID,
                      event.cardID == shown.presentation.cardID, event.presentationID == shown.presentation.id else {
                    throw ExamError.invalid("双FSRS自评或暂缓断点无效。")
                }
                let id = shown.presentation.cardID
                if event.kind == "grade" {
                    guard shown.presentation.revealed, let remembered = event.remembered else { throw ExamError.invalid("须先翻答案再自评。") }
                    let rating = remembered ? 3 : 1
                    // A user-initiated retry remains a retry even if the phone
                    // crossed midnight before the rating. It updates the all
                    // track only and must not become a new daily observation.
                    if d.roundKind != "retry" && d.daily[id]?.lastDay != event.day {
                        d.daily[id] = try FSRS6Shadow.review(d.daily[id], day: event.day, rating: rating,
                            timestampMs: milliseconds(event.at)).memory
                    }
                    d.all[id] = try FSRS6Shadow.review(d.all[id], day: event.day, rating: rating,
                        timestampMs: milliseconds(event.at)).memory
                    d.lastRating[id] = .init(day: event.day, at: event.at, remembered: remembered)
                    d.queue.removeFirst()
                } else if event.kind == "familiar" {
                    guard event.remembered == nil, d.familiar.insert(id).inserted else { throw ExamError.invalid("熟记事件无效。") }
                    d.queue.removeFirst()
                } else {
                    guard event.remembered == nil, d.queue.count > 1 else { throw ExamError.invalid("无法将最后一张卡再次延后。") }
                    d.queue.append(d.queue.removeFirst())
                }
                if d.queue.isEmpty { d.roundKind = nil }
                d.shown = try acceptNext(event.next, d.queue, event.at)
            default: throw ExamError.invalid("未知双FSRS事件。")
            }
        }
        return d
    }

    private static func dueDay(id: String, daily: [String: FSRS6Shadow.Memory], packed: [String: UInt32]) -> UInt32? {
        if let memory = daily[id] { return memory.dueDay }
        guard let p = packed[id], p & (1 << 21) == 0, (1...10).contains((p >> 16) & 15) else { return nil }
        let due = p & 65_535
        return due == 0 || due == 65_535 ? nil : due
    }
    private static func activeIDs(_ state: HandbookDualFSRSState) -> [String] {
        let legacy = Set(state.legacyIDs), active = Set(state.legacyActiveIDs)
        return state.ids.filter { !legacy.contains($0) || active.contains($0) }
    }
    private static func isNew(id: String, daily: [String: FSRS6Shadow.Memory], packed: [String: UInt32]) -> Bool {
        guard daily[id] == nil else { return false }
        let p = packed[id] ?? 0
        return p & (1 << 21) == 0 && p & (1 << 20) == 0 && ((p >> 16) & 15) == 0
    }
    /// The FSRS equation outputs whole-day intervals. Requiring both its
    /// calendar due date and the corresponding elapsed duration prevents a
    /// 23:59 answer becoming due one minute later. Old packed-only states have
    /// no trustworthy wall time and keep their original calendar due rule.
    private static func targetMilliseconds(_ memory: FSRS6Shadow.Memory) -> Int64? {
        guard let timestamp = memory.timestampMs, memory.dueDay >= memory.lastDay else { return nil }
        let (duration, productOverflow) = Int64(memory.dueDay - memory.lastDay).multipliedReportingOverflow(by: 86_400_000)
        guard !productOverflow else { return nil }
        let (target, sumOverflow) = timestamp.addingReportingOverflow(duration)
        return sumOverflow ? nil : target
    }
    private static func isDue(id: String, daily: [String: FSRS6Shadow.Memory], packed: [String: UInt32],
                              now: Date, day: UInt32) -> Bool {
        guard let due = dueDay(id: id, daily: daily, packed: packed), due <= day else { return false }
        guard let memory = daily[id], memory.timestampMs != nil else { return true }
        guard let target = targetMilliseconds(memory), finite(now) else { return false }
        return milliseconds(now) >= target
    }
    /// Optional same-day practice is a user-initiated queue, not an FSRS
    /// interval, and never creates an assessment by merely waiting/entering.
    private static func retryCandidates(ids: [String], lastRating: [String: HandbookDualLastRating],
                                        familiar: Set<String>, queued: Set<String>, now: Date, day: UInt32) -> [String] {
        return ids.filter { id in
            guard !familiar.contains(id), !queued.contains(id), let last = lastRating[id],
                  !last.remembered, last.day == day else { return false }
            return now.timeIntervalSince(last.at) >= 600
        }
    }
    private static func select(ids: [String], daily: [String: FSRS6Shadow.Memory], packed: [String: UInt32],
                               familiar: Set<String>, now: Date, today: UInt32, retainedHead: String? = nil) -> [String] {
        let due = ids.filter { id in id != retainedHead && !familiar.contains(id) &&
            isDue(id: id, daily: daily, packed: packed, now: now, day: today) }
        let fresh = ids.filter { id in id != retainedHead && !familiar.contains(id) &&
            isNew(id: id, daily: daily, packed: packed) }
        let headNew = retainedHead.map { isNew(id: $0, daily: daily, packed: packed) } ?? false
        let dueQuota = 10 - (retainedHead != nil && !headNew ? 1 : 0)
        let freshQuota = 10 - (retainedHead != nil && headNew ? 1 : 0)
        var selected = retainedHead.map { [$0] } ?? []
        selected += due.prefix(dueQuota); selected += fresh.prefix(freshQuota)
        var remaining = 20 - selected.count
        if remaining > 0 { let extra = Array(due.dropFirst(dueQuota).prefix(remaining)); selected += extra; remaining -= extra.count }
        if remaining > 0 { selected += fresh.dropFirst(freshQuota).prefix(remaining) }
        return selected
    }
    private func ensureTime(_ now: Date) throws -> UInt32 {
        let day = try Self.day(now)
        let last = state.events.last?.at ?? state.migratedAt
        let lastDay = state.events.last?.day ?? state.migratedDay
        guard now >= last, day >= lastDay else { throw ExamError.invalid("手机时间早于已有学习记录，原记录已保留。") }
        return day
    }
    private func frozen(_ id: String, now: Date) throws -> HandbookDualFrozen {
        guard let card = package.cards.first(where: { $0.id == id }) else { throw ExamError.invalid("所选卡片不存在。") }
        return .init(presentation: .init(id: UUID(), cardID: id, definitionID: card.definitionID,
                                         revealed: false, shownAt: now),
                     card: card, guide: package.memoryGuide(for: card))
    }
    private func event(_ kind: String, now: Date, day: UInt32, cardID: String? = nil,
                       presentationID: UUID? = nil, remembered: Bool? = nil,
                       round: [String]? = nil, next: HandbookDualFrozen? = nil) -> HandbookDualEvent {
        .init(id: UUID(), sequence: state.events.count + 1, kind: kind, at: now, day: day,
              utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: now), cardID: cardID,
              presentationID: presentationID, remembered: remembered, round: round, next: next)
    }
    private func commit(_ event: HandbookDualEvent) throws {
        var candidate = state; candidate.events.append(event)
        let result = try Self.replay(candidate); Self.assign(result, to: &candidate); state = candidate
    }
    func start(now: Date = Date()) throws {
        let today = try ensureTime(now)
        guard state.queue.isEmpty else { return }
        let selected = Self.select(ids: Self.activeIDs(state), daily: state.daily, packed: state.legacyPacked,
                                   familiar: Set(state.familiar), now: now, today: today)
        guard let head = selected.first else { return }
        try commit(event("start", now: now, day: today, round: selected, next: frozen(head, now: now)))
    }
    /// Counts all currently eligible items, which may require several optional
    /// rounds. A partially completed normal or retry round is never displaced.
    func retryCount(on now: Date = Date()) -> Int {
        guard let today = try? ensureTime(now) else { return 0 }
        return Self.retryCandidates(ids: Self.activeIDs(state), lastRating: state.lastRating, familiar: Set(state.familiar),
                                    queued: Set(state.queue), now: now, day: today).count
    }
    func startRetry(now: Date = Date()) throws {
        let today = try ensureTime(now)
        guard state.queue.isEmpty else { return }
        let selected = Array(Self.retryCandidates(ids: Self.activeIDs(state), lastRating: state.lastRating,
            familiar: Set(state.familiar), queued: Set(state.queue), now: now, day: today).prefix(20))
        guard let head = selected.first else { return }
        try commit(event("retry", now: now, day: today, round: selected, next: frozen(head, now: now)))
    }
    func reveal(token: UUID, now: Date = Date()) throws {
        guard let shown = state.shown, shown.presentation.id == token, !shown.presentation.revealed else { return }
        let today = try ensureTime(now)
        try commit(event("reveal", now: now, day: today, cardID: shown.presentation.cardID, presentationID: token))
    }
    func rate(remembered: Bool, token: UUID, now: Date = Date()) throws {
        guard let shown = state.shown, shown.presentation.id == token else { return }
        guard shown.presentation.revealed else { throw ExamError.invalid("请先主动回忆并翻开答案，再自评。") }
        let today = try ensureTime(now), rest = Array(state.queue.dropFirst())
        let next = try rest.first.map { try frozen($0, now: now) }
        try commit(event("grade", now: now, day: today, cardID: shown.presentation.cardID,
                         presentationID: token, remembered: remembered, next: next))
    }
    func markFamiliar(token: UUID, now: Date = Date()) throws {
        guard let shown = state.shown, shown.presentation.id == token else { return }
        let today = try ensureTime(now), rest = Array(state.queue.dropFirst())
        let next = try rest.first.map { try frozen($0, now: now) }
        try commit(event("familiar", now: now, day: today, cardID: shown.presentation.cardID,
                         presentationID: token, next: next))
    }
    @discardableResult func postpone(token: UUID, now: Date = Date()) throws -> Bool {
        guard let shown = state.shown, shown.presentation.id == token, state.queue.count > 1 else { return false }
        let today = try ensureTime(now), nextID = state.queue[1]
        try commit(event("postpone", now: now, day: today, cardID: shown.presentation.cardID,
                         presentationID: token, next: frozen(nextID, now: now)))
        return true
    }
    func updatePackage(_ incoming: HandbookCardPackage, ids: [String], now: Date = Date()) throws {
        _ = try ensureTime(now); try incoming.validate()
        guard incoming.id == package.id, incoming.subject == package.subject,
              incoming.revision.compare(package.revision, options: .numeric) != .orderedAscending,
              Array(ids.prefix(state.ids.count)) == state.ids, Set(ids).count == ids.count,
              Set(ids) == Set(incoming.cards.map(\.id)) else { throw ExamError.invalid("旧版本、删卡或重排槽位不能覆盖已有记录。") }
        var candidate = state; candidate.ids = ids
        let derived = try Self.replay(candidate); Self.assign(derived, to: &candidate)
        package = incoming; state = candidate
    }
    var nextDueAt: Date? {
        let familiar = Set(state.familiar)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        return Self.activeIDs(state).compactMap { id -> Date? in
            guard !familiar.contains(id), let day = Self.dueDay(id: id, daily: state.daily, packed: state.legacyPacked) else { return nil }
            let parts = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
            guard let calendarDue = local.date(from: parts) else { return nil }
            guard let memory = state.daily[id], memory.timestampMs != nil else { return calendarDue }
            guard let target = Self.targetMilliseconds(memory) else { return nil }
            return max(calendarDue, Date(timeIntervalSince1970: Double(target) / 1_000))
        }.min()
    }
    func stats(on now: Date = Date()) -> HandbookCardStats {
        let day = (try? Self.day(now)) ?? 0, familiar = Set(state.familiar)
        let active = Self.activeIDs(state), allowed = Set(active)
        let seen = state.seen.filter { allowed.contains($0) }.count
        let old = state.legacyRatings.filter { !$0.retracted && allowed.contains($0.cardID) }
        let recent = state.events.filter { $0.kind == "grade" && $0.cardID.map { allowed.contains($0) } == true }
        return .init(total: active.count, seen: seen,
            due: active.filter { id in !familiar.contains(id) &&
                Self.isDue(id: id, daily: state.daily, packed: state.legacyPacked, now: now, day: day) }.count,
            unseen: max(0, active.count - seen),
            remembered: old.filter(\.remembered).count + recent.filter { $0.remembered == true }.count,
            forgotten: old.filter { !$0.remembered }.count + recent.filter { $0.remembered == false }.count,
            nextDueAt: nextDueAt,
            ratedToday: old.filter { $0.day == day }.count + recent.filter { $0.day == day }.count,
            remainingToday: state.queue.count)
    }
}
