import Foundation
import StudyCore

/// A source knowledge point and its readable answer. It is not an original-question answer key.
struct HandbookCard: Codable, Equatable, Identifiable {
    struct SourceReference: Codable, Equatable, Hashable {
        let sourceID: String
        let page: Int
    }
    struct Block: Codable, Equatable {
        let title: String
        let kind: String
        var text: String? = nil
        var items: [String]? = nil
        var columns: [String]? = nil
        var rows: [[String]]? = nil
        var collapsed = false
    }
    struct Example: Codable, Equatable {
        let title: String
        let prompt: String
        let steps: [String]
        let answer: String
        let sourcePage: Int
        var sourceIssueNote: String? = nil
    }
    let id: String
    let sourceGroupIDs: [String]
    let topicNumber: Int
    let title: String
    let prompt: String
    let answerSummary: String
    let blocks: [Block]
    let sourcePages: [Int]
    let examples: [Example]
    let sourceNotes: [String]
    var chapterID: String? = nil
    /// References to additional sources only; sourcePages retains its original handbook meaning.
    var sourceReferences: [SourceReference]? = nil

    var definitionID: String { handbookHash(self) }
    func validate(pages: Set<Int>, chapterIDs: Set<String>, additionalSources: [HandbookCardPackage.AdditionalSource]? = nil) throws {
        let references = sourceReferences ?? []
        guard handbookText(id, 200), !sourceGroupIDs.isEmpty, sourceGroupIDs.count <= 30,
              Set(sourceGroupIDs).count == sourceGroupIDs.count, sourceGroupIDs.allSatisfy({ handbookText($0, 200) }),
              (1...1_000).contains(topicNumber), handbookText(title, 160), handbookText(prompt, 1_200),
              handbookText(answerSummary, 2_000), blocks.count <= 16,
              (!sourcePages.isEmpty || !references.isEmpty), Set(sourcePages).count == sourcePages.count, Set(sourcePages).isSubset(of: pages),
              Set(references).count == references.count,
              references.allSatisfy({ reference in
                  (additionalSources ?? []).contains { $0.id == reference.sourceID && $0.source.includedPages.contains(reference.page) }
              }),
              chapterID == nil || chapterIDs.contains(chapterID!), examples.count <= 12,
              sourceNotes.count <= 30, sourceNotes.allSatisfy({ handbookText($0, 4_000) }) else {
            throw ExamError.invalid("宝典卡片的标题、答案、身份或出处不完整：\(id)")
        }
        for block in blocks {
            guard block.title.count <= 200 else { throw ExamError.invalid("宝典答案分块标题过长。") }
            switch block.kind {
            case "text":
                guard let text = block.text, handbookText(text, 6_000) else { throw ExamError.invalid("宝典文字分块为空。") }
            case "bullets", "steps":
                guard let items = block.items, (1...24).contains(items.count), items.allSatisfy({ handbookText($0, 1_600) }) else {
                    throw ExamError.invalid("宝典分行答案不完整。")
                }
            case "diagram":
                guard block.collapsed, let mode = block.text, let items = block.items,
                      ((mode == "branch" && items.count == 3) || (mode == "flow" && (2...6).contains(items.count))),
                      items.allSatisfy({ handbookText($0, 100) }), block.columns == nil, block.rows == nil else {
                    throw ExamError.invalid("宝典关系图须折叠，且模式和节点完整。")
                }
            case "keyValues":
                guard let rows = block.rows, (1...30).contains(rows.count), rows.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isEmpty || handbookText($0, 1_600) } }),
                      rows.joined().contains(where: { !$0.isEmpty }) else {
                    throw ExamError.invalid("宝典对照答案须为两列。")
                }
            case "table":
                guard let columns = block.columns, (1...3).contains(columns.count), columns.allSatisfy({ $0.isEmpty || handbookText($0, 200) }),
                      let rows = block.rows, (1...30).contains(rows.count), rows.allSatisfy({ $0.count == columns.count && $0.allSatisfy { $0.isEmpty || handbookText($0, 1_600) } }),
                      rows.joined().contains(where: { !$0.isEmpty }) else {
                    throw ExamError.invalid("宝典表格行列不匹配，或超过手机支持的三列。")
                }
            default: throw ExamError.invalid("未知宝典答案分块：\(block.kind)")
            }
        }
        for example in examples {
            guard handbookText(example.title, 300), handbookText(example.prompt, 4_000), example.steps.count <= 20,
                  example.steps.allSatisfy({ handbookText($0, 2_000) }), handbookText(example.answer, 4_000),
                  pages.contains(example.sourcePage), (example.sourceIssueNote?.count ?? 0) <= 4_000 else {
                throw ExamError.invalid("宝典辅助例子或出处不完整。")
            }
        }
    }
}

struct HandbookCardPackage: Codable, Equatable {
    struct Source: Codable, Equatable {
        let title: String
        let fileName: String
        let sha256: String
        let pdfPageCount: Int
        let includedPages: [Int]
    }
    struct Chapter: Codable, Equatable, Identifiable { let id: String; let title: String }
    struct Page: Codable, Equatable { let number: Int; let asset: ProfessionalSourceFileAsset }
    /// The book's rating belongs to a whole topic, not to an individual fact or observed exam frequency.
    /// Explicit card IDs prevent later additions from inheriting a rating by proximity.
    struct TopicFrequency: Codable, Equatable {
        let topicNumber: Int
        let stars: Int
        let sourcePage: Int
        let cardIDs: [String]
    }
    /// Presentation-only guidance is kept outside the immutable card definition.
    /// Each guide is explicitly assigned to an existing knowledge-point card.
    struct MemoryGuide: Codable, Equatable {
        struct Row: Codable, Equatable { let cue: String; let answer: String }
        let cardID: String
        let explanation: String?
        let rows: [Row]
        let mnemonic: String?
        var isValid: Bool {
            handbookText(cardID, 200) && (1...6).contains(rows.count) &&
            rows.allSatisfy { handbookText($0.cue, 80) && handbookText($0.answer, 300) } &&
            (explanation?.count ?? 0) <= 300 && (mnemonic?.count ?? 0) <= 160
        }
    }
    struct AdditionalSource: Codable, Equatable, Identifiable {
        let id: String
        let source: Source
        var sourcePages: [Page]? = nil
    }
    var format = "xkl-handbook-cards-v1"
    let id: String
    let subject: ConceptSubject
    let title: String
    let revision: String
    let source: Source
    let chapters: [Chapter]
    let cards: [HandbookCard]
    var sourcePages: [Page]? = nil
    var additionalSources: [AdditionalSource]? = nil
    /// Optional package-level presentation metadata; it does not alter card definitions or scheduling.
    var topicFrequencies: [TopicFrequency]? = nil
    var memoryGuides: [MemoryGuide]? = nil

    var hash: String { handbookHash(self) }
    static func load(_ data: Data) throws -> Self {
        guard data.count <= 40 * 1_024 * 1_024 else { throw ExamError.invalid("宝典文字卡包超过40MB。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    func validate() throws {
        guard format == "xkl-handbook-cards-v1", handbookText(id, 200), handbookText(title, 600), handbookText(revision, 100),
              (1...100).contains(chapters.count), Set(chapters.map(\.id)).count == chapters.count,
              chapters.allSatisfy({ handbookText($0.id, 100) && handbookText($0.title, 300) }),
              (1...5_000).contains(cards.count), Set(cards.map(\.id)).count == cards.count else {
            throw ExamError.invalid("宝典卡包身份、章节或卡片ID无效。")
        }
        try Self.validateSource(source, sourcePages: sourcePages)
        try Self.validateAdditionalSources(additionalSources)
        try validateTopicFrequencies()
        try validateMemoryGuides()
        for card in cards {
            try card.validate(pages: Set(source.includedPages), chapterIDs: Set(chapters.map(\.id)), additionalSources: additionalSources)
        }
    }
    private func validateMemoryGuides() throws {
        guard let guides = memoryGuides else { return }
        let cardIDs = Set(cards.map(\.id))
        guard guides.count <= cards.count, Set(guides.map(\.cardID)).count == guides.count,
              guides.allSatisfy({ guide in
                  guide.isValid && cardIDs.contains(guide.cardID)
              }) else {
            throw ExamError.invalid("宝典回忆骨架的卡片对应或内容不完整。")
        }
    }
    func memoryGuide(for card: HandbookCard) -> MemoryGuide? {
        memoryGuides?.first { $0.cardID == card.id }
    }
    private func validateTopicFrequencies() throws {
        guard let frequencies = topicFrequencies else { return }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let assigned = frequencies.flatMap(\.cardIDs)
        guard frequencies.count <= 1_000,
              Set(frequencies.map(\.topicNumber)).count == frequencies.count,
              Set(assigned).count == assigned.count,
              frequencies.allSatisfy({ item in
                  (1...1_000).contains(item.topicNumber) && (1...5).contains(item.stars) &&
                  source.includedPages.contains(item.sourcePage) && item.cardIDs.count <= cards.count &&
                  item.cardIDs.allSatisfy { byID[$0]?.topicNumber == item.topicNumber }
              }) else {
            throw ExamError.invalid("宝典考点星级的来源、范围或卡片对应关系无效。")
        }
    }
    /// Nil for older packages; unlisted cards are explicitly not individually rated by the book.
    func frequencyLabel(for card: HandbookCard) -> String? {
        guard let frequencies = topicFrequencies else { return nil }
        guard let item = frequencies.first(where: { $0.cardIDs.contains(card.id) }) else {
            return "宝典未单独标注"
        }
        return "宝典考点频率 " + String(repeating: "★", count: item.stars) +
            String(repeating: "☆", count: 5 - item.stars)
    }
    static func validateAdditionalSources(_ sources: [AdditionalSource]?) throws {
        let sources = sources ?? []
        guard sources.count <= 100, Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ handbookText($0.id, 100) && $0.id == $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw ExamError.invalid("宝典追加来源ID为空、重复或无效。")
        }
        for item in sources { try validateSource(item.source, sourcePages: item.sourcePages) }
    }
    static func validateSource(_ source: Source, sourcePages: [Page]?) throws {
        guard handbookText(source.title, 600), handbookText(source.fileName, 300), !source.fileName.contains("/"),
              !source.fileName.contains("\\"), !source.fileName.contains(".."), ExamContent.isHash(source.sha256),
              (1...20_000).contains(source.pdfPageCount), !source.includedPages.isEmpty,
              Set(source.includedPages).count == source.includedPages.count,
              source.includedPages.allSatisfy({ (1...source.pdfPageCount).contains($0) }),
              (sourcePages ?? []).count <= source.includedPages.count,
              Set((sourcePages ?? []).map(\.number)).count == (sourcePages ?? []).count else {
            throw ExamError.invalid("宝典来源文件或原页范围无效。")
        }
        for page in sourcePages ?? [] {
            guard source.includedPages.contains(page.number) else { throw ExamError.invalid("宝典原页不在声明范围。") }
            // Source pixels are optional reference material, not a gate on text recall.
            try page.asset.validateMetadata()
        }
    }
    func chapter(for card: HandbookCard) -> Chapter? {
        if let id = card.chapterID { return chapters.first { $0.id == id } }
        return chapters.count == 1 ? chapters.first : nil
    }
}

struct HandbookCardProgress: Codable, Equatable {
    var rememberedCount = 0
    var forgottenCount = 0
    var streak = 0
    var lastRatedAt: Date? = nil
    var nextDueAt: Date? = nil
}
struct HandbookCardPresentation: Codable, Equatable {
    let id: UUID
    let cardID: String
    let definitionID: String
    var revealed = false
    let shownAt: Date
}
struct HandbookCardRating: Codable, Equatable, Identifiable {
    let id: UUID
    let presentationID: UUID
    let cardID: String
    let definitionID: String
    let remembered: Bool
    let at: Date
    let nextDueAt: Date
    let beforeProgress: HandbookCardProgress
    let afterProgress: HandbookCardProgress
}
struct HandbookCardEvent: Codable, Equatable {
    let sequence: Int
    let kind: String
    let at: Date
    var presentation: HandbookCardPresentation? = nil
    var ratingID: UUID? = nil
}
struct HandbookCardContentVersion: Codable, Equatable {
    let packageSHA256: String
    let revision: String
    let cardIDs: [String]
    let activeDefinitions: [String: String]
    let source: HandbookCardPackage.Source
    let chapters: [HandbookCardPackage.Chapter]
    var sourcePages: [HandbookCardPackage.Page]? = nil
    var additionalSources: [HandbookCardPackage.AdditionalSource]? = nil
}
struct HandbookCardRecord: Codable, Equatable {
    var format = "xkl-handbook-card-record-v1"
    let packageID: String
    let subject: ConceptSubject
    var definitions: [String: HandbookCard]
    var activeDefinitions: [String: String]
    var cardOrder: [String]
    var contentVersions: [HandbookCardContentVersion]
    var progress: [String: HandbookCardProgress] = [:]
    var ratings: [HandbookCardRating] = []
    var events: [HandbookCardEvent] = []
    var presentation: HandbookCardPresentation? = nil
    var bookmarks: [String: HandbookCardPresentation] = [:]
    var deferredCardIDs: [String] = []
    var lastObservedAt: Date? = nil
}
struct HandbookCardStats: Equatable {
    let total, seen, due, unseen, remembered, forgotten: Int
    let nextDueAt: Date?
    let ratedToday, remainingToday: Int
}

/// Dedicated self-rated recall. Real elapsed durations avoid midnight retries.
/// No event here is an objective original-question success or an English grade.
struct HandbookRecallEngine {
    static let rememberedGaps = [3, 7, 14, 30, 60, 90, 180]
    private(set) var package: HandbookCardPackage
    private(set) var record: HandbookCardRecord
    var presentation: HandbookCardPresentation? { record.presentation }
    var currentCard: HandbookCard? { presentation.flatMap { record.definitions[$0.definitionID] } }
    var nextDueAt: Date? { record.progress.values.compactMap(\.nextDueAt).min() }
    init(package: HandbookCardPackage, record: HandbookCardRecord? = nil) throws {
        try package.validate(); self.package = package
        if let record { self.record = record; try validateRecord() }
        else {
            let active = Dictionary(uniqueKeysWithValues: package.cards.map { ($0.id, $0.definitionID) })
            self.record = .init(packageID: package.id, subject: package.subject,
                definitions: Dictionary(uniqueKeysWithValues: package.cards.map { ($0.definitionID, $0) }),
                activeDefinitions: active, cardOrder: package.cards.map(\.id),
                contentVersions: [.init(packageSHA256: package.hash, revision: package.revision,
                    cardIDs: package.cards.map(\.id), activeDefinitions: active, source: package.source,
                    chapters: package.chapters, sourcePages: package.sourcePages, additionalSources: package.additionalSources)])
        }
    }
    static func fresh(_ package: HandbookCardPackage) throws -> Self { try .init(package: package) }
    mutating func updatePackage(_ next: HandbookCardPackage) throws {
        try next.validate()
        guard next.id == package.id, next.subject == package.subject else { throw ExamError.invalid("宝典卡包科目或ID不同，原记录保留。") }
        if next == package { return }
        guard next.revision.compare(package.revision, options: .numeric) == .orderedDescending,
              !record.contentVersions.contains(where: { $0.packageSHA256 == next.hash }),
              Set(record.cardOrder).isSubset(of: Set(next.cards.map(\.id))) else {
            throw ExamError.invalid("不能用旧版或删卡包覆盖已有宝典进度。")
        }
        var saved = record
        for card in next.cards { saved.definitions[card.definitionID] = card }
        let known = Set(saved.cardOrder); saved.cardOrder += next.cards.map(\.id).filter { !known.contains($0) }
        saved.activeDefinitions = Dictionary(uniqueKeysWithValues: next.cards.map { ($0.id, $0.definitionID) })
        saved.contentVersions.append(.init(packageSHA256: next.hash, revision: next.revision,
            cardIDs: saved.cardOrder, activeDefinitions: saved.activeDefinitions, source: next.source,
            chapters: next.chapters, sourcePages: next.sourcePages, additionalSources: next.additionalSources))
        // A displayed/back-side or postponed card retains its frozen definition.
        self = try Self(package: next, record: saved)
    }
    mutating func start(now: Date = Date()) throws {
        if presentation != nil { return }
        try checked(now)
        record.deferredCardIDs = []
        event("start", at: now)
        choose(now: now, allowDeferred: true)
    }
    mutating func reveal(token: UUID, now: Date = Date()) throws {
        guard var p = presentation, p.id == token else { throw ExamError.invalid("当前宝典卡已切换，原记录保留。") }
        if p.revealed { return }
        try checked(now); p.revealed = true; record.presentation = p
        event("reveal", at: now, presentation: p)
    }
    mutating func rate(remembered: Bool, token: UUID, now: Date = Date()) throws {
        if record.ratings.contains(where: { $0.presentationID == token }) { return }
        try checked(now)
        guard let p = presentation, p.id == token, p.revealed, currentCard != nil,
              (record.progress[p.cardID]?.nextDueAt ?? .distantPast) <= now else {
            throw ExamError.invalid("请先翻开当前宝典答案；尚未到期的卡不会再次评分。")
        }
        let before = record.progress[p.cardID] ?? .init()
        let after = Self.graded(before, remembered: remembered, at: now)
        let rating = HandbookCardRating(id: UUID(), presentationID: p.id, cardID: p.cardID, definitionID: p.definitionID,
            remembered: remembered, at: now, nextDueAt: after.nextDueAt!, beforeProgress: before, afterProgress: after)
        record.ratings.append(rating); record.progress[p.cardID] = after
        event("rate", at: now, presentation: p, ratingID: rating.id)
        record.presentation = nil; record.bookmarks.removeValue(forKey: p.cardID)
        record.deferredCardIDs.removeAll { $0 == p.cardID }
        choose(now: now, allowDeferred: true)
    }
    mutating func postpone(token: UUID, now: Date = Date()) throws {
        try checked(now)
        guard let p = presentation, p.id == token else { throw ExamError.invalid("当前宝典卡已切换，不能重复暂缓。") }
        record.bookmarks[p.cardID] = p
        if !record.deferredCardIDs.contains(p.cardID) { record.deferredCardIDs.append(p.cardID) }
        event("postpone", at: now, presentation: p)
        record.presentation = nil; choose(now: now)
    }
    func stats(on now: Date = Date()) -> HandbookCardStats {
        let introduced = Set(record.events.compactMap { $0.kind == "show" ? $0.presentation?.cardID : nil })
        let due = record.progress.values.filter { ($0.nextDueAt ?? .distantFuture) <= now }.count
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let deferred = Set(record.deferredCardIDs)
        return .init(total: record.cardOrder.count, seen: introduced.count, due: due,
            unseen: record.cardOrder.count - introduced.count,
            remembered: record.ratings.filter(\.remembered).count,
            forgotten: record.ratings.filter { !$0.remembered }.count,
            nextDueAt: nextDueAt, ratedToday: record.ratings.filter { $0.at >= start && $0.at < end }.count,
            remainingToday: record.cardOrder.filter { !deferred.contains($0) && eligible($0, at: now) }.count)
    }
    private func checked(_ now: Date) throws {
        guard handbookDate(now), now >= (record.lastObservedAt ?? now) else {
            throw ExamError.invalid("当前时间早于上次保存，宝典原进度已保留。")
        }
    }
    private func eligible(_ id: String, at now: Date) -> Bool { (record.progress[id]?.nextDueAt ?? .distantPast) <= now }
    private mutating func choose(now: Date, allowDeferred: Bool = false) {
        var deferred = Set(record.deferredCardIDs)
        var available = record.cardOrder.enumerated().filter { !deferred.contains($0.element) && eligible($0.element, at: now) }
        if available.isEmpty, allowDeferred, !deferred.isEmpty {
            record.deferredCardIDs = []; event("resumeDeferred", at: now); deferred = []
            available = record.cardOrder.enumerated().filter { eligible($0.element, at: now) }
        }
        let ordered = available.sorted { a, b in
            let av = record.progress[a.element]?.nextDueAt, bv = record.progress[b.element]?.nextDueAt
            if (av != nil) != (bv != nil) { return av != nil }
            if let av, let bv, av != bv { return av < bv }
            return a.offset < b.offset
        }
        guard let id = ordered.first?.element, let definition = record.activeDefinitions[id] else { return }
        let p = record.bookmarks.removeValue(forKey: id) ?? .init(id: UUID(), cardID: id, definitionID: definition, shownAt: now)
        record.presentation = p; event("show", at: now, presentation: p)
    }
    private mutating func event(_ kind: String, at: Date, presentation: HandbookCardPresentation? = nil, ratingID: UUID? = nil) {
        record.events.append(.init(sequence: record.events.count + 1, kind: kind, at: at, presentation: presentation, ratingID: ratingID))
        record.lastObservedAt = at
    }
    private static func graded(_ before: HandbookCardProgress, remembered: Bool, at: Date) -> HandbookCardProgress {
        var after = before
        if remembered { after.rememberedCount += 1; after.streak += 1 }
        else { after.forgottenCount += 1; after.streak = 0 }
        let days = remembered ? rememberedGaps[min(after.streak - 1, rememberedGaps.count - 1)] : 1
        after.lastRatedAt = at; after.nextDueAt = at.addingTimeInterval(Double(days) * 86_400)
        return after
    }
    private func validateRecord() throws {
        guard record.format == "xkl-handbook-card-record-v1", record.packageID == package.id, record.subject == package.subject,
              Set(record.cardOrder).count == record.cardOrder.count, Set(record.cardOrder) == Set(package.cards.map(\.id)),
              record.activeDefinitions == Dictionary(uniqueKeysWithValues: package.cards.map { ($0.id, $0.definitionID) }),
              !record.contentVersions.isEmpty, record.contentVersions.last?.packageSHA256 == package.hash,
              record.contentVersions.last?.cardIDs == record.cardOrder,
              record.contentVersions.last?.activeDefinitions == record.activeDefinitions,
              record.definitions.allSatisfy({ $0.key == $0.value.definitionID }),
              Set(record.definitions.keys) == Set(record.contentVersions.flatMap { $0.activeDefinitions.values }),
              record.events.count <= 200_000, record.ratings.count <= 100_000,
              Set(record.ratings.map(\.id)).count == record.ratings.count,
              Set(record.ratings.map(\.presentationID)).count == record.ratings.count else {
            throw ExamError.invalid("宝典卡身份、定义版本或自评记录不一致，原档案保留。")
        }
        var previousIDs = [String](), previousRevision: String? = nil
        var hashes = Set<String>()
        for version in record.contentVersions {
            guard ExamContent.isHash(version.packageSHA256), hashes.insert(version.packageSHA256).inserted,
                  Set(version.cardIDs).count == version.cardIDs.count,
                  Array(version.cardIDs.prefix(previousIDs.count)) == previousIDs,
                  Set(version.activeDefinitions.keys) == Set(version.cardIDs),
                  previousRevision == nil || version.revision.compare(previousRevision!, options: .numeric) == .orderedDescending else {
                throw ExamError.invalid("宝典内容版本链缺失或发生回退。")
            }
            try HandbookCardPackage.validateSource(version.source, sourcePages: version.sourcePages)
            try HandbookCardPackage.validateAdditionalSources(version.additionalSources)
            for (id, hash) in version.activeDefinitions {
                guard let card = record.definitions[hash], card.id == id else { throw ExamError.invalid("宝典旧卡定义缺失。") }
                try card.validate(pages: Set(version.source.includedPages), chapterIDs: Set(version.chapters.map(\.id)), additionalSources: version.additionalSources)
            }
            previousIDs = version.cardIDs; previousRevision = version.revision
        }
        var progress = [String: HandbookCardProgress](), ratingsByID = [UUID: HandbookCardRating]()
        var lastRating = Date.distantPast
        for rating in record.ratings {
            guard let card = record.definitions[rating.definitionID], card.id == rating.cardID, handbookDate(rating.at),
                  rating.at >= lastRating, rating.beforeProgress == (progress[rating.cardID] ?? .init()),
                  (rating.beforeProgress.nextDueAt ?? .distantPast) <= rating.at else { throw ExamError.invalid("宝典自评时间、旧定义或进度链无效。") }
            let after = Self.graded(rating.beforeProgress, remembered: rating.remembered, at: rating.at)
            guard after == rating.afterProgress, after.nextDueAt == rating.nextDueAt else { throw ExamError.invalid("宝典自评间隔与原始记录不一致。") }
            progress[rating.cardID] = after; ratingsByID[rating.id] = rating; lastRating = rating.at
        }
        guard progress == record.progress else { throw ExamError.invalid("宝典进度与自评日志不一致。") }
        var shown: HandbookCardPresentation?, bookmarks = [String: HandbookCardPresentation](), deferred = [String]()
        var knownTokens = [UUID: HandbookCardPresentation](), rated = [UUID](), eventTime = Date.distantPast
        for (index, e) in record.events.enumerated() {
            guard e.sequence == index + 1, handbookDate(e.at), e.at >= eventTime else { throw ExamError.invalid("宝典事件顺序或时间无效。") }
            eventTime = e.at
            switch e.kind {
            case "start":
                guard shown == nil, e.presentation == nil, e.ratingID == nil else { throw ExamError.invalid("宝典开始事件与当前卡不一致。") }
                deferred = []
            case "resumeDeferred":
                guard shown == nil, !deferred.isEmpty, e.presentation == nil, e.ratingID == nil else { throw ExamError.invalid("宝典暂缓队列恢复事件无效。") }
                deferred = []
            case "show":
                guard shown == nil, let p = e.presentation, e.ratingID == nil,
                      record.cardOrder.contains(p.cardID), record.definitions[p.definitionID]?.id == p.cardID,
                      handbookDate(p.shownAt), p.shownAt <= e.at else { throw ExamError.invalid("宝典显示断点无效。") }
                if let prior = bookmarks.removeValue(forKey: p.cardID) { guard prior == p else { throw ExamError.invalid("宝典暂缓断点被改写。") } }
                else { guard knownTokens[p.id] == nil, !p.revealed, p.shownAt == e.at else { throw ExamError.invalid("宝典显示身份重复。") } }
                knownTokens[p.id] = p; shown = p
            case "reveal":
                guard var prior = shown, !prior.revealed, let p = e.presentation, e.ratingID == nil else { throw ExamError.invalid("宝典翻面事件无效。") }
                prior.revealed = true; guard prior == p else { throw ExamError.invalid("宝典翻面与卡片身份不符。") }; shown = p
            case "postpone":
                guard let prior = shown, let p = e.presentation, prior == p, e.ratingID == nil else { throw ExamError.invalid("宝典暂缓事件无效。") }
                bookmarks[p.cardID] = p; if !deferred.contains(p.cardID) { deferred.append(p.cardID) }; shown = nil
            case "rate":
                guard let p = shown, p.revealed, p == e.presentation, let id = e.ratingID,
                      let r = ratingsByID[id], r.presentationID == p.id, r.cardID == p.cardID,
                      r.definitionID == p.definitionID, r.at == e.at else { throw ExamError.invalid("宝典自评没有对应的已翻面卡片。") }
                rated.append(id); shown = nil; bookmarks.removeValue(forKey: p.cardID); deferred.removeAll { $0 == p.cardID }
            default: throw ExamError.invalid("未知宝典学习事件，原档案保留。")
            }
        }
        guard rated == record.ratings.map(\.id), shown == record.presentation, bookmarks == record.bookmarks,
              deferred == record.deferredCardIDs, record.lastObservedAt == record.events.last?.at else {
            throw ExamError.invalid("宝典断点、暂缓队列或自评与事件日志不一致。")
        }
    }
}

private func handbookText(_ value: String, _ limit: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
}
private func handbookDate(_ value: Date) -> Bool {
    value.timeIntervalSince1970.isFinite && (1_500_000_000...5_000_000_000).contains(value.timeIntervalSince1970)
}
private func handbookHash<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return StudySHA256.hex((try? encoder.encode(value)) ?? Data())
}
