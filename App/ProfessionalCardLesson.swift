import Foundation
import StudyCore

/// Explanation-only content. It has no scheduler ID, grade, or original-question identity.
struct ProfessionalCardLesson: Codable, Equatable, Identifiable {
    struct Binding: Codable, Equatable { let cardID: String; let sourceCardDigest: String }
    struct Example: Codable, Equatable {
        let prompt: String
        let steps: [String]
        let answer: String
    }
    let id: String
    let title: String
    let bindings: [Binding]
    let intuition: String
    let conditions: [String]
    let workedExample: Example
    let transferCheck: Example
    let transferHint: String
    let sourceRefs: [String]

    static func validateAll(_ lessons: [Self], deck: RecallDeck, groups: [SupplementRecallGroup]) throws {
        let all=deck.cards.map(\.card)+groups.flatMap(\.recallCards)
        guard Set(all.map(\.id)).count == all.count else { throw ExamError.invalid("讲解原卡身份重复。") }
        let cards=Dictionary(uniqueKeysWithValues:all.map { ($0.id,$0) })
        var bound=Set<String>()
        func text(_ value:String,_ maximum:Int)->Bool {
            !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count <= maximum
        }
        func example(_ value:Example)->Bool {
            text(value.prompt,1200) && (2...10).contains(value.steps.count)
                && value.steps.allSatisfy { text($0,1200) } && text(value.answer,1200)
        }
        guard lessons.count <= 200, Set(lessons.map(\.id)).count == lessons.count else {
            throw ExamError.invalid("讲解单元重复或过多。")
        }
        for lesson in lessons {
            guard text(lesson.id,120), lesson.id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
                  text(lesson.title,160), (1...80).contains(lesson.bindings.count),
                  text(lesson.intuition,2000), (1...6).contains(lesson.conditions.count),
                  lesson.conditions.allSatisfy({ text($0,1000) }), example(lesson.workedExample), example(lesson.transferCheck),
                  text(lesson.transferHint,1000), (1...8).contains(lesson.sourceRefs.count),
                  lesson.sourceRefs.allSatisfy({ text($0,1200) }),
                  lesson.workedExample.prompt != lesson.transferCheck.prompt else {
                throw ExamError.invalid("讲解缺少直观含义、条件、完整例题或换条件自检。")
            }
            for binding in lesson.bindings {
                guard let card=cards[binding.cardID], card.professionalDigest == binding.sourceCardDigest,
                      bound.insert(binding.cardID).inserted else {
                    throw ExamError.invalid("讲解绑定重复或与当前卡片摘要不一致，原进度保留。")
                }
            }
        }
    }
}

extension ConceptTeaching {
    func applicationLesson(for card: RecallCard)->ProfessionalCardLesson? {
        cardLessons?.first { lesson in lesson.bindings.contains { $0.cardID == card.id && $0.sourceCardDigest == card.professionalDigest } }
    }
}
