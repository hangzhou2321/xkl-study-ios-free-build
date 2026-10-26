import Foundation
import StudyCore

/// Supplied original question and answer. No lesson-card self assessment is a grade.
struct ProfessionalObjectiveQuestion: Codable, Equatable, Identifiable {
    let id: String
    let type: ExamQuestionType
    let book: String
    let chapter: String
    let prompt: String
    let options: [ExamOption]
    let answer: [String]
    let sourceLocation: String
    let sourceDocumentID: String
    let pdfPage: Int
    let sourceAnswer: String
    var explanation: String? = nil
    var preserveOptionOrder: Bool? = nil
    var sourceAsset: ProfessionalSourceFileAsset? = nil
    var sourceAssets: [ProfessionalSourceFileAsset]? = nil
    var fingerprintKey: String? = nil
    var isActive: Bool? = nil
    var scopeNote: String? = nil

    var active: Bool { isActive != false }
    var assets: [ProfessionalSourceFileAsset] { (sourceAsset.map { [$0] } ?? []) + (sourceAssets ?? []) }
    var canShuffleOptions: Bool {
        guard preserveOptionOrder != true, type != .judgment else { return false }
        let text = prompt + "\n" + options.map(\.text).joined(separator: "\n")
        // Preserve letter/order-dependent originals; shuffling "all of the above"
        // or a reference to option A would silently change the supplied question.
        return text.range(of: "以上|上述|选项\\s*[A-Ha-h]|[A-Ha-h]\\s*项|[A-Ha-h]\\s*[、和与或及]\\s*[A-Ha-h]", options: .regularExpression) == nil
    }
    func accepts(_ values: [String]) -> Bool {
        !values.isEmpty && Set(values).count == values.count &&
        Set(values).isSubset(of: Set(options.map(\.id))) && (type == .multiple || values.count == 1)
    }
    func correct(_ values: [String]) -> Bool { accepts(values) && Set(values) == Set(answer) }
    var definitionID: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // This type contains only finite validated metadata and strings.
        return StudySHA256.hex((try? encoder.encode(self)) ?? Data())
    }
    var fingerprint: String {
        if let fingerprintKey, !fingerprintKey.isEmpty { return fingerprintKey }
        func normalized(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let texts = options.map { normalized($0.text) }.sorted()
        let answers = options.filter { answer.contains($0.id) }.map { normalized($0.text) }.sorted()
        let values = [normalized(prompt)] + texts + ["ANSWER"] + answers
        return StudySHA256.hex(Data(values.map { String($0.utf8.count) + ":" + $0 }.joined().utf8))
    }
    func validate(sourceIDs: Set<String>) throws {
        func good(_ value: String, _ limit: Int) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit }
        let ids = Set(options.map(\.id))
        guard good(id, 200), ["basic", "reinforcement"].contains(book), good(chapter, 600),
              good(prompt, 30_000), options.count <= 20, !active || options.count >= 2, ids.count == options.count,
              options.allSatisfy({ good($0.id, 40) && good($0.text, 20_000) }),
              Set(answer).count == answer.count, answer.allSatisfy({ good($0, 40) }), !active || Set(answer).isSubset(of: ids),
              !active || (accepts(answer) && good(sourceAnswer, 10_000)),
              !active || answer.isEmpty || type == .multiple || answer.count == 1,
              !active || type != .judgment || options.count == 2,
              good(sourceLocation, 2_000), sourceIDs.contains(sourceDocumentID), pdfPage > 0,
              (explanation?.count ?? 0) <= 30_000, (scopeNote?.count ?? 0) <= 5_000,
              fingerprintKey == nil || good(fingerprintKey!, 300), assets.count <= 8 else {
            throw ExamError.invalid("原题的题干、选项、给定答案、范围或来源不完整：\(id)")
        }
        // Full pixels are verified by the rendering UI. Import is metadata-only,
        // so platforms lacking Apple ImageIO can validate the actual payload.
        for asset in assets { try asset.validateMetadata() }
    }
}

struct ProfessionalQuestionPackage: Codable, Equatable {
    var format = "xkl-professional-questions-v1"
    let id: String
    let subject: ConceptSubject
    let title: String
    let revision: String
    let sources: [ConceptSource]
    let questions: [ProfessionalObjectiveQuestion]

    var hash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return StudySHA256.hex((try? encoder.encode(self)) ?? Data())
    }
    static func load(_ data: Data) throws -> Self {
        guard data.count <= 40 * 1_024 * 1_024 else { throw ExamError.invalid("专业原题包超过40MB。") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    func validate() throws {
        guard format == "xkl-professional-questions-v1", !id.isEmpty, id.count <= 200,
              !title.isEmpty, title.count <= 600, !revision.isEmpty, revision.count <= 100,
              (1...10_000).contains(questions.count), Set(questions.map(\.id)).count == questions.count,
              !sources.isEmpty, Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.reference.isEmpty }) else {
            throw ExamError.invalid("专业原题包身份或来源无效。")
        }
        let ids = Set(sources.map(\.id)); for question in questions { try question.validate(sourceIDs: ids) }
    }
}

struct ProfessionalQuestionProgress: Codable, Equatable {
    var correctCount = 0
    var wrongCount = 0
    var independentCorrectCount = 0
    var correctStreak = 0
    var lastDay: Int? = nil
    var dueDay: Int? = nil
}

struct ProfessionalQuestionSessionPresentation: Codable, Equatable {
    let id: UUID
    let questionID: String
    let definitionID: String
    let optionOrder: [String]
    var selectedOptions: [String] = []
    var helped = false
    var resultAttemptID: UUID? = nil
}

struct ProfessionalQuestionAttempt: Codable, Equatable, Identifiable {
    let id: UUID
    let presentationID: UUID
    let questionID: String
    let definitionID: String
    let selectedOptions: [String]
    let correctOptions: [String]
    let optionOrder: [String]
    let isCorrect: Bool
    let helped: Bool
    /// Unassisted attempt. Correctness is a separate property, not mastery.
    let independent: Bool
    let day: Int
    let at: Date
    let dueDay: Int
    let beforeProgress: ProfessionalQuestionProgress
    let afterProgress: ProfessionalQuestionProgress
}

struct ProfessionalQuestionContentVersion: Codable, Equatable {
    let packageSHA256: String
    let revision: String
    let questionIDs: [String]
    let activeDefinitions: [String: String]
}

struct ProfessionalQuestionRecord: Codable, Equatable {
    var format = "xkl-professional-question-record-v1"
    let packageID: String
    let subject: ConceptSubject
    var definitions: [String: ProfessionalObjectiveQuestion]
    var activeDefinitions: [String: String]
    var questionOrder: [String]
    var contentVersions: [ProfessionalQuestionContentVersion]
    var progress: [String: ProfessionalQuestionProgress] = [:]
    /// Shared scheduling only; never awards an unattempted source question a grade.
    var fingerprintDueDays: [String: Int] = [:]
    var attempts: [ProfessionalQuestionAttempt] = []
    var presentation: ProfessionalQuestionSessionPresentation? = nil
    var bookmarks: [String: ProfessionalQuestionSessionPresentation] = [:]
    var lastObservedDay: Int? = nil
    var deferredDay: Int? = nil
    var deferredQuestionIDs: [String] = []
}

struct ProfessionalQuestionStats: Equatable {
    let total, answered, correct, wrong, due, unseen, independentCorrect, archived: Int
    let nextDueDay: Int?
}

/// Dedicated long-interval professional policy. It never changes or claims to
/// reproduce the English PocketEngine interval/graduation rules.
struct ProfessionalQuestionEngine {
    static let correctGaps = [3, 7, 14, 30, 60, 90, 180]
    private(set) var package: ProfessionalQuestionPackage
    private(set) var record: ProfessionalQuestionRecord
    var presentation: ProfessionalQuestionSessionPresentation? { record.presentation }
    var currentQuestion: ProfessionalObjectiveQuestion? {
        guard let p = presentation else { return nil }; return record.definitions[p.definitionID]
    }
    var result: ProfessionalQuestionAttempt? {
        guard let id = presentation?.resultAttemptID else { return nil }; return record.attempts.first { $0.id == id }
    }
    var nextDueDay: Int? { nextDue(on: record.lastObservedDay ?? ((try? ConceptCalendar.studyDay(Date())) ?? 0)) }

    init(package: ProfessionalQuestionPackage, record: ProfessionalQuestionRecord? = nil) throws {
        try package.validate(); self.package = package
        if let record { self.record = record; try validateRecord() }
        else {
            let definitions = Dictionary(uniqueKeysWithValues: package.questions.map { ($0.definitionID, $0) })
            let active = Dictionary(uniqueKeysWithValues: package.questions.map { ($0.id, $0.definitionID) })
            self.record = .init(packageID: package.id, subject: package.subject, definitions: definitions,
                activeDefinitions: active, questionOrder: package.questions.map(\.id),
                contentVersions: [.init(packageSHA256: package.hash, revision: package.revision,
                    questionIDs: package.questions.map(\.id), activeDefinitions: active)])
        }
    }
    static func fresh(_ package: ProfessionalQuestionPackage) throws -> Self { try .init(package: package) }

    mutating func updatePackage(_ next: ProfessionalQuestionPackage) throws {
        try next.validate()
        guard next.id == package.id, next.subject == package.subject else { throw ExamError.invalid("专业原题包科目或ID不同，原记录保留。") }
        if next == package { return }
        guard !record.contentVersions.contains(where: { $0.packageSHA256 == next.hash }),
              next.revision.compare(package.revision, options: .numeric) == .orderedDescending,
              Set(record.activeDefinitions.keys).isSubset(of: Set(next.questions.map(\.id))) else {
            throw ExamError.invalid("不能用旧版或删题包覆盖当前专业原题记录。")
        }
        var nextRecord = record
        for q in next.questions { nextRecord.definitions[q.definitionID] = q }
        let active = Dictionary(uniqueKeysWithValues: next.questions.map { ($0.id, $0.definitionID) })
        nextRecord.activeDefinitions = active; nextRecord.questionOrder = next.questions.map(\.id)
        nextRecord.contentVersions.append(.init(packageSHA256: next.hash, revision: next.revision,
            questionIDs: next.questions.map(\.id), activeDefinitions: active))
        // Current presentation, drafts and past answers retain their original definition.
        let candidate = try Self(package: next, record: nextRecord)
        self = candidate
    }

    mutating func start(now: Date = Date()) throws {
        let day = try checkedDay(now)
        record.lastObservedDay = day
        if record.presentation != nil { return }
        if record.deferredDay != day { record.deferredDay = day; record.deferredQuestionIDs = [] }
        choose(day: day, allowDeferred: true)
    }
    mutating func saveDraft(_ selected: [String], token: UUID) throws {
        guard var p = presentation, p.id == token, p.resultAttemptID == nil, let q = currentQuestion,
              Set(selected).count == selected.count, Set(selected).isSubset(of: Set(q.options.map(\.id))),
              q.type == .multiple || selected.count <= 1 else { throw ExamError.invalid("原题作答草稿与当前题不一致。") }
        p.selectedOptions = selected.sorted(); record.presentation = p
    }
    mutating func markHelped(token: UUID) throws {
        guard var p = presentation, p.id == token, p.resultAttemptID == nil else { throw ExamError.invalid("当前原题已提交或已切换。") }
        p.helped = true; record.presentation = p
    }
    mutating func submit(token: UUID, now: Date = Date()) throws {
        // Retry after an uncertain persistence response is exactly idempotent.
        if record.attempts.contains(where: { $0.presentationID == token }) { return }
        let day = try checkedDay(now)
        guard var p = presentation, p.id == token, p.resultAttemptID == nil, let q = currentQuestion,
              q.accepts(p.selectedOptions), !record.attempts.contains(where: { $0.questionID == q.id && $0.day == day }),
              !record.attempts.contains(where: { $0.day == day && record.definitions[$0.definitionID]?.fingerprint == q.fingerprint }) else {
            throw ExamError.invalid("请先完成当前原题选择；同题今天已记过一次作答。")
        }
        let before = record.progress[q.id] ?? .init(); var after = before
        let correct = q.correct(p.selectedOptions)
        if correct {
            after.correctCount += 1
            if !p.helped { after.correctStreak += 1; after.independentCorrectCount += 1 }
        } else { after.wrongCount += 1; after.correctStreak = 0 }
        let gap = correct ? (p.helped ? 3 : Self.correctGaps[min(max(after.correctStreak - 1, 0), Self.correctGaps.count - 1)]) : 1
        let due = max(day + gap, before.dueDay ?? 0, record.fingerprintDueDays[q.fingerprint] ?? 0)
        after.lastDay = day; after.dueDay = due
        let attempt = ProfessionalQuestionAttempt(id: UUID(), presentationID: p.id, questionID: q.id,
            definitionID: p.definitionID, selectedOptions: p.selectedOptions, correctOptions: q.answer,
            optionOrder: p.optionOrder, isCorrect: correct, helped: p.helped, independent: !p.helped,
            day: day, at: now, dueDay: due, beforeProgress: before, afterProgress: after)
        record.progress[q.id] = after; record.fingerprintDueDays[q.fingerprint] = due
        record.attempts.append(attempt); record.lastObservedDay = day
        p.resultAttemptID = attempt.id; record.presentation = p
    }
    mutating func next(token: UUID, now: Date = Date()) throws {
        let day = try checkedDay(now)
        guard let p = presentation, p.id == token, p.resultAttemptID != nil else { throw ExamError.invalid("请先提交当前原题。") }
        record.presentation = nil; record.lastObservedDay = day
        if record.deferredDay != day { record.deferredDay = day; record.deferredQuestionIDs = [] }
        choose(day: day, allowDeferred: true)
    }
    mutating func deferCurrent(token: UUID, now: Date = Date()) throws {
        let day = try checkedDay(now)
        guard let p = presentation, p.id == token, p.resultAttemptID == nil else { throw ExamError.invalid("本题已提交或已切换，不能暂缓。") }
        if record.deferredDay != day { record.deferredDay = day; record.deferredQuestionIDs = [] }
        record.bookmarks[p.questionID] = p
        let family = currentQuestion?.fingerprint
        for q in package.questions where q.id == p.questionID || (family != nil && q.fingerprint == family) {
            if !record.deferredQuestionIDs.contains(q.id) { record.deferredQuestionIDs.append(q.id) }
        }
        record.presentation = nil; record.lastObservedDay = day
        // When nothing else is available, do not immediately redisplay the same stem.
        choose(day: day, allowDeferred: false)
    }

    func stats(on date: Date = Date()) -> ProfessionalQuestionStats {
        let day = (try? ConceptCalendar.studyDay(date)) ?? record.lastObservedDay ?? 0
        let active = package.questions.filter(\.active), ids = Set(active.map(\.id))
        let attempts = record.attempts.filter { ids.contains($0.questionID) }
        return .init(total: active.count, answered: active.filter { record.progress[$0.id]?.lastDay != nil }.count,
            correct: attempts.filter(\.isCorrect).count, wrong: attempts.filter { !$0.isCorrect }.count,
            due: active.filter { record.progress[$0.id]?.lastDay != nil && eligible($0, day: day) }.count,
            unseen: active.filter { record.progress[$0.id]?.lastDay == nil }.count,
            independentCorrect: attempts.filter { $0.isCorrect && $0.independent }.count,
            archived: package.questions.count - active.count, nextDueDay: nextDue(on: day))
    }

    private func checkedDay(_ date: Date) throws -> Int {
        guard date.timeIntervalSince1970.isFinite else { throw ExamError.invalid("学习日期无效。") }
        let day = try ConceptCalendar.studyDay(date)
        guard day >= (record.lastObservedDay ?? day) else { throw ExamError.invalid("手机日期早于上次作答日期，原进度已保留。") }
        return day
    }
    private func eligible(_ q: ProfessionalObjectiveQuestion, day: Int) -> Bool {
        q.active && max(record.progress[q.id]?.dueDay ?? day, record.fingerprintDueDays[q.fingerprint] ?? day) <= day &&
        !record.attempts.contains { $0.day == day && (record.definitions[$0.definitionID]?.fingerprint == q.fingerprint || $0.questionID == q.id) }
    }
    private func nextDue(on day: Int) -> Int? {
        package.questions.filter(\.active).map {
            max(record.progress[$0.id]?.dueDay ?? day, record.fingerprintDueDays[$0.fingerprint] ?? day)
        }.min()
    }
    private mutating func choose(day: Int, allowDeferred: Bool) {
        let all = package.questions.filter { eligible($0, day: day) }
        let deferred = Set(record.deferredQuestionIDs)
        let immediate = all.filter { !deferred.contains($0.id) }
        let candidates = immediate.isEmpty && allowDeferred ? all : immediate
        // Due reviews precede unseen questions; within either bucket basic then reinforcement.
        let sorted = candidates.enumerated().sorted { a, b in
            let ap = record.progress[a.element.id]?.lastDay != nil, bp = record.progress[b.element.id]?.lastDay != nil
            if ap != bp { return ap }
            if a.element.book != b.element.book { return a.element.book == "basic" }
            return a.offset < b.offset
        }
        guard let question = sorted.first?.element else { return }
        if let saved = record.bookmarks.removeValue(forKey: question.id) {
            record.deferredQuestionIDs.removeAll { $0 == question.id }
            record.presentation = saved
            return
        }
        var order = question.options.map(\.id)
        if question.canShuffleOptions {
            order.shuffle()
            // Do not accidentally repeat the immediately previous permutation.
            if let old = record.attempts.last(where: { $0.questionID == question.id }), old.optionOrder == order, order.count > 1 {
                order.append(order.removeFirst())
            }
        }
        record.deferredQuestionIDs.removeAll { $0 == question.id }
        record.presentation = .init(id: UUID(), questionID: question.id, definitionID: question.definitionID, optionOrder: order)
    }

    private func validateRecord() throws {
        guard record.format == "xkl-professional-question-record-v1", record.packageID == package.id,
              record.subject == package.subject, record.questionOrder == package.questions.map(\.id),
              record.activeDefinitions == Dictionary(uniqueKeysWithValues: package.questions.map { ($0.id, $0.definitionID) }),
              record.contentVersions.last?.packageSHA256 == package.hash,
              !record.contentVersions.isEmpty,
              record.lastObservedDay == nil || (18_000...50_000).contains(record.lastObservedDay!),
              record.deferredDay == nil || (18_000...50_000).contains(record.deferredDay!),
              Set(record.contentVersions.map(\.packageSHA256)).count == record.contentVersions.count,
              Set(record.deferredQuestionIDs).count == record.deferredQuestionIDs.count,
              Set(record.deferredQuestionIDs).isSubset(of: Set(record.questionOrder)) else {
            throw ExamError.invalid("专业原题记录身份或题库版本不一致；停止初始化。")
        }
        for (id, definition) in record.definitions {
            guard id == definition.definitionID else { throw ExamError.invalid("历史原题定义摘要损坏。") }
        }
        for version in record.contentVersions {
            guard ExamContent.isHash(version.packageSHA256), !version.revision.isEmpty,
                  Set(version.questionIDs).count == version.questionIDs.count,
                  Set(version.activeDefinitions.keys) == Set(version.questionIDs),
                  version.activeDefinitions.allSatisfy({ record.definitions[$0.value]?.id == $0.key }) else { throw ExamError.invalid("专业题库历史定义链缺失。") }
        }
        var progress: [String: ProfessionalQuestionProgress] = [:], fingerprints: [String: Int] = [:]
        var days = Set<String>(), groups = Set<String>(), presentations = Set<UUID>(), attemptIDs = Set<UUID>()
        var last = 0
        for attempt in record.attempts {
            guard let q = record.definitions[attempt.definitionID], q.id == attempt.questionID,
                  q.accepts(attempt.selectedOptions), attempt.correctOptions == q.answer,
                  Set(attempt.optionOrder) == Set(q.options.map(\.id)), attempt.optionOrder.count == q.options.count,
                  attempt.isCorrect == q.correct(attempt.selectedOptions), attempt.independent == !attempt.helped,
                  attempt.at.timeIntervalSince1970.isFinite, try ConceptCalendar.studyDay(attempt.at) == attempt.day,
                  attempt.day >= last, presentations.insert(attempt.presentationID).inserted,
                  attemptIDs.insert(attempt.id).inserted,
                  days.insert(q.id + ":" + String(attempt.day)).inserted,
                  groups.insert(q.fingerprint + ":" + String(attempt.day)).inserted,
                  attempt.beforeProgress == (progress[q.id] ?? .init()) else { throw ExamError.invalid("专业原题逐次记录不连续或重复。") }
            let before = progress[q.id] ?? .init(); var after = before
            if attempt.isCorrect {
                after.correctCount += 1
                if !attempt.helped { after.correctStreak += 1; after.independentCorrectCount += 1 }
            } else { after.wrongCount += 1; after.correctStreak = 0 }
            let gap = attempt.isCorrect ? (attempt.helped ? 3 : Self.correctGaps[min(max(after.correctStreak - 1, 0), Self.correctGaps.count - 1)]) : 1
            let due = max(attempt.day + gap, before.dueDay ?? 0, fingerprints[q.fingerprint] ?? 0)
            after.lastDay = attempt.day; after.dueDay = due
            guard after == attempt.afterProgress, due == attempt.dueDay else { throw ExamError.invalid("专业原题间隔与原始作答不匹配。") }
            progress[q.id] = after; fingerprints[q.fingerprint] = due; last = attempt.day
        }
        guard progress == record.progress, fingerprints == record.fingerprintDueDays,
              record.lastObservedDay == nil || record.lastObservedDay! >= last else { throw ExamError.invalid("专业原题进度与逐次日志不一致。") }
        guard Set(record.bookmarks.keys).isSubset(of: Set(record.questionOrder)),
              Set(record.bookmarks.values.map(\.id)).count == record.bookmarks.count else { throw ExamError.invalid("专业原题暂缓草稿身份缺失或重复。") }
        for (key, p) in record.bookmarks {
            guard key == p.questionID, p.resultAttemptID == nil,
                  p.id != record.presentation?.id else { throw ExamError.invalid("专业原题暂缓草稿重复。") }
            try validatePresentation(p)
        }
        if let p = presentation { try validatePresentation(p) }
    }
    private func validatePresentation(_ p: ProfessionalQuestionSessionPresentation) throws {
            guard let q = record.definitions[p.definitionID], q.id == p.questionID,
                  record.activeDefinitions[q.id] != nil, Set(p.optionOrder) == Set(q.options.map(\.id)),
                  p.optionOrder.count == q.options.count, Set(p.selectedOptions).count == p.selectedOptions.count,
                  Set(p.selectedOptions).isSubset(of: Set(q.options.map(\.id))), q.type == .multiple || p.selectedOptions.count <= 1 else { throw ExamError.invalid("专业原题中断草稿损坏。") }
            if let id = p.resultAttemptID {
                guard let attempt = record.attempts.first(where: { $0.id == id }), attempt.presentationID == p.id,
                      attempt.definitionID == p.definitionID, attempt.selectedOptions == p.selectedOptions,
                      attempt.optionOrder == p.optionOrder, attempt.helped == p.helped else { throw ExamError.invalid("专业原题反馈断点不一致。") }
            } else if record.attempts.contains(where: { $0.presentationID == p.id }) { throw ExamError.invalid("专业原题提交断点缺少反馈。") }
    }
}
