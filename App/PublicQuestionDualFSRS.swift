import Foundation
import CPocket
import StudyCore

/// Read-only evidence from the original Pocket task. Stages remain evidence;
/// they are not transformed into artificial historical answers.
struct PublicDualLegacyToken: Codable, Equatable {
    let word: UInt32
    let stage: UInt32
    let failedRound: UInt32
}

/// category: 0 loaded-new, 1 loaded-review, 2 unloaded-review, 3 unloaded-new.
struct PublicDualLegacyItem: Codable, Equatable {
    let word: UInt32
    let stageMask: UInt32
    let failedRound: UInt32
    let category: UInt32
}

struct PublicDualHistoricalRating: Codable, Equatable {
    let attemptID: UUID
    let sequence: UInt32
    let questionID: String
    let at: Date
    let day: UInt32
    let grade: Int32
    let retracted: Bool
}

struct PublicDualEvent: Codable, Equatable {
    let sequence: Int
    let kind: String
    let at: Date
    let day: UInt32
    let timeZoneID: String
    let round: [String]?
    let attempt: ExamAttempt?
}

struct PublicDualLastRating: Codable, Equatable {
    let day: UInt32
    let at: Date
    let remembered: Bool
}

struct PublicDualStats: Equatable {
    var sessionCount = 0
    var sessionPosition = 0
    var newRemaining = 0
    var reviewRemaining = 0
    var totalRemaining = 0
    var dueTodayCount = 0
    var reinforcementRemaining = 0
    var totalAnsweredCount = 0
    var wrongCount = 0
    var unseenQuestionCount = 0
    var newIntroducedToday = 0
    var carryRemaining = 0
    var retryAvailable = 0
    var retryNextAvailableAt: Date?
}

/// The old ExamDiskRecord and its volumes remain immutable, separately
/// archived bytes. New real events are kept here and never receive fake Pocket
/// sequence numbers or revisions.
struct PublicQuestionDualState: Codable, Equatable {
    var format = "xkl-public-question-dual-fsrs-v1"
    let bankID: String
    let bankSHA256: String
    let legacyAnchorSHA256: String
    let legacySnapshotSHA256: String
    let legacyIDs: [String]
    let legacyPacked: [String: UInt32]
    let legacyTokens: [PublicDualLegacyToken]
    let legacyItems: [PublicDualLegacyItem]
    let legacyRatings: [PublicDualHistoricalRating]
    let legacyAttempts: [ExamAttempt]
    let migratedAt: Date
    let migratedDay: UInt32
    let migrationTimeZoneID: String
    let initialCarry: [String]
    let initialQueue: [String]
    let initialFamiliar: [String]
    let legacyUndoableAttemptID: UUID?
    var events: [PublicDualEvent] = []
    var daily: [String: FSRS6Shadow.Memory] = [:]
    var all: [String: FSRS6Shadow.Memory] = [:]
    var lastRating: [String: PublicDualLastRating] = [:]
    var familiar: [String] = []
    var carry: [String] = []
    var queue: [String] = []
    var roundKind: String?
    var presentation: ExamPresentation?
    var answerReview: ExamAnswerReview?
    var previousOrders: [String: [String]]
    var taskID: UUID
    var lastUndoableAttemptID: UUID?
    var sessionCount: Int
    var completedCount: Int = 0
}

@MainActor final class PublicQuestionDualFSRS {
    let bank: ExamBank
    let hash: String
    private(set) var state: PublicQuestionDualState

    private struct Derived {
        var daily: [String: FSRS6Shadow.Memory] = [:]
        var all: [String: FSRS6Shadow.Memory] = [:]
        var lastRating: [String: PublicDualLastRating] = [:]
        var familiar = Set<String>()
        var carry: [String] = []
        var queue: [String] = []
        var roundKind: String?
        var lastUndoable: UUID?
        var sessionCount = 0
        var completedCount = 0
    }

    private static func fail(_ reason: String) -> ExamError {
        .invalid(reason + "；原题库记录已保留。")
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value)
    }
    private static func finite(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (1_555_027_200...4_320_172_800).contains(date.timeIntervalSince1970)
    }
    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
    private static func day(_ date: Date, timeZone: TimeZone = .current) throws -> UInt32 {
        guard finite(date) else { throw fail("手机日期异常") }
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = utc.date(from: local.dateComponents([.year, .month, .day], from: date)) else {
            throw fail("手机日期无法解析")
        }
        let value = Int(midnight.timeIntervalSince1970 / 86_400)
        guard (18_000...50_000).contains(value) else { throw fail("手机日期异常") }
        return UInt32(value)
    }

    /// `priorVolumeBytes` are the unchanged archive bytes, in reference order.
    /// Legacy items/tokens come from the read-only Pocket task capture API.
    init(migrating bank: ExamBank, hash: String, record: ExamDiskRecord,
         legacyRecordBytes: Data, priorVolumeBytes: [Data],
         legacyTokens: [PublicDualLegacyToken], legacyItems: [PublicDualLegacyItem],
         now: Date = Date()) throws {
        try bank.validate(); try record.validateContent(bank: bank, hash: hash)
        let decoded = try JSONDecoder().decode(ExamDiskRecord.self, from: legacyRecordBytes)
        guard try Self.encode(decoded) == Self.encode(record) else { throw Self.fail("迁移原档与当前题库不一致") }
        let zone = TimeZone.current
        let evidence = try Self.legacyEvidence(bank: bank, hash: hash, record: record,
            priorVolumeBytes: priorVolumeBytes, now: now, timeZone: zone)
        let old = try ExamLearningEngine(bank: bank, hash: hash, record: record)
        let info = try old.info
        let captured = try Self.capture(snapshot: record.snapshot, count: bank.questions.count, on: Self.day(now, timeZone: zone))
        guard captured.tokens == legacyTokens, captured.items == legacyItems else {
            throw Self.fail("旧任务清单与只读快照不一致")
        }
        if captured.canUndo {
            guard let id = record.lastUndoableAttemptID,
                  let original = evidence.attempts.first(where: { $0.id == id }),
                  Int(captured.undoWord) < bank.questions.count,
                  original.questionID == bank.questions[Int(captured.undoWord)].id,
                  !evidence.attempts.contains(where: { $0.undoneAttemptID == id }),
                  original.mode == "familiar" || (original.mode == "answer" && original.grade == 0) else {
                throw Self.fail("旧题库可撤销操作与原始快照不一致")
            }
        }
        guard legacyItems.count == Int(info.total_remaining),
              Set(legacyItems.map(\.word)).count == legacyItems.count,
              legacyItems.allSatisfy({ Int($0.word) < bank.questions.count && $0.category <= 3 && $0.failedRound <= 2 }),
              legacyTokens.allSatisfy({ Int($0.word) < bank.questions.count && $0.stage <= 7 && $0.failedRound <= 2 }),
              Set(legacyTokens.map { "\($0.word):\($0.stage)" }).count == legacyTokens.count else {
            throw Self.fail("旧任务待办身份或数量不一致")
        }
        let itemWords = Set(legacyItems.map(\.word))
        guard legacyTokens.allSatisfy({ itemWords.contains($0.word) }) else { throw Self.fail("旧任务阶段缺少对应题目") }
        for item in legacyItems {
            let tokens = legacyTokens.filter { $0.word == item.word }
            let mask = tokens.reduce(UInt32(0)) { $0 | (UInt32(1) << $1.stage) }
            guard item.stageMask == mask,
                  tokens.allSatisfy({ $0.failedRound == item.failedRound }),
                  (item.category < 2 ? !tokens.isEmpty : tokens.isEmpty) else {
                throw Self.fail("旧任务阶段与题目不一致")
            }
        }
        if info.has_task != 0 {
            guard let p = record.presentation, !legacyItems.isEmpty,
                  legacyItems[0].word == info.word, bank.questions[Int(info.word)].id == p.questionID else {
                throw Self.fail("旧题库当前题及待办不一致")
            }
        } else if record.presentation != nil || !legacyItems.isEmpty || !legacyTokens.isEmpty {
            throw Self.fail("旧题库已结束但仍存在待办")
        }
        let ids = bank.questions.map(\.id)
        let carry = legacyItems.map { ids[Int($0.word)] }
        let initialQueue = record.presentation == nil ? [] : Array(carry.prefix(20))
        let familiar = ids.filter { (evidence.packed[$0] ?? 0) & (1 << 21) != 0 }
        self.bank = bank; self.hash = hash
        var initial = PublicQuestionDualState(bankID: bank.id, bankSHA256: hash,
            legacyAnchorSHA256: StudySHA256.hex(legacyRecordBytes), legacySnapshotSHA256: record.snapshotSHA256,
            legacyIDs: ids, legacyPacked: evidence.packed, legacyTokens: legacyTokens,
            legacyItems: legacyItems, legacyRatings: evidence.ratings, legacyAttempts: evidence.attempts,
            migratedAt: now, migratedDay: try Self.day(now, timeZone: zone), migrationTimeZoneID: zone.identifier, initialCarry: carry,
            initialQueue: initialQueue, initialFamiliar: familiar,
            legacyUndoableAttemptID: info.can_undo != 0 ? record.lastUndoableAttemptID : nil,
            presentation: record.presentation, answerReview: record.answerReview,
            previousOrders: record.previousOrders, taskID: record.taskID,
            sessionCount: initialQueue.count)
        let derived = try Self.replay(initial, bank: bank)
        Self.assign(derived, to: &initial)
        try Self.validatePresentation(initial, bank: bank, hash: hash)
        self.state = initial
    }

    init(state: PublicQuestionDualState, bank: ExamBank, hash: String) throws {
        try bank.validate()
        guard state.format == "xkl-public-question-dual-fsrs-v1", state.bankID == bank.id,
              state.bankSHA256 == hash, state.legacyIDs == bank.questions.map(\.id),
              ExamContent.isHash(state.legacyAnchorSHA256), ExamContent.isHash(state.legacySnapshotSHA256),
              TimeZone(identifier: state.migrationTimeZoneID) != nil,
              Set(state.legacyPacked.keys) == Set(state.legacyIDs) else { throw Self.fail("双FSRS题库身份不一致") }
        let d = try Self.replay(state, bank: bank)
        guard Self.memoryCachesMatch(state.daily, d.daily), Self.memoryCachesMatch(state.all, d.all),
              state.lastRating == d.lastRating,
              state.familiar == d.familiar.sorted(), state.carry == d.carry,
              state.queue == d.queue, state.roundKind == d.roundKind,
              state.lastUndoableAttemptID == d.lastUndoable,
              state.sessionCount == d.sessionCount, state.completedCount == d.completedCount else {
            throw Self.fail("双FSRS缓存与真实事件回放不一致")
        }
        try Self.validatePresentation(state, bank: bank, hash: hash)
        self.bank = bank; self.hash = hash; self.state = state
    }

    /// FSRS uses libm pow/exp, whose last bits can differ across OS/CPU
    /// implementations. Accept only minute relative differences in the two
    /// floating values; identity and every discrete scheduling field must
    /// remain exact. The caller keeps the decoded cache, without rewriting it.
    private static func memoryCachesMatch(_ stored: [String: FSRS6Shadow.Memory],
                                          _ replayed: [String: FSRS6Shadow.Memory]) -> Bool {
        guard stored.count == replayed.count else { return false }
        func close(_ a: Double, _ b: Double) -> Bool {
            guard a.isFinite, b.isFinite else { return false }
            return a == b || abs(a - b) <= max(abs(a), abs(b)) * 1e-12
        }
        for (key, actual) in stored {
            guard let expected = replayed[key],
                  actual.stability.isFinite, actual.stability >= 0.001,
                  actual.difficulty.isFinite, (1...10).contains(actual.difficulty),
                  actual.lastDay == expected.lastDay, actual.dueDay == expected.dueDay,
                  actual.timestampMs == expected.timestampMs,
                  close(actual.stability, expected.stability),
                  close(actual.difficulty, expected.difficulty) else { return false }
        }
        return true
    }

    func validateLegacy(recordBytes: Data, priorVolumeBytes: [Data]) throws {
        guard StudySHA256.hex(recordBytes) == state.legacyAnchorSHA256 else { throw Self.fail("旧题库原档哈希变化") }
        let old = try JSONDecoder().decode(ExamDiskRecord.self, from: recordBytes)
        guard old.snapshotSHA256 == state.legacySnapshotSHA256 else { throw Self.fail("旧快照哈希变化") }
        let captured = try Self.capture(snapshot: old.snapshot, count: bank.questions.count, on: state.migratedDay)
        guard captured.tokens == state.legacyTokens, captured.items == state.legacyItems else {
            throw Self.fail("旧任务清单与原始快照不一致")
        }
        let oldCarry = captured.items.map { bank.questions[Int($0.word)].id }
        let oldQueue = old.presentation == nil ? [] : Array(oldCarry.prefix(20))
        guard state.initialCarry == oldCarry, state.initialQueue == oldQueue,
              state.legacyUndoableAttemptID == (captured.canUndo ? old.lastUndoableAttemptID : nil) else {
            throw Self.fail("旧任务起点或撤销身份不一致")
        }
        let hasNewGrade = state.events.contains { $0.kind == "answer" || $0.kind == "familiar" || $0.kind == "undo" }
        if !hasNewGrade, let original = old.presentation {
            guard let current = state.presentation, current.id == original.id,
                  current.questionID == original.questionID, current.optionOrder == original.optionOrder,
                  current.presentedAt == original.presentedAt, current.pending == original.pending,
                  current.supplementVisible == original.supplementVisible else {
                throw Self.fail("旧当前题的续学断点发生变化")
            }
        }
        guard let zone = TimeZone(identifier: state.migrationTimeZoneID) else { throw Self.fail("迁移时区无效") }
        let proof = try Self.legacyEvidence(bank: bank, hash: hash, record: old,
            priorVolumeBytes: priorVolumeBytes, now: state.migratedAt, timeZone: zone)
        guard proof.packed == state.legacyPacked, proof.ratings == state.legacyRatings,
              proof.attempts == state.legacyAttempts else { throw Self.fail("旧事件或旧题目槽与迁移证据不一致") }
    }

    var presentation: ExamPresentation? { state.presentation }
    var answerReview: ExamAnswerReview? { state.answerReview }
    var currentQuestion: ExamQuestion? { question(state.presentation?.questionID) }
    var displayPresentation: ExamPresentation? { state.answerReview?.presentation ?? state.presentation }
    var displayQuestion: ExamQuestion? { question(displayPresentation?.questionID) }
    var displayAttempt: ExamAttempt? { state.answerReview?.attempt ?? state.presentation?.pending }
    var isShowingResult: Bool { state.answerReview != nil || state.presentation?.pending != nil }
    var canUndo: Bool { state.lastUndoableAttemptID != nil && !isShowingResult && (state.presentation?.selectedOptionIDs.isEmpty ?? true) }
    var canUndoLegacy: Bool {
        state.legacyUndoableAttemptID != nil && !isShowingResult &&
        (state.presentation?.selectedOptionIDs.isEmpty ?? true) &&
        !state.events.contains(where: { $0.kind == "answer" || $0.kind == "familiar" || $0.kind == "undo" })
    }
    private func question(_ id: String?) -> ExamQuestion? { bank.questions.first { $0.id == id } }

    func start(now: Date = Date()) throws {
        guard state.queue.isEmpty, state.presentation == nil, state.answerReview == nil else { return }
        let day = try checkedDay(now)
        let round = Self.select(state: state, bank: bank, now: now, day: day)
        guard !round.isEmpty else { return }
        var next = state; next.taskID = UUID()
        try Self.append(kind: "start", round: round, attempt: nil, now: now, day: day, state: &next, bank: bank)
        Self.present(&next, bank: bank, now: now)
        state = next
    }

    /// Explicitly chosen wrong-question practice. This does not steal the
    /// unfinished page or the original carry, and affects only the all track.
    func startRetry(now: Date = Date()) throws {
        guard state.queue.isEmpty, state.presentation == nil, state.answerReview == nil else { return }
        let day = try checkedDay(now)
        let round = Array(Self.retryCandidates(state: state, now: now, day: day).prefix(20))
        guard !round.isEmpty else { return }
        var next = state; next.taskID = UUID()
        try Self.append(kind: "startRetry", round: round, attempt: nil, now: now, day: day, state: &next, bank: bank)
        Self.present(&next, bank: bank, now: now)
        state = next
    }

    func toggle(_ id: String, token: UUID?) throws {
        guard state.answerReview == nil, var p = state.presentation, p.id == token,
              p.pending == nil, let q = question(p.questionID), q.options.contains(where: { $0.id == id }) else { return }
        var selected = Set(p.selectedOptionIDs)
        if q.type == .multiple { if !selected.insert(id).inserted { selected.remove(id) } }
        else { selected = selected == [id] ? [] : [id] }
        p.selectedOptionIDs = selected.sorted(); state.presentation = p
    }

    func selectAndSubmit(_ id: String, presentationID: UUID?, now: Date = Date()) throws {
        guard let p = state.presentation, p.id == presentationID, state.answerReview == nil,
              p.pending == nil, let q = question(p.questionID), q.type != .multiple,
              q.options.contains(where: { $0.id == id }) else { return }
        var next = state; next.presentation?.selectedOptionIDs = [id]
        try Self.submit(&next, bank: bank, hash: hash, now: now)
        state = next
    }

    func submitAutomatically(presentationID: UUID?, now: Date = Date()) throws {
        guard let p = state.presentation, p.id == presentationID, p.pending == nil,
              state.answerReview == nil else { return }
        var next = state; try Self.submit(&next, bank: bank, hash: hash, now: now); state = next
    }

    func nextQuestion(presentationID: UUID?, now: Date = Date()) throws {
        if let review = state.answerReview, review.presentation.id == presentationID {
            state.answerReview = nil; return
        }
        guard let p = state.presentation, p.id == presentationID, let pending = p.pending else { return }
        // A legacy result that was visible but not yet graded: user explicitly
        // chooses Next, which is the first actual score in the new model.
        var next = state
        next.presentation?.pending = nil; next.presentation?.supplementVisible = false
        var realPending = pending
        realPending.gradingSource = p.supplementVisible ? "legacy-explicit-partial" : "legacy-pending-auto"
        try Self.grade(&next, bank: bank, hash: hash, shown: p, attempt: realPending,
                       grade: p.supplementVisible ? 3 : (pending.isCorrect ? 0 : 1), now: now)
        next.answerReview = nil
        state = next
    }

    func familiar(now: Date = Date()) throws {
        guard state.answerReview == nil, let p = state.presentation, p.pending == nil,
              let q = question(p.questionID) else { return }
        let day = try checkedDay(now)
        var a = Self.attempt(bank: bank, hash: hash, q: q, presentation: p, mode: "familiar", sessionID: state.taskID, now: now)
        a.grade = 2; a.gradedAt = now
        var next = state
        try Self.append(kind: "familiar", round: nil, attempt: a, now: now, day: day, state: &next, bank: bank)
        Self.present(&next, bank: bank, now: now); state = next
    }

    func undo(now: Date = Date()) throws {
        guard canUndo, let target = state.lastUndoableAttemptID,
              let original = state.events.last(where: { $0.attempt?.id == target })?.attempt,
              let q = question(original.questionID) else { return }
        let day = try checkedDay(now)
        let p = ExamPresentation(id: UUID(), questionID: q.id, optionOrder: original.optionOrder,
            selectedOptionIDs: [], pending: nil, supplementVisible: false, presentedAt: now)
        var a = Self.attempt(bank: bank, hash: hash, q: q, presentation: p, mode: "undo", sessionID: state.taskID, now: now)
        a.gradedAt = now; a.undoneAttemptID = target
        var next = state
        try Self.append(kind: "undo", round: nil, attempt: a, now: now, day: day, state: &next, bank: bank)
        next.previousOrders[q.id] = p.optionOrder; next.presentation = p; next.answerReview = nil
        state = next
    }

    func stats(now: Date = Date()) throws -> PublicDualStats {
        let day = try checkedDay(now)
        let allAttempts = state.legacyAttempts + state.events.compactMap(\.attempt)
        let undone = Set(allAttempts.compactMap(\.undoneAttemptID))
        let actual = allAttempts.filter { $0.mode != "undo" && !undone.contains($0.id) }
        var latest: [String: ExamAttempt] = [:]
        for a in actual { latest[a.questionID] = a }
        let known = Set(actual.map(\.questionID)).union(state.legacyIDs.filter { (state.legacyPacked[$0] ?? 0) & ((1 << 20) | (1 << 21)) != 0 })
        let fresh = state.queue.filter { Self.isFresh($0, state: state) }.count
        var out = PublicDualStats()
        out.sessionCount = state.sessionCount
        out.sessionPosition = state.sessionCount == 0 ? 0 : min(state.sessionCount, state.completedCount + (isShowingResult ? 0 : 1))
        out.newRemaining = fresh; out.reviewRemaining = state.queue.count - fresh
        out.totalRemaining = state.queue.count; out.carryRemaining = state.carry.count
        out.retryAvailable = Self.retryCandidates(state: state, now: now, day: day).count
        out.retryNextAvailableAt = Self.nextRetry(state: state, now: now, day: day)
        let newlyGraded = Self.newlyGradedIDs(state)
        out.dueTodayCount = state.legacyIDs.filter { Self.isDue($0, state: state, now: now, day: day, newlyGraded: newlyGraded) }.count
        out.totalAnsweredCount = latest.count; out.wrongCount = latest.values.filter { $0.mode == "answer" && !$0.isCorrect }.count
        out.unseenQuestionCount = max(0, bank.questions.count - known.count)
        var first: [String: Date] = [:]
        for a in actual where first[a.questionID] == nil { first[a.questionID] = a.gradedAt ?? a.answeredAt }
        out.newIntroducedToday = first.values.filter { (try? Self.day($0)) == day }.count
        return out
    }

    private func checkedDay(_ now: Date) throws -> UInt32 {
        let day = try Self.day(now), last = state.events.last?.at ?? state.migratedAt
        guard now >= last, day >= (state.events.last?.day ?? state.migratedDay) else { throw Self.fail("手机时间早于已有题库记录") }
        return day
    }

    private static func attempt(bank: ExamBank, hash: String, q: ExamQuestion,
                                presentation p: ExamPresentation, mode: String, sessionID: UUID, now: Date) -> ExamAttempt {
        let selected = mode == "answer" ? p.selectedOptionIDs : []
        return ExamAttempt(id: UUID(), bankID: bank.id, bankSHA256: hash, questionID: q.id,
            number: q.number, selectedOptions: selected, correctOptions: q.answer.sorted(),
            optionOrder: p.optionOrder, isCorrect: mode == "answer" && q.isCorrect(Set(selected)),
            answeredAt: now, sessionID: sessionID, presentationID: p.id, mode: mode)
    }

    private static func submit(_ state: inout PublicQuestionDualState, bank: ExamBank,
                               hash: String, now: Date) throws {
        guard let p = state.presentation, let q = bank.questions.first(where: { $0.id == p.questionID }),
              q.accepts(Set(p.selectedOptionIDs)) else { throw fail("请先选择答案") }
        var a = attempt(bank: bank, hash: hash, q: q, presentation: p, mode: "answer", sessionID: state.taskID, now: now)
        a.gradingSource = "automatic-choice"
        try grade(&state, bank: bank, hash: hash, shown: p, attempt: a, grade: a.isCorrect ? 0 : 1, now: now)
    }

    private static func grade(_ state: inout PublicQuestionDualState, bank: ExamBank, hash: String,
                              shown: ExamPresentation, attempt input: ExamAttempt, grade: Int32, now: Date) throws {
        let day = try day(now); var a = input
        guard now >= (state.events.last?.at ?? state.migratedAt),
              day >= (state.events.last?.day ?? state.migratedDay), a.mode == "answer",
              [Int32(0),1,3].contains(grade), a.isCorrect || grade == 1 else { throw fail("题库评分无效") }
        a.grade = grade; a.gradedAt = now
        try append(kind: "answer", round: nil, attempt: a, now: now, day: day, state: &state, bank: bank)
        var old = shown; old.pending = nil; old.supplementVisible = false
        present(&state, bank: bank, now: now)
        state.answerReview = ExamAnswerReview(presentation: old, attempt: a)
    }

    private static func present(_ state: inout PublicQuestionDualState, bank: ExamBank, now: Date) {
        guard let id = state.queue.first, let q = bank.questions.first(where: { $0.id == id }) else {
            state.presentation = nil; return
        }
        let order = ExamPresentation.order(for: q, avoiding: state.previousOrders[id])
        state.previousOrders[id] = order
        state.presentation = ExamPresentation(id: UUID(), questionID: id, optionOrder: order,
            selectedOptionIDs: [], pending: nil, supplementVisible: false, presentedAt: now)
    }

    private static func legacyEvidence(bank: ExamBank, hash: String, record: ExamDiskRecord,
                                       priorVolumeBytes: [Data], now: Date, timeZone: TimeZone) throws ->
        (packed: [String: UInt32], ratings: [PublicDualHistoricalRating], attempts: [ExamAttempt]) {
        guard priorVolumeBytes.count == record.volumes.count else { throw fail("旧题库分卷不完整") }
        let current = try PocketEngine(snapshot: record.snapshot)
        let stream = try current.streamID
        var segments: [ExamDiskRecord] = []
        for (index, data) in priorVolumeBytes.enumerated() {
            let ref = record.volumes[index]
            guard StudySHA256.hex(data) == ref.sha256 else { throw fail("旧题库分卷哈希不一致") }
            let archived = try JSONDecoder().decode(ExamDiskRecord.self, from: data)
            try archived.validateContent(bank: bank, hash: hash)
            let engine = try PocketEngine(snapshot: archived.snapshot)
            guard archived.volumes == Array(record.volumes.prefix(index)),
                  engine.logBase + 1 == ref.firstSequence, try engine.info.log_records == ref.lastSequence,
                  archived.attempts.count == ref.attemptCount, try engine.streamID == stream else {
                throw fail("旧题库分卷边界不一致")
            }
            segments.append(archived)
        }
        segments.append(record)
        var pocketEvents: [UInt32: StudyEvent] = [:]
        var attempts: [ExamAttempt] = []
        for segment in segments {
            let engine = try PocketEngine(snapshot: segment.snapshot)
            guard try engine.streamID == stream else { throw fail("旧题库日志身份不一致") }
            for e in try engine.events(from: engine.logBase + 1) {
                guard pocketEvents.updateValue(e, forKey: e.sequence) == nil else { throw fail("旧题库事件序列重复") }
            }
            attempts += segment.attempts
        }
        guard Set(attempts.map(\.id)).count == attempts.count else { throw fail("旧题库作答身份重复") }
        let indices = Dictionary(uniqueKeysWithValues: bank.questions.enumerated().map { ($0.element.id, UInt32($0.offset)) })
        var seen: [UUID: ExamAttempt] = [:], retracted = Set<UUID>(), used = Set<UInt32>()
        var lastSequence: UInt32 = 0
        for a in attempts {
            guard let seq = a.engineSequence, seq > lastSequence, let e = pocketEvents[seq],
                  used.insert(seq).inserted, let index = indices[a.questionID], e.word == index,
                  a.beforeRevision == e.beforeRevision, a.afterRevision == e.afterRevision,
                  let at = a.gradedAt, finite(at), at <= now else { throw fail("旧题库评分与原始日志不一致") }
            let expected: UInt32
            switch (a.mode, a.grade) {
            case ("answer", 0?): expected = 5
            case ("answer", 1?): expected = 6
            case ("answer", 3?): expected = 10
            case ("familiar", 2?): expected = 7
            case ("undo", nil): expected = 8
            default: throw fail("旧题库评分类型不受支持")
            }
            guard e.kind == expected else { throw fail("旧题库评分类型与原始日志不一致") }
            if a.mode == "undo" {
                guard let id = a.undoneAttemptID, let target = seen[id], target.questionID == a.questionID,
                      target.afterRevision == e.undoRevision, retracted.insert(id).inserted else {
                    throw fail("旧题库撤销目标不明确")
                }
            }
            seen[a.id] = a; lastSequence = seq
        }
        let actualEvents = pocketEvents.values.filter { [UInt32(5),6,7,8,10].contains($0.kind) }
        guard actualEvents.count == used.count else { throw fail("旧题库作答与事件数量不一致") }
        var ratings: [PublicDualHistoricalRating] = []
        for a in attempts where a.mode == "answer" {
            guard let grade = a.grade, let at = a.gradedAt, let seq = a.engineSequence else { throw fail("旧评分缺少实际时间") }
            ratings.append(.init(attemptID: a.id, sequence: seq, questionID: a.questionID,
                                 at: at, day: try day(at, timeZone: timeZone), grade: grade, retracted: retracted.contains(a.id)))
        }
        let handle = record.snapshot.withUnsafeBytes {
            xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard let handle else { throw fail("旧题库快照无法读取") }
        defer { xkl_engine_free(handle) }
        var packed: [String: UInt32] = [:]
        for (i, q) in bank.questions.enumerated() { packed[q.id] = xkl_engine_card(handle, UInt32(i)) }
        return (packed, ratings, attempts)
    }

    private static func capture(snapshot: Data, count: Int, on day: UInt32) throws ->
        (tokens: [PublicDualLegacyToken], items: [PublicDualLegacyItem], canUndo: Bool, undoWord: UInt32) {
        let ptr = snapshot.withUnsafeBytes {
            xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard let ptr else { throw fail("旧任务快照无法读取") }
        defer { xkl_engine_free(ptr) }
        var info = xkl_task_capture_info_t()
        guard xkl_engine_capture_task(ptr, UInt32(count), day, nil, 0, nil, 0, &info) else {
            throw fail("旧任务无法完整读取")
        }
        var rawTokens = [xkl_task_token_t](repeating: xkl_task_token_t(), count: Int(info.token_count))
        var rawItems = [xkl_task_item_t](repeating: xkl_task_item_t(), count: Int(info.item_count))
        let ok = rawTokens.withUnsafeMutableBufferPointer { tokens in
            rawItems.withUnsafeMutableBufferPointer { items in
                xkl_engine_capture_task(ptr, UInt32(count), day, tokens.baseAddress, UInt32(tokens.count),
                                        items.baseAddress, UInt32(items.count), &info)
            }
        }
        guard ok else { throw fail("旧任务读取不完整") }
        return (rawTokens.map { .init(word: $0.word, stage: $0.stage, failedRound: $0.failed_round) },
                rawItems.map { .init(word: $0.word, stageMask: $0.stage_mask,
                                     failedRound: $0.failed_round, category: $0.category) },
                info.can_undo != 0, info.undo_word)
    }

    private static func replay(_ state: PublicQuestionDualState, bank: ExamBank) throws -> Derived {
        let ids = bank.questions.map(\.id), idSet = Set(ids)
        guard let zone = TimeZone(identifier: state.migrationTimeZoneID),
              state.legacyIDs == ids, state.legacyItems.allSatisfy({ Int($0.word) < ids.count }),
              Set(state.initialCarry).count == state.initialCarry.count,
              state.initialCarry.allSatisfy({ idSet.contains($0) }),
              state.initialCarry == state.legacyItems.map({ ids[Int($0.word)] }),
              state.initialQueue == Array(state.initialCarry.prefix(state.initialQueue.count)),
              state.initialQueue.count <= 20,
              state.initialFamiliar == ids.filter({ (state.legacyPacked[$0] ?? 0) & (1 << 21) != 0 }),
              finite(state.migratedAt), try day(state.migratedAt, timeZone: zone) == state.migratedDay else {
            throw fail("双FSRS迁移起点无效")
        }
        var d = Derived()
        d.familiar = Set(state.initialFamiliar); d.carry = state.initialCarry
        d.queue = state.initialQueue; d.roundKind = d.queue.isEmpty ? nil : "carry"
        d.sessionCount = d.queue.count
        for rating in state.legacyRatings where !rating.retracted {
            guard idSet.contains(rating.questionID), [Int32(0), 1, 3].contains(rating.grade),
                  finite(rating.at), rating.at <= state.migratedAt,
                  try day(rating.at, timeZone: zone) == rating.day else { throw fail("旧评分回放证据无效") }
            let value = rating.grade == 0 ? 3 : 1
            if d.daily[rating.questionID]?.lastDay != rating.day {
                d.daily[rating.questionID] = try FSRS6Shadow.review(d.daily[rating.questionID],
                    day: rating.day, rating: value, timestampMs: ms(rating.at)).memory
            }
            d.all[rating.questionID] = try FSRS6Shadow.review(d.all[rating.questionID],
                day: rating.day, rating: value, timestampMs: ms(rating.at)).memory
            d.lastRating[rating.questionID] = .init(day: rating.day, at: rating.at, remembered: rating.grade == 0)
        }
        var checkpoint: Derived?, target: ExamAttempt?
        var seen = Set(state.legacyAttempts.map(\.id))
        var lastAt = state.migratedAt, lastDay = state.migratedDay
        let questions = Dictionary(uniqueKeysWithValues: bank.questions.map { ($0.id, $0) })
        for (index, e) in state.events.enumerated() {
            guard let eventZone = TimeZone(identifier: e.timeZoneID),
                  e.sequence == index + 1, finite(e.at), e.at >= lastAt, e.day >= lastDay,
                  (18_000...50_000).contains(e.day), try day(e.at, timeZone: eventZone) == e.day else {
                throw fail("双FSRS事件时间或顺序无效")
            }
            lastAt = e.at; lastDay = e.day
            if e.kind == "start" || e.kind == "startRetry" {
                var before = state
                before.events = Array(state.events.prefix(index))
                assign(d, to: &before)
                let expected = e.kind == "start" ? select(state: before, bank: bank, now: e.at, day: e.day) :
                    Array(retryCandidates(state: before, now: e.at, day: e.day).prefix(20))
                guard e.attempt == nil, d.queue.isEmpty, let round = e.round, !round.isEmpty,
                      round.count <= 20, Set(round).count == round.count,
                      round.allSatisfy({ idSet.contains($0) && !d.familiar.contains($0) }),
                      round == expected else {
                    throw fail("双FSRS任务分页无效")
                }
                d.queue = round; d.sessionCount = round.count; d.completedCount = 0
                d.roundKind = e.kind == "startRetry" ? "retry" : (d.carry.isEmpty ? "main" : "carry")
                d.lastUndoable = nil; checkpoint = nil; target = nil
                continue
            }
            guard e.round == nil, let a = e.attempt, seen.insert(a.id).inserted,
                  let q = questions[a.questionID], a.bankID == state.bankID,
                  a.bankSHA256 == state.bankSHA256, a.number == q.number,
                  a.correctOptions == q.answer.sorted(),
                  a.optionOrder.count == q.options.count,
                  Set(a.optionOrder) == Set(q.options.map(\.id)),
                  a.selectedOptions == Set(a.selectedOptions).sorted(),
                  Set(a.selectedOptions).isSubset(of: Set(q.options.map(\.id))),
                  a.gradedAt == e.at, a.engineSequence == nil,
                  a.beforeRevision == nil, a.afterRevision == nil else { throw fail("双FSRS作答证据无效") }
            if e.kind == "undo" {
                guard a.mode == "undo", a.grade == nil, let old = checkpoint, let original = target,
                      d.lastUndoable == original.id, a.undoneAttemptID == original.id,
                      a.questionID == original.questionID else { throw fail("双FSRS撤销目标无效") }
                d = old; d.lastUndoable = nil; checkpoint = nil; target = nil
                continue
            }
            guard d.queue.first == a.questionID, !d.familiar.contains(a.questionID) else {
                throw fail("双FSRS作答与当前任务不一致")
            }
            checkpoint = d; target = a
            if e.kind == "answer" {
                guard a.mode == "answer", let grade = a.grade, [Int32(0), 1, 3].contains(grade),
                      q.accepts(Set(a.selectedOptions)), a.isCorrect == q.isCorrect(Set(a.selectedOptions)),
                      a.isCorrect || grade == 1 else { throw fail("双FSRS答案或评分无效") }
                let rating = grade == 0 ? 3 : 1
                if d.roundKind != "retry" && d.daily[q.id]?.lastDay != e.day {
                    d.daily[q.id] = try FSRS6Shadow.review(d.daily[q.id], day: e.day,
                        rating: rating, timestampMs: ms(e.at)).memory
                }
                d.all[q.id] = try FSRS6Shadow.review(d.all[q.id], day: e.day,
                    rating: rating, timestampMs: ms(e.at)).memory
                d.lastRating[q.id] = .init(day: e.day, at: e.at, remembered: grade == 0)
            } else if e.kind == "familiar" {
                guard a.mode == "familiar", a.grade == 2, a.selectedOptions.isEmpty,
                      d.familiar.insert(q.id).inserted else { throw fail("双FSRS熟记事件无效") }
            } else { throw fail("双FSRS事件类型无效") }
            d.queue.removeFirst(); d.carry.removeAll { $0 == q.id }
            d.completedCount += 1; d.lastUndoable = a.id
        }
        return d
    }

    private static func assign(_ d: Derived, to state: inout PublicQuestionDualState) {
        state.daily = d.daily; state.all = d.all; state.lastRating = d.lastRating
        state.familiar = d.familiar.sorted(); state.carry = d.carry; state.queue = d.queue
        state.roundKind = d.roundKind; state.lastUndoableAttemptID = d.lastUndoable
        state.sessionCount = d.sessionCount; state.completedCount = d.completedCount
    }

    private static func append(kind: String, round: [String]?, attempt: ExamAttempt?,
                               now: Date, day: UInt32, state: inout PublicQuestionDualState,
                               bank: ExamBank) throws {
        var next = state
        next.events.append(.init(sequence: next.events.count + 1, kind: kind, at: now,
                                 day: day, timeZoneID: TimeZone.current.identifier, round: round, attempt: attempt))
        assign(try replay(next, bank: bank), to: &next)
        state = next
    }

    private static func isFresh(_ id: String, state: PublicQuestionDualState) -> Bool {
        let packed = state.legacyPacked[id] ?? 0
        return state.daily[id] == nil && packed & ((1 << 20) | (1 << 21)) == 0 &&
            !state.familiar.contains(id)
    }

    private static func retryCandidates(state: PublicQuestionDualState, now: Date, day: UInt32) -> [String] {
        let carry = Set(state.carry), familiar = Set(state.familiar), wrong = latestWrongIDs(state)
        return state.lastRating.filter { id, rating in
            rating.day == day && wrong.contains(id) && !rating.remembered && !carry.contains(id) && !familiar.contains(id) &&
                now.timeIntervalSince(rating.at) >= 600
        }.sorted {
            $0.value.at == $1.value.at ? $0.key < $1.key : $0.value.at < $1.value.at
        }.map(\.key)
    }

    private static func nextRetry(state: PublicQuestionDualState, now: Date, day: UInt32) -> Date? {
        let carry = Set(state.carry), familiar = Set(state.familiar), wrong = latestWrongIDs(state)
        return state.lastRating.compactMap { id, rating -> Date? in
            guard rating.day == day, wrong.contains(id), !rating.remembered,
                  !carry.contains(id), !familiar.contains(id) else { return nil }
            let ready = rating.at.addingTimeInterval(600)
            return ready > now ? ready : nil
        }.min()
    }

    private static func latestWrongIDs(_ state: PublicQuestionDualState) -> Set<String> {
        let attempts = state.legacyAttempts + state.events.compactMap(\.attempt)
        let undone = Set(attempts.compactMap(\.undoneAttemptID))
        var latest: [String: ExamAttempt] = [:]
        for attempt in attempts where attempt.mode == "answer" && !undone.contains(attempt.id) {
            latest[attempt.questionID] = attempt
        }
        return Set(latest.values.filter { !$0.isCorrect }.map(\.questionID))
    }

    private static func newlyGradedIDs(_ state: PublicQuestionDualState) -> Set<String> {
        let undone = Set(state.events.compactMap { $0.kind == "undo" ? $0.attempt?.undoneAttemptID : nil })
        var isRetry = false, ids = Set<String>()
        for event in state.events {
            if event.kind == "start" { isRetry = false }
            if event.kind == "startRetry" { isRetry = true }
            if event.kind == "answer", !isRetry, let a = event.attempt, !undone.contains(a.id) {
                ids.insert(a.questionID)
            }
        }
        return ids
    }

    private static func isDue(_ id: String, state: PublicQuestionDualState, now: Date, day: UInt32,
                              newlyGraded: Set<String>) -> Bool {
        guard !state.familiar.contains(id) else { return false }
        let packed = state.legacyPacked[id] ?? 0, level = (packed >> 16) & 15
        let due = packed & 65_535
        // The old engine also represents already-known/imported items as
        // learned with level 0 and no due date. If no real score can seed
        // FSRS, admit a review without fabricating a historical outcome.
        if !newlyGraded.contains(id), packed & (1 << 20) != 0,
           level == 0, due == 65_535, state.daily[id] == nil { return true }
        if !newlyGraded.contains(id) && packed & (1 << 20) != 0 && (1...10).contains(level) &&
            due != 0 && due != 65_535 && due <= day { return true }
        guard let memory = state.daily[id], memory.dueDay <= day, memory.dueDay >= memory.lastDay else { return false }
        guard let at = memory.timestampMs else { return true }
        let (duration, productOverflow) = Int64(memory.dueDay - memory.lastDay).multipliedReportingOverflow(by: 86_400_000)
        let (target, sumOverflow) = at.addingReportingOverflow(duration)
        return !productOverflow && !sumOverflow && finite(now) && ms(now) >= target
    }

    private static func select(state: PublicQuestionDualState, bank: ExamBank,
                               now: Date, day: UInt32) -> [String] {
        let ids = bank.questions.map(\.id), newlyGraded = newlyGradedIDs(state)
        let carrySet = Set(state.carry)
        let due = ids.filter {
            !carrySet.contains($0) && isDue($0, state: state, now: now, day: day, newlyGraded: newlyGraded)
        }
        let other = state.carry.isEmpty ? ids.filter { isFresh($0, state: state) } : state.carry
        var result = Array(other.prefix(10)) + Array(due.prefix(10))
        let selected = Set(result)
        let remaining = (other + due).filter { !selected.contains($0) }
        if result.count < 20 { result += remaining.prefix(20 - result.count) }
        return result
    }

    private static func validatePresentation(_ state: PublicQuestionDualState, bank: ExamBank, hash: String) throws {
        let questions = Dictionary(uniqueKeysWithValues: bank.questions.map { ($0.id, $0) })
        func check(_ p: ExamPresentation) -> Bool {
            guard let q = questions[p.questionID], finite(p.presentedAt),
                  p.optionOrder.count == q.options.count, Set(p.optionOrder) == Set(q.options.map(\.id)),
                  p.selectedOptionIDs == Set(p.selectedOptionIDs).sorted(),
                  Set(p.selectedOptionIDs).isSubset(of: Set(q.options.map(\.id))),
                  q.type == .multiple || p.selectedOptionIDs.count <= 1 else { return false }
            return true
        }
        for (id, order) in state.previousOrders {
            guard let q = questions[id], order.count == q.options.count,
                  Set(order) == Set(q.options.map(\.id)) else { throw fail("双FSRS选项排列无效") }
        }
        if let p = state.presentation {
            guard check(p), state.queue.first == p.questionID,
                  state.previousOrders[p.questionID] == p.optionOrder else { throw fail("双FSRS当前题断点无效") }
            if let a = p.pending {
                guard let q = questions[p.questionID], a.mode == "answer", a.grade == nil, a.gradedAt == nil,
                      a.engineSequence == nil, a.id != state.lastUndoableAttemptID,
                      a.bankID == bank.id, a.bankSHA256 == hash, a.questionID == p.questionID,
                      a.number == q.number, a.presentationID == p.id, a.optionOrder == p.optionOrder,
                      a.selectedOptions == p.selectedOptionIDs, a.correctOptions == q.answer.sorted(),
                      q.accepts(Set(a.selectedOptions)), a.isCorrect == q.isCorrect(Set(a.selectedOptions)),
                      !p.supplementVisible || a.isCorrect else { throw fail("双FSRS待评分断点无效") }
            } else if p.supplementVisible { throw fail("双FSRS补看断点无效") }
        } else if !state.queue.isEmpty { throw fail("双FSRS队列缺少当前题") }
        if let review = state.answerReview {
            let p = review.presentation, a = review.attempt
            let known = (state.legacyAttempts + state.events.compactMap(\.attempt)).contains(a)
            guard check(p), p.pending == nil, !p.supplementVisible, a.mode == "answer",
                  p.id == a.presentationID, p.questionID == a.questionID,
                  p.optionOrder == a.optionOrder, p.selectedOptionIDs == a.selectedOptions, known else {
                throw fail("双FSRS结果页记录无效")
            }
        }
    }
}
