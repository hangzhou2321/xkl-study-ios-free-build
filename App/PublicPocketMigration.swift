import Foundation
import CPocket
import StudyCore

/// A genuine uncompleted pre-switch obligation. Its old stage mask and packed
/// value stay bound to the original question ID; this is not an answer event.
struct PublicPocketObligation: Codable, Equatable {
    let questionID: String
    let word: UInt32
    let packed: UInt32
    let stages: UInt8
    let failedRound: UInt8
}

/// Stable provenance for the independent Pocket stream. Historical answers
/// remain in the unmodified dual and legacy archives; no old score is copied
/// into this stream as a fabricated Pocket event.
struct PublicPocketMigrationPlan: Codable {
    let bankID: String
    let bankSHA256: String
    let sourceDualSHA256: String
    let sourceAnchorSHA256: String
    let migratedAt: Date
    let streamID: UUID
    let questionIDs: [String]
    let mappedCards: [UInt32]
    let initialObligations: [PublicPocketObligation]
    var parkedObligations: [PublicPocketObligation]
    var record: ExamDiskRecord
    var bridgeReview: ExamAnswerReview?
}

@MainActor enum PublicPocketMigration {
    private static let inert: UInt32 = (1 << 20) | (1 << 22) | 65_535
    private static let learned: UInt32 = 1 << 20
    private static let familiar: UInt32 = 1 << 21
    private static let partial: UInt32 = 1 << 23

    private struct SourceDisk: Decodable {
        let format: String
        let bankSHA256: String
        let state: PublicQuestionDualState
    }

    private static func fail(_ message: String) -> ExamError {
        .invalid(message + "；双 FSRS 和原题库记录均已保留。")
    }

    /// Preserve the per-question original W-stage order while spreading the
    /// first stage of each transferred question across the page. This avoids
    /// displaying one question's seven pre-existing stages back-to-back.
    static func interleavedTokens(_ obligations: [PublicPocketObligation],
                                  legacyTokens: [PublicDualLegacyToken]) throws -> [xkl_task_token_t] {
        var perQuestion: [[xkl_task_token_t]] = []
        for item in obligations {
            let old = legacyTokens.filter { $0.word == item.word && (item.stages & (UInt8(1) << UInt8($0.stage))) != 0 }
            let stages: [UInt32]
            if item.stages == 1 {
                stages = [0]
            } else {
                stages = old.map(\.stage)
                let mask = stages.reduce(UInt8(0)) { $0 | (UInt8(1) << UInt8($1)) }
                guard mask == item.stages, stages.count == item.stages.nonzeroBitCount,
                      old.allSatisfy({ $0.failedRound == UInt32(item.failedRound) }) else {
                    throw fail("旧任务阶段顺序不完整")
                }
            }
            perQuestion.append(stages.map { xkl_task_token_t(word: item.word, stage: $0,
                                                              failed_round: UInt32(item.failedRound)) })
        }
        let maxCount = perQuestion.map(\.count).max() ?? 0
        var result: [xkl_task_token_t] = []
        for round in 0..<maxCount {
            for row in perQuestion where round < row.count { result.append(row[round]) }
        }
        return result
    }

    /// Create an independent stream from a fully validated, immutable dual
    /// snapshot. Exactly the visible task is activated; remaining old tasks
    /// are parked with their original stage masks for later admission.
    static func prepare(bank: ExamBank, hash: String, source: PublicQuestionDualState,
                        sourceDualBytes: Data, anchorBytes: Data, priorVolumeBytes: [Data],
                        now: Date, stream: UUID = UUID()) throws -> PublicPocketMigrationPlan {
        let dual = try PublicQuestionDualFSRS(state: source, bank: bank, hash: hash)
        try dual.validateLegacy(recordBytes: anchorBytes, priorVolumeBytes: priorVolumeBytes)
        let sourceDisk = try JSONDecoder().decode(SourceDisk.self, from: sourceDualBytes)
        guard sourceDisk.format == "xkl-ios-public-dual-store-v1", sourceDisk.bankSHA256 == hash,
              sourceDisk.state == source else { throw fail("双 FSRS 原档与待迁移状态不一致") }
        guard now >= (source.events.last?.at ?? source.migratedAt) else { throw fail("手机日期早于已有题库记录") }
        let day = UInt32(try ConceptCalendar.studyDay(now))
        guard bank.questions.count <= Int(XKL_WORD_COUNT), source.queue.count <= 20,
              Set(source.queue).count == source.queue.count, Set(source.carry).count == source.carry.count else {
            throw fail("原题库任务数量无效")
        }
        let original = try JSONDecoder().decode(ExamDiskRecord.self, from: anchorBytes)
        let ids = bank.questions.map(\.id)
        let words = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, UInt32($0.offset)) })
        let carries = Set(source.carry), queued = Set(source.queue), familiarIDs = Set(source.familiar)
        let legacy = Dictionary(uniqueKeysWithValues: source.legacyItems.map { (ids[Int($0.word)], $0) })
        let retracted = Set(source.events.compactMap { $0.kind == "undo" ? $0.attempt?.undoneAttemptID : nil })
        var latest: [String: PublicDualEvent] = [:]
        for event in source.events where event.kind == "answer" {
            guard let attempt = event.attempt else { throw fail("旧评分事件缺少原始作答") }
            if !retracted.contains(attempt.id) { latest[attempt.questionID] = event }
        }
        var mapped = [UInt32](repeating: 0, count: ids.count)
        for (index, id) in ids.enumerated() {
            guard let originalPacked = source.legacyPacked[id] else { throw fail("原题库槽位缺失") }
            var packed = originalPacked
            if familiarIDs.contains(id) {
                // A real explicit familiar action, never inferred from viewing.
                packed = (packed & ~(UInt32(1) << 22) & ~partial) | familiar
            } else if let event = latest[id], let attempt = event.attempt, let grade = attempt.grade {
                guard [Int32(0), 1, 3].contains(grade) else { throw fail("旧评分类型无效") }
                let oldLevel = (packed >> 16) & 15
                let oldLearned = packed & learned != 0
                let isWrong = grade != 0
                let level: UInt32 = isWrong ? 1 : ((1...10).contains(oldLevel) ? oldLevel : 1)
                let due: UInt32
                if isWrong {
                    guard event.day < 50_180 else { throw fail("旧答错日期无效") }
                    due = event.day + 1
                } else {
                    guard let memory = source.daily[id], (1...50_180).contains(memory.dueDay) else {
                        throw fail("已评分题目的复习日期缺失")
                    }
                    due = memory.dueDay
                }
                // A real correct answer establishes a learned review slot;
                // a wrong answer does not manufacture a prior success.
                let learnedFlag: UInt32 = oldLearned || !isWrong ? learned : 0
                packed = due | (level << 16) | learnedFlag
            } else if queued.contains(id), packed & learned != 0, ((packed >> 16) & 15) == 0 {
                // The dual queue can explicitly contain an old first-known
                // item. Preserve that ungraded presentation as a review;
                // the old first-known packed value remains in the source.
                guard let memory = source.daily[id], (1...50_180).contains(memory.dueDay) else {
                    throw fail("当前题的复习日期缺失")
                }
                packed = memory.dueDay | (UInt32(1) << 16) | learned
            }
            mapped[index] = packed
        }

        func obligation(_ id: String) throws -> PublicPocketObligation {
            guard let word = words[id] else { throw fail("待续题目不存在") }
            let packed = mapped[Int(word)]
            var stages: UInt8 = 1, failed: UInt8 = 0
            if carries.contains(id), let item = legacy[id], item.stageMask != 0 {
                guard item.stageMask <= 255, item.failedRound <= 2 else { throw fail("旧任务阶段无效") }
                stages = UInt8(item.stageMask); failed = UInt8(item.failedRound)
            } else if packed & partial != 0 {
                failed = 2
            }
            return .init(questionID: id, word: word, packed: packed, stages: stages, failedRound: failed)
        }
        let current = try source.queue.map(obligation)
        let parked = try source.carry.filter { !queued.contains($0) }.map(obligation)
        let obligations = current + parked
        guard Set(obligations.map(\.questionID)).count == obligations.count else { throw fail("待续题目重复") }
        let parkedWords = Set(parked.map(\.word))
        var enabled = [UInt8](repeating: 0, count: ids.count)
        var stages = [UInt8](repeating: 0, count: ids.count)
        var failed = [UInt8](repeating: 0, count: ids.count)
        let initial = [UInt32](repeating: inert, count: ids.count)
        var streamBytes = stream.uuid
        let engine = withUnsafeBytes(of: &streamBytes) { streamRaw in
            initial.withUnsafeBufferPointer { cards in
                xkl_engine_import_cards(UInt32(ids.count), cards.baseAddress, day, UInt32.max,
                                        streamRaw.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard let engine else { throw fail("无法创建独立单词引擎档案") }
        defer { xkl_engine_free(engine) }
        var uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        func apply() throws {
            uptime += 1
            let ok = enabled.withUnsafeBufferPointer { eb in
                mapped.withUnsafeBufferPointer { mb in
                    stages.withUnsafeBufferPointer { sb in
                        failed.withUnsafeBufferPointer { fb in
                            xkl_engine_reconcile_collection(engine, UInt32(ids.count), UInt32(ids.count),
                                eb.baseAddress, mb.baseAddress, uptime, sb.baseAddress, fb.baseAddress)
                        }
                    }
                }
            }
            guard ok else { throw fail("无法无损接续原待办阶段") }
        }
        // Activate each current item separately so the displayed head and all
        // remaining stage order survive. Only START/PRESENT metadata is made.
        for item in current {
            let i = Int(item.word); enabled[i] = 1; stages[i] = item.stages; failed[i] = item.failedRound
            try apply()
        }
        for i in ids.indices where !parkedWords.contains(UInt32(i)) { enabled[i] = 1 }
        try apply()
        let ordered = try interleavedTokens(current, legacyTokens: source.legacyTokens)
        if !ordered.isEmpty {
            uptime += 1
            let reordered = ordered.withUnsafeBufferPointer {
                xkl_engine_reorder_question_migration(engine, $0.baseAddress, UInt32($0.count), uptime)
            }
            guard reordered else { throw fail("无法安全排列原待办") }
        }
        if source.presentation?.pending != nil {
            uptime += 1
            guard xkl_engine_reveal(engine, uptime) else { throw fail("无法保留原答题结果页") }
        }
        var info = xkl_info_t()
        guard xkl_engine_info(engine, &info),
              (source.presentation == nil && info.has_task == 0) ||
                (source.presentation != nil && info.has_task != 0 &&
                 words[source.presentation!.questionID] == info.word) else {
            throw fail("当前题与迁移后队列不一致")
        }
        let size = xkl_engine_snapshot_size(engine)
        var snapshot = Data(count: size)
        let written = snapshot.withUnsafeMutableBytes { raw in
            xkl_engine_snapshot(engine, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard written == size, size > 0 else { throw fail("单词引擎快照未完整保存") }
        let pocket = try PocketEngine(snapshot: snapshot)
        var analysis = StudyAnalysisSettings(streamID: try pocket.streamID,
                                             nextSequence: info.log_records + 1, now: now)
        analysis.setEnabled(original.analysis.conservativeEnabled, nextSequence: info.log_records + 1, now: now)
        var record = ExamDiskRecord(bankSHA256: hash, snapshot: snapshot,
            snapshotSHA256: StudySHA256.hex(snapshot), taskID: source.taskID,
            presentation: source.presentation, previousOrders: source.previousOrders,
            attempts: [], analysis: analysis, volumes: [], lastUndoableAttemptID: nil)
        record.examReductionEnabled = original.examReductionEnabled
        _ = try ExamLearningEngine(bank: bank, hash: hash, record: record)
        return PublicPocketMigrationPlan(bankID: bank.id, bankSHA256: hash,
            sourceDualSHA256: StudySHA256.hex(sourceDualBytes), sourceAnchorSHA256: StudySHA256.hex(anchorBytes),
            migratedAt: now, streamID: stream, questionIDs: ids, mappedCards: mapped,
            initialObligations: obligations, parkedObligations: parked, record: record,
            bridgeReview: source.answerReview)
    }
}
