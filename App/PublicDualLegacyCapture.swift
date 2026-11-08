import Foundation
import CPocket

/// Read an already-selected Pocket task without refreshing or changing it.
/// The preserved snapshot remains the authority for a genuine legacy undo.
enum PublicDualLegacyCapture {
    static func read(snapshot: Data, bankCount: Int, now: Date) throws
        -> (tokens: [PublicDualLegacyToken], items: [PublicDualLegacyItem]) {
        guard bankCount > 0, bankCount <= Int(XKL_WORD_COUNT) else {
            throw ExamError.invalid("题库数量不正确，原学习记录已保留。")
        }
        let engine = snapshot.withUnsafeBytes { raw in
            xkl_engine_restore(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard let engine else { throw ExamError.invalid("原题库记录校验失败，未切换学习算法。") }
        defer { xkl_engine_free(engine) }
        let today = UInt32(try ConceptCalendar.studyDay(now))
        let count = UInt32(bankCount)
        var original = xkl_info_t()
        var first = xkl_task_capture_info_t()
        guard xkl_engine_info(engine, &original),
              xkl_engine_capture_task(engine, count, today, nil, 0, nil, 0, &first),
              first.item_count == original.total_remaining,
              first.item_count <= count, first.token_count <= 350 else {
            throw ExamError.invalid("原题库待学队列校验失败，未切换学习算法。")
        }
        var tokens = Array(repeating: xkl_task_token_t(), count: Int(first.token_count))
        var items = Array(repeating: xkl_task_item_t(), count: Int(first.item_count))
        var second = xkl_task_capture_info_t()
        let captured = tokens.withUnsafeMutableBufferPointer { tokenBuffer in
            items.withUnsafeMutableBufferPointer { itemBuffer in
                xkl_engine_capture_task(engine, count, today,
                    tokenBuffer.baseAddress, UInt32(tokenBuffer.count),
                    itemBuffer.baseAddress, UInt32(itemBuffer.count), &second)
            }
        }
        guard captured, second.day == first.day, second.selection_day == first.selection_day,
              second.token_count == first.token_count, second.item_count == first.item_count,
              second.active_count == first.active_count,
              second.unloaded_review_count == first.unloaded_review_count,
              second.unloaded_new_count == first.unloaded_new_count,
              second.can_undo == first.can_undo, second.undo_word == first.undo_word,
              (original.has_task == 0 && tokens.isEmpty && items.isEmpty) ||
              (original.has_task != 0 && tokens.first?.word == original.word && items.first?.word == original.word) else {
            throw ExamError.invalid("原题库待学顺序校验失败，未切换学习算法。")
        }
        return (tokens.map { PublicDualLegacyToken(word: $0.word, stage: $0.stage, failedRound: $0.failed_round) },
                items.map { PublicDualLegacyItem(word: $0.word, stageMask: $0.stage_mask,
                                                failedRound: $0.failed_round, category: $0.category) })
    }
}
