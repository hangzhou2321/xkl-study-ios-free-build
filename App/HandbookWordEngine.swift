import Foundation
import CPocket

struct HandbookWordState: Codable, Equatable {
    var format = "xkl-handbook-word-state-v1"
    var package: HandbookCardPackage
    /// Original public IDs never change. Internal aliases bind these IDs to permanent C slots.
    var originalCardIDs: [String]
    var word: ProfessionalRecallRecord
    var frozenCard: HandbookCard?
    var frozenToken: UUID?
}

/// Uses the existing English PocketEngine through its already tested professional adapter.
/// No interval table, repetition policy or graduation decision is implemented here.
@MainActor final class HandbookWordEngine {
    private(set) var package: HandbookCardPackage
    private var originalIDs: [String]
    private var core: ProfessionalRecallEngine
    private var frozenCard: HandbookCard?
    private var frozenToken: UUID?
    var record: ProfessionalRecallRecord { core.record }
    var state: HandbookWordState { .init(package: package, originalCardIDs: originalIDs, word: core.record,
                                       frozenCard: frozenCard, frozenToken: frozenToken) }
    var currentCard: HandbookCard? { core.record.presentation == nil ? nil : frozenCard }
    var presentation: HandbookCardPresentation? {
        guard let p = core.record.presentation, let card = frozenCard else { return nil }
        return .init(id: p.id, cardID: card.id, definitionID: card.definitionID, revealed: p.revealed,
                     shownAt: core.record.migration.at)
    }
    private static func catalog(_ package: HandbookCardPackage, ids: [String]) -> RecallDeck {
        // These short aliases are internal C-slot labels, not replacement card IDs or content.
        .init(subject: package.subject, bankID: package.subject.bankID, cards: ids.indices.map { index in
            .init(conceptID: "handbook", conceptTitle: "Handbook slot",
                  card: .init(id: "handbook:\(index)", prompt: "slot \(index)", answer: "slot \(index)"))
        })
    }
    init(package: HandbookCardPackage, now: Date = Date()) throws {
        try package.validate(); self.package = package; originalIDs = package.cards.map(\.id)
        core = try ProfessionalRecallEngine.fresh(deck: Self.catalog(package, ids: originalIDs), now: now)
    }
    init(state: HandbookWordState) throws {
        try state.package.validate()
        guard state.format == "xkl-handbook-word-state-v1", Set(state.originalCardIDs).count == state.originalCardIDs.count,
              Set(state.originalCardIDs) == Set(state.package.cards.map(\.id)) else { throw ExamError.invalid("宝典单词调度的卡片映射不一致。") }
        package = state.package; originalIDs = state.originalCardIDs
        core = try ProfessionalRecallEngine(deck: Self.catalog(package, ids: originalIDs), record: state.word)
        frozenCard = state.frozenCard; frozenToken = state.frozenToken
        if let p = core.record.presentation {
            guard p.id == frozenToken, let index = core.record.cardIDs.firstIndex(of: p.cardID),
                  frozenCard?.id == originalIDs[index] else { throw ExamError.invalid("宝典单词调度断点缺失，原文件保留。") }
        } else if frozenCard != nil || frozenToken != nil { throw ExamError.invalid("宝典单词调度存在过期断点。") }
    }
    private init(package: HandbookCardPackage, ids: [String], core: ProfessionalRecallEngine,
                 card: HandbookCard?, token: UUID?) {
        self.package = package; originalIDs = ids; self.core = core; frozenCard = card; frozenToken = token
    }
    func fork() throws -> HandbookWordEngine {
        .init(package: package, ids: originalIDs, core: try core.fork(), card: frozenCard, token: frozenToken)
    }
    private func refreshCard() {
        guard let p = core.record.presentation, let index = core.record.cardIDs.firstIndex(of: p.cardID) else {
            frozenCard = nil; frozenToken = nil; return
        }
        if frozenToken != p.id {
            frozenToken = p.id; frozenCard = package.cards.first { $0.id == originalIDs[index] }
        }
    }
    func start(now: Date = Date(), conservative: Bool = true) throws {
        try core.setConservativeEnabled(conservative, now: now)
        try core.start(day: UInt32(ConceptCalendar.studyDay(now)), now: now); refreshCard()
    }
    func reveal(token: UUID, now: Date = Date()) throws { try core.reveal(token: token, now: now); refreshCard() }
    func rate(remembered: Bool, token: UUID, now: Date = Date()) throws {
        try core.grade(remembered: remembered, token: token, now: now); refreshCard()
    }
    func postpone(token: UUID, now: Date = Date()) throws {
        guard try core.postpone(token: token, now: now) else { throw ExamError.invalid("当前只剩这张卡，暂时不能再延后；可退出后接着背。") }
        refreshCard()
    }
    func updatePackage(_ incoming: HandbookCardPackage, now: Date = Date()) throws {
        try incoming.validate()
        guard incoming.id == package.id, incoming.subject == package.subject,
              incoming.revision.compare(package.revision, options: .numeric) != .orderedAscending,
              Set(originalIDs).isSubset(of: Set(incoming.cards.map(\.id))) else { throw ExamError.invalid("旧版本或删卡包不能覆盖已有宝典记录。") }
        let known = Set(originalIDs), next = originalIDs + incoming.cards.map(\.id).filter { !known.contains($0) }
        if next != originalIDs { try core.reconcile(to: Self.catalog(incoming, ids: next), now: now) }
        originalIDs = next; package = incoming; refreshCard()
    }
    private func packedValues() -> [UInt32] {
        let raw = core.record.snapshot
        guard let pointer = raw.withUnsafeBytes({ xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }) else { return [] }
        defer { xkl_engine_free(pointer) }
        return originalIDs.indices.map { xkl_engine_card(pointer, UInt32($0)) }
    }
    var nextDueAt: Date? {
        let days = packedValues().filter { $0 & (1 << 20) != 0 && $0 & (1 << 21) == 0 && (1...10).contains(($0 >> 16) & 15) }.map { Int($0 & 65_535) }
        guard let day = days.min() else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
        return Calendar.current.date(from: parts)
    }
    func stats(on now: Date = Date()) -> HandbookCardStats {
        let day = UInt32((try? ConceptCalendar.studyDay(now)) ?? 0)
        let values = packedValues()
        let seen = Set(record.attempts.map(\.cardID) + (record.postponements ?? []).map(\.cardID) + [record.presentation?.cardID].compactMap { $0 }).count
        let start = Calendar.current.startOfDay(for: now), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return .init(total: originalIDs.count, seen: seen,
            due: values.filter { $0 & (1 << 20) != 0 && $0 & (1 << 21) == 0 && (1...10).contains(($0 >> 16) & 15) && ($0 & 65_535) <= day }.count,
            unseen: originalIDs.count - seen, remembered: record.attempts.filter(\.remembered).count,
            forgotten: record.attempts.filter { !$0.remembered }.count, nextDueAt: nextDueAt,
            ratedToday: record.attempts.filter { $0.at >= start && $0.at < end }.count,
            remainingToday: Int((try? core.info.total_remaining) ?? 0))
    }
}
