import Foundation
import StudyCore
struct MathRichBlock: Codable { enum Kind: String, Codable { case text, math }; var kind: Kind; var value: String }
struct MathGuideOption: Codable { var label: String; var blocks: [MathRichBlock] }
struct MathGuideCard: Codable, Identifiable { var id: String; var title: String; var prompt: [MathRichBlock]; var answer: [MathRichBlock]; var detail: [MathRichBlock]; var syllabusIDs: [Int]; var sourceMethodIDs: [String] }
struct MathGuideQuestion: Codable { var questionID: String; var sourceTextSHA256: String; var stem: [MathRichBlock]; var options: [MathGuideOption]; var answer: [MathRichBlock]; var keyStep: [MathRichBlock]; var details: [MathRichBlock]; var hint: [MathRichBlock]; var cardIDs: [String]; var requiresDiagram: Bool; var diagramVisuals: [MathVisual]; var notes: [String]; var practiceBlockedReason: String? = nil
    var practiceAllowed: Bool { practiceBlockedReason?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false }
}
struct MathGuide: Codable {
    var format: String; var id: String; var version: String; var baseCourseID: String; var basePackageSHA256: String
    var cards: [MathGuideCard]; var questions: [MathGuideQuestion]
    static func sourceDigest(_ q: MathQuestion) -> String { StudySHA256.hex(Data(((q.questionText ?? "")+"\u{001f}"+(q.answerText ?? "")+"\u{001f}"+(q.solutionNote ?? "")).utf8)) }
    func validate(content: MathContent, packageSHA256: String) throws {
        guard format == "xkl-math-guide-v1", Self.identifier(id), Self.identifier(version),
              baseCourseID == content.id,
              basePackageSHA256.count == 64, basePackageSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), packageSHA256 == basePackageSHA256,
              Set(cards.map(\.id)).count == cards.count, Set(questions.map(\.questionID)).count == questions.count else { throw MathFailure.invalid("导学包课程或基线摘要不匹配。") }
        let cardIDs=Set(cards.map(\.id)), assets=Set(content.assets.map(\.id)), syllabus=Set(content.syllabus.map(\.id))
        for c in cards { guard !c.id.isEmpty, !c.title.isEmpty, !c.prompt.isEmpty, !c.answer.isEmpty, Set(c.syllabusIDs).isSubset(of:syllabus) else { throw MathFailure.invalid("知识卡引用无效。") }; try Self.blocks(c.prompt+c.answer+c.detail) }
        for g in questions {
            guard let q=content.questions.first(where: { $0.id == g.questionID }), g.sourceTextSHA256 == Self.sourceDigest(q), (g.practiceBlockedReason?.utf8.count ?? 0) <= 4096, !g.stem.isEmpty, !g.answer.isEmpty, Set(g.options.map(\.label)).count == g.options.count, Set(g.cardIDs).isSubset(of:cardIDs), !g.requiresDiagram || !g.diagramVisuals.isEmpty else { throw MathFailure.invalid("导学题源文本或知识卡引用不匹配。") }
            try Self.blocks(g.stem+g.options.flatMap(\.blocks)+g.answer+g.keyStep+g.details+g.hint)
            for visual in g.diagramVisuals { let c=visual.normalizedCrop; guard assets.contains(visual.assetID), c.count == 4, c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), c[2] > 0, c[3] > 0, c[0]+c[2] <= 1.000001, c[1]+c[3] <= 1.000001 else { throw MathFailure.invalid("导学图裁区无效。") } }
        }
    }
    private static func identifier(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func blocks(_ blocks: [MathRichBlock]) throws { guard blocks.count < 10000, blocks.allSatisfy({ !$0.value.isEmpty && $0.value.utf8.count <= 100000 }) else { throw MathFailure.invalid("导学排版块无效。") } }
}
