import Foundation
import StudyCore

/// A new knowledge-point curriculum. Legacy recall IDs/grades are archival only.
struct KnowledgeCourse: Codable, Equatable {
    struct Section: Codable, Equatable { let title: String; let body: String }
    struct Source: Codable, Equatable { let documentID: String; let title: String; let page: Int }
    struct Check: Codable, Equatable, Identifiable {
        struct Choice: Codable, Equatable, Identifiable { let id: String; let text: String; let feedback: String }
        let id: String; let prompt: String; let choices: [Choice]; let answerID: String; let explanation: String
    }
    struct Point: Codable, Equatable, Identifiable {
        let id: String; let title: String; let goal: String
        let prerequisites: [String]; let sections: [Section]; let keyFacts: [String]
        let example: ProfessionalCardLesson.Example; let checks: [Check]; let sources: [Source]
        let legacyEvidenceCardIDs: [String]
    }
    struct QuestionMapping: Codable, Equatable, Identifiable {
        let id: String; let documentID: String; let book: String; let page: Int
        let knowledgeIDs: [String]; let method: String; let status: String
        var questionText: String? = nil
        var label: String? = nil
    }
    struct Document:Codable,Equatable,Identifiable {
        struct Page:Codable,Equatable {let number:Int;let asset:ProfessionalSourceFileAsset}
        let id:String;let title:String;let fileName:String;let sha256:String;let bytes:Int
        var pages:[Page]=[]
    }
    let format: String; let id: String; let subject: ConceptSubject; let bankSHA256: String
    let retiredLegacyCards: Bool; let points: [Point]; let questionMappings: [QuestionMapping]
    var sourceDocuments:[Document]=[]

    func validate(bank: ConceptBank, teaching: ConceptTeaching) throws {
        func valid(_ s: String,_ max: Int)->Bool { !s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.count<=max }
        guard format=="knowledge-course-v1", retiredLegacyCards, subject.bankID==bank.id,
              bankSHA256==teaching.bankSHA256, valid(id,100), (1...256).contains(points.count),
              Set(points.map(\.id)).count==points.count else { throw ExamError.invalid("知识点课程身份不一致；旧记录保留。") }
        let old=Set((teaching.primaryRecallDeck?.cards.map(\.id) ?? [])+(teaching.recallGroups ?? []).flatMap { $0.recallCards.map(\.id) })
        var earlier=Set<String>(),checkIDs=Set<String>()
        let pointIDs=Set(points.map(\.id))
        for p in points {
            guard valid(p.id,120),valid(p.title,120),valid(p.goal,600),
                  Set(p.prerequisites).count==p.prerequisites.count,Set(p.prerequisites).isSubset(of:pointIDs),!p.prerequisites.contains(p.id),
                  (2...8).contains(p.sections.count),p.sections.allSatisfy({ valid($0.title,120) && valid($0.body,1800) }),
                  (1...24).contains(p.keyFacts.count),p.keyFacts.allSatisfy({valid($0,1500)}),
                  valid(p.example.prompt,1600),(2...10).contains(p.example.steps.count),p.example.steps.allSatisfy({valid($0,1600)}),valid(p.example.answer,1600),
                  (2...6).contains(p.checks.count),!p.sources.isEmpty,p.sources.allSatisfy({valid($0.documentID,30) && valid($0.title,300) && $0.page>0}),
                  Set(p.legacyEvidenceCardIDs).isSubset(of:old) else { throw ExamError.invalid("知识点缺少可读讲解、前置关系、例题或来源。") }
            for q in p.checks {
                guard valid(q.id,140),checkIDs.insert(q.id).inserted,valid(q.prompt,2000),
                      (2...6).contains(q.choices.count),Set(q.choices.map(\.id)).count==q.choices.count,
                      q.choices.contains(where:{$0.id==q.answerID}),q.choices.allSatisfy({valid($0.id,30) && valid($0.text,800) && valid($0.feedback,1500)}),
                      valid(q.explanation,2000) else { throw ExamError.invalid("知识点诊断题不完整或重复。") }
            }
            earlier.insert(p.id)
        }
        var visiting=Set<String>(),visited=Set<String>()
        func visit(_ id:String)throws {
            if visited.contains(id){return}
            guard visiting.insert(id).inserted else{throw ExamError.invalid("知识点前置关系存在循环。")}
            for parent in point(id)!.prerequisites{try visit(parent)}
            visiting.remove(id);visited.insert(id)
        }
        for p in points{try visit(p.id)}
        guard questionMappings.count<=2500,Set(questionMappings.map(\.id)).count==questionMappings.count else { throw ExamError.invalid("题库知识点对应重复。") }
        for m in questionMappings {
            guard valid(m.id,180),valid(m.documentID,30),valid(m.book,80),m.page>0,valid(m.method,2500),
                  ["supported","mapped","method_gap","source_pending","out_of_scope"].contains(m.status),
                  Set(m.knowledgeIDs).isSubset(of:earlier),!["supported","mapped"].contains(m.status) || !m.knowledgeIDs.isEmpty else {
                throw ExamError.invalid("题库与知识点对应关系不完整。")
            }
        }
        guard Set(sourceDocuments.map(\.id)).count==sourceDocuments.count,sourceDocuments.allSatisfy({
            valid($0.id,30) && valid($0.title,300) && $0.fileName==$0.id+".pdf" && !$0.id.contains("/") && !$0.id.contains("\\") && !$0.id.contains("..") && ExamContent.isHash($0.sha256) && (1...268435456).contains($0.bytes)
        }) else{throw ExamError.invalid("知识点来源文档清单不完整。")}
        for doc in sourceDocuments {
            guard Set(doc.pages.map(\.number)).count==doc.pages.count,doc.pages.allSatisfy({$0.number>0}) else{throw ExamError.invalid("资料页码重复或无效。")}
            for page in doc.pages {try page.asset.validateMetadata()}
        }
        try recallDeck(bankID:bank.id).validate()
    }
    func point(_ id:String)->Point? { points.first {$0.id==id} }
    func recallDeck(bankID:String)->RecallDeck {
        RecallDeck(subject:subject,bankID:bankID,cards:points.map { p in
            RecallDeck.Item(conceptID:p.id,conceptTitle:p.title,card:RecallCard(id:p.id+":knowledge-v1",
                prompt:"说清“\(p.title)”的意思，并举一个适用的例子。",answer:p.sections[0].body,
                detail:p.keyFacts.joined(separator:"\n")+"\n\n讲义出处：\n"+p.sources.map { "\($0.title) PDF第\($0.page)页" }.joined(separator:"\n")))
        })
    }
}
