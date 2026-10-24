import Foundation
import StudyCore

enum ExamError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum ExamQuestionType: String, Codable {
    case single, multiple, judgment
    var title: String {
        switch self {
        case .single: return "单选题"
        case .multiple: return "多选题"
        case .judgment: return "判断题"
        }
    }
}

struct ExamOption: Codable, Identifiable, Equatable {
    let id: String
    let text: String
}

struct ExamQuestion: Codable, Identifiable, Equatable {
    let id: String
    let number: Int
    let type: ExamQuestionType
    let section: String
    let prompt: String
    let options: [ExamOption]
    let answer: [String]
    let pageStart: Int
    let pageEnd: Int

    func accepts(_ selection: Set<String>) -> Bool {
        !selection.isEmpty && selection.isSubset(of: Set(options.map(\.id))) &&
        (type == .multiple || selection.count == 1)
    }

    func isCorrect(_ selection: Set<String>) -> Bool {
        accepts(selection) && selection == Set(answer)
    }
}

struct ExamBank: Codable, Equatable {
    let id: String
    let title: String
    let sourceName: String
    let sourceSHA256: String
    let totalPages: Int
    let questions: [ExamQuestion]

    var sections: [String] {
        var seen = Set<String>()
        return questions.compactMap { seen.insert($0.section).inserted ? $0.section : nil }
    }

    func validate() throws {
        guard !id.isEmpty, id.count <= 200, !title.isEmpty, title.count <= 500,
              !sourceName.isEmpty, sourceName.count <= 1_000,
              ExamContent.isHash(sourceSHA256), (1...10_000).contains(totalPages),
              !questions.isEmpty, questions.count <= 10_000,
              Set(questions.map(\.id)).count == questions.count,
              Set(questions.map(\.number)).count == questions.count else {
            throw ExamError.invalid("题库标识、来源或题目数量无效。")
        }
        for q in questions {
            guard !q.id.isEmpty, q.id.count <= 200, q.number > 0,
                  !q.section.isEmpty, q.section.count <= 500,
                  !q.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  q.prompt.count <= 30_000, (2...20).contains(q.options.count),
                  Set(q.options.map(\.id)).count == q.options.count,
                  q.options.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 40 &&
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      $0.text.count <= 20_000 }),
                  !q.answer.isEmpty, Set(q.answer).count == q.answer.count,
                  q.accepts(Set(q.answer)),
                  q.type != .judgment || q.options.count == 2,
                  q.pageStart >= 1, q.pageEnd >= q.pageStart, q.pageEnd <= totalPages else {
                throw ExamError.invalid("第 \(q.number) 题的题干、选项、答案或页码无效。")
            }
        }
    }
}

struct ExamContent: Codable {
    static let formatName = "xkl-ios-questions-v1"
    static let maximumFileBytes = 20 * 1_024 * 1_024
    let format: String
    let bankBytes: Data
    let bankSHA256: String

    static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func load(_ data: Data) throws -> (ExamContent, ExamBank) {
        guard data.count <= maximumFileBytes else { throw ExamError.invalid("题库包超过 20MB。") }
        let package = try JSONDecoder().decode(Self.self, from: data)
        guard package.format == formatName, isHash(package.bankSHA256),
              StudySHA256.hex(package.bankBytes) == package.bankSHA256 else {
            throw ExamError.invalid("题库包版本或内容校验不通过。")
        }
        let bank = try JSONDecoder().decode(ExamBank.self, from: package.bankBytes)
        try bank.validate()
        return (package, bank)
    }
}

struct ExamAttempt: Codable, Identifiable, Equatable {
    let id: UUID
    let bankID: String
    let bankSHA256: String
    let questionID: String
    let number: Int
    let selectedOptions: [String]
    let correctOptions: [String]
    let optionOrder: [String]
    let isCorrect: Bool
    let answeredAt: Date
    let sessionID: UUID
    let presentationID: UUID
    let mode: String
    var grade: Int32?
    var gradedAt: Date?
    var engineSequence: UInt32?
    var beforeRevision: UInt32?
    var afterRevision: UInt32?
    var undoneAttemptID: UUID?
    var examPlan: UInt32?
    var shortenedRepeats: UInt32?
    var tailRemoved: UInt32?
    var tailDeferred: Bool?
    var failureCountInTask: Int?
    /// Nil is retained for older self-assessed answers; never backfill it.
    var gradingSource: String?
    /// Only a real initial correct answer can enter training this way.
    /// Nil is retained for older records; no answer or mistake is backfilled.
    var learningInitialization: String?
    var initializedRepeats: UInt32?
}

struct ExamPresentation: Codable, Equatable {
    let id: UUID
    let questionID: String
    let optionOrder: [String]
    var selectedOptionIDs: [String]
    var pending: ExamAttempt?
    var supplementVisible: Bool
    let presentedAt: Date

    static func order(for question: ExamQuestion, avoiding previous: [String]?) -> [String] {
        var result = question.options.map(\.id).shuffled()
        if result == previous, result.count > 1 { result.append(result.removeFirst()) }
        return result
    }

    static func label(_ optionID: String, in order: [String]) -> String {
        guard let index = order.firstIndex(of: optionID),
              let scalar = UnicodeScalar(65 + index) else { return "?" }
        return String(Character(scalar))
    }
}

struct ExamVolumeReference: Codable, Equatable {
    let filename: String
    let sha256: String
    let firstSequence: UInt32
    let lastSequence: UInt32
    let attemptCount: Int
}

struct ExamAnswerReview: Codable, Equatable {
    let presentation: ExamPresentation
    let attempt: ExamAttempt
}

struct ExamReductionChange: Codable {
    let enabled: Bool
    let changedAt: Date
    let taskID: UUID
    let firstSequence: UInt32
}

struct ExamDiskRecord: Codable {
    var format = "xkl-ios-question-study-v2"
    let bankSHA256: String
    var snapshot: Data
    var snapshotSHA256: String
    var taskID: UUID
    var presentation: ExamPresentation?
    var previousOrders: [String: [String]]
    var attempts: [ExamAttempt]
    var analysis: StudyAnalysisSettings
    var volumes: [ExamVolumeReference]
    var lastUndoableAttemptID: UUID?
    var examReductionEnabled = true
    var failureCounts: [String: Int] = [:]
    var shortPlanQuestionIDs: [String] = []
    var examReductionChanges: [ExamReductionChange] = []
    /// Optional for byte-compatible decoding of existing 1.4.0 archives.
    /// The C engine already points at the next question while this is visible.
    var answerReview: ExamAnswerReview?

    func validateContent(bank: ExamBank, hash: String) throws {
        guard format == "xkl-ios-question-study-v2", bankSHA256 == hash,
              snapshotSHA256 == StudySHA256.hex(snapshot),
              Set(attempts.map(\.id)).count == attempts.count else {
            throw ExamError.invalid("题库记忆档案版本或校验失败，原文件已保留。")
        }
        let questions = Dictionary(uniqueKeysWithValues: bank.questions.map { ($0.id, $0) })
        guard failureCounts.allSatisfy({ questions[$0.key] != nil && $0.value > 0 }),
              shortPlanQuestionIDs == Set(shortPlanQuestionIDs).sorted(),
              shortPlanQuestionIDs.allSatisfy({ questions[$0] != nil && (failureCounts[$0] ?? 0) <= 1 }),
              examReductionChanges.allSatisfy({ $0.firstSequence > 0 &&
                  $0.changedAt.timeIntervalSince1970.isFinite }) else {
            throw ExamError.invalid("题库试行策略或本轮错误计数无效。")
        }
        func validOrder(_ order: [String], _ question: ExamQuestion) -> Bool {
            order.count == question.options.count && Set(order) == Set(question.options.map(\.id))
        }
        for (id, order) in previousOrders {
            guard let question = questions[id], validOrder(order, question) else {
                throw ExamError.invalid("题库选项排列记录无效。")
            }
        }
        func validAttempt(_ attempt: ExamAttempt, pending: Bool) -> Bool {
            guard let q = questions[attempt.questionID], attempt.bankID == bank.id,
                  attempt.bankSHA256 == hash, attempt.number == q.number,
                  validOrder(attempt.optionOrder, q), attempt.correctOptions == q.answer.sorted(),
                  attempt.selectedOptions == Set(attempt.selectedOptions).sorted(),
                  Set(attempt.selectedOptions).isSubset(of: Set(q.options.map(\.id))),
                  attempt.answeredAt.timeIntervalSince1970.isFinite else { return false }
            if attempt.mode == "answer" {
                guard q.accepts(Set(attempt.selectedOptions)),
                      attempt.isCorrect == q.isCorrect(Set(attempt.selectedOptions)) else { return false }
                if pending {
                    return attempt.grade == nil && attempt.gradedAt == nil &&
                        attempt.engineSequence == nil && attempt.learningInitialization == nil &&
                        attempt.initializedRepeats == nil
                }
                guard let grade = attempt.grade, [0, 1, 3].contains(grade),
                      attempt.isCorrect || grade == 1,
                      let plan = attempt.examPlan, plan <= 4,
                      let removed = attempt.shortenedRepeats, removed <= 4,
                      let tail = attempt.tailRemoved, tail <= 2,
                      attempt.tailDeferred == (tail > 0),
                      attempt.failureCountInTask != nil else { return false }
            } else if attempt.mode == "familiar" {
                guard !pending, attempt.grade == 2, attempt.selectedOptions.isEmpty else { return false }
            } else if attempt.mode == "undo" {
                guard !pending, attempt.grade == nil, attempt.undoneAttemptID != nil else { return false }
            } else { return false }
            if let initialization = attempt.learningInitialization {
                guard attempt.mode == "answer", attempt.grade == 0, attempt.isCorrect,
                      attempt.failureCountInTask == 0,
                      (initialization == "correct-short" && attempt.examPlan == 3 && attempt.initializedRepeats == 3) ||
                      (initialization == "correct-full" && attempt.examPlan == 4 && attempt.initializedRepeats == 7)
                else { return false }
            } else if attempt.initializedRepeats != nil || attempt.examPlan == 3 || attempt.examPlan == 4 {
                return false
            }
            return attempt.gradedAt?.timeIntervalSince1970.isFinite == true &&
                attempt.engineSequence != nil && attempt.beforeRevision != nil &&
                attempt.afterRevision == (attempt.beforeRevision.map { $0 &+ 1 })
        }
        guard attempts.allSatisfy({ validAttempt($0, pending: false) }) else {
            throw ExamError.invalid("题库逐次作答记录无效。")
        }
        if let p = presentation {
            guard let q = questions[p.questionID], validOrder(p.optionOrder, q),
                  previousOrders[p.questionID] == p.optionOrder,
                  p.selectedOptionIDs == Set(p.selectedOptionIDs).sorted(),
                  Set(p.selectedOptionIDs).isSubset(of: Set(q.options.map(\.id))),
                  q.type == .multiple || p.selectedOptionIDs.count <= 1,
                  p.presentedAt.timeIntervalSince1970.isFinite else {
                throw ExamError.invalid("题库出题断点无效。")
            }
            if let pending = p.pending {
                guard validAttempt(pending, pending: true), pending.questionID == p.questionID,
                      pending.presentationID == p.id, pending.sessionID == taskID,
                      pending.optionOrder == p.optionOrder,
                      pending.selectedOptions == p.selectedOptionIDs,
                      !attempts.contains(where: { $0.id == pending.id }),
                      !p.supplementVisible || pending.isCorrect else {
                    throw ExamError.invalid("题库待评分断点无效。")
                }
            } else if p.supplementVisible {
                throw ExamError.invalid("没有待评分答案时不能进入补看。")
            }
        }
        if let review = answerReview {
            let p = review.presentation, attempt = review.attempt
            guard let q = questions[p.questionID], validOrder(p.optionOrder, q),
                  validAttempt(attempt, pending: false), attempt.mode == "answer",
                  p.pending == nil, !p.supplementVisible,
                  p.selectedOptionIDs == attempt.selectedOptions,
                  p.id == attempt.presentationID, p.questionID == attempt.questionID,
                  p.optionOrder == attempt.optionOrder,
                  p.presentedAt.timeIntervalSince1970.isFinite,
                  presentation?.id != p.id, presentation?.pending == nil,
                  !(presentation?.supplementVisible ?? false) else {
                throw ExamError.invalid("题库结果页与已保存的作答记录不一致。")
            }
            if let saved = attempts.first(where: { $0.id == attempt.id }) {
                guard saved == attempt else { throw ExamError.invalid("题库结果页引用了不同的作答内容。") }
            } else {
                guard let sequence = attempt.engineSequence,
                      let end = volumes.last?.lastSequence, sequence <= end else {
                    throw ExamError.invalid("题库结果页引用的作答记录缺失。")
                }
            }
        }
        var end: UInt32 = 0
        for volume in volumes {
            guard ExamContent.isHash(volume.sha256), volume.filename == volume.sha256 + ".json",
                  volume.firstSequence == end + 1, volume.lastSequence >= volume.firstSequence,
                  volume.lastSequence < UInt32.max, volume.attemptCount >= 0 else {
                throw ExamError.invalid("题库分卷记录无效。")
            }
            end = volume.lastSequence
        }
    }
}

struct ExamVersionExport: Codable {
    let bankSHA256: String
    let bank: ExamBank
    let attempts: [ExamAttempt]
    let activeRecord: ExamDiskRecord
    /// Exact immutable records preserve C logs, scheduling decisions and every
    /// option permutation. Their names and hashes are in activeRecord.volumes.
    let volumeBytes: [String: Data]
}

struct ExamRecordsExport: Codable {
    let format: String
    let exportedAt: Date
    let activeBankSHA256: String?
    let versions: [ExamVersionExport]
}

/// Read-only first-pass coverage guidance. The caller supplies normalized
/// local calendar days and counts derived from real, non-undone history.
/// "Introduced" includes a first encounter or an explicit familiar skip; it
/// does not mean mastered. No queue, due date, or lesson size is changed here.
struct ExamStudyPlan: Equatable {
    let totalQuestionCount: Int
    let unseenQuestionCount: Int
    let newIntroducedToday: Int
    let todayDay: Int
    let examDay: Int
    /// A user-set time budget, never converted into a guessed answer count.
    let dailyMinutes: Int
    let reviewBufferDays: Int
    let daysToExam: Int
    let newLearningDaysAvailable: Int
    /// Once the preferred first-pass window has passed, distribute unfinished
    /// coverage across the remaining days before the exam, with a warning.
    let pacingDays: Int
    let newTargetTotal: Int
    let targetNewToday: Int
    let remainingNewToday: Int
    let isExamDay: Bool
    let examHasPassed: Bool
    let isInsideReviewBuffer: Bool

    init(totalQuestionCount: Int, unseenQuestionCount: Int, newIntroducedToday: Int,
         todayDay: Int, examDay: Int, dailyMinutes: Int = 30, reviewBufferDays: Int = 14) {
        let total = max(0, totalQuestionCount)
        let unseen = min(max(0, unseenQuestionCount), total)
        let introduced = min(max(0, newIntroducedToday), total - unseen)
        let buffer = max(0, reviewBufferDays)
        let distance = max(0, examDay - todayDay)
        let available = max(0, distance - buffer + 1)
        let beforeExam = todayDay < examDay
        let effectiveDays = beforeExam ? (available > 0 ? available : distance) : 0
        let toCover = unseen + introduced
        // Division/remainder avoids addition overflow in ceil(n / d).
        let dailyTarget = effectiveDays > 0 ?
            toCover / effectiveDays + (toCover % effectiveDays == 0 ? 0 : 1) : 0
        self.totalQuestionCount = total
        self.unseenQuestionCount = unseen
        self.newIntroducedToday = introduced
        self.todayDay = todayDay
        self.examDay = examDay
        self.dailyMinutes = max(0, dailyMinutes)
        self.reviewBufferDays = buffer
        self.daysToExam = distance
        self.newLearningDaysAvailable = beforeExam ? available : 0
        self.pacingDays = effectiveDays
        self.newTargetTotal = toCover
        self.targetNewToday = dailyTarget
        self.remainingNewToday = max(0, dailyTarget - introduced)
        self.isExamDay = todayDay == examDay
        self.examHasPassed = todayDay > examDay
        self.isInsideReviewBuffer = beforeExam && available == 0 && unseen > 0
    }
}
