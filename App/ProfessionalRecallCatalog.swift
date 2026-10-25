import Foundation

enum ProfessionalRecallScope: String, Codable, CaseIterable {
    case mainline, related
    var title: String { self == .mainline ? "必学主线" : "拓展选学" }
}

/// A view of existing IDs. Neither course identity nor the legacy decks change.
enum ProfessionalRecallCatalog {
    static func make(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching,
                     scope: ProfessionalRecallScope) throws -> RecallDeck {
        guard let plan = teaching.studyPlan, teaching.hasCompleteProfessionalExtension else {
            throw ExamError.invalid("请先导入带主线计划的最新版课程；原记录保留。")
        }
        let primary = try RecallDeck.make(subject: subject, bank: bank, teaching: teaching)
        try plan.validate(bank: bank, teaching: teaching, deck: primary)
        let main = scope == .mainline
        let ids = Set(main ? plan.mainlineCardIDs : plan.relatedCardIDs)
        var items = primary.cards.filter { ids.contains($0.id) }
        var groupBranches: [String: String] = [:]
        for group in teaching.recallGroups ?? [] {
            guard let partition = plan.supplementSelections.first(where: { $0.groupID == group.id }) else {
                throw ExamError.invalid("补卡缺少主线范围；保留原档案，停止创建队列。")
            }
            let selected = Set(main ? partition.mainlineCardIDs : partition.relatedCardIDs)
            let deck = try RecallDeck.makeSupplement(subject: subject, bank: bank, group: group)
            items += deck.cards.filter { selected.contains($0.id) }
            groupBranches[group.id] = group.branchID
        }
        // Curriculum branches interleave primary and necessary supplemental cards.
        // Priority labels are presentation metadata and never change stored indices.
        let branches = teaching.syllabus?.branches.map(\.id) ?? []
        let topics = teaching.syllabus?.topics ?? []
        func branchRank(_ item: RecallDeck.Item) -> Int {
            let id = groupBranches[item.conceptID] ?? topics.first(where: { $0.conceptIDs.contains(item.conceptID) })?.branchID
            return id.flatMap { branches.firstIndex(of: $0) } ?? branches.count
        }
        items = items.enumerated().sorted {
            let a = branchRank($0.element), b = branchRank($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let deck = RecallDeck(subject: subject, bankID: bank.id, cards: items)
        try deck.validate()
        return deck
    }

    static func usingStoredOrder(_ deck: RecallDeck, cardIDs: [String]) throws -> RecallDeck {
        guard Set(cardIDs) == Set(deck.cards.map(\.id)), Set(cardIDs).count == cardIDs.count else {
            throw ExamError.invalid("主线卡ID范围已变化，旧进度已保留；需要明确的追加迁移，不能重建空进度。")
        }
        let byID = Dictionary(uniqueKeysWithValues: deck.cards.map { ($0.id, $0) })
        return RecallDeck(subject: deck.subject, bankID: deck.bankID, cards: cardIDs.map { byID[$0]! })
    }
}
