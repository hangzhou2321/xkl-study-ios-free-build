import Foundation
import StudyCore

/// A new knowledge-point curriculum. Legacy recall IDs/grades are archival only.
struct KnowledgeCourse: Codable, Equatable {
    struct Section: Codable, Equatable {
        let title: String; let body: String
        var id:String? = nil
        var example:ProfessionalCardLesson.Example? = nil
        var diagram:ConceptDiagram? = nil
        var checkpointID:String? = nil
    }
    struct Source: Codable, Equatable { let documentID: String; let title: String; let page: Int }
    struct Check: Codable, Equatable, Identifiable {
        struct Choice: Codable, Equatable, Identifiable {
            let id: String; let text: String; let feedback: String
            var errorTag:String? = nil
            var repairSectionID:String? = nil
            var repairPointID:String? = nil
            var probeSkillID:String? = nil
        }
        struct Numeric:Codable,Equatable {
            let value:Double;let tolerance:Double;let unit:String
            var unitFactors:[String:Double]? = nil
            var requiresUnit:Bool? = nil
        }
        struct CommonError:Codable,Equatable {
            let value:Double;let feedback:String;let errorTag:String
            var repairSectionID:String? = nil
        }
        struct ExpressionError:Codable,Equatable {
            let forms:[String];let feedback:String;let errorTag:String
            var repairSectionID:String?=nil
            var repairPointID:String?=nil
            var probeSkillID:String?=nil
        }
        struct Expression:Codable,Equatable {
            let version:Int;let variables:[String];let expectedLHS:String?;let accepted:[String]
            var rejected:[ExpressionError]?=nil
        }
        let id: String; let prompt: String; let choices: [Choice]; let answerID: String; let explanation: String
        var purpose:String? = nil
        var skillID:String? = nil
        var family:String? = nil
        var hint:String? = nil
        var responseType:String? = nil
        var correctChoiceIDs:[String]? = nil
        var numeric:Numeric? = nil
        var commonErrors:[CommonError]? = nil
        var repairSectionID:String? = nil
        var relatedKnowledgeIDs:[String]? = nil
        var originalQuestionID:String? = nil
        var practiceStage:String? = nil
        var expression:Expression? = nil
        var steps:[Check]? = nil
        var methodIDs:[String]? = nil
        var stemID:String? = nil
        var exposureAliases:[String]? = nil
        var evidenceKind:String? = nil
    }
    struct Skill:Codable,Equatable,Identifiable {
        let id:String;let title:String;let lessonSectionID:String
        var practiceStages:[String]? = nil
        var independentEvidence:String? = nil
    }
    struct LegacyBaseline:Codable,Equatable {
        let checks:[Check];let sectionCount:Int
        var digest:String? = nil
        var sections:[Section]? = nil
        var example:ProfessionalCardLesson.Example? = nil
        var keyFacts:[String]? = nil
        var prerequisites:[String]? = nil
    }
    struct Point: Codable, Equatable, Identifiable {
        let id: String; let title: String; let goal: String
        let prerequisites: [String]; let sections: [Section]; let keyFacts: [String]
        let example: ProfessionalCardLesson.Example; let checks: [Check]; let sources: [Source]
        let legacyEvidenceCardIDs: [String]
        var skills:[Skill]? = nil
        var retiredChecks:[Check]? = nil
        var legacyBaseline:LegacyBaseline? = nil
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
        guard ["knowledge-course-v1","knowledge-course-v2"].contains(format), retiredLegacyCards, subject.bankID==bank.id,
              bankSHA256==teaching.bankSHA256, valid(id,100), (1...256).contains(points.count),
              Set(points.map(\.id)).count==points.count else { throw ExamError.invalid("知识点课程身份不一致；旧记录保留。") }
        let old=Set((teaching.primaryRecallDeck?.cards.map(\.id) ?? [])+(teaching.recallGroups ?? []).flatMap { $0.recallCards.map(\.id) })
        var earlier=Set<String>(),checkIDs=Set<String>()
        let pointIDs=Set(points.map(\.id))
        let methodPairs=points.flatMap{p in (p.skills?.map(\.id) ?? [p.id]).map{($0,p.id)}}
        let methodIDs=Set(methodPairs.map(\.0))
        guard methodIDs.count==methodPairs.count else{throw ExamError.invalid("不同知识点的方法身份重复。")}
        let methodOwners=Dictionary(uniqueKeysWithValues:methodPairs)
        for p in points {
            guard valid(p.id,120),valid(p.title,120),valid(p.goal,600),
                  Set(p.prerequisites).count==p.prerequisites.count,Set(p.prerequisites).isSubset(of:pointIDs),!p.prerequisites.contains(p.id),
                  (2...48).contains(p.sections.count),p.sections.allSatisfy({ valid($0.title,120) && valid($0.body,2400) }),
                  (1...24).contains(p.keyFacts.count),p.keyFacts.allSatisfy({valid($0,1500)}),
                  valid(p.example.prompt,1600),(2...10).contains(p.example.steps.count),p.example.steps.allSatisfy({valid($0,1600)}),valid(p.example.answer,1600),
                  (2...96).contains(p.checks.count),!p.sources.isEmpty,p.sources.allSatisfy({valid($0.documentID,30) && valid($0.title,300) && $0.page>0}),
                  Set(p.legacyEvidenceCardIDs).isSubset(of:old) else { throw ExamError.invalid("知识点缺少可读讲解、前置关系、例题或来源。") }
            let sectionIDs=Set(p.sections.enumerated().map { $0.element.id ?? "section-\($0.offset)" })
            guard sectionIDs.count==p.sections.count else{throw ExamError.invalid("教学小节身份重复。")}
            let skills=p.skills ?? []
            guard (p.skills==nil || (1...48).contains(skills.count)),Set(skills.map(\.id)).count==skills.count,skills.allSatisfy({valid($0.id,160) && valid($0.title,160) && sectionIDs.contains($0.lessonSectionID)}) else{throw ExamError.invalid("知识点内方法身份不完整。")}
            guard skills.allSatisfy({s in let stages=s.practiceStages ?? ["practice"];return !stages.isEmpty && Set(stages).count==stages.count && stages.allSatisfy{["practice","scaffold-high","scaffold-low"].contains($0)}}) else{throw ExamError.invalid("方法的练习梯度定义无效。")}
            guard skills.allSatisfy({$0.independentEvidence==nil || ["concept","steps"].contains($0.independentEvidence!)}) else{throw ExamError.invalid("独立证据要求无效。")}
            if format=="knowledge-course-v2" {
                guard !skills.isEmpty,p.checks.allSatisfy({$0.skillID != nil && $0.purpose != nil}),
                      p.checks.filter({$0.purpose != "guided"}).count>=2,p.checks.contains(where:{["transfer","original"].contains($0.purpose ?? "")}),
                      skills.allSatisfy({skill in p.checks.contains(where:{$0.skillID==skill.id && $0.purpose=="guided"}) && p.checks.contains(where:{$0.skillID==skill.id && $0.purpose != "guided"})}) else{throw ExamError.invalid("新课程每种方法需有练习和独立题，并含换条件或原题检验。")}
                for skill in skills {for stage in skill.practiceStages ?? ["practice"] {
                    guard p.checks.contains(where:{$0.skillID==skill.id && $0.purpose=="guided" && ($0.practiceStage ?? "practice")==stage}) else{throw ExamError.invalid("方法缺少所需梯度的练习。")}
                }}
            }
            for section in p.sections {
                if let diagram=section.diagram{try diagram.validate()}
                if let e=section.example{guard valid(e.prompt,1600),(2...10).contains(e.steps.count),e.steps.allSatisfy({valid($0,1600)}),valid(e.answer,1600) else{throw ExamError.invalid("分步例题不完整。")}}
                if let id=section.checkpointID{guard p.checks.contains(where:{$0.id==id}) else{throw ExamError.invalid("补步骤题不属于本知识点。")}}
            }
            for q in p.checks+(p.retiredChecks ?? []) {
                guard valid(q.id,140),checkIDs.insert(q.id).inserted,valid(q.prompt,2000),
                      valid(q.explanation,2000) else { throw ExamError.invalid("知识点诊断题不完整或重复。") }
                try q.validateResponse()
                var helpScope=Set([p.id]+(q.relatedKnowledgeIDs ?? [])),toVisit=Array(helpScope)
                while let id=toVisit.popLast(){for parent in point(id)?.prerequisites ?? []{if helpScope.insert(parent).inserted{toVisit.append(parent)}}}
                for component in [q]+(q.steps ?? []) {
                    guard Set(component.methodIDs ?? []).isSubset(of:methodIDs),Set((component.methodIDs ?? []).compactMap{methodOwners[$0]}).isSubset(of:helpScope),component.repairSectionID==nil || sectionIDs.contains(component.repairSectionID!) else{throw ExamError.invalid("步骤引用的方法、帮助范围或回补小节不存在。")}
                    for error in component.expression?.rejected ?? [] {
                        guard error.repairPointID==nil || helpScope.contains(error.repairPointID!),error.probeSkillID==nil || (error.repairPointID != nil && methodOwners[error.probeSkillID!]==error.repairPointID),error.repairSectionID==nil || sectionIDs.contains(error.repairSectionID!) else{throw ExamError.invalid("式子探针或回补位置不存在。")}
                    }
                    for choice in component.choices {
                        guard choice.repairSectionID==nil || sectionIDs.contains(choice.repairSectionID!),choice.repairPointID==nil || helpScope.contains(choice.repairPointID!),choice.probeSkillID==nil || (choice.repairPointID != nil && methodOwners[choice.probeSkillID!]==choice.repairPointID) else{throw ExamError.invalid("步骤选项的回补或探针引用无效。")}
                    }
                }
                guard q.skillID==nil || skills.contains(where:{$0.id==q.skillID}),
                      q.repairSectionID==nil || sectionIDs.contains(q.repairSectionID!),
                      Set(q.relatedKnowledgeIDs ?? []).isSubset(of:pointIDs) else{throw ExamError.invalid("小题的方法或回补位置不存在。")}
                for choice in q.choices {
                    guard choice.repairSectionID==nil || sectionIDs.contains(choice.repairSectionID!),choice.repairPointID==nil || pointIDs.contains(choice.repairPointID!) else{throw ExamError.invalid("错误回补入口不存在。")}
                }
                if let id=q.originalQuestionID{guard q.purpose=="original",questionMappings.contains(where:{$0.id==id && $0.status=="supported" && $0.knowledgeIDs.contains(p.id)}) else{throw ExamError.invalid("原题检验缺少可靠题源绑定。")}}
            }
            if let baseline=p.legacyBaseline {
                guard baseline.sectionCount>=2,(2...6).contains(baseline.checks.count),
                      baseline.checks.allSatisfy({old in (p.checks+(p.retiredChecks ?? [])).contains(where:{$0.id==old.id && (try? $0.gradingDigest()) == (try? old.gradingDigest())})}) else{throw ExamError.invalid("旧版诊断身份基线不匹配；原记录保留。")}
                if let digest=baseline.digest{guard ExamContent.isHash(digest),try KnowledgeLearningEngine.legacyDigest(pointID:p.id,checks:baseline.checks)==digest else{throw ExamError.invalid("旧题摘要与本机原算法不一致。")}}
                if let sections=baseline.sections {
                    guard sections.count==baseline.sectionCount,baseline.example != nil,baseline.keyFacts?.isEmpty==false,Set(baseline.prerequisites ?? []).isSubset(of:pointIDs) else{throw ExamError.invalid("旧讲解版本缺件，不能替换旧断点。")}
                }
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
    func affectedPoints(documentID:String,page:Int)->[String] {
        let exact=Array(Set(points.filter{$0.sources.contains{$0.documentID==documentID && $0.page==page}}.map(\.id)+questionMappings.filter{$0.documentID==documentID && $0.page==page}.flatMap(\.knowledgeIDs))).sorted()
        // A full-page browser may include continuation pages without a precise
        // point index. Preserve the help fact conservatively for this document.
        if !exact.isEmpty{return exact}
        let documentPoints=points.filter{$0.sources.contains{$0.documentID==documentID}}.map(\.id)
        return documentPoints.isEmpty ? points.map(\.id):documentPoints
    }
    func recallDeck(bankID:String)->RecallDeck {
        RecallDeck(subject:subject,bankID:bankID,cards:points.map { p in
            RecallDeck.Item(conceptID:p.id,conceptTitle:p.title,card:RecallCard(id:p.id+":knowledge-v1",
                prompt:"说清“\(p.title)”的意思，并举一个适用的例子。",answer:p.sections[0].body,
                detail:p.keyFacts.joined(separator:"\n")+"\n\n讲义出处：\n"+p.sources.map { "\($0.title) PDF第\($0.page)页" }.joined(separator:"\n")))
        })
    }
}
