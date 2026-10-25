import Foundation
import StudyCore

/// A content-bound quarantine. Original questions, answers and past attempts stay intact.
struct ProfessionalQuestionPracticeNote: Codable, Equatable {
    let questionID: String
    let sourceQuestionDigest: String
    let status: String
    let reason: String
    let sourceRef: String
    let replacementQuestionIDs: [String]

    static func validateAll(_ notes: [Self], bank: ConceptBank) throws {
        let questions = bank.concepts.flatMap(\.questions)
        let allIDs = Set(questions.map(\.id))
        guard notes.count <= 5000, Set(notes.map(\.questionID)).count == notes.count else {
            throw ExamError.invalid("原题校勘提示重复或过多。")
        }
        for note in notes {
            guard let question = questions.first(where: { $0.id == note.questionID }),
                  question.professionalDigest == note.sourceQuestionDigest,
                  note.status == "hold", !note.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  note.reason.count <= 2000, !note.sourceRef.isEmpty, note.sourceRef.count <= 2000,
                  note.replacementQuestionIDs.count <= 12,
                  Set(note.replacementQuestionIDs).count == note.replacementQuestionIDs.count,
                  !note.replacementQuestionIDs.contains(note.questionID),
                  Set(note.replacementQuestionIDs).isSubset(of: allIDs) else {
                throw ExamError.invalid("原题校勘提示与原题摘要或替代题不一致。")
            }
        }
    }
}

struct ProfessionalSupplementSelection: Codable, Equatable {
    let groupID: String
    let mainlineCardIDs: [String]
    let relatedCardIDs: [String]
    enum CodingKeys: String, CodingKey { case groupID,mainlineCardIDs,relatedCardIDs }
}
struct ProfessionalStudyPlan: Codable, Equatable {
    let format: String
    let id: String
    let subject: ConceptSubject
    let basePrimaryDeckSHA256: String
    let mainlineCardIDs: [String]
    let relatedCardIDs: [String]
    let mainlineSupplementGroupIDs: [String]
    let relatedSupplementGroupIDs: [String]
    var supplementSelections: [ProfessionalSupplementSelection] = []
    let priorityConceptIDs: [String]
    let sourceQuestionIDs: [String]
    enum CodingKeys: String, CodingKey { case format,id,subject,basePrimaryDeckSHA256,mainlineCardIDs,relatedCardIDs,mainlineSupplementGroupIDs,relatedSupplementGroupIDs,supplementSelections,priorityConceptIDs,sourceQuestionIDs }

    func validate(bank: ConceptBank, teaching: ConceptTeaching, deck: RecallDeck) throws {
        let cards=mainlineCardIDs+relatedCardIDs, groups=mainlineSupplementGroupIDs+relatedSupplementGroupIDs
        guard format == "xkl-professional-plan-v1", !id.isEmpty, id.count <= 160,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              subject == deck.subject, bank.id == deck.bankID, basePrimaryDeckSHA256 == (try deck.hash),
              Set(cards).count == cards.count, Set(cards) == Set(deck.cards.map(\.id)),
              Set(mainlineSupplementGroupIDs).count == mainlineSupplementGroupIDs.count, Set(relatedSupplementGroupIDs).count == relatedSupplementGroupIDs.count,
              Set(groups) == Set((teaching.recallGroups ?? []).map(\.id)),
              Set(supplementSelections.map(\.groupID)).count == supplementSelections.count,
              Set(supplementSelections.map(\.groupID)) == Set((teaching.recallGroups ?? []).map(\.id)),
              Set(mainlineSupplementGroupIDs) == Set(supplementSelections.filter { !$0.mainlineCardIDs.isEmpty }.map(\.groupID)),
              Set(relatedSupplementGroupIDs) == Set(supplementSelections.filter { !$0.relatedCardIDs.isEmpty }.map(\.groupID)),
              Set(priorityConceptIDs).count == priorityConceptIDs.count, Set(priorityConceptIDs).isSubset(of:Set(bank.concepts.map(\.id))),
              Set(sourceQuestionIDs).count == sourceQuestionIDs.count, Set(sourceQuestionIDs).isSubset(of:Set(bank.concepts.flatMap { $0.questions.map(\.id) })),
              Set(sourceQuestionIDs).isSubset(of:Set((teaching.questionPresentations ?? []).map(\.questionID))) else {
            throw ExamError.invalid("专业课主线计划与冻结卡组或题源引用不匹配。")
        }
        for selection in supplementSelections {
            guard let group=(teaching.recallGroups ?? []).first(where: { $0.id == selection.groupID }) else { throw ExamError.invalid("补充卡选择引用未知分组。") }
            let ids=selection.mainlineCardIDs+selection.relatedCardIDs
            guard Set(ids).count == ids.count, Set(ids) == Set(group.recallCards.map(\.id)) else { throw ExamError.invalid("补充卡主线与拓展须逐组完整分区，不得丢卡或重复。") }
        }
    }
}

struct ProfessionalCardCorrection: Codable, Equatable {
    let cardID: String
    let sourceCardDigest: String
    let note: String
    let sourceRef: String
    enum CodingKeys: String, CodingKey { case cardID,sourceCardDigest,note,sourceRef }
    static func validateAll(_ notes: [Self], deck: RecallDeck, groups: [SupplementRecallGroup]) throws {
        let cards=deck.cards.map(\.card)+groups.flatMap(\.recallCards)
        guard notes.count <= 5000, Set(notes.map(\.cardID)).count == notes.count else { throw ExamError.invalid("卡片校勘注重复或过多。") }
        for note in notes {
            guard let card=cards.first(where: { $0.id == note.cardID }), card.professionalDigest == note.sourceCardDigest,
                  !note.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, note.note.count <= 4000,
                  !note.sourceRef.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, note.sourceRef.count <= 2000 else {
                throw ExamError.invalid("卡片校勘注与原卡摘要或来源不一致。")
            }
        }
    }
}

extension RecallCard {
    var professionalDigest: String {
        let values=[id,prompt,answer,detail ?? ""]
        return StudySHA256.hex(Data(values.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
}

private struct ProfessionalPlanJSONKey: CodingKey {
    let stringValue: String; var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue=stringValue }
    init?(intValue: Int) { return nil }
}
private func professionalPlanKeys(_ decoder: Decoder, allowed: [String]) throws {
    let container=try decoder.container(keyedBy:ProfessionalPlanJSONKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of:Set(allowed)) else { throw ExamError.invalid("专业课计划或校勘注含未知字段，拒绝忽略。") }
}
extension ProfessionalStudyPlan {
    init(from decoder: Decoder) throws {
        try professionalPlanKeys(decoder,allowed:["format","id","subject","basePrimaryDeckSHA256","mainlineCardIDs","relatedCardIDs","mainlineSupplementGroupIDs","relatedSupplementGroupIDs","supplementSelections","priorityConceptIDs","sourceQuestionIDs"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(format:try c.decode(String.self,forKey:.format),id:try c.decode(String.self,forKey:.id),subject:try c.decode(ConceptSubject.self,forKey:.subject),basePrimaryDeckSHA256:try c.decode(String.self,forKey:.basePrimaryDeckSHA256),mainlineCardIDs:try c.decode([String].self,forKey:.mainlineCardIDs),relatedCardIDs:try c.decode([String].self,forKey:.relatedCardIDs),mainlineSupplementGroupIDs:try c.decode([String].self,forKey:.mainlineSupplementGroupIDs),relatedSupplementGroupIDs:try c.decode([String].self,forKey:.relatedSupplementGroupIDs),supplementSelections:try c.decode([ProfessionalSupplementSelection].self,forKey:.supplementSelections),priorityConceptIDs:try c.decode([String].self,forKey:.priorityConceptIDs),sourceQuestionIDs:try c.decode([String].self,forKey:.sourceQuestionIDs))
    }
}
extension ProfessionalCardCorrection {
    init(from decoder: Decoder) throws {
        try professionalPlanKeys(decoder,allowed:["cardID","sourceCardDigest","note","sourceRef"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(cardID:try c.decode(String.self,forKey:.cardID),sourceCardDigest:try c.decode(String.self,forKey:.sourceCardDigest),note:try c.decode(String.self,forKey:.note),sourceRef:try c.decode(String.self,forKey:.sourceRef))
    }
}

extension ProfessionalSupplementSelection {
    init(from decoder: Decoder) throws {
        try professionalPlanKeys(decoder,allowed:["groupID","mainlineCardIDs","relatedCardIDs"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(groupID:try c.decode(String.self,forKey:.groupID),mainlineCardIDs:try c.decode([String].self,forKey:.mainlineCardIDs),relatedCardIDs:try c.decode([String].self,forKey:.relatedCardIDs))
    }
}
