import Foundation

/// Read-only provenance and navigation. Leaves never become formal attempts.
struct ConceptSyllabusTree: Codable, Equatable {
    let version: Int
    let title: String
    let outlineSource: String
    let frequencyNote: String
    let sources: [Source]
    let branches: [Branch]
    let topics: [Topic]
    let leaves: [Leaf]

    struct Source: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let kind: String
        let edition: String
        let sha256: String
        let fileName: String
        var paperNumber: Int? = nil
        var password: String? = nil
    }
    struct Branch: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let syllabusText: String
        let scope: String
    }
    struct Topic: Codable, Equatable, Identifiable {
        let id: String
        let branchID: String
        let title: String
        let conceptIDs: [String]
        var coverageNote: String? = nil
    }
    struct Leaf: Codable, Equatable, Identifiable {
        let id: String
        let sourceID: String
        let topicID: String
        let number: String
        let page: Int
        let prompt: String
        let options: [String]
        var points: Double? = nil
        var duplicateGroup: String? = nil
        let verification: String
        let linkedQuestionIDs: [String]
    }

    struct Statistics: Equatable {
        let bookCount: Int
        let uniqueBookCount: Int
        let mockCount: Int
        let uniqueMockCount: Int
        let papers: [Int]
        let pendingCount: Int
        var frequencyBand: String {
            switch papers.count {
            case 4...6: return "高频"
            case 2...3: return "中频"
            case 1: return "低频"
            default: return "未见"
            }
        }
        var total: Int { bookCount + mockCount }
    }

    static func validPDFFileName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 240 && value.lowercased().hasSuffix(".pdf") &&
        !value.contains("/") && !value.contains("\\") && !value.contains(":") &&
        value != ".pdf" && !value.hasPrefix(".") &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    func validate(bank: ConceptBank) throws {
        func text(_ value: String, _ limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
        }
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 120 && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
            }
        }
        func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count }
        guard version == 1, text(title, 120), text(outlineSource, 2_000), outlineSource.contains("2027"),
              text(frequencyNote, 1_200), (1...64).contains(sources.count), (1...80).contains(branches.count),
              topics.count <= 400, leaves.count <= 12_000,
              unique(sources.map(\.id)), unique(branches.map(\.id)), unique(topics.map(\.id)), unique(leaves.map(\.id)) else {
            throw ExamError.invalid("考纲树版本、来源说明或条目数量无效。")
        }
        var sourceByName: [String: Source] = [:]
        for source in sources {
            let paperValid = source.kind == "mock" ? source.paperNumber.map { (1...6).contains($0) } == true : source.paperNumber == nil
            guard identifier(source.id), text(source.title, 240), ["book", "mock"].contains(source.kind),
                  text(source.edition, 240),
                  (source.edition.range(of: "[0-9]{4}", options: .regularExpression) != nil ||
                   source.edition.contains("年份未标注") || source.edition.contains("年份未知")),
                  ExamContent.isHash(source.sha256), Self.validPDFFileName(source.fileName), paperValid,
                  source.password.map({ !$0.isEmpty && $0.count <= 120 }) ?? true else {
                throw ExamError.invalid("考纲树资料版本、PDF名称或模拟卷编号无效。")
            }
            let key = source.fileName.lowercased()
            if let old = sourceByName[key] {
                guard old.sha256 == source.sha256, old.password == source.password else {
                    throw ExamError.invalid("同名PDF不能指向不同资料版本。")
                }
            }
            sourceByName[key] = source
        }
        let sourceIDs = Set(sources.map(\.id)), branchIDs = Set(branches.map(\.id)), topicIDs = Set(topics.map(\.id))
        let activeConceptIDs = Set(bank.concepts.filter { !bank.activeQuestions(in: $0).isEmpty }.map(\.id))
        let questionIDs = Set(bank.concepts.flatMap { $0.questions.map(\.id) })
        for branch in branches {
            guard identifier(branch.id), text(branch.title, 160), text(branch.syllabusText, 4_000),
                  ["mainline", "related", "archived"].contains(branch.scope) else {
                throw ExamError.invalid("考纲分支名称、范围或说明无效。")
            }
        }
        for topic in topics {
            guard identifier(topic.id), branchIDs.contains(topic.branchID), text(topic.title, 160),
                  topic.conceptIDs.count <= 12, unique(topic.conceptIDs), Set(topic.conceptIDs).isSubset(of: activeConceptIDs),
                  topic.coverageNote.map({ text($0, 1_000) }) ?? true else {
                throw ExamError.invalid("考点未对应有效考纲分支或当前讲解。")
            }
        }
        for leaf in leaves {
            guard identifier(leaf.id), sourceIDs.contains(leaf.sourceID), topicIDs.contains(leaf.topicID),
                  text(leaf.number, 80), (1...5_000).contains(leaf.page), text(leaf.prompt, 12_000),
                  leaf.options.count <= 16, leaf.options.allSatisfy({ text($0, 4_000) }),
                  leaf.points.map({ $0.isFinite && $0 > 0 && $0 <= 100 }) ?? true,
                  leaf.duplicateGroup.map(identifier) ?? true,
                  ["sourcePending", "linkedReviewed"].contains(leaf.verification),
                  leaf.linkedQuestionIDs.count <= 16, unique(leaf.linkedQuestionIDs),
                  Set(leaf.linkedQuestionIDs).isSubset(of: questionIDs),
                  (leaf.verification == "linkedReviewed") == !leaf.linkedQuestionIDs.isEmpty else {
                throw ExamError.invalid("资料原题的来源、页码、核对标记或题目关联无效。")
            }
        }
    }

    func topicLeaves(_ topicID: String) -> [Leaf] { leaves.filter { $0.topicID == topicID } }
    func branchLeaves(_ branchID: String) -> [Leaf] {
        let ids = Set(topics.filter { $0.branchID == branchID }.map(\.id))
        return leaves.filter { ids.contains($0.topicID) }
    }
    func statistics(for selected: [Leaf]) -> Statistics {
        let sourceLookup = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let books = selected.filter { sourceLookup[$0.sourceID]?.kind == "book" }
        let mocks = selected.filter { sourceLookup[$0.sourceID]?.kind == "mock" }
        func deduplicated(_ items: [Leaf]) -> Int {
            Set(items.map { leaf in leaf.duplicateGroup.map { "group:" + $0 } ?? "leaf:" + leaf.id }).count
        }
        return Statistics(bookCount: books.count, uniqueBookCount: deduplicated(books),
                          mockCount: mocks.count, uniqueMockCount: deduplicated(mocks),
                          papers: Set(mocks.compactMap { sourceLookup[$0.sourceID]?.paperNumber }).sorted(),
                          pendingCount: selected.filter { $0.verification == "sourcePending" }.count)
    }
}
