import Foundation
import StudyCore

struct KnowledgeStepScore:Codable,Equatable {
    let id:String;let status:String;let response:String;let methodIDs:[String]
    var errorTag:String?=nil
}

extension KnowledgeCourse.Point {
    func inheritedPriorityTitles(_ values:[ProfessionalCardPriority])->[String] {
        let linked=values.filter{legacyEvidenceCardIDs.contains($0.cardID)}
        return ["priority","regular","extension"].compactMap{level in linked.first{$0.level==level}?.title}
    }
    var allChecks:[KnowledgeCourse.Check]{checks+(retiredChecks ?? [])}
    var lessonPageCount:Int{sections.count+2}
    var requiredSkillIDs:[String]{skills?.map(\.id) ?? [id]}
    func sectionIndex(_ id:String?)->Int? {
        guard let id else{return nil}
        return sections.enumerated().first{$0.element.id == id || ($0.element.id==nil && id=="section-\($0.offset)")}?.offset
    }
    func skill(_ q:KnowledgeCourse.Check)->String{q.skillID ?? id}
    func purpose(_ q:KnowledgeCourse.Check)->String {
        q.purpose ?? (allChecks.firstIndex(where:{$0.id==q.id})==0 ? "guided":"independent")
    }
}

extension KnowledgeCourse.Check {
    var type:String{responseType ?? "single"}
    var exposureIdentity:String{stemID ?? originalQuestionID ?? id}
    var exposureKeys:Set<String>{Set([id,exposureIdentity]+(exposureAliases ?? []))}
    var evidence:String{evidenceKind ?? (type=="structured" ? "steps":(type=="number" ? "result":(type=="expression" ? "relation":"concept")))}
    func gradingDigest()throws->String {
        var object:[String:Any]=["id":id,"prompt":prompt,"type":type,"answer":answerID,
            "choices":choices.sorted{$0.id<$1.id}.map{["id":$0.id,"text":$0.text]}]
        if let numeric {object["numeric"]=["value":numeric.value,"tolerance":numeric.tolerance,"unit":numeric.unit,"factors":numeric.unitFactors ?? [:],"requiresUnit":numeric.requiresUnit ?? false] as [String:Any]}
        if let correctChoiceIDs{object["correctChoices"]=correctChoiceIDs.sorted()}
        if let expression{object["expression"]=["version":expression.version,"variables":expression.variables.sorted(),"lhs":expression.expectedLHS ?? "","accepted":expression.accepted.sorted()] as [String:Any]}
        if let steps{object["steps"]=try steps.map{["id":$0.id,"grade":try $0.gradingDigest()]}}
        return StudySHA256.hex(try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]))
    }
    func validateResponse(depth:Int=0)throws {
        func good(_ s:String,_ n:Int)->Bool{!s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.count<=n}
        guard depth<=1,["single","multiple","number","expression","structured"].contains(type),purpose==nil || ["guided","independent","transfer","original","mixed"].contains(purpose!),
              hint==nil || good(hint!,1200),family==nil || good(family!,160),stemID==nil || good(stemID!,180),
              (exposureAliases ?? []).count<=16,(exposureAliases ?? []).allSatisfy({good($0,180)}),
              ["steps","result","relation","concept"].contains(evidence),evidence != "steps" || type=="structured",
              practiceStage==nil || ["practice","scaffold-high","scaffold-low"].contains(practiceStage!) else{throw ExamError.invalid("诊断形式或提示无效。")}
        if type=="structured" {
            guard depth==0,choices.isEmpty,let steps,(2...12).contains(steps.count),Set(steps.map(\.id)).count==steps.count,
                  steps.allSatisfy({good($0.id,40) && good($0.prompt,300) && good($0.explanation,2000) && $0.type != "structured"}) else{throw ExamError.invalid("分步骤题缺少可核对的条件、关系或结果。")}
            for step in steps{try step.validateResponse(depth:depth+1)}
        } else if type=="expression" {
            guard choices.isEmpty,let e=expression,e.version==1,(1...12).contains(e.variables.count),Set(e.variables).count==e.variables.count,
                  e.variables.allSatisfy({$0.range(of:"^[a-z][a-z0-9]{0,7}$",options:.regularExpression) != nil}),
                  e.expectedLHS==nil || e.variables.contains(e.expectedLHS!),
                  (1...24).contains(e.accepted.count),e.accepted.allSatisfy({good($0,300) && KnowledgeFormula.equivalent($0,to:$0,variables:e.variables,lhs:e.expectedLHS)==true}) else{throw ExamError.invalid("式子核对模板或变量定义无效。")}
            for error in e.rejected ?? [] {
                guard !error.forms.isEmpty,error.forms.count<=12,good(error.feedback,1500),good(error.errorTag,80),error.forms.allSatisfy({form in
                    good(form,300) && KnowledgeFormula.equivalent(form,to:form,variables:e.variables,lhs:e.expectedLHS)==true && !e.accepted.contains{KnowledgeFormula.equivalent(form,to:$0,variables:e.variables,lhs:e.expectedLHS)==true}
                }) else{throw ExamError.invalid("式子误区与正确模板冲突。")}
            }
        } else if type=="number" {
            guard choices.isEmpty,let n=numeric,n.value.isFinite,n.tolerance.isFinite,n.tolerance>=0,n.unit.count<=30,
                  (n.unitFactors ?? [:]).allSatisfy({!$0.key.isEmpty && $0.key.count<=30 && $0.value.isFinite && $0.value>0}),
                  (commonErrors ?? []).allSatisfy({$0.value.isFinite && good($0.feedback,1500) && good($0.errorTag,80)}) else{throw ExamError.invalid("数值题答案、单位或误区定义无效。")}
        } else {
            let ids=Set(choices.map(\.id))
            guard (2...6).contains(choices.count),ids.count==choices.count,
                  choices.allSatisfy({good($0.id,30) && good($0.text,800) && good($0.feedback,1500)}) else{throw ExamError.invalid("选项不完整。")}
            if type=="single"{guard ids.contains(answerID) else{throw ExamError.invalid("正确选项不存在。")}}
            else{guard let correctChoiceIDs,!correctChoiceIDs.isEmpty,Set(correctChoiceIDs).count==correctChoiceIDs.count,Set(correctChoiceIDs).isSubset(of:ids) else{throw ExamError.invalid("多选答案不完整。")}}
        }
    }
    func number(_ response:String)->Double? {
        guard let n=numeric,response.count<=100 else{return nil}
        let text=response.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"−",with:"-")
        let pattern="^([+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\\s*([^0-9\\s]*)$"
        guard let regex=try? NSRegularExpression(pattern:pattern),let m=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let vr=Range(m.range(at:1),in:text),let ur=Range(m.range(at:2),in:text),let value=Double(text[vr]),value.isFinite else{return nil}
        let unit=String(text[ur]);let factors=n.unitFactors ?? [n.unit:1]
        if unit.isEmpty{return n.requiresUnit==true ? nil:value}
        guard let factor=factors[unit] ?? (unit==n.unit ? 1:nil) else{return nil}
        let result=value*factor;return result.isFinite ? result:nil
    }
    func accepts(_ response:String)->Bool {
        if type=="structured" {
            guard let values=stepResponses(response),let steps,Set(values.keys)==Set(steps.map(\.id)) else{return false}
            return steps.allSatisfy{$0.accepts(values[$0.id] ?? "")}
        }
        if type=="expression"{return expressionStatus(response) != "pending"}
        if type=="number"{return number(response) != nil}
        if type=="single"{return choices.contains{$0.id==response}}
        let selected=response.split(separator:"|").map(String.init)
        return !selected.isEmpty && Set(selected).count==selected.count && Set(selected).isSubset(of:Set(choices.map(\.id)))
    }
    func correct(_ response:String)->Bool {
        if type=="structured",let values=stepResponses(response),let steps{return Set(values.keys)==Set(steps.map(\.id)) && steps.allSatisfy{$0.correct(values[$0.id] ?? "")}}
        if type=="expression"{return expressionStatus(response)=="correct"}
        if type=="number"{guard let n=numeric,let value=number(response) else{return false};return abs(value-n.value)<=max(n.tolerance,1e-10*abs(n.value))}
        if type=="multiple"{return accepts(response) && Set(response.split(separator:"|").map(String.init))==Set(correctChoiceIDs ?? [])}
        return response==answerID
    }
    func feedback(_ response:String)->String {
        if type=="expression",let error=expressionError(response){return error.feedback}
        if type=="structured",let values=stepResponses(response),let step=steps?.first(where:{!$0.correct(values[$0.id] ?? "")}){return step.prompt+"："+step.feedback(values[step.id] ?? "")}
        if type=="single",let c=choices.first(where:{$0.id==response}){return c.feedback}
        if let e=numericError(response){return e.feedback}
        return explanation
    }
    func numericError(_ response:String)->CommonError? {
        guard let value=number(response),let n=numeric else{return nil}
        return commonErrors?.first{abs($0.value-value)<=max(n.tolerance,abs(value)*1e-8)}
    }
    func errorTag(_ response:String)->String? {
        if type=="expression"{return expressionError(response)?.errorTag}
        if type=="structured",let values=stepResponses(response){return steps?.first(where:{!$0.correct(values[$0.id] ?? "")}).flatMap{$0.errorTag(values[$0.id] ?? "")}}
        return choices.first{$0.id==response}?.errorTag ?? numericError(response)?.errorTag
    }
    func repairSection(_ response:String)->String? {
        if type=="structured",let values=stepResponses(response),let step=steps?.first(where:{!$0.correct(values[$0.id] ?? "")}){return step.repairSection(values[step.id] ?? "") ?? repairSectionID}
        return choices.first{$0.id==response}?.repairSectionID ?? numericError(response)?.repairSectionID ?? expressionError(response)?.repairSectionID ?? repairSectionID
    }
    func repairPoint(_ response:String)->String?{
        if type=="structured",let values=stepResponses(response),let step=steps?.first(where:{!$0.correct(values[$0.id] ?? "")}){return step.repairPoint(values[step.id] ?? "")}
        return choices.first{$0.id==response}?.repairPointID ?? expressionError(response)?.repairPointID
    }
    func probeSkill(_ response:String)->String? {
        if type=="structured",let values=stepResponses(response),let step=steps?.first(where:{!$0.correct(values[$0.id] ?? "")}){return step.probeSkill(values[step.id] ?? "")}
        return choices.first{$0.id==response}?.probeSkillID ?? expressionError(response)?.probeSkillID
    }
    func stepResponses(_ response:String)->[String:String]? {
        guard response.utf8.count<=16*1024,let data=response.data(using:.utf8),let values=try? JSONDecoder().decode([String:String].self,from:data),values.count<=12,values.values.allSatisfy({$0.count<=600}) else{return nil};return values
    }
    func expressionStatus(_ response:String)->String {
        guard let e=expression,e.version==1,response.count<=300 else{return "pending"}
        if e.accepted.contains(where:{KnowledgeFormula.equivalent(response,to:$0,variables:e.variables,lhs:e.expectedLHS)==true}){return "correct"}
        return expressionError(response)==nil ? "pending":"wrong"
    }
    func expressionError(_ response:String)->ExpressionError? {
        guard let e=expression else{return nil}
        return e.rejected?.first{error in error.forms.contains{KnowledgeFormula.equivalent(response,to:$0,variables:e.variables,lhs:e.expectedLHS)==true}}
    }
    func stepScores(_ response:String)->[KnowledgeStepScore]? {
        guard type=="structured",let values=stepResponses(response),let steps else{return nil}
        return steps.map{s in let v=values[s.id] ?? "";return .init(id:s.id,status:!s.accepts(v) ? "pending":(s.correct(v) ? "correct":"wrong"),response:v,methodIDs:s.methodIDs ?? [],errorTag:s.correct(v) ? nil:s.errorTag(v))}
    }
    func inputIssue(_ response:String)->String {
        if type=="structured",let values=stepResponses(response),let steps {
            if let step=steps.first(where:{!$0.accepts(values[$0.id] ?? "")}){return step.prompt+"："+step.inputIssue(values[step.id] ?? "")}
        }
        if type=="expression"{return "这种式子写法暂未被可靠识别。草稿会保留，该步骤待确认，不判为方法错误。可使用题给变量名补齐运算符，或先学别的。"}
        if type=="number"{return "请填写有限数值和题目要求的单位。"}
        return "请先完成题目要求的选择或步骤。"
    }
}
