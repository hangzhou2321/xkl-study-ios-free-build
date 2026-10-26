import Foundation
import StudyCore

extension KnowledgeCourse.Point {
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
    func gradingDigest()throws->String {
        var object:[String:Any]=["id":id,"prompt":prompt,"type":type,"answer":answerID,
            "choices":choices.sorted{$0.id<$1.id}.map{["id":$0.id,"text":$0.text]}]
        if let numeric {object["numeric"]=["value":numeric.value,"tolerance":numeric.tolerance,"unit":numeric.unit,"factors":numeric.unitFactors ?? [:],"requiresUnit":numeric.requiresUnit ?? false] as [String:Any]}
        if let correctChoiceIDs{object["correctChoices"]=correctChoiceIDs.sorted()}
        return StudySHA256.hex(try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]))
    }
    func validateResponse()throws {
        func good(_ s:String,_ n:Int)->Bool{!s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.count<=n}
        guard ["single","multiple","number"].contains(type),purpose==nil || ["guided","independent","transfer","original"].contains(purpose!),
              hint==nil || good(hint!,1200),family==nil || good(family!,160) else{throw ExamError.invalid("诊断形式或提示无效。")}
        if type=="number" {
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
        if type=="number"{return number(response) != nil}
        if type=="single"{return choices.contains{$0.id==response}}
        let selected=response.split(separator:"|").map(String.init)
        return !selected.isEmpty && Set(selected).count==selected.count && Set(selected).isSubset(of:Set(choices.map(\.id)))
    }
    func correct(_ response:String)->Bool {
        if type=="number",let n=numeric,let value=number(response){return abs(value-n.value)<=max(n.tolerance,1e-10*abs(n.value))}
        if type=="multiple"{return Set(response.split(separator:"|").map(String.init))==Set(correctChoiceIDs ?? [])}
        return response==answerID
    }
    func feedback(_ response:String)->String {
        if type=="single",let c=choices.first(where:{$0.id==response}){return c.feedback}
        if let e=numericError(response){return e.feedback}
        return explanation
    }
    func numericError(_ response:String)->CommonError? {
        guard let value=number(response),let n=numeric else{return nil}
        return commonErrors?.first{abs($0.value-value)<=max(n.tolerance,abs(value)*1e-8)}
    }
    func errorTag(_ response:String)->String? {
        choices.first{$0.id==response}?.errorTag ?? numericError(response)?.errorTag
    }
    func repairSection(_ response:String)->String? {
        choices.first{$0.id==response}?.repairSectionID ?? numericError(response)?.repairSectionID ?? repairSectionID
    }
    func repairPoint(_ response:String)->String?{choices.first{$0.id==response}?.repairPointID}
}
