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
    /// A presented guide is frozen with the card, including across package updates.
    /// Missing in pre-guide records, which therefore retain their existing display.
    var frozenGuide: HandbookCardPackage.MemoryGuide? = nil
    /// Versioned professional-only scheduler. The complete Pocket record above
    /// remains an immutable historical baseline after the cutover.
    var dualFSRS: HandbookDualFSRSState? = nil
}

/// Keeps the original professional Pocket adapter as a validated historical
/// baseline while routing new professional-card activity through dual FSRS.
/// English and other subjects never share this professional state.
@MainActor final class HandbookWordEngine {
    private(set) var package: HandbookCardPackage
    private var originalIDs: [String]
    private var core: ProfessionalRecallEngine
    private var frozenCard: HandbookCard?
    private var frozenToken: UUID?
    private var frozenGuide: HandbookCardPackage.MemoryGuide?
    private var dualFSRS: HandbookDualFSRS?
    var record: ProfessionalRecallRecord { core.record }
    var state: HandbookWordState { .init(package: package, originalCardIDs: originalIDs, word: core.record,
                                       frozenCard: frozenCard, frozenToken: frozenToken, frozenGuide: frozenGuide,
                                       dualFSRS: dualFSRS?.state) }
    var usesDualFSRS: Bool { dualFSRS != nil }
    var currentCard: HandbookCard? { dualFSRS?.currentCard ?? (dualFSRS == nil && core.record.presentation != nil ? frozenCard : nil) }
    var currentMemoryGuide: HandbookCardPackage.MemoryGuide? { dualFSRS?.currentMemoryGuide ?? (dualFSRS == nil && core.record.presentation != nil ? frozenGuide : nil) }
    func activePosition(of cardID: String) -> Int? {
        if let dualFSRS {
            let value = dualFSRS.state, legacy = Set(value.legacyIDs), active = Set(value.legacyActiveIDs)
            return value.ids.filter { !legacy.contains($0) || active.contains($0) }.firstIndex(of: cardID).map { $0 + 1 }
        }
        return activeOriginalIDs.firstIndex(of: cardID).map { $0 + 1 }
    }
    var presentation: HandbookCardPresentation? {
        if let dualFSRS { return dualFSRS.presentation }
        guard let p = core.record.presentation, let card = frozenCard else { return nil }
        return .init(id: p.id, cardID: card.id, definitionID: card.definitionID, revealed: p.revealed,
                     shownAt: core.record.migration.at)
    }
    private static func catalog(_ package: HandbookCardPackage, ids: [String], active: Set<String>? = nil) -> RecallDeck {
        // These short aliases are internal C-slot labels, not replacement card IDs or content.
        .init(subject: package.subject, bankID: package.subject.bankID, cards: ids.indices.filter { active == nil || active!.contains(ids[$0]) }.map { index in
            .init(conceptID: "handbook", conceptTitle: "Handbook slot",
                  card: .init(id: "handbook:\(index)", prompt: "slot \(index)", answer: "slot \(index)"))
        })
    }
    init(package: HandbookCardPackage, now: Date = Date()) throws {
        try package.validate(); self.package = package; originalIDs = package.cards.map(\.id)
        core = try ProfessionalRecallEngine.fresh(deck: Self.catalog(package, ids: originalIDs), now: now)
        if let main = package.mainCardIDs {
            try core.reconcile(to: Self.catalog(package, ids: originalIDs, active: Set(main)), now: now)
        }
    }
    init(state: HandbookWordState) throws {
        try state.package.validate()
        guard state.format == "xkl-handbook-word-state-v1", Set(state.originalCardIDs).count == state.originalCardIDs.count,
              Set(state.originalCardIDs) == Set(state.package.cards.map(\.id)) else { throw ExamError.invalid("宝典单词调度的卡片映射不一致。") }
        package = state.package; originalIDs = state.originalCardIDs
        let legacyCount = state.word.cardIDs.count
        guard legacyCount <= originalIDs.count, state.dualFSRS != nil || legacyCount == originalIDs.count else {
            throw ExamError.invalid("宝典历史槽位与当前卡片映射不一致。")
        }
        core = try ProfessionalRecallEngine(deck: Self.catalog(package, ids: Array(originalIDs.prefix(legacyCount))), record: state.word)
        frozenCard = state.frozenCard; frozenToken = state.frozenToken; frozenGuide = state.frozenGuide
        if let p = core.record.presentation {
            guard p.id == frozenToken, let index = core.record.cardIDs.firstIndex(of: p.cardID),
                  frozenCard?.id == originalIDs[index],
                  frozenGuide == nil || (frozenGuide?.isValid == true && frozenGuide?.cardID == frozenCard?.id) else { throw ExamError.invalid("宝典单词调度断点缺失，原文件保留。") }
        } else if frozenCard != nil || frozenToken != nil || frozenGuide != nil { throw ExamError.invalid("宝典单词调度存在过期断点。") }
        if let fsrs = state.dualFSRS {
            let restored = try HandbookDualFSRS(state: fsrs, package: package, ids: originalIDs)
            try restored.validateLegacy(state)
            dualFSRS = restored
        }
    }
    private init(package: HandbookCardPackage, ids: [String], core: ProfessionalRecallEngine,
                 card: HandbookCard?, token: UUID?, guide: HandbookCardPackage.MemoryGuide?, dualFSRS: HandbookDualFSRS?) {
        self.package = package; originalIDs = ids; self.core = core; frozenCard = card; frozenToken = token; frozenGuide = guide; self.dualFSRS = dualFSRS
    }
    func fork() throws -> HandbookWordEngine {
        .init(package: package, ids: originalIDs, core: try core.fork(), card: frozenCard, token: frozenToken, guide: frozenGuide, dualFSRS: try dualFSRS?.fork())
    }
    /// Replay only validated, actual professional self-ratings. The Pocket
    /// history remains intact and never becomes an English or question score.
    func enableDualFSRS(now: Date = Date()) throws {
        guard dualFSRS == nil else { return }
        dualFSRS = try HandbookDualFSRS(legacy: state, now: now)
    }
    private func refreshCard() {
        guard let p = core.record.presentation, let index = core.record.cardIDs.firstIndex(of: p.cardID) else {
            frozenCard = nil; frozenToken = nil; frozenGuide = nil; return
        }
        if frozenToken != p.id {
            frozenToken = p.id; frozenCard = package.cards.first { $0.id == originalIDs[index] }
            frozenGuide = frozenCard.flatMap { package.memoryGuide(for: $0) }
        }
    }
    func start(now: Date = Date(), conservative: Bool = true) throws {
        if let dualFSRS { try dualFSRS.start(now: now); return }
        try core.setConservativeEnabled(conservative, now: now)
        try core.start(day: UInt32(ConceptCalendar.studyDay(now)), now: now); refreshCard()
    }
    func reveal(token: UUID, now: Date = Date()) throws {
        if let dualFSRS { try dualFSRS.reveal(token: token, now: now); return }
        try core.reveal(token: token, now: now); refreshCard()
    }
    func rate(remembered: Bool, token: UUID, now: Date = Date()) throws {
        if let dualFSRS { try dualFSRS.rate(remembered: remembered, token: token, now: now); return }
        try core.grade(remembered: remembered, token: token, now: now); refreshCard()
    }
    func markFamiliar(token: UUID, now: Date = Date()) throws {
        if let dualFSRS { try dualFSRS.markFamiliar(token: token, now: now); return }
        try core.markFamiliar(token: token, now: now); refreshCard()
    }
    func retryCount(on now: Date = Date()) -> Int { dualFSRS?.retryCount(on: now) ?? 0 }
    func startRetry(now: Date = Date()) throws {
        guard let dualFSRS else { throw ExamError.invalid("当前算法不支持此补练。") }
        try dualFSRS.startRetry(now: now)
    }
    func postpone(token: UUID, now: Date = Date()) throws {
        if let dualFSRS {
            guard try dualFSRS.postpone(token: token, now: now) else { throw ExamError.invalid("当前只剩这张卡，暂时不能再延后；可退出后接着背。") }
            return
        }
        guard try core.postpone(token: token, now: now) else { throw ExamError.invalid("当前只剩这张卡，暂时不能再延后；可退出后接着背。") }
        refreshCard()
    }
    @discardableResult func requeue(cardID: String, now: Date = Date()) throws -> Bool {
        guard dualFSRS == nil else { throw ExamError.invalid("当前双FSRS卡片暂不支持手动重排；原记录保留。") }
        guard let index = originalIDs.firstIndex(of: cardID), index < record.cardIDs.count else {
            throw ExamError.invalid("卡片不存在，原记录保留。")
        }
        let changed = try core.requeue(cardID: record.cardIDs[index], now: now)
        refreshCard()
        return changed
    }
    func updatePackage(_ incoming: HandbookCardPackage, now: Date = Date()) throws {
        try incoming.validate()
        guard incoming.id == package.id, incoming.subject == package.subject,
              incoming.revision.compare(package.revision, options: .numeric) != .orderedAscending,
              Set(originalIDs).isSubset(of: Set(incoming.cards.map(\.id))) else { throw ExamError.invalid("旧版本或删卡包不能覆盖已有宝典记录。") }
        if incoming == package { return }
        if let expected = incoming.requiredBasePackageHash, expected != package.hash {
            throw ExamError.invalid("已有课程内容已变化，新卡包不适用；原课程和学习记录保留。")
        }
        let known = Set(originalIDs), next = originalIDs + incoming.cards.map(\.id).filter { !known.contains($0) }
        if let dualFSRS {
            guard incoming.mainCardIDs == nil else { throw ExamError.invalid("当前调度不能自动切换新的主线范围，原记录保留。") }
            try dualFSRS.updatePackage(incoming, ids: next, now: now)
        } else if let main = incoming.mainCardIDs {
            // First cutover applies the supplied mainline. Later updates retain
            // cards the learner explicitly added outside the former mainline.
            let overrides: Set<String>
            if let previousMain = package.mainCardIDs {
                overrides = Set(activeOriginalIDs).subtracting(previousMain)
            } else { overrides = [] }
            let active = Set(main).union(overrides)
            try core.reconcile(to: Self.catalog(incoming, ids: next, active: active),
                               retaining: Self.catalog(incoming, ids: next).cards, now: now)
        } else {
            guard package.mainCardIDs == nil else { throw ExamError.invalid("新卡包缺少已有主线范围，原记录保留。") }
            if next != originalIDs { try core.reconcile(to: Self.catalog(incoming, ids: next), now: now) }
        }
        originalIDs = next; package = incoming; refreshCard()
    }
    private var activeOriginalIDs: [String] {
        let aliases = Set(core.activeCardIDs)
        return originalIDs.indices.compactMap { index in
            guard index < record.cardIDs.count, aliases.contains(record.cardIDs[index]) else { return nil }
            return originalIDs[index]
        }
    }
    func isInMainScope(_ cardID: String) -> Bool {
        if dualFSRS != nil { return true }
        return activeOriginalIDs.contains(cardID)
    }
    var otherScopeHistory: (cards: Int, assessments: Int, familiarMarks: Int) {
        guard dualFSRS == nil else { return (0, 0, 0) }
        let active = Set(core.activeCardIDs)
        let attempts = record.attempts.filter { !active.contains($0.cardID) }
        let familiar = ((try? core.allEvents()) ?? []).filter {
            $0.kind == 7 && Int($0.word) < record.cardIDs.count && !active.contains(record.cardIDs[Int($0.word)])
        }.map { record.cardIDs[Int($0.word)] }
        return (Set(attempts.map(\.cardID) + familiar).count, attempts.count, familiar.count)
    }
    func historyLabel(for cardID: String) -> String? {
        guard dualFSRS == nil, let index = originalIDs.firstIndex(of: cardID), index < record.cardIDs.count else { return nil }
        let alias = record.cardIDs[index]
        let attempts = record.attempts.filter { $0.cardID == alias }
        let familiar = ((try? core.allEvents()) ?? []).contains { $0.kind == 7 && Int($0.word) == index }
        guard !attempts.isEmpty || familiar else { return nil }
        let remembered = attempts.filter(\.remembered).count
        let forgotten = attempts.count - remembered
        return "已有自评：记住\(remembered)次，没记住\(forgotten)次" + (familiar ? "；曾标为熟记" : "")
    }
    private func packedValues() -> [UInt32] {
        let raw = core.record.snapshot
        guard let pointer = raw.withUnsafeBytes({ xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }) else { return [] }
        defer { xkl_engine_free(pointer) }
        return originalIDs.indices.map { xkl_engine_card(pointer, UInt32($0)) }
    }
    private func activePackedValues() -> [UInt32] {
        let active = Set(core.activeCardIDs)
        let values = packedValues()
        var result: [UInt32] = []
        for (index, value) in values.enumerated() {
            if index < record.cardIDs.count && active.contains(record.cardIDs[index]) { result.append(value) }
        }
        return result
    }
    var nextDueAt: Date? {
        if let dualFSRS { return dualFSRS.nextDueAt }
        let values = activePackedValues()
        let days = values.filter { value in
            value & (1 << 20) != 0 && value & (1 << 21) == 0 && (1...10).contains((value >> 16) & 15)
        }.map { Int($0 & 65_535) }
        guard let day = days.min() else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
        return Calendar.current.date(from: parts)
    }
    func stats(on now: Date = Date()) -> HandbookCardStats {
        if let dualFSRS { return dualFSRS.stats(on: now) }
        let day = UInt32((try? ConceptCalendar.studyDay(now)) ?? 0)
        let active = Set(core.activeCardIDs)
        let values = activePackedValues()
        let familiarIDs = (try? core.allEvents())?.filter { $0.kind == 7 && Int($0.word) < record.cardIDs.count }.map { record.cardIDs[Int($0.word)] } ?? []
        let seen = Set(record.attempts.map(\.cardID) + (record.postponements ?? []).map(\.cardID) + familiarIDs + [record.presentation?.cardID].compactMap { $0 }).intersection(active).count
        let attempts = record.attempts.filter { active.contains($0.cardID) }
        let start = Calendar.current.startOfDay(for: now), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return .init(total: active.count, seen: seen,
            due: values.filter { $0 & (1 << 20) != 0 && $0 & (1 << 21) == 0 && (1...10).contains(($0 >> 16) & 15) && ($0 & 65_535) <= day }.count,
            unseen: active.count - seen, remembered: attempts.filter(\.remembered).count,
            forgotten: attempts.filter { !$0.remembered }.count, nextDueAt: nextDueAt,
            ratedToday: attempts.filter { $0.at >= start && $0.at < end }.count,
            remainingToday: Int((try? core.info.total_remaining) ?? 0))
    }
}
