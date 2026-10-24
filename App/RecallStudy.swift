import Foundation
import StudyCore

struct RecallCard: Codable, Equatable, Identifiable {
    let id: String
    let prompt: String
    let answer: String
    var detail: String? = nil
}

struct RecallDeck: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        let conceptID: String
        let conceptTitle: String
        let card: RecallCard
        var id: String { card.id }
    }
    let subject: ConceptSubject
    let bankID: String
    let cards: [Item]

    func validate() throws {
        guard bankID == subject.bankID, !cards.isEmpty, cards.count <= 5_000,
              Set(cards.map(\.id)).count == cards.count,
              cards.allSatisfy({ item in
                  !item.conceptID.isEmpty && !item.conceptTitle.isEmpty &&
                  item.card.id.hasPrefix(item.conceptID + ":") && item.card.id.count <= 160 &&
                  !item.card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.card.prompt.count <= 300 &&
                  !item.card.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.card.answer.count <= 500 &&
                  (item.card.detail?.count ?? 0) <= 4_000
              }) else { throw ExamError.invalid("背诵卡内容或标识无效。") }
    }
    var hash: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return StudySHA256.hex(try encoder.encode(self))
        }
    }
    static func make(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching) throws -> Self {
        guard bank.id == subject.bankID else { throw ExamError.invalid("背诵卡科目不匹配。") }
        guard !teaching.hasProfessionalExtension || teaching.primaryRecallDeck != nil else { throw ExamError.invalid("专业课扩展缺失冻结主卡组，拒绝回退新建进度。") }
        if let frozen=teaching.primaryRecallDeck { try teaching.validatePrimarySnapshot(bank:bank); guard frozen.subject == subject else { throw ExamError.invalid("冻结背诵卡科目不匹配。") }; return frozen }
        var items: [Item] = []
        for concept in bank.concepts where !bank.activeQuestions(in: concept).isEmpty {
            guard let lesson = teaching.lessons.first(where: { $0.conceptID == concept.id }),
                  let cards = lesson.recallCards, !cards.isEmpty else {
                throw ExamError.invalid("请先在专业课首页导入本次问答背诵卡课程包，原练习进度会保留。")
            }
            items += cards.map { Item(conceptID: concept.id, conceptTitle: concept.title, card: $0) }
        }
        let result = Self(subject: subject, bankID: bank.id, cards: items)
        try result.validate(); return result
    }
    static func makeSupplement(subject: ConceptSubject, bank: ConceptBank, group: SupplementRecallGroup) throws -> Self {
        guard bank.id == subject.bankID else { throw ExamError.invalid("补充知识卡科目不匹配。") }
        let deck = Self(subject: subject, bankID: bank.id, cards: group.recallCards.map {
            Item(conceptID: group.id, conceptTitle: group.title, card: $0)
        })
        try deck.validate(); return deck
    }
}

struct RecallProgress: Codable, Equatable {
    var level = 0
    var dueDay = 0
    var lastDay: Int? = nil
    var remembered = 0
    var forgotten = 0
}
struct RecallPresentation: Codable, Equatable {
    let id: UUID
    let cardID: String
    var revealed = false
}
struct RecallResult: Codable, Equatable {
    let presentation: RecallPresentation
    let remembered: Bool
    let dueDay: Int
}
struct RecallSelection: Codable, Equatable { let id: String; let cardIDs: [String] }
struct RecallState: Codable, Equatable {
    var day = 0
    var progress: [String: RecallProgress] = [:]
    var queue: [String] = []
    var shown: RecallPresentation? = nil
    var result: RecallResult? = nil
    var retries: [String: Int] = [:]
    var selection: RecallSelection? = nil
    var parkedQueue: [String]? = nil
}
struct RecallEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let sequence: Int
    let kind: String
    let day: Int
    let at: Date
    let token: UUID?
    let newLimit: Int?
    let remembered: Bool?
    var selectionID: String? = nil
    var selectedCardIDs: [String]? = nil
    var expectedDeckSHA256: String? = nil
}
struct RecallRecord: Codable, Equatable {
    var format = "xkl-recall-record-v1"
    let deckSHA256: String
    var state = RecallState()
    var events: [RecallEvent] = []
}

/// Self-assessed recall has its own history. It never awards objective-question
/// correctness, consumes a question variant, or writes the existing course log.
struct RecallEngine {
    let deck: RecallDeck
    private(set) var record: RecallRecord
    static let gaps = ConceptEngine.gaps

    init(deck: RecallDeck, record: RecallRecord? = nil) throws {
        try deck.validate()
        self.deck = deck
        let hash = try deck.hash
        self.record = record ?? RecallRecord(deckSHA256: hash)
        guard self.record.format == "xkl-recall-record-v1", self.record.deckSHA256 == hash else {
            throw ExamError.invalid("背诵档案与卡片版本不匹配。")
        }
        var replay = RecallState(); var ids = Set<UUID>()
        for (index, event) in self.record.events.enumerated() {
            guard event.sequence == index + 1, ids.insert(event.id).inserted else {
                throw ExamError.invalid("背诵日志序号缺失或重复。")
            }
            try Self.reduce(event, deck: deck, state: &replay)
        }
        guard replay == self.record.state else { throw ExamError.invalid("背诵进度与逐次日志不一致，已停止写入。") }
    }

    var item: RecallDeck.Item? {
        let id = record.state.result?.presentation.cardID ?? record.state.shown?.cardID
        return deck.cards.first { $0.id == id }
    }
    func dueCount(day: Int) -> Int {
        record.state.progress.values.filter { $0.dueDay <= day && ($0.lastDay ?? day) < day }.count
    }
    var newCount: Int { deck.cards.count - record.state.progress.count }
    func selectedDueCount(day: Int) -> Int {
        let allowed=Set(record.state.selection?.cardIDs ?? deck.cards.map(\.id))
        return record.state.progress.filter { allowed.contains($0.key) && $0.value.dueDay <= day && ($0.value.lastDay ?? day) < day }.count
    }
    var selectedTotal: Int { record.state.selection?.cardIDs.count ?? deck.cards.count }
    var selectedNewCount: Int {
        (record.state.selection?.cardIDs ?? deck.cards.map(\.id)).filter { record.state.progress[$0] == nil }.count
    }

    mutating func act(_ kind: String, day: Int, token: UUID? = nil,
                      newLimit: Int? = nil, remembered: Bool? = nil, selectionID: String? = nil,
                      selectedCardIDs: [String]? = nil, expectedDeckSHA256: String? = nil, now: Date = Date()) throws {
        let event = RecallEvent(id: UUID(), sequence: record.events.count + 1, kind: kind,
            day: day, at: now, token: token, newLimit: newLimit, remembered: remembered,selectionID:selectionID,selectedCardIDs:selectedCardIDs,expectedDeckSHA256:expectedDeckSHA256)
        var next = record.state
        try Self.reduce(event, deck: deck, state: &next)
        if next == record.state { return }
        record.events.append(event); record.state = next
    }

    private static func reduce(_ event: RecallEvent, deck: RecallDeck, state: inout RecallState) throws {
        guard (18_000...50_000).contains(event.day), event.day >= state.day,
              event.at.timeIntervalSinceReferenceDate.isFinite else {
            throw ExamError.invalid("学习日期异常，请核对手机日期。")
        }
        guard event.kind == "select-plan" || (event.selectionID == nil && event.selectedCardIDs == nil && event.expectedDeckSHA256 == nil) else { throw ExamError.invalid("背诵事件混入选题计划字段。") }
        let day = event.day
        if state.day < day { state.day = day; state.retries = [:] }
        func selected(_ id: String) -> Bool { state.selection?.cardIDs.contains(id) ?? true }
        func reconcileSelection() {
            guard state.selection != nil else { return }
            let shown=state.shown?.cardID, result=state.result?.presentation.cardID
            var seen=Set<String>(), pool:[String]=[]
            for id in state.queue+(state.parkedQueue ?? []) where seen.insert(id).inserted { pool.append(id) }
            let active=pool.filter { $0 == shown || (selected($0) && $0 != result) }
            state.queue=active
            if let shown, let i=state.queue.firstIndex(of:shown), i != 0 { state.queue.remove(at:i); state.queue.insert(shown,at:0) }
            let activeIDs=Set(state.queue); state.parkedQueue=pool.filter { !activeIDs.contains($0) }
        }
        func admitDue() {
            let queued = Set(state.queue+(state.parkedQueue ?? []))
            let reviewing = state.result?.presentation.cardID
            let due = deck.cards.filter { item in
                guard selected(item.id), !queued.contains(item.id), item.id != reviewing,
                      let p = state.progress[item.id], let last = p.lastDay else { return false }
                return p.dueDay <= day && last < day
            }.sorted {
                let a = state.progress[$0.id]!.dueDay, b = state.progress[$1.id]!.dueDay
                return a == b ? $0.id < $1.id : a < b
            }
            state.queue += due.map(\.id)
        }
        func present() {
            if state.shown == nil && state.result == nil, let id = state.queue.first {
                state.shown = RecallPresentation(id: event.id, cardID: id)
            }
        }
        switch event.kind {
        case "select-plan":
            guard event.token == nil, event.newLimit == nil, event.remembered == nil,
                  let id=event.selectionID, !id.isEmpty, id.count <= 160,
                  id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
                  let cards=event.selectedCardIDs, Set(cards).count == cards.count,
                  Set(cards).isSubset(of:Set(deck.cards.map(\.id))), event.expectedDeckSHA256 == (try deck.hash) else { throw ExamError.invalid("选题计划或原卡组摘要不匹配。") }
            state.selection=RecallSelection(id:id,cardIDs:cards); if state.parkedQueue == nil { state.parkedQueue=[] }
            reconcileSelection(); admitDue()
        case "start":
            guard event.token == nil, event.remembered == nil, let limit = event.newLimit,
                  (1...25).contains(limit) else { throw ExamError.invalid("新卡数量无效。") }
            let begins = state.queue.isEmpty && state.shown == nil && state.result == nil
            admitDue()
            if begins { state.queue += deck.cards.filter { selected($0.id) && state.progress[$0.id] == nil && !state.queue.contains($0.id) && !(state.parkedQueue ?? []).contains($0.id) }.prefix(limit).map(\.id) }
            present()
        case "refresh":
            guard event.token == nil, event.newLimit == nil, event.remembered == nil else { throw ExamError.invalid("刷新事件无效。") }
            admitDue()
        case "reveal":
            guard event.newLimit == nil, event.remembered == nil, state.result == nil,
                  var p = state.shown, p.id == event.token, !p.revealed else { throw ExamError.invalid("这张卡片已变化，请重新查看。") }
            admitDue(); p.revealed = true; state.shown = p
        case "grade":
            guard event.newLimit == nil, let remembered = event.remembered, state.result == nil,
                  let p = state.shown, p.id == event.token, p.revealed,
                  state.queue.first == p.cardID else { throw ExamError.invalid("请先回忆并翻开答案，再自评。") }
            admitDue()
            var progress = state.progress[p.cardID] ?? RecallProgress()
            if remembered {
                progress.remembered += 1
                if progress.lastDay == nil || progress.lastDay! < day { progress.level = min(gaps.count, progress.level + 1) }
                progress.dueDay = day + gaps[max(0, progress.level - 1)]
            } else {
                progress.forgotten += 1; progress.level = 0; progress.dueDay = day + 1
            }
            progress.lastDay = day; state.progress[p.cardID] = progress
            state.queue.removeFirst()
            if !remembered && (state.retries[p.cardID] ?? 0) == 0 && state.queue.count >= 3 {
                if selected(p.cardID) { state.queue.insert(p.cardID, at: 3) }
                else if !(state.parkedQueue ?? []).contains(p.cardID) { state.parkedQueue=(state.parkedQueue ?? [])+[p.cardID] }
                state.retries[p.cardID] = 1
            }
            state.result = RecallResult(presentation: p, remembered: remembered, dueDay: progress.dueDay)
            state.shown = nil
        case "next":
            guard event.newLimit == nil, event.remembered == nil,
                  let result = state.result, result.presentation.id == event.token else { throw ExamError.invalid("这次自评已经处理。") }
            state.result = nil; reconcileSelection(); admitDue(); present()
        default: throw ExamError.invalid("未知背诵日志事件。")
        }
    }
}
