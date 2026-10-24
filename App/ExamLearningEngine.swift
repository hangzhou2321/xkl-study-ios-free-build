import Foundation
import CPocket
import StudyCore

/// UI-independent adapter: original CPocket scheduling with an explicitly
/// optional question-only 3/7 experiment. Vocabulary entry points are unchanged.
@MainActor
final class ExamLearningEngine {
    let bank: ExamBank
    private(set) var record: ExamDiskRecord
    private var engine: PocketEngine

    var info: xkl_info_t { get throws { try engine.info } }
    var currentQuestion: ExamQuestion? {
        guard let p = record.presentation else { return nil }
        return bank.questions.first { $0.id == p.questionID }
    }
    var pendingGrade: Int32? {
        (record.answerReview?.attempt ?? record.presentation?.pending).map { $0.isCorrect ? 0 : 1 }
    }
    var displayPresentation: ExamPresentation? { record.answerReview?.presentation ?? record.presentation }
    var displayQuestion: ExamQuestion? {
        guard let p = displayPresentation else { return nil }
        return bank.questions.first { $0.id == p.questionID }
    }
    var displayAttempt: ExamAttempt? { record.answerReview?.attempt ?? record.presentation?.pending }
    var isShowingResult: Bool { record.answerReview != nil || record.presentation?.pending != nil }
    var volumeRecords: UInt32 { engine.volumeRecords }
    var logBase: UInt32 { engine.logBase }
    func dueCount(on day: UInt32) -> Int { engine.dueCount(on: day, limit: bank.questions.count) }
    var reinforcementRemaining: Int { get throws { Int(engine.currentRepeats) } }

    init(bank: ExamBank, hash: String, record: ExamDiskRecord) throws {
        try bank.validate()
        try record.validateContent(bank: bank, hash: hash)
        self.bank = bank
        self.record = record
        self.engine = try PocketEngine(snapshot: record.snapshot)
        let info = try engine.info
        try record.analysis.validate(streamID: engine.streamID, logCount: info.log_records)
        guard engine.logBase == (record.volumes.last?.lastSequence ?? 0) else {
            throw ExamError.invalid("题库当前日志与分卷边界不一致。")
        }
        if info.has_task != 0 {
            guard Int(info.word) < bank.questions.count,
                  record.presentation?.questionID == bank.questions[Int(info.word)].id,
                  (info.revealed != 0) == (record.presentation?.pending != nil) else {
                throw ExamError.invalid("题库出题断点与原记忆引擎不一致。")
            }
        } else if record.presentation != nil {
            throw ExamError.invalid("没有学习任务时不应存在题库出题断点。")
        }
    }

    static func fresh(bank: ExamBank, hash: String, now: Date = Date()) throws -> ExamLearningEngine {
        try bank.validate()
        guard bank.questions.count <= Int(XKL_WORD_COUNT) else {
            throw ExamError.invalid("题库超过记忆引擎可用容量。")
        }
        var stream = UUID().uuid
        let handle = withUnsafeBytes(of: &stream) {
            xkl_engine_blank(UInt32(bank.questions.count), $0.bindMemory(to: UInt8.self).baseAddress)
        }
        guard let handle else { throw ExamError.invalid("无法创建独立题库记忆档案。") }
        defer { xkl_engine_free(handle) }
        var snapshot = Data(count: xkl_engine_snapshot_size(handle))
        let written = snapshot.withUnsafeMutableBytes {
            xkl_engine_snapshot(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard written == snapshot.count else { throw ExamError.invalid("题库初始化校验失败。") }
        let temporary = try PocketEngine(snapshot: snapshot)
        let record = ExamDiskRecord(bankSHA256: hash, snapshot: snapshot,
            snapshotSHA256: StudySHA256.hex(snapshot), taskID: UUID(), presentation: nil,
            previousOrders: [:], attempts: [],
            analysis: StudyAnalysisSettings(streamID: try temporary.streamID, nextSequence: 1, now: now),
            volumes: [], lastUndoableAttemptID: nil)
        return try Self(bank: bank, hash: hash, record: record)
    }

    func start(day: UInt32, now: Date = Date()) throws {
        let before = try engine.info
        guard day >= before.day else {
            throw ExamError.invalid("手机日期早于上次题库学习日期，请先核对系统时间；原进度已保留。")
        }
        let hadTask = before.has_task != 0
        // A completed task must show its saved last answer before admitting a
        // new lesson; opening the directory never dismisses the result page.
        if record.answerReview != nil && !hadTask { return }
        let old = record.presentation
        try engine.start(day: day)
        if !hadTask {
            record.taskID = UUID(); record.lastUndoableAttemptID = nil
            record.failureCounts = [:]; record.shortPlanQuestionIDs = []
        }
        if hadTask, let old {
            record.presentation = old // cold launch never reshuffles the visible question
            if old.pending != nil { try engine.reveal() }
        } else {
            try present(now: now)
        }
        try capture()
    }

    func toggle(_ id: String) throws {
        guard record.answerReview == nil, var p = record.presentation, p.pending == nil, let q = currentQuestion,
              q.options.contains(where: { $0.id == id }) else { return }
        var selection = Set(p.selectedOptionIDs)
        if q.type == .multiple {
            if !selection.insert(id).inserted { selection.remove(id) }
        } else { selection = selection == [id] ? [] : [id] }
        p.selectedOptionIDs = selection.sorted()
        record.presentation = p
    }

    func submit(now: Date = Date()) throws {
        guard record.answerReview == nil, var p = record.presentation, p.pending == nil, let q = currentQuestion else { return }
        guard q.accepts(Set(p.selectedOptionIDs)) else { throw ExamError.invalid("请先选择答案。") }
        try engine.reveal()
        p.pending = attempt(question: q, presentation: p, mode: "answer", now: now)
        // ANY mismatch, including a strict subset, is objectively wrong.
        // Partial is available only as an explicit self-report after a correct answer.
        p.supplementVisible = false
        record.presentation = p
        try capture()
    }

    func confirm(_ grade: Int32, now: Date = Date()) throws {
        guard record.answerReview == nil, var p = record.presentation, var pending = p.pending else { return }
        let allowed: Set<Int32> = pending.isCorrect ? [0, 1, 3] : [1]
        guard allowed.contains(grade), !p.supplementVisible || grade != 0 else {
            throw ExamError.invalid("错选或漏选按答错处理，不能改为没背全。")
        }
        if grade == 3 && !p.supplementVisible {
            p.supplementVisible = true
            record.presentation = p
            return
        }
        let before = try engine.info
        let priorFailures = record.failureCounts[p.questionID] ?? 0
        let priorShort = record.shortPlanQuestionIDs.contains(p.questionID)
        let plan: UInt32
        if grade == 1 { plan = record.examReductionEnabled && priorFailures == 0 ? 1 : 0 }
        else if grade == 0 && engine.currentIsNew { plan = record.examReductionEnabled ? 3 : 4 }
        else { plan = record.examReductionEnabled && priorShort ? 2 : 0 }
        let (decision, examDecision) = try engine.answerExam(grade, policy: record.analysis, plan: plan)
        let after = try engine.info
        if grade == 1 {
            guard priorFailures < Int.max else { throw ExamError.invalid("题库错误次数超出可保存范围。") }
            record.failureCounts[p.questionID] = priorFailures + 1
            record.shortPlanQuestionIDs.removeAll { $0 == p.questionID }
            if plan == 1 { record.shortPlanQuestionIDs.append(p.questionID); record.shortPlanQuestionIDs.sort() }
        }
        pending.grade = grade
        pending.gradedAt = now
        pending.beforeRevision = before.revision
        pending.afterRevision = after.revision
        pending.engineSequence = try gradeEvent(after: before.log_records).sequence
        pending.examPlan = plan
        pending.shortenedRepeats = examDecision.shortened_repeats
        pending.tailRemoved = examDecision.tail_removed
        pending.tailDeferred = examDecision.tail_deferred != 0
        pending.failureCountInTask = record.failureCounts[p.questionID] ?? 0
        if plan == 3 || plan == 4 {
            let expected: UInt32 = plan == 3 ? 3 : 7
            guard examDecision.initial_learning_scheduled == 1,
                  examDecision.initial_learning_repeats == expected else {
                throw ExamError.invalid("题库首次答对的学习安排未完成。")
            }
            pending.learningInitialization = plan == 3 ? "correct-short" : "correct-full"
            pending.initializedRepeats = expected
            if plan == 3 {
                record.shortPlanQuestionIDs.removeAll { $0 == p.questionID }
                record.shortPlanQuestionIDs.append(p.questionID)
                record.shortPlanQuestionIDs.sort()
            }
        }
        record.attempts.append(pending)
        if let decision { record.analysis.reductions.append(decision) }
        record.lastUndoableAttemptID = after.can_undo != 0 ? pending.id : nil
        try present(now: now)
        try capture()
    }

    /// A single-choice/judgment tap and the resulting grade are saved together
    /// by the store. The visible token prevents a stale button grading a newly
    /// scheduled encounter of the SAME question.
    func selectAndSubmit(_ id: String, presentationID: UUID?, now: Date = Date()) throws {
        guard let token = presentationID, token == displayPresentation?.id,
              !isShowingResult, let q = currentQuestion, q.type != .multiple,
              q.options.contains(where: { $0.id == id }), var p = record.presentation else { return }
        p.selectedOptionIDs = [id]
        record.presentation = p
        try submitAutomatically(presentationID: token, now: now)
    }

    func submitAutomatically(presentationID: UUID?, now: Date = Date()) throws {
        guard let token = presentationID, token == displayPresentation?.id, !isShowingResult else { return }
        try submit(now: now)
        try finishPendingForReview(source: "automatic-choice", now: now)
    }

    func nextQuestion(presentationID: UUID?, now: Date = Date()) throws {
        guard let token = presentationID, token == displayPresentation?.id else { return }
        if record.answerReview != nil {
            record.answerReview = nil // Already graded; never call C a second time.
        } else if let old = record.presentation, old.pending != nil {
            // Upgrade a pending answer only after the user chooses Next.
            // An explicit old partial self-report is not rewritten as automatic
            // correctness just because this version removed the rating buttons.
            let source = old.supplementVisible ? "legacy-explicit-partial" : "legacy-pending-auto"
            try finishPendingForReview(source: source, now: now)
            record.answerReview = nil
        }
    }

    private func finishPendingForReview(source: String, now: Date) throws {
        guard record.answerReview == nil, var shown = record.presentation, let pending = shown.pending else { return }
        let grade: Int32 = shown.supplementVisible ? 3 : (pending.isCorrect ? 0 : 1)
        try confirm(grade, now: now)
        guard let index = record.attempts.indices.last,
              record.attempts[index].id == pending.id else {
            throw ExamError.invalid("本次题库结果未找到对应的已保存评分。")
        }
        record.attempts[index].gradingSource = source
        shown.pending = nil; shown.supplementVisible = false
        record.answerReview = ExamAnswerReview(presentation: shown, attempt: record.attempts[index])
    }

    func familiar(now: Date = Date()) throws {
        guard record.answerReview == nil, let p = record.presentation, p.pending == nil, let q = currentQuestion else { return }
        let before = try engine.info
        try engine.answer(2)
        let after = try engine.info
        var entry = attempt(question: q, presentation: p, mode: "familiar", now: now)
        entry.grade = 2; entry.gradedAt = now
        entry.beforeRevision = before.revision; entry.afterRevision = after.revision
        entry.engineSequence = try gradeEvent(after: before.log_records).sequence
        record.attempts.append(entry)
        record.lastUndoableAttemptID = entry.id
        try present(now: now)
        try capture()
    }

    func undo(now: Date = Date()) throws {
        guard record.answerReview == nil, record.presentation?.pending == nil,
              let target = record.lastUndoableAttemptID else { return }
        let before = try engine.info
        guard before.can_undo != 0 else { return }
        try engine.undo()
        try present(now: now)
        guard let p = record.presentation, let q = currentQuestion else {
            throw ExamError.invalid("无法恢复撤销后的题目。")
        }
        var entry = attempt(question: q, presentation: p, mode: "undo", now: now)
        entry.gradedAt = now
        entry.beforeRevision = before.revision; entry.afterRevision = try engine.info.revision
        entry.engineSequence = try gradeEvent(after: before.log_records).sequence
        entry.undoneAttemptID = target
        record.attempts.append(entry)
        record.lastUndoableAttemptID = nil
        try capture()
    }

    func setPolicy(_ enabled: Bool, now: Date = Date()) throws {
        let info = try engine.info
        record.analysis.setEnabled(enabled, nextSequence: info.log_records + 1, now: now)
    }

    func setExamReduction(_ enabled: Bool, now: Date = Date()) {
        guard record.examReductionEnabled != enabled else { return }
        record.examReductionEnabled = enabled
        // Changes govern later errors; existing scored history/queues are not
        // rewritten or restored by inventing an additional wrong answer.
        record.examReductionChanges.append(ExamReductionChange(enabled: enabled, changedAt: now,
            taskID: record.taskID, firstSequence: (try? engine.info.log_records + 1) ?? 1))
    }

    /// Caller seals and syncs the complete old record first, then persists this
    /// new active record. Old volumes are never deleted by this adapter.
    func rotate(reference: ExamVolumeReference) throws {
        guard reference.firstSequence == engine.logBase + 1,
              reference.lastSequence == (try engine.info.log_records),
              reference.attemptCount == record.attempts.count else {
            throw ExamError.invalid("题库分卷边界不正确。")
        }
        engine = try engine.rotated(policyFirst: record.analysis.conservativeFirstSequence)
        record.volumes.append(reference)
        record.analysis.archivedSavedRepetitions = record.analysis.savedRepetitions
        record.analysis.reductions = []
        if let last = record.analysis.changes.last { record.analysis.changes = [last] }
        if let last = record.examReductionChanges.last { record.examReductionChanges = [last] }
        // Keep the current policy activation cut, not a new learning-rule boundary.
        record.attempts = []
        try capture()
    }

    private func attempt(question q: ExamQuestion, presentation p: ExamPresentation,
                         mode: String, now: Date) -> ExamAttempt {
        let selection = mode == "answer" ? p.selectedOptionIDs : []
        return ExamAttempt(id: UUID(), bankID: bank.id, bankSHA256: record.bankSHA256,
            questionID: q.id, number: q.number, selectedOptions: selection,
            correctOptions: q.answer.sorted(), optionOrder: p.optionOrder,
            isCorrect: mode == "answer" && q.isCorrect(Set(selection)), answeredAt: now,
            sessionID: record.taskID, presentationID: p.id, mode: mode)
    }

    private func present(now: Date) throws {
        let info = try engine.info
        guard info.has_task != 0 else { record.presentation = nil; return }
        guard Int(info.word) < bank.questions.count else {
            throw ExamError.invalid("记忆引擎返回了题库范围外的项目。")
        }
        let question = bank.questions[Int(info.word)]
        let order = ExamPresentation.order(for: question, avoiding: record.previousOrders[question.id])
        record.previousOrders[question.id] = order
        record.presentation = ExamPresentation(id: UUID(), questionID: question.id,
            optionOrder: order, selectedOptionIDs: [], pending: nil, supplementVisible: false, presentedAt: now)
    }

    private func gradeEvent(after sequence: UInt32) throws -> StudyEvent {
        guard let event = try engine.events(from: sequence + 1).first(where: {
            [UInt32(5), 6, 7, 8, 10].contains($0.kind)
        }) else { throw ExamError.invalid("无法核对本次题库评分日志。") }
        return event
    }

    private func capture() throws {
        record.snapshot = try engine.snapshot()
        record.snapshotSHA256 = StudySHA256.hex(record.snapshot)
    }
}
