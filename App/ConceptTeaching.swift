import Foundation
import StudyCore

enum ConceptSubject: String, Codable, CaseIterable, Identifiable {
    case computer, power
    var id: String { rawValue }
    var title: String { self == .computer ? "计算机基础" : "电力系统基础" }
    var shortTitle: String { self == .computer ? "计算机" : "电力系统" }
    var symbol: String { self == .computer ? "desktopcomputer" : "bolt.circle" }
    var directoryName: String { self == .computer ? "ComputerFoundation" : "PowerSystems" }
    var bankID: String { "other-engineering-\(self == .computer ? "computer" : "power")-2027-v1" }
}

enum ConceptCalendar {
    static func studyDay(_ date: Date) throws -> Int {
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = utc.date(from: local.dateComponents([.year, .month, .day], from: date)) else {
            throw ExamError.invalid("无法解析学习日期。")
        }
        let day = Int(midnight.timeIntervalSince1970 / 86_400)
        guard (18_000...50_000).contains(day) else { throw ExamError.invalid("请检查手机日期。") }
        return day
    }
}

struct ConceptLesson: Codable, Equatable {
    let conceptID: String
    let title: String
    let story: String
    let keyIdea: String
    let workedExample: String
    let commonTrap: String
    var guide: ConceptGuide? = nil
    var recallCards: [RecallCard]? = nil
}

struct SupplementRecallGroup: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let branchID: String
    var topicID: String? = nil
    let recallCards: [RecallCard]
}

struct ConceptTeaching: Codable, Equatable {
    let format: String
    let bankSHA256: String
    let lessons: [ConceptLesson]
    var syllabus: ConceptSyllabusTree? = nil
    var recallGroups: [SupplementRecallGroup]? = nil
    var primaryRecallDeck: RecallDeck? = nil
    var studyPlan: ProfessionalStudyPlan? = nil
    var questionPresentations: [ProfessionalQuestionPresentation]? = nil
    var questionLinks: [ProfessionalQuestionLinks]? = nil
    var cardCorrections: [ProfessionalCardCorrection]? = nil
    var sourceLeaves: [ProfessionalSourceLeaf]? = nil
    var cardPriorities: [ProfessionalCardPriority]? = nil

    var hasProfessionalExtension: Bool { primaryRecallDeck != nil || studyPlan != nil || questionPresentations != nil || questionLinks != nil || cardCorrections != nil || sourceLeaves != nil || cardPriorities != nil }
    var hasCompleteProfessionalExtension: Bool { primaryRecallDeck != nil && studyPlan != nil && questionPresentations != nil && questionLinks != nil && cardCorrections != nil && sourceLeaves != nil }
    func validatePrimaryRecallIdentity(from old: ConceptTeaching, bank: ConceptBank) throws {
        let subject: ConceptSubject = bank.id == ConceptSubject.computer.bankID ? .computer : .power
        let prior=try RecallDeck.make(subject:subject,bank:bank,teaching:old)
        guard let primaryRecallDeck, primaryRecallDeck == prior else { throw ExamError.invalid("冻结主卡组与当前旧课程不一致，停止导入，原进度保留。") }
    }
    func validateAppendOnlyRecall(from old: ConceptTeaching, bank: ConceptBank) throws {
        try validatePrimaryRecallIdentity(from:old,bank:bank)
        for lesson in old.lessons {
            guard lessons.first(where: { $0.conceptID == lesson.conceptID })?.recallCards == lesson.recallCards else { throw ExamError.invalid("旧背诵卡正文或顺序改变，拒绝替换。") }
        }
        let oldIDs=Set(old.lessons.map(\.conceptID))
        guard lessons.filter({ !oldIDs.contains($0.conceptID) }).allSatisfy({ $0.recallCards == nil }) else { throw ExamError.invalid("新增背诵卡必须放入独立补充组，不能加入新主课卡组。") }
        let prior=old.recallGroups ?? [], next=recallGroups ?? []
        guard next.count >= prior.count, Array(next.prefix(prior.count)) == prior else { throw ExamError.invalid("旧补充卡组内容或顺序改变，拒绝替换。") }
    }
    func validatePrimarySnapshot(bank: ConceptBank) throws {
        guard let primaryRecallDeck else { return }
        try primaryRecallDeck.validate()
        guard primaryRecallDeck.bankID == bank.id else { throw ExamError.invalid("冻结主卡组科目不匹配。") }
        var ordered: [RecallDeck.Item]=[]
        for concept in bank.concepts {
            guard let lesson=lessons.first(where: { $0.conceptID == concept.id }) else { throw ExamError.invalid("冻结主卡组缺少旧课。") }
            ordered += (lesson.recallCards ?? []).map { RecallDeck.Item(conceptID:concept.id,conceptTitle:concept.title,card:$0) }
        }
        for id in Set(primaryRecallDeck.cards.map(\.conceptID)) {
            guard primaryRecallDeck.cards.filter({ $0.conceptID == id }) == ordered.filter({ $0.conceptID == id }) else { throw ExamError.invalid("冻结主卡组不能截断同一旧考点的卡片。") }
        }
        var index=0
        for item in primaryRecallDeck.cards {
            guard let position=ordered[index...].firstIndex(of:item) else { throw ExamError.invalid("冻结主卡组卡片、归属、正文或顺序不匹配。") }
            index=position+1
        }
    }


    func validate(bank: ConceptBank, hash: String) throws {
        guard format == "xkl-teaching-v1", bankSHA256 == hash,
              Set(lessons.map(\.conceptID)) == Set(bank.concepts.map(\.id)),
              lessons.count == bank.concepts.count,
              lessons.allSatisfy({ lesson in
                  [lesson.title, lesson.story, lesson.keyIdea, lesson.workedExample, lesson.commonTrap]
                      .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 8_000 }
              }) else {
            throw ExamError.invalid("教学内容与考点题库不匹配，原进度未替换。")
        }
        for lesson in lessons {
            if let guide = lesson.guide { try guide.validate(conceptID: lesson.conceptID, bank: bank) }
            if let cards = lesson.recallCards {
                guard (1...30).contains(cards.count), Set(cards.map(\.id)).count == cards.count else {
                    throw ExamError.invalid("问答背诵卡数量或标识无效。")
                }
                let subject: ConceptSubject = bank.id == ConceptSubject.computer.bankID ? .computer : .power
                try RecallDeck(subject: subject, bankID: bank.id,
                    cards: cards.map { .init(conceptID: lesson.conceptID, conceptTitle: lesson.title, card: $0) }).validate()
            }
        }
        if let syllabus { try syllabus.validate(bank: bank) }
        if let groups = recallGroups {
            guard !groups.isEmpty, groups.count <= 400, let syllabus,
                  Set(groups.map(\.id)).count == groups.count,
                  groups.reduce(0, { $0 + $1.recallCards.count }) <= 5_000 else {
                throw ExamError.invalid("补充知识卡分组或考纲关联无效。")
            }
            let reserved = Set(bank.concepts.map(\.id))
            for group in groups {
                guard !group.id.isEmpty, group.id.count <= 120,
                      group.id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
                      !reserved.contains(group.id),
                      !group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, group.title.count <= 160,
                      syllabus.branches.contains(where: { $0.id == group.branchID }),
                      group.topicID.map({ topicID in syllabus.topics.contains(where: { $0.id == topicID && $0.branchID == group.branchID }) }) ?? true,
                      (1...30).contains(group.recallCards.count) else {
                    throw ExamError.invalid("补充知识卡主题、数量或考纲关联无效。")
                }
                let subject: ConceptSubject = bank.id == ConceptSubject.computer.bankID ? .computer : .power
                try RecallDeck.makeSupplement(subject: subject, bank: bank, group: group).validate()
            }
        }
        if hasProfessionalExtension {
            guard let primaryRecallDeck, let studyPlan, let questionPresentations, let questionLinks, let cardCorrections, let sourceLeaves else { throw ExamError.invalid("专业课v5扩展字段不完整。") }
            try validatePrimarySnapshot(bank:bank)
            let supplementIDs=(recallGroups ?? []).flatMap { $0.recallCards.map(\.id) }
            guard Set(supplementIDs).count == supplementIDs.count, Set(primaryRecallDeck.cards.map(\.id)).isDisjoint(with:Set(supplementIDs)) else { throw ExamError.invalid("主卡组与补充卡身份冲突。") }
            try studyPlan.validate(bank:bank,teaching:self,deck:primaryRecallDeck)
            try ProfessionalQuestionPresentation.validateAll(questionPresentations,bank:bank)
            let activeIDs=Set(bank.concepts.flatMap { bank.activeQuestions(in:$0).map(\.id) })
            guard activeIDs.isSubset(of:Set(questionPresentations.map(\.questionID))) else { throw ExamError.invalid("专业课v5可练题缺少已验证题级呈现，拒绝导入。") }
            try ProfessionalQuestionLinks.validateAll(questionLinks,bank:bank,teaching:self)
            try ProfessionalCardCorrection.validateAll(cardCorrections,deck:primaryRecallDeck,groups:recallGroups ?? [])
            try ProfessionalSourceLeaf.validateAll(sourceLeaves,bank:bank,teaching:self)
            if let cardPriorities { try ProfessionalCardPriority.validateAll(cardPriorities,bank:bank,teaching:self) }
        }
    }
}

struct ConceptCourse: Codable {
    let format: String
    let subject: ConceptSubject
    let bankContent: Data
    let teaching: ConceptTeaching

    static func load(_ data: Data, subject: ConceptSubject) throws -> (ConceptCourse, ConceptBank) {
        guard data.count <= 50 * 1_024 * 1_024 else { throw ExamError.invalid("课程包过大。") }
        let course = try JSONDecoder().decode(Self.self, from: data)
        guard ["xkl-course-v1", "xkl-course-v2", "xkl-course-v3", "xkl-course-v4", "xkl-course-v5"].contains(course.format), course.subject == subject else {
            throw ExamError.invalid("请在对应科目中导入课程包。")
        }
        guard (course.format == "xkl-course-v5") == course.teaching.hasProfessionalExtension else { throw ExamError.invalid("专业课扩展必须显式使用完整v5课程格式。") }
        let (pack, bank) = try ConceptContent.load(course.bankContent)
        guard bank.id == subject.bankID else { throw ExamError.invalid("课程科目标识不一致。") }
        try course.teaching.validate(bank: bank, hash: pack.bankSHA256)
        return (course, bank)
    }
}

enum ConceptMistakeReason: String, Codable, CaseIterable, Identifiable {
    case concept, method, calculation, conditions, guessed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .concept: return "概念混淆"
        case .method: return "不会列式／推理"
        case .calculation: return "计算／操作失误"
        case .conditions: return "看漏条件"
        case .guessed: return "蒙的／没把握"
        }
    }
}

/// Supplementary observations never change objective answers or old scheduling records.
struct ConceptCoachingEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let sequence: Int
    let kind: String
    let conceptID: String
    let questionID: String
    let presentationID: UUID
    let attemptID: UUID?
    let reason: ConceptMistakeReason?
    let automatic: Bool?
    let beforeAnswer: Bool
    let teachingSHA256: String?
    let recordedAt: Date
    var linkedPrimaryCardIDs: [String]? = nil
    var linkedSupplementCardIDs: [String]? = nil
    var linkedGuideConceptIDs: [String]? = nil
}

struct ConceptCoachingRecord: Codable, Equatable {
    var format = "xkl-concept-coaching-v1"
    var bankSHA256: String
    var nextSequence = 1
    var events: [ConceptCoachingEvent] = []
    var volumes: [ConceptVolume] = []

    mutating func rotate(hash: String) throws {
        guard ExamContent.isHash(hash), let first = events.first, let last = events.last else {
            throw ExamError.invalid("无法封存空的教学记录。")
        }
        volumes.append(ConceptVolume(sha256: hash, first: first.sequence,
                                     last: last.sequence, count: events.count))
        events = []
    }

    func validate(bank: ConceptBank, hash: String) throws {
        guard format == "xkl-concept-coaching-v1", bankSHA256 == hash, ExamContent.isHash(hash) else {
            throw ExamError.invalid("教学记录身份无效。")
        }
        var expected = 1
        for volume in volumes {
            guard ExamContent.isHash(volume.sha256), volume.first == expected,
                  volume.count > 0, volume.last == volume.first + volume.count - 1 else {
                throw ExamError.invalid("教学分卷顺序不一致。")
            }
            expected = volume.last + 1
        }
        let concepts = Dictionary(uniqueKeysWithValues: bank.concepts.map { ($0.id, Set($0.questions.map(\.id))) })
        var ids = Set<UUID>()
        for event in events {
            guard event.sequence == expected, ids.insert(event.id).inserted,
                  concepts[event.conceptID]?.contains(event.questionID) == true,
                  event.recordedAt.timeIntervalSince1970.isFinite,
                  event.teachingSHA256.map(ExamContent.isHash) ?? true else {
                throw ExamError.invalid("教学记录的考点、时间或序号无效。")
            }
            if event.kind != "linked-card-help" {
                guard event.linkedPrimaryCardIDs == nil, event.linkedSupplementCardIDs == nil, event.linkedGuideConceptIDs == nil else { throw ExamError.invalid("旧教学事件不能混入知识卡查询字段。") }
            }
            if event.kind == "story" {
                guard event.reason == nil, event.automatic != nil,
                      event.teachingSHA256 != nil,
                      event.automatic != true || event.beforeAnswer else {
                    throw ExamError.invalid("故事阅读记录无效。")
                }
            } else if event.kind == "reason" {
                guard event.attemptID != nil, event.automatic == nil, !event.beforeAnswer else {
                    throw ExamError.invalid("错因标记记录无效。")
                }
            } else if event.kind == "linked-card-help" {
                guard event.beforeAnswer, event.attemptID == nil, event.reason == nil, event.automatic == nil, event.teachingSHA256 != nil,
                      let primary=event.linkedPrimaryCardIDs, let supplement=event.linkedSupplementCardIDs, let guides=event.linkedGuideConceptIDs,
                      !(primary+supplement+guides).isEmpty,
                      [primary,supplement,guides].allSatisfy({ ids in ids.count <= 12 && Set(ids).count == ids.count && ids.allSatisfy({ !$0.isEmpty && $0.count <= 160 }) }),
                      Set(primary).isDisjoint(with:Set(supplement)), Set(guides).isSubset(of:Set(concepts.keys)) else { throw ExamError.invalid("答前知识卡查询的关联或时间边界无效。") }
            } else { throw ExamError.invalid("未知的教学记录类型。") }
            expected += 1
        }
        guard expected == nextSequence else { throw ExamError.invalid("教学记录末尾不一致。") }
    }

    static func shouldAutoShow(conceptID: String, progress: ConceptProgress?,
                               events: [ConceptCoachingEvent]) -> Bool {
        // Existing studied/familiar concepts never acquire a fabricated first-lesson event.
        guard progress?.usedQuestionIDs.isEmpty ?? true, progress?.familiar != true else { return false }
        return !events.contains { $0.kind == "story" && $0.conceptID == conceptID }
    }

    static func selectedReason(attemptID: UUID, events: [ConceptCoachingEvent]) -> ConceptMistakeReason? {
        events.last { $0.kind == "reason" && $0.attemptID == attemptID }?.reason
    }
}
