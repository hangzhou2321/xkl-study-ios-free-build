import Foundation
import CPocket
import StudyCore

/// All calls are confined to StudyStore's main actor. The C engine is not thread safe.
@MainActor
final class PocketEngine {
    private var handle: OpaquePointer

    init(snapshot: Data) throws {
        guard let engine = snapshot.withUnsafeBytes({ raw in
            xkl_engine_restore(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }) else {
            throw StudyError.engine("学习记录校验失败。已保留原文件，没有重新初始化。")
        }
        handle = engine
    }

    init(seed: Data, stream: UUID) throws {
        var streamBytes = stream.uuid
        let engine = withUnsafeBytes(of: &streamBytes) { streamRaw in
            seed.withUnsafeBytes { raw in
                xkl_engine_seed(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                streamRaw.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard let engine else { throw StudyError.engine("原始学习记录校验失败，无法创建学习副本。") }
        handle = engine
    }

    deinit { xkl_engine_free(handle) }

    var info: xkl_info_t {
        get throws {
            var result = xkl_info_t()
            guard xkl_engine_info(handle, &result) else { throw StudyError.engine("无法读取学习状态。") }
            return result
        }
    }

    /// Read-only calendar visibility, including when no task has been started.
    func dueCount(on day: UInt32, limit: Int = Int(XKL_WORD_COUNT)) -> Int {
        var count = 0
        for id in 0..<max(0, min(limit, Int(XKL_WORD_COUNT))) {
            let packed = xkl_engine_card(handle, UInt32(id))
            let level = (packed >> 16) & 15
            if packed & (1 << 20) != 0, packed & (1 << 21) == 0,
               (1...10).contains(level), (packed & 65_535) <= day {
                count += 1
            }
        }
        return count
    }

    func snapshot() throws -> Data {
        let count = xkl_engine_snapshot_size(handle)
        guard count > 0 else { throw StudyError.engine("无法封装学习状态。") }
        var data = Data(count: count)
        let written = data.withUnsafeMutableBytes { raw in
            xkl_engine_snapshot(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard written == count else { throw StudyError.engine("学习状态写入不完整。") }
        return data
    }

    func rawLog() throws -> Data {
        let count = xkl_engine_log_size(handle)
        var data = Data(count: count)
        let written = data.withUnsafeMutableBytes { raw in
            xkl_engine_log(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard written == count else { throw StudyError.engine("逐次记录导出不完整。") }
        return data
    }

    func start(day: UInt32, preservingRevealedAnswer: Bool = false,
               preservingShownStepAcrossDay: Bool = false) throws {
        let before = try info
        let restoreReveal = preservingRevealedAnswer && before.has_task != 0
            && before.revealed != 0 && (before.day == day || preservingShownStepAcrossDay)
        guard xkl_engine_start(handle, day, now) else { throw StudyError.engine("无法开始任务，请检查日期或记录容量。") }
        if restoreReveal { try reveal() }
    }

    func reveal() throws {
        guard xkl_engine_reveal(handle, now) else { throw StudyError.engine("无法显示答案。") }
    }

    func answer(_ answer: Int32) throws {
        guard xkl_engine_answer(handle, answer, now) else { throw StudyError.engine("本次回答未保存。请先核对答案或导出已满的记录。") }
    }

    func answer(_ answer: Int32, policy: StudyAnalysisSettings) throws -> ReductionDecision? {
        var result=xkl_policy_result_t()
        guard xkl_engine_answer_conservative(handle, answer, now, policy.conservativeEnabled,
                                             policy.conservativeFirstSequence, &result) else {
            throw StudyError.engine("本次回答未保存。请先核对答案或导出已满的记录。")
        }
        guard result.removed > 0 else { return nil }
        return ReductionDecision(word:result.word,day:result.day,sequence:result.answer_sequence,
            before:result.before_revision,after:result.after_revision,first:result.first_sequence,
            recalls:result.qualified_recalls,gap:result.distinct_gap,longGap:result.long_gap,removed:result.removed)
    }

    /// Isolated question-bank experiment. Existing vocabulary callers continue
    /// using answer(_:policy:) and never pass an exam plan.
    func answerExam(_ answer: Int32, policy: StudyAnalysisSettings,
                    plan: UInt32) throws -> (ReductionDecision?, xkl_exam_result_t) {
        var policyResult = xkl_policy_result_t()
        var examResult = xkl_exam_result_t()
        guard xkl_engine_answer_exam(handle, answer, now, policy.conservativeEnabled,
                                    policy.conservativeFirstSequence, plan, &policyResult, &examResult) else {
            throw StudyError.engine("题库评分未完成，原进度已保留。")
        }
        let reduction: ReductionDecision? = policyResult.removed > 0 ?
            ReductionDecision(word: policyResult.word, day: policyResult.day, sequence: policyResult.answer_sequence,
                before: policyResult.before_revision, after: policyResult.after_revision,
                first: policyResult.first_sequence, recalls: policyResult.qualified_recalls,
                gap: policyResult.distinct_gap, longGap: policyResult.long_gap, removed: policyResult.removed) : nil
        return (reduction, examResult)
    }

    var currentRepeats: UInt32 { xkl_engine_current_repeats(handle) }
    /// Explicit professional UI action; English/exam/math never use this API.
    var canPostponeProfessionalCard: Bool { xkl_engine_can_postpone_professional(handle) }
    func postponeProfessionalCard() throws {
        guard xkl_engine_postpone_professional(handle, now) else {
            throw StudyError.engine("暂缓未保存，当前卡和原记录已保留。")
        }
    }
    var currentIsNew: Bool { xkl_engine_current_is_new(handle) }

    var streamID: String {
        get throws {
            var bytes=[UInt8](repeating:0,count:16)
            guard bytes.withUnsafeMutableBufferPointer({ xkl_engine_stream(handle,$0.baseAddress) }) else {
                throw StudyError.persistence("无法读取学习日志身份。")
            }
            return bytes.map { String(format:"%02x",$0) }.joined()
        }
    }

    func events(from firstSequence: UInt32) throws -> [StudyEvent] {
        let count=try info.log_records
        guard firstSequence > logBase, firstSequence <= count+1 else { throw AnalysisError.invalidSettings }
        return try (firstSequence-1..<count).map { index in
            var e=xkl_event_info_t()
            guard xkl_engine_event(handle,index,&e) else { throw StudyError.persistence("学习日志校验失败。") }
            return StudyEvent(sequence:e.sequence,kind:e.kind,day:e.day,word:e.word,stage:e.stage,
                beforeCard:e.before_card,afterCard:e.after_card,beforeRevision:e.before_revision,
                afterRevision:e.after_revision,undoRevision:e.undo_revision,
                presentation:e.presentation,session:e.session,uptimeMs:e.uptime_ms,
                revealMs:e.reveal_ms,answerMs:e.answer_ms,flags:e.flags)
        }
    }

    func undo() throws {
        guard xkl_engine_undo(handle, now) else { throw StudyError.engine("当前没有可撤销的熟悉操作。") }
    }
    var logBase: UInt32 { xkl_engine_log_base(handle) }
    var volumeRecords: UInt32 { xkl_engine_volume_records(handle) }
    func rotated(policyFirst: UInt32) throws -> PocketEngine {
        let copy=try PocketEngine(snapshot:snapshot())
        guard xkl_engine_rotate_log(copy.handle,policyFirst) else { throw StudyError.persistence("日志分卷未完成，原进度已保留。") }
        return copy
    }

    private var now: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1_000_000) }
}
