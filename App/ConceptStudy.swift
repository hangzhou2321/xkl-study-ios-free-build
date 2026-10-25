import Foundation
import StudyCore

struct ConceptSource: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let reference: String
}

struct ConceptQuestion: Codable, Equatable, Identifiable {
    let id: String
    let type: ExamQuestionType
    let prompt: String
    let options: [ExamOption]
    let answer: [String]
    let explanation: String
    let sourceIDs: [String]
    let sourceLocation: String
    let verification: String
    var preserveOptionOrder: Bool? = nil
}

struct StudyConcept: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let section: String
    let method: String
    let questions: [ConceptQuestion]
}

/// The bank remains an append-only historical dictionary. Scope selects only
/// which of those immutable questions may be scheduled for current practice.
struct ConceptStudyScope: Codable, Equatable {
    let id: String
    let title: String
    let sourceReference: String
    let includedQuestionIDs: [String]
    let excludedQuestionReasons: [String: String]
}

struct ConceptBank: Codable, Equatable {
    let id: String
    let title: String
    let scope: String
    let notice: String
    let sources: [ConceptSource]
    let concepts: [StudyConcept]
    var studyScope: ConceptStudyScope? = nil

    func isActive(_ questionID: String) -> Bool {
        if let studyScope { return studyScope.includedQuestionIDs.contains(questionID) }
        return concepts.contains { $0.questions.contains { $0.id == questionID } }
    }

    func activeQuestions(in concept: StudyConcept) -> [ConceptQuestion] {
        guard let studyScope else { return concept.questions }
        let included = Set(studyScope.includedQuestionIDs)
        return concept.questions.filter { included.contains($0.id) }
    }

    /// Updates may append questions/concepts but cannot reinterpret historical IDs.
    func validateAppendOnly(from old: ConceptBank) throws {
        try validate()
        guard id == old.id, concepts.count >= old.concepts.count,
              Array(concepts.prefix(old.concepts.count).map(\.id)) == old.concepts.map(\.id),
              Array(sources.prefix(old.sources.count)) == old.sources else {
            throw ExamError.invalid("题库更新改变了原考点或来源，原学习记录已保留。")
        }
        for (before, after) in zip(old.concepts, concepts) {
            guard before.id == after.id, before.title == after.title,
                  before.section == after.section, before.method == after.method,
                  Array(after.questions.prefix(before.questions.count)) == before.questions else {
                throw ExamError.invalid("题库更新修改或删除了已有题目，不能自动继承进度。")
            }
        }
    }

    func validate() throws {
        let sourceIDs = Set(sources.map(\.id))
        guard !id.isEmpty, !title.isEmpty, !scope.isEmpty, !notice.isEmpty,
              !sources.isEmpty, sourceIDs.count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.reference.isEmpty }),
              (1...2_000).contains(concepts.count),
              Set(concepts.map(\.id)).count == concepts.count else {
            throw ExamError.invalid("考点题库的标识或来源无效。")
        }
        var ids = Set<String>()
        for c in concepts {
            let fingerprints = c.questions.map {
                $0.prompt.filter { !$0.isWhitespace } + "\n" +
                $0.options.map { $0.text.filter { !$0.isWhitespace } }.sorted().joined(separator: "\n")
            }
            guard !c.id.isEmpty, !c.title.isEmpty, !c.section.isEmpty, !c.method.isEmpty,
                  (2...2_000).contains(c.questions.count),
                  Set(fingerprints).count == c.questions.count else {
                throw ExamError.invalid("每个考点至少需要两道不同的、已核对的题。")
            }
            for q in c.questions {
                let optionIDs = Set(q.options.map(\.id))
                guard ids.insert(q.id).inserted, !q.id.isEmpty,
                      !q.prompt.isEmpty, q.prompt.count <= 30_000,
                      (2...20).contains(q.options.count),
                      optionIDs.count == q.options.count,
                      q.options.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty }),
                      Set(q.options.map(\.text)).count == q.options.count,
                      !q.answer.isEmpty, Set(q.answer).count == q.answer.count,
                      Set(q.answer).isSubset(of: optionIDs),
                      q.type == .multiple || q.answer.count == 1,
                      q.type != .judgment || q.options.count == 2,
                      !q.explanation.isEmpty, !q.verification.isEmpty,
                      !q.sourceLocation.isEmpty, !q.sourceIDs.isEmpty,
                      Set(q.sourceIDs).isSubset(of: sourceIDs) else {
                    throw ExamError.invalid("考点题目的选项、解析或核对依据不完整。")
                }
            }
        }
        if let studyScope {
            let included = Set(studyScope.includedQuestionIDs)
            let excluded = Set(studyScope.excludedQuestionReasons.keys)
            guard !studyScope.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !studyScope.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !studyScope.sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !included.isEmpty, included.count == studyScope.includedQuestionIDs.count,
                  included.isDisjoint(with: excluded), included.union(excluded) == ids,
                  studyScope.excludedQuestionReasons.values.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw ExamError.invalid("练习范围必须明确覆盖每道题，不能遗漏、重复或引用未知题目。")
            }
        }
    }
}

struct ConceptContent: Codable {
    let format: String
    let bankBytes: Data
    let bankSHA256: String

    static func load(_ data: Data) throws -> (ConceptContent, ConceptBank) {
        guard data.count <= 30 * 1_024 * 1_024 else { throw ExamError.invalid("考点题库超过可导入大小。") }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        guard pack.format == "xkl-concepts-v1", ExamContent.isHash(pack.bankSHA256),
              StudySHA256.hex(pack.bankBytes) == pack.bankSHA256 else {
            throw ExamError.invalid("考点题库校验失败。")
        }
        let bank = try JSONDecoder().decode(ConceptBank.self, from: pack.bankBytes)
        try bank.validate()
        return (pack, bank)
    }
}

struct ConceptProgress: Codable, Equatable {
    var level = 0
    var dueDay = 0
    var lastAnsweredDay: Int?
    var usedQuestionIDs: [String] = []
    var familiar = false
    var correct = 0
    var wrong = 0
    var delayedCorrect = 0
}

struct ConceptPresentation: Codable, Equatable {
    let id: UUID
    let conceptID: String
    let questionID: String
    let order: [String]
    var selected: [String]
    let presentedAt: Date
}

struct ConceptAttempt: Codable, Equatable, Identifiable {
    let id: UUID
    let sequence: Int
    let sessionID: UUID
    let presentation: ConceptPresentation
    let mode: String
    let isCorrect: Bool?
    let answeredAt: Date
    let day: Int
    let before: ConceptProgress
    let after: ConceptProgress
    let retryQueued: Bool
    let undoTarget: UUID?
}

struct ConceptVolume: Codable, Equatable {
    let sha256: String
    let first: Int
    let last: Int
    let count: Int
}

/// A syllabus update parks only live UI pointers. It never manufactures an
/// answer or changes the immutable attempt/progress that those pointers refer to.
struct ConceptScopeSuspension: Codable, Equatable {
    let scopeID: String
    let parkedAt: Date
    let presentation: ConceptPresentation?
    let review: ConceptAttempt?
    let undoFamiliar: ConceptAttempt?
    /// A content hold may remove a queued concept without grading it. Keep the
    /// complete prior queue so the transition remains inspectable/recoverable.
    var parkedQueue: [String]? = nil
}

struct ConceptRecord: Codable {
    var format = "xkl-concept-study-v1"
    var bankSHA256: String
    var day = 0
    var sessionID = UUID()
    var progress: [String: ConceptProgress] = [:]
    var queue: [String] = []
    var retriesToday: [String: Int] = [:]
    var presentation: ConceptPresentation?
    var review: ConceptAttempt?
    var undoFamiliar: ConceptAttempt?
    var attempts: [ConceptAttempt] = []
    var volumes: [ConceptVolume] = []
    var nextSequence = 1
    var scopeSuspensions: [ConceptScopeSuspension]? = nil

    func validate(bank: ConceptBank, hash: String) throws {
        guard format == "xkl-concept-study-v1", bankSHA256 == hash,
              ExamContent.isHash(hash), day >= 0, nextSequence > 0 else {
            throw ExamError.invalid("考点学习档案身份或版本无效。")
        }
        let concepts = Dictionary(uniqueKeysWithValues: bank.concepts.map { ($0.id, $0) })
        func validProgress(_ p: ConceptProgress, _ c: StudyConcept) -> Bool {
            (0...10).contains(p.level) && p.dueDay >= 0 && p.correct >= 0 &&
            p.wrong >= 0 && p.delayedCorrect >= 0 &&
            p.usedQuestionIDs.count == Set(p.usedQuestionIDs).count &&
            Set(p.usedQuestionIDs).isSubset(of: Set(c.questions.map(\.id))) &&
            p.correct + p.wrong == p.usedQuestionIDs.count &&
            (p.lastAnsweredDay == nil || p.lastAnsweredDay! >= 0)
        }
        func validPresentation(_ p: ConceptPresentation) -> Bool {
            guard let c = concepts[p.conceptID],
                  let q = c.questions.first(where: { $0.id == p.questionID }) else { return false }
            return p.order.count == q.options.count && Set(p.order) == Set(q.options.map(\.id)) &&
                p.selected == Set(p.selected).sorted() && Set(p.selected).isSubset(of: Set(p.order)) &&
                (q.type == .multiple || p.selected.count <= 1) &&
                p.presentedAt.timeIntervalSince1970.isFinite
        }
        func validAttempt(_ a: ConceptAttempt) -> Bool {
            guard let c = concepts[a.presentation.conceptID],
                  let q = c.questions.first(where: { $0.id == a.presentation.questionID }),
                  validPresentation(a.presentation), validProgress(a.before, c), validProgress(a.after, c),
                  a.sequence > 0, a.sequence < nextSequence, a.day >= 0,
                  a.answeredAt.timeIntervalSince1970.isFinite else { return false }
            switch a.mode {
            case "answer":
                return !a.presentation.selected.isEmpty && a.undoTarget == nil &&
                    a.isCorrect == (Set(a.presentation.selected) == Set(q.answer)) &&
                    !a.before.usedQuestionIDs.contains(q.id) &&
                    a.after.usedQuestionIDs == a.before.usedQuestionIDs + [q.id] &&
                    a.after.correct == a.before.correct + (a.isCorrect == true ? 1 : 0) &&
                    a.after.wrong == a.before.wrong + (a.isCorrect == true ? 0 : 1)
            case "familiar":
                return a.isCorrect == nil && a.undoTarget == nil && a.after.familiar &&
                    !a.before.familiar && a.before.usedQuestionIDs == a.after.usedQuestionIDs
            case "undo":
                return a.isCorrect == nil && a.undoTarget != nil
            default: return false
            }
        }
        guard progress.allSatisfy({ key, value in
            concepts[key].map { validProgress(value, $0) } ?? false
        }), queue.allSatisfy({ concepts[$0] != nil }), Set(queue).count == queue.count,
           retriesToday.allSatisfy({ concepts[$0.key] != nil && (0...1).contains($0.value) }),
           attempts.allSatisfy(validAttempt) else {
            throw ExamError.invalid("考点进度或作答记录无效，原档案已保留。")
        }
        var expected = 1
        for volume in volumes {
            guard ExamContent.isHash(volume.sha256), volume.first == expected,
                  volume.last >= volume.first, volume.count == volume.last - volume.first + 1 else {
                throw ExamError.invalid("考点日志分卷顺序无效。")
            }
            expected = volume.last + 1
        }
        for a in attempts {
            guard a.sequence == expected else { throw ExamError.invalid("考点日志序号不连续。") }
            expected += 1
        }
        guard expected == nextSequence else { throw ExamError.invalid("考点日志边界不一致。") }
        if let p = presentation {
            guard review == nil, validPresentation(p), queue.first == p.conceptID,
                  !(progress[p.conceptID]?.familiar ?? false),
                  !(progress[p.conceptID]?.usedQuestionIDs.contains(p.questionID) ?? false) else {
                throw ExamError.invalid("当前变式断点不一致。")
            }
        }
        if let review {
            guard presentation == nil, validAttempt(review), review.mode == "answer" else {
                throw ExamError.invalid("考点结果页无效。")
            }
        }
        if let undoFamiliar {
            guard validAttempt(undoFamiliar), undoFamiliar.mode == "familiar",
                  undoFamiliar.sequence == nextSequence - 1 else {
                throw ExamError.invalid("熟悉撤销断点无效。")
            }
        }
        for suspension in scopeSuspensions ?? [] {
            func hasAttempt(_ a: ConceptAttempt) -> Bool {
                if let stored = attempts.first(where: { $0.sequence == a.sequence }) {
                    return stored == a
                }
                // The store separately checks copied pointers against actual
                // decoded volume contents during its full-history replay.
                return volumes.contains { ($0.first...$0.last).contains(a.sequence) }
            }
            guard !suspension.scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  suspension.parkedAt.timeIntervalSince1970.isFinite,
                  suspension.presentation != nil || suspension.review != nil || suspension.undoFamiliar != nil || suspension.parkedQueue?.isEmpty == false,
                  suspension.presentation == nil || suspension.review == nil else {
                throw ExamError.invalid("停用题目保存的断点无效，原档案已保留。")
            }
            if let p = suspension.presentation, !validPresentation(p) {
                throw ExamError.invalid("停用题目的待答断点无法核对。")
            }
            if let queue = suspension.parkedQueue {
                guard Set(queue).count == queue.count, queue.allSatisfy({ concepts[$0] != nil }) else {
                    throw ExamError.invalid("暂缓题目保存的队列无效。")
                }
            }
            if let a = suspension.review {
                guard validAttempt(a), a.mode == "answer", hasAttempt(a) else {
                    throw ExamError.invalid("停用题目的结果断点与真实日志不一致。")
                }
            }
            if let a = suspension.undoFamiliar {
                guard validAttempt(a), a.mode == "familiar", hasAttempt(a) else {
                    throw ExamError.invalid("停用题目的熟悉断点与真实日志不一致。")
                }
            }
        }
    }
}

/// Independent concept practice: no writes to CPocket, word state or exam state.
struct ConceptEngine {
    let bank: ConceptBank
    var record: ConceptRecord
    private(set) var heldQuestionIDs: Set<String> = []
    static let gaps = [1, 2, 3, 5, 7, 10, 15, 30, 90, 180]

    init(bank: ConceptBank, hash: String, record: ConceptRecord? = nil) throws {
        try bank.validate()
        self.bank = bank
        self.record = record ?? ConceptRecord(bankSHA256: hash)
        try self.record.validate(bank: bank, hash: hash)
    }

    var shown: ConceptPresentation? { record.review?.presentation ?? record.presentation }
    var concept: StudyConcept? { bank.concepts.first { $0.id == shown?.conceptID } }
    var question: ConceptQuestion? { concept?.questions.first { $0.id == shown?.questionID } }
    var activeConcepts: [StudyConcept] {
        bank.concepts.filter { !conceptQuestions($0.id).isEmpty }
    }
    var activeQuestionCount: Int {
        activeConcepts.reduce(0) { $0 + conceptQuestions($1.id).count }
    }
    var archivedConcepts: [StudyConcept] {
        bank.concepts.filter { bank.activeQuestions(in: $0).isEmpty }
    }
    var exhausted: [StudyConcept] {
        activeConcepts.filter {
            let p = record.progress[$0.id] ?? ConceptProgress()
            return !p.familiar && !hasActiveUnusedQuestion($0.id)
        }
    }

    /// Invoked explicitly by import/migration, never as a side effect of load.
    /// Progress, schedule dates, familiarity and the attempt log remain exact.
    mutating func applyStudyScope(now: Date = Date()) {
        guard let scope = bank.studyScope else { return }
        let pending = record.presentation.flatMap { bank.isActive($0.questionID) ? nil : $0 }
        let result = record.review.flatMap { bank.isActive($0.presentation.questionID) ? nil : $0 }
        let familiar = record.undoFamiliar.flatMap { bank.isActive($0.presentation.questionID) ? nil : $0 }
        if pending != nil || result != nil || familiar != nil {
            let parked = ConceptScopeSuspension(scopeID: scope.id, parkedAt: now,
                presentation: pending, review: result, undoFamiliar: familiar)
            if record.scopeSuspensions == nil { record.scopeSuspensions = [] }
            record.scopeSuspensions!.append(parked)
            if pending != nil { record.presentation = nil }
            if result != nil { record.review = nil }
            if familiar != nil { record.undoFamiliar = nil }
        }
        record.queue = record.queue.filter {
            !(record.progress[$0]?.familiar ?? false) && hasActiveUnusedQuestion($0)
        }
    }

    /// Editorial holds change selection only. They never consume a question,
    /// mark a concept familiar, or manufacture a score. The immutable teaching
    /// hash identifies why a live pointer/queue was parked.
    mutating func applyQuestionHolds(_ ids: Set<String>, revision: String, now: Date = Date()) throws {
        guard ids.isSubset(of: Set(bank.concepts.flatMap(\.questions).map(\.id))),
              !revision.isEmpty, revision.count <= 160, now.timeIntervalSince1970.isFinite else {
            throw ExamError.invalid("暂缓判分范围或来源无效。")
        }
        heldQuestionIDs = ids
        guard !ids.isEmpty else { return }
        let pending = record.presentation.flatMap { ids.contains($0.questionID) ? $0 : nil }
        let result = record.review.flatMap { ids.contains($0.presentation.questionID) ? $0 : nil }
        let familiar = record.undoFamiliar.flatMap { ids.contains($0.presentation.questionID) ? $0 : nil }
        let priorQueue = record.queue
        let nextQueue = priorQueue.filter { !(record.progress[$0]?.familiar ?? false) && hasActiveUnusedQuestion($0) }
        guard pending != nil || result != nil || familiar != nil || priorQueue != nextQueue else { return }
        if record.scopeSuspensions == nil { record.scopeSuspensions = [] }
        record.scopeSuspensions!.append(ConceptScopeSuspension(scopeID: "question-hold-" + revision,
            parkedAt: now, presentation: pending, review: result, undoFamiliar: familiar, parkedQueue: priorQueue))
        if pending != nil { record.presentation = nil }
        if result != nil { record.review = nil }
        if familiar != nil { record.undoFamiliar = nil }
        record.queue = nextQueue
    }

    mutating func start(day: Int, now: Date = Date(), newLimit: Int = 25) throws {
        guard day >= record.day && (18_000...50_000).contains(day), (1...25).contains(newLimit) else {
            throw ExamError.invalid("日期早于上次练习，请核对手机时间。")
        }
        // Capture this before refreshing: an empty new task still includes its
        // requested fresh allowance even when refresh discovers due reviews.
        let beginsTask = record.queue.isEmpty && record.review == nil && record.presentation == nil
        try refreshDue(day: day, now: now)
        guard record.review == nil, record.presentation == nil else { return }
        if beginsTask {
            record.sessionID = UUID()
            let fresh = activeConcepts.filter {
                let p = record.progress[$0.id] ?? ConceptProgress()
                return !p.familiar && p.usedQuestionIDs.isEmpty && hasActiveUnusedQuestion($0.id)
            }
            record.queue += fresh.prefix(newLimit).map(\.id)
        }
        present(now: now)
    }

    /// Explicit source practice uses the same answer reducer and schedule. Never reopens consumed IDs.
    mutating func startQuestion(questionID: String, day: Int, now: Date = Date()) throws {
        guard day >= record.day, (18_000...50_000).contains(day) else {
            throw ExamError.invalid("日期无效，原断点保留。")
        }
        if let shown {
            guard shown.questionID == questionID else {
                throw ExamError.invalid("请先完成当前题或结果页，原断点未替换。")
            }
            return // Same live presentation/result resumes with exact token and selection.
        }
        guard let concept = bank.concepts.first(where: { $0.questions.contains { $0.id == questionID } }),
              let question = concept.questions.first(where: { $0.id == questionID }), bank.isActive(questionID),
              !heldQuestionIDs.contains(questionID) else {
            throw ExamError.invalid("题目不存在或未纳入当前练习范围。")
        }
        let progress = record.progress[concept.id] ?? ConceptProgress()
        guard !progress.familiar, !progress.usedQuestionIDs.contains(questionID) else {
            throw ExamError.invalid("此题已作答或考点已标熟悉，仅可查看历史，不能重复评分。")
        }
        try updateDay(day)
        record.queue.removeAll { $0 == concept.id }
        record.queue.insert(concept.id, at: 0)
        let order = question.type == .judgment || question.preserveOptionOrder == true ? question.options.map(\.id) : question.options.map(\.id).shuffled()
        record.presentation = ConceptPresentation(id: UUID(), conceptID: concept.id, questionID: question.id,
            order: order, selected: [], presentedAt: now)
    }

    /// Reconcile due reviews even if today's date was already stored by an
    /// older app. This never grades, starts fresh work, or replaces a live card.
    mutating func refreshDue(day: Int, now: Date = Date()) throws {
        try updateDay(day)
        let queued = Set(record.queue)
        let reviewing = record.review?.presentation.conceptID
        let due = activeConcepts.filter { concept in
            guard !queued.contains(concept.id), concept.id != reviewing,
                  let p = record.progress[concept.id] else { return false }
            return !p.familiar && !p.usedQuestionIDs.isEmpty && p.dueDay <= day &&
                (p.lastAnsweredDay == nil || p.lastAnsweredDay! < day) &&
                hasActiveUnusedQuestion(concept.id)
        }.sorted {
            let a = record.progress[$0.id]!, b = record.progress[$1.id]!
            return a.dueDay == b.dueDay ? $0.id < $1.id : a.dueDay < b.dueDay
        }
        // Keep the current card and every existing retry/fresh card in place.
        record.queue += due.map(\.id)
    }

    mutating func toggle(_ id: String, token: UUID) {
        guard var p = record.presentation, p.id == token, record.review == nil,
              bank.isActive(p.questionID), !heldQuestionIDs.contains(p.questionID), question?.type == .multiple, p.order.contains(id) else { return }
        var selection = Set(p.selected)
        if !selection.insert(id).inserted { selection.remove(id) }
        p.selected = selection.sorted()
        record.presentation = p
    }

    mutating func answer(_ choice: String? = nil, token: UUID, day: Int, now: Date = Date()) throws {
        guard var p = record.presentation, p.id == token, record.review == nil, let q = question else { return }
        guard bank.isActive(q.id), !heldQuestionIDs.contains(q.id) else {
            throw ExamError.invalid("这道题已移出当前练习范围，原断点和学习记录会保留。")
        }
        try refreshDue(day: day, now: now)
        if q.type != .multiple {
            guard let choice, p.order.contains(choice) else { return }
            p.selected = [choice]
        }
        guard !p.selected.isEmpty else { throw ExamError.invalid("请先选择答案。") }
        let before = record.progress[p.conceptID] ?? ConceptProgress()
        guard !before.familiar, !before.usedQuestionIDs.contains(q.id) else {
            throw ExamError.invalid("这道题已计入记录，不能重复评分。")
        }
        let correct = Set(p.selected) == Set(q.answer)
        var after = before
        after.usedQuestionIDs.append(q.id)
        after.lastAnsweredDay = day
        var retry = false
        record.queue.removeFirst()
        if correct {
            after.correct += 1
            if before.lastAnsweredDay == nil || before.lastAnsweredDay! < day {
                after.level = min(10, before.level + 1)
                if before.lastAnsweredDay != nil { after.delayedCorrect += 1 }
            }
            after.dueDay = day + Self.gaps[max(0, after.level - 1)]
        } else {
            after.wrong += 1
            after.level = 0
            after.delayedCorrect = 0
            after.dueDay = day + 1
            // At most one same-day repair, after three OTHER concepts, using a
            // never-answered variant. A short tail waits until tomorrow.
            let available = conceptQuestions(p.conceptID).contains { !after.usedQuestionIDs.contains($0.id) }
            if (record.retriesToday[p.conceptID] ?? 0) == 0 && record.queue.count >= 3 && available {
                record.queue.insert(p.conceptID, at: 3)
                record.retriesToday[p.conceptID] = 1
                retry = true
            }
        }
        record.progress[p.conceptID] = after
        let attempt = ConceptAttempt(id: UUID(), sequence: record.nextSequence, sessionID: record.sessionID,
            presentation: p, mode: "answer", isCorrect: correct, answeredAt: now, day: day,
            before: before, after: after, retryQueued: retry, undoTarget: nil)
        record.attempts.append(attempt)
        record.nextSequence += 1
        record.review = attempt
        record.presentation = nil
        record.undoFamiliar = nil
    }

    mutating func next(token: UUID, now: Date = Date()) {
        guard let result = record.review, result.presentation.id == token,
              bank.isActive(result.presentation.questionID) else { return }
        record.review = nil
        present(now: now)
    }

    /// A result may remain open overnight. After dismissing it, its concept can
    /// become eligible for a new due variant without rewriting the old answer.
    mutating func nextOnDay(token: UUID, day: Int, now: Date = Date()) throws {
        try refreshDue(day: day, now: now)
        guard let result = record.review, result.presentation.id == token,
              bank.isActive(result.presentation.questionID) else { return }
        record.review = nil
        try refreshDue(day: day, now: now)
        present(now: now)
    }

    mutating func familiar(token: UUID, day: Int, now: Date = Date()) throws {
        guard let p = record.presentation, p.id == token, record.review == nil else { return }
        guard bank.isActive(p.questionID), !heldQuestionIDs.contains(p.questionID) else {
            throw ExamError.invalid("这道题已移出当前练习范围，不能改变原熟悉记录。")
        }
        try refreshDue(day: day, now: now)
        let before = record.progress[p.conceptID] ?? ConceptProgress()
        var after = before
        after.familiar = true
        let a = ConceptAttempt(id: UUID(), sequence: record.nextSequence, sessionID: record.sessionID,
            presentation: p, mode: "familiar", isCorrect: nil, answeredAt: now, day: day,
            before: before, after: after, retryQueued: false, undoTarget: nil)
        record.progress[p.conceptID] = after
        record.queue.removeAll { $0 == p.conceptID }
        record.attempts.append(a)
        record.nextSequence += 1
        record.undoFamiliar = a
        record.presentation = nil
        present(now: now)
    }

    mutating func undo(now: Date = Date()) {
        guard let target = record.undoFamiliar, record.review == nil,
              bank.isActive(target.presentation.questionID), !heldQuestionIDs.contains(target.presentation.questionID) else { return }
        record.progress[target.presentation.conceptID] = target.before
        record.queue.removeAll { $0 == target.presentation.conceptID }
        record.queue.insert(target.presentation.conceptID, at: 0)
        let restored = ConceptPresentation(id: UUID(), conceptID: target.presentation.conceptID,
            questionID: target.presentation.questionID, order: target.presentation.order,
            selected: [], presentedAt: now)
        let a = ConceptAttempt(id: UUID(), sequence: record.nextSequence, sessionID: record.sessionID,
            presentation: restored, mode: "undo", isCorrect: nil, answeredAt: now, day: record.day,
            before: target.after, after: target.before, retryQueued: false, undoTarget: target.id)
        record.attempts.append(a)
        record.nextSequence += 1
        record.presentation = restored
        record.undoFamiliar = nil
    }

    mutating func rotate(hash: String) throws {
        guard ExamContent.isHash(hash), let first = record.attempts.first, let last = record.attempts.last else {
            throw ExamError.invalid("无法封存空的考点日志。")
        }
        record.volumes.append(ConceptVolume(sha256: hash, first: first.sequence,
            last: last.sequence, count: record.attempts.count))
        record.attempts = []
    }

    private mutating func updateDay(_ day: Int) throws {
        guard day >= record.day && (18_000...50_000).contains(day) else {
            throw ExamError.invalid("日期无效，原进度已保留。")
        }
        if day != record.day { record.retriesToday = [:] }
        record.day = day
    }

    private func conceptQuestions(_ id: String) -> [ConceptQuestion] {
        guard let c = bank.concepts.first(where: { $0.id == id }) else { return [] }
        return bank.activeQuestions(in: c).filter { !heldQuestionIDs.contains($0.id) }
    }

    private func hasActiveUnusedQuestion(_ id: String) -> Bool {
        let used = Set(record.progress[id]?.usedQuestionIDs ?? [])
        return conceptQuestions(id).contains { !used.contains($0.id) }
    }

    private mutating func present(now: Date) {
        while let id = record.queue.first {
            let p = record.progress[id] ?? ConceptProgress()
            let unused = conceptQuestions(id).filter { !p.usedQuestionIDs.contains($0.id) }
            if !p.familiar, let q = unused.first {
                let order = q.type == .judgment || q.preserveOptionOrder == true ? q.options.map(\.id) : q.options.map(\.id).shuffled()
                record.presentation = ConceptPresentation(id: UUID(), conceptID: id, questionID: q.id,
                    order: order, selected: [], presentedAt: now)
                return
            }
            record.queue.removeFirst() // exhausted is exposed separately, never "mastered"
        }
        record.presentation = nil
    }
}
