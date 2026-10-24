import Foundation
import StudyCore

/// Optional authoring schema; legacy lessons decode with no guide.
struct ConceptGuide: Codable, Equatable {
    let version: Int
    let goal: String
    let referenceQuestionIDs: [String]
    let relatedConceptIDs: [String]
    let remember: [Recall]
    let steps: [Step]
    struct Recall: Codable, Equatable { let prompt: String; let answer: String }
    struct Step: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let body: String
        var visual: Visual? = nil
        var check: Check? = nil
        var diagram: ConceptDiagram? = nil
    }
    struct Visual: Codable, Equatable {
        let kind: String
        let items: [Item]
        struct Item: Codable, Equatable { let label: String; let detail: String }
    }
    struct Check: Codable, Equatable {
        let prompt: String
        let options: [Option]
        let answerID: String
        let repairStepID: String
        struct Option: Codable, Equatable, Identifiable {
            let id: String
            let text: String
            let feedback: String
        }
    }
    static let recallStepID = "__remember"
    func validate(conceptID: String, bank: ConceptBank) throws {
        func text(_ value: String, _ limit: Int = 800) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
        }
        func unique(_ values: [String]) -> Bool { Set(values).count == values.count }
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 80 && value != Self.recallStepID &&
            value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
        }
        let active = bank.concepts.filter { !bank.activeQuestions(in: $0).isEmpty }
        guard let concept = active.first(where: { $0.id == conceptID }), version == 1,
              text(goal), (1...4).contains(referenceQuestionIDs.count), unique(referenceQuestionIDs),
              Set(referenceQuestionIDs).isSubset(of: Set(bank.activeQuestions(in: concept).map(\.id))),
              relatedConceptIDs.count <= 3, unique(relatedConceptIDs), !relatedConceptIDs.contains(conceptID),
              Set(relatedConceptIDs).isSubset(of: Set(active.map(\.id))),
              (2...4).contains(remember.count), remember.allSatisfy({ text($0.prompt) && text($0.answer) }),
              (4...7).contains(steps.count), unique(steps.map(\.id)),
              (1...3).contains(steps.filter { $0.check != nil }.count),
              steps.contains(where: { $0.visual != nil }) else {
            throw ExamError.invalid("分步讲解版本、考点或参考题目无效。")
        }
        for (index, step) in steps.enumerated() {
            guard identifier(step.id), text(step.title), text(step.body, 220) else {
                throw ExamError.invalid("分步讲解步骤标识或正文无效。")
            }
            if let diagram = step.diagram { try diagram.validate() }
            if let visual = step.visual {
                guard ["flow", "compare"].contains(visual.kind), (2...4).contains(visual.items.count),
                      visual.items.allSatisfy({ text($0.label, 18) && text($0.detail, 65) }) else {
                    throw ExamError.invalid("讲解关系图格式无效。")
                }
            }
            if let check = step.check {
                guard text(check.prompt), (2...4).contains(check.options.count),
                      unique(check.options.map(\.id)),
                      check.options.allSatisfy({ identifier($0.id) && text($0.text) && text($0.feedback) }),
                      check.options.contains(where: { $0.id == check.answerID }),
                      steps.prefix(index + 1).contains(where: { $0.id == check.repairStepID }) else {
                    throw ExamError.invalid("讲解小检查的选项、反馈或回看步骤无效。")
                }
            }
        }
    }
}

struct ConceptGuidancePosition: Codable, Equatable {
    let sessionID: UUID
    let conceptID: String
    let bankSHA256: String
    let teachingSHA256: String
    let presentationID: UUID?
    var stepID: String
    var choices: [String: String] = [:]
    var revealedRecall: [Int] = []
    var completed = false
    var key: String { Self.key(conceptID: conceptID, teaching: teachingSHA256) }
    static func key(conceptID: String, teaching: String) -> String { teaching + ":" + conceptID }
}

/// A supplementary event never contains a grade, due day, or formal attempt.
struct ConceptGuidanceEvent: Codable, Equatable, Identifiable {
    let eventID: UUID
    var id: UUID { eventID }
    let sequence: Int
    let kind: String
    let sessionID: UUID
    let conceptID: String
    let bankSHA256: String
    let teachingSHA256: String
    let stepID: String
    let choiceID: String?
    let correct: Bool?
    let recallIndex: Int?
    let presentationID: UUID?
    let recordedAt: Date
}

struct ConceptGuidanceRecord: Codable, Equatable {
    var format = "xkl-concept-guidance-v1"
    let subject: ConceptSubject
    var nextSequence = 1
    var events: [ConceptGuidanceEvent] = []
    var volumes: [ConceptVolume] = []
    var positions: [String: ConceptGuidancePosition] = [:]
    var activeKey: String?
    var active: ConceptGuidancePosition? { activeKey.flatMap { positions[$0] } }

    func validateHeader() throws {
        guard format == "xkl-concept-guidance-v1" else { throw ExamError.invalid("讲解记录版本无效。") }
        var expected = 1
        for ref in volumes {
            guard ExamContent.isHash(ref.sha256), ref.first == expected, ref.count == 1_000,
                  ref.last == ref.first + ref.count - 1 else { throw ExamError.invalid("讲解分卷顺序无效。") }
            expected = ref.last + 1
        }
        guard events.count <= 1_000 else { throw ExamError.invalid("讲解当前日志过长。") }
        for event in events {
            guard event.sequence == expected else { throw ExamError.invalid("讲解日志序号不连续。") }
            expected += 1
        }
        guard expected == nextSequence, activeKey == nil || positions[activeKey!] != nil else {
            throw ExamError.invalid("讲解恢复位置或末尾无效。")
        }
    }

    /// Used both for live actions and full disk replay. References are checked
    /// against the exact immutable teaching version used for this event.
    mutating func apply(_ event: ConceptGuidanceEvent, guide: ConceptGuide, bankHash: String) throws {
        guard event.sequence == nextSequence, event.bankSHA256 == bankHash,
              ExamContent.isHash(event.teachingSHA256), ExamContent.isHash(bankHash),
              event.recordedAt.timeIntervalSince1970.isFinite else { throw ExamError.invalid("讲解事件身份无效。") }
        let key = ConceptGuidancePosition.key(conceptID: event.conceptID, teaching: event.teachingSHA256)
        var position: ConceptGuidancePosition
        if event.kind == "open" {
            if let old = positions[key], !old.completed {
                guard old.sessionID == event.sessionID, old.presentationID == event.presentationID,
                      old.stepID == event.stepID else { throw ExamError.invalid("讲解断点不能被覆盖。") }
                position = old
            } else {
                guard guide.steps.first?.id == event.stepID else { throw ExamError.invalid("讲解起点无效。") }
                position = ConceptGuidancePosition(sessionID: event.sessionID, conceptID: event.conceptID,
                    bankSHA256: bankHash, teachingSHA256: event.teachingSHA256,
                    presentationID: event.presentationID, stepID: event.stepID)
            }
            guard event.choiceID == nil, event.correct == nil, event.recallIndex == nil else {
                throw ExamError.invalid("讲解打开事件包含无效作答。")
            }
            activeKey = key
        } else {
            guard let old = positions[key], activeKey == key, !old.completed,
                  old.sessionID == event.sessionID, old.presentationID == event.presentationID else {
                throw ExamError.invalid("讲解事件未对应当前断点。")
            }
            position = old
            let index = guide.steps.firstIndex { $0.id == old.stepID } ?? guide.steps.count
            switch event.kind {
            case "step":
                let target = guide.steps.firstIndex { $0.id == event.stepID } ?? (event.stepID == ConceptGuide.recallStepID ? guide.steps.count : -1)
                let repair = index < guide.steps.count ? guide.steps[index].check : nil
                let isRepair = repair.map { $0.repairStepID == event.stepID && old.choices[old.stepID] != nil && old.choices[old.stepID] != $0.answerID } ?? false
                guard target >= 0, abs(target - index) == 1 || isRepair,
                      target <= index || index >= guide.steps.count || guide.steps[index].check == nil || old.choices[old.stepID] != nil else {
                    throw ExamError.invalid("请先完成本步小检查，再继续讲解。")
                }
                position.stepID = event.stepID
            case "answer":
                guard event.stepID == old.stepID, index < guide.steps.count,
                      let check = guide.steps[index].check, let choice = event.choiceID,
                      check.options.contains(where: { $0.id == choice }),
                      event.correct == (choice == check.answerID), event.recallIndex == nil else {
                    throw ExamError.invalid("讲解作答或判定无效。")
                }
                position.choices[event.stepID] = choice
            case "remember":
                guard old.stepID == ConceptGuide.recallStepID, event.stepID == old.stepID,
                      let recall = event.recallIndex, guide.remember.indices.contains(recall),
                      !old.revealedRecall.contains(recall), event.choiceID == nil, event.correct == nil else {
                    throw ExamError.invalid("回忆卡记录无效。")
                }
                position.revealedRecall.append(recall)
            case "finish":
                guard old.stepID == ConceptGuide.recallStepID, event.stepID == old.stepID else {
                    throw ExamError.invalid("请读到回忆核对页后结束。")
                }
                position.completed = true
                activeKey = nil
            case "leave":
                guard event.stepID == old.stepID else { throw ExamError.invalid("讲解离开位置无效。") }
                activeKey = nil
            default: throw ExamError.invalid("未知的讲解事件。")
            }
            if !["answer", "remember"].contains(event.kind) {
                guard event.choiceID == nil, event.correct == nil, event.recallIndex == nil else {
                    throw ExamError.invalid("讲解导航包含无效作答。")
                }
            }
        }
        positions[key] = position
        events.append(event)
        nextSequence += 1
    }
}
