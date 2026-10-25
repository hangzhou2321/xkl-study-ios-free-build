import Foundation

/// Presentation metadata only; never part of RecallCard or RecallDeck identity.
struct ProfessionalCardPriority: Codable, Equatable {
    let cardID: String
    let sourceCardDigest: String
    let level: String
    let classificationBasis: String
    let reason: String
    let sourceQuestionIDs: [String]

    enum CodingKeys:String,CodingKey { case cardID,sourceCardDigest,level,classificationBasis,reason,sourceQuestionIDs }

    var title: String {
        switch level { case "priority": return "优先掌握"; case "regular": return "常规掌握"; default: return "拓展选学" }
    }
    var basisTitle: String {
        switch classificationBasis {
        case "foundation": return "基础框架"
        case "prerequisite": return "后续学习的前提"
        case "reusable_method": return "多题共用的方法"
        case "local_detail": return "具体条件与应用细节"
        default: return "当前范围之外的拓展"
        }
    }
    static func validateAll(_ values:[Self],bank:ConceptBank,teaching:ConceptTeaching) throws {
        guard teaching.hasCompleteProfessionalExtension,let deck=teaching.primaryRecallDeck,let plan=teaching.studyPlan else {
            throw ExamError.invalid("卡片优先级缺少完整课程依据。")
        }
        let cards=deck.cards.map(\.card)+(teaching.recallGroups ?? []).flatMap(\.recallCards)
        let byID=Dictionary(cards.map { ($0.id,$0) },uniquingKeysWith: { first,_ in first })
        guard byID.count == cards.count,values.count == cards.count,Set(values.map(\.cardID)).count == values.count,Set(values.map(\.cardID)) == Set(byID.keys) else {
            throw ExamError.invalid("卡片优先级必须逐一覆盖完整卡组，且不能重复。")
        }
        let mainline=Set(plan.mainlineCardIDs+plan.supplementSelections.flatMap(\.mainlineCardIDs))
        let originals=Set((teaching.sourceLeaves ?? []).filter { $0.status == "verified" && $0.sourceStatus == .verified && $0.courseReadiness == .ready && $0.scope == .mainline }.compactMap(\.bankQuestionID).filter { bank.isActive($0) }).intersection(Set(plan.sourceQuestionIDs))
        let questions=Dictionary(uniqueKeysWithValues:bank.concepts.flatMap(\.questions).map { ($0.id,$0) })
        let links=Dictionary((teaching.questionLinks ?? []).map { ($0.questionID,$0) },uniquingKeysWith:{ first,_ in first })
        for value in values {
            guard let card=byID[value.cardID],value.sourceCardDigest == card.professionalDigest,
                  !value.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.reason.count<=300,
                  Set(value.sourceQuestionIDs).count == value.sourceQuestionIDs.count,Set(value.sourceQuestionIDs).isSubset(of:originals) else {
                throw ExamError.invalid("卡片优先级与原卡摘要、理由或讲义原题依据不匹配。")
            }
            let allowed:Set<String>
            switch value.level {
            case "priority": allowed=["foundation","prerequisite","reusable_method"]
            case "regular": allowed=["foundation","prerequisite","reusable_method","local_detail"]
            case "extension": allowed=["extension"]
            default: throw ExamError.invalid("卡片优先级不受支持。")
            }
            guard allowed.contains(value.classificationBasis),(value.level == "extension") == !mainline.contains(value.cardID) else {
                throw ExamError.invalid("卡片优先级与当前主线范围或分类依据不一致。")
            }
            for id in value.sourceQuestionIDs {
                guard let question=questions[id],let link=links[id],link.sourceQuestionDigest == question.professionalDigest,
                      link.primaryCardIDs.contains(value.cardID) || link.supplementCardIDs.contains(value.cardID) else {
                    throw ExamError.invalid("卡片优先级引用了未实际关联的原题。")
                }
            }
        }
    }
}

private struct ProfessionalPriorityJSONKey:CodingKey {
    let stringValue:String; let intValue:Int?=nil
    init?(stringValue:String) { self.stringValue=stringValue }
    init?(intValue:Int) { return nil }
}
extension ProfessionalCardPriority {
    init(from decoder:Decoder) throws {
        let keys=try decoder.container(keyedBy:ProfessionalPriorityJSONKey.self)
        let allowed:Set<String>=["cardID","sourceCardDigest","level","classificationBasis","reason","sourceQuestionIDs"]
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of:allowed) else { throw ExamError.invalid("卡片优先级含不支持的字段。") }
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(cardID:try c.decode(String.self,forKey:.cardID),sourceCardDigest:try c.decode(String.self,forKey:.sourceCardDigest),level:try c.decode(String.self,forKey:.level),classificationBasis:try c.decode(String.self,forKey:.classificationBasis),reason:try c.decode(String.self,forKey:.reason),sourceQuestionIDs:try c.decode([String].self,forKey:.sourceQuestionIDs))
    }
}
