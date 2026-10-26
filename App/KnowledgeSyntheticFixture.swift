#if DEBUG
import Foundation

extension KnowledgeCourse {
    static func structuredSynthetic(subject:ConceptSubject,hash:String,legacyIDs:[String])->Self {
        let base=adaptiveSynthetic(subject:subject,hash:hash,legacyIDs:legacyIDs)
        let points=base.points.enumerated().map { index,p -> Point in
            let method=p.id+"-calculation",section="worked-method"
            func number(_ id:String,_ prompt:String,_ value:Double,_ unit:String)->Check {
                var q=Check(id:id,prompt:prompt,choices:[],answerID:"number",explanation:"按本题条件核对数值与单位。")
                q.responseType="number";q.numeric = .init(value:value,tolerance:0.0001,unit:unit,unitFactors:unit=="h" ? ["h":1,"min":1.0/60]:[unit:1],requiresUnit:true);q.methodIDs=[method];return q
            }
            func task(_ label:String,role:String,e:Double,rate:Double,reserve:Double,stage:String?=nil,mixed:Bool=false)->Check {
                let id=p.id+"-structured-"+label+"-v2",time=mixed ? (24-3*2)/6:(e-reserve)/rate
                var conditions=Check(id:"conditions",prompt:"你对条件的判断",choices:[.init(id:"A",text:mixed ? "问题问第二阶段；第一阶段已发生；两段速度分别恒定":"e是总量，p是每小时速度；留存部分不可消耗",feedback:"本题的可用范围与时段条件已明确。"),.init(id:"B",text:"问题总问最初起算的全部时间，且任何总量都可全部使用",feedback:"必须分清所求时段及允许使用范围。",errorTag:"conditions",repairSectionID:section)],answerID:"A",explanation:"先确定问题实际可用的总量和所求时段。")
                conditions.methodIDs=[method]
                let vars=mixed ? ["t","e","p1","t1","p2"]:(reserve>0 ? ["t","e","reserve","p"]:["t","e","p"])
                let right=mixed ? "t=(e-p1*t1)/p2":(reserve>0 ? "t=(e-reserve)/p":"t=e/p")
                let wrong=mixed ? "t=e/p2":(reserve>0 ? "t=e/p":"t=e*p")
                var relation=Check(id:"relation",prompt:"写出你使用的关系（t是所求小时数）",choices:[],answerID:"expression",explanation:"先确定可用量，再除以这一阶段每小时用量。")
                relation.responseType="expression";relation.expression = .init(version:1,variables:vars,expectedLHS:"t",accepted:[right],rejected:[.init(forms:[wrong],feedback:mixed ? "遗漏了前一阶段已经消耗的量。":(reserve>0 ? "把必须保留的部分也算成可用了。":"相乘不能得到持续时长。"),errorTag:"method",repairSectionID:section)])
                relation.methodIDs=[method]
                let prompt=reserve>0 ? "纯合成题：总量e=\(e)L，必须保留reserve=\(reserve)L，每小时消耗p=\(rate)L/h。求还能使用的时间t。":"纯合成题：允许使用的总量e=\(e)L，每小时消耗p=\(rate)L/h。求还能使用的时间t。"
                var root=Check(id:id,prompt:mixed ? "纯合成组合题：总量e=24L，第一段以p1=3L/h用t1=2h，之后改为p2=6L/h。第二段还能使用多久？请自己组织关系。":prompt+(stage=="scaffold-high" ? "\n本轮已给框架：先求可用量，再除以每小时速度。只补关键数值，记录有帮助练习。":""),choices:[],answerID:"steps",explanation:"各项按同一题面分别核对。条件或关系不符时，最终数值相符也不记方法通过。")
                root.responseType="structured";root.steps=[conditions,relation,number("result","时间结果（带单位）",time,"h")]
                root.skillID=method;root.purpose=role;root.family=p.id+"-"+label;root.repairSectionID=section;root.practiceStage=stage
                root.hint=mixed ? "第一段已用量是p1×t1，剩余再除以p2。":"用总量先扣保留量，再按每小时用量计算。"
                if mixed{root.stemID="synthetic-shared-mixed-stem";root.relatedKnowledgeIDs=base.points.filter{$0.id != p.id}.map(\.id)}
                return root
            }
            var high=task("high",role:"guided",e:12,rate:3,reserve:index==0 ? 0:6,stage:"scaffold-high")
            high.steps=[number("available","允许使用多少L？",index==0 ? 12:6,"L"),number("result","能用多少h？",index==0 ? 4:2,"h")]
            high.exposureAliases=[p.id+"-practice"]+(index==0 ? [p.id+"-number-v2"]:[])
            let low=task("low",role:"guided",e:18,rate:3,reserve:index==0 ? 0:6,stage:"scaffold-low")
            let independent=task("independent",role:"independent",e:25,rate:4,reserve:index==0 ? 0:5)
            let transfer=task("transfer",role:"transfer",e:28,rate:4,reserve:index==0 ? 8:4)
            let mixed=task("mixed",role:"mixed",e:24,rate:6,reserve:0,mixed:true)
            var sections=p.sections;sections[2].checkpointID=high.id
            sections.append(.init(title:"撤去给定公式，再独立组织一遍",body:"先判断允许使用的范围，再组织总量、每小时用量和时间的关系。留存部分不能拿来消耗；分段时先扣已用量。不要只填写看起来合理的最终数。",id:"low-scaffold",checkpointID:low.id))
            let skills=[Skill(id:method,title:"确定可用量并求时长",lessonSectionID:section,practiceStages:["scaffold-high","scaffold-low"],independentEvidence:"steps")]
            return Point(id:p.id,title:p.title,goal:p.goal,prerequisites:p.prerequisites,sections:sections,keyFacts:p.keyFacts,example:p.example,checks:[high,low,independent,transfer,mixed],sources:p.sources,legacyEvidenceCardIDs:p.legacyEvidenceCardIDs,skills:skills,retiredChecks:(p.retiredChecks ?? [])+p.checks,legacyBaseline:p.legacyBaseline)
        }
        return .init(format:"knowledge-course-v2",id:base.id,subject:subject,bankSHA256:hash,retiredLegacyCards:true,points:points,questionMappings:base.questionMappings)
    }
    static func adaptiveSynthetic(subject:ConceptSubject,hash:String,legacyIDs:[String])->Self {
        let base=synthetic(subject:subject,hash:hash,legacyIDs:legacyIDs)
        let points=base.points.map { old -> Point in
            let method=old.id+"-calculation",section="worked-method"
            var numeric=Check(id:old.id+"-number-v2",prompt:"纯合成小题：允许使用12份水，每小时消耗3份，能持续多久？填写数值与h。",choices:[],answerID:"number",explanation:"时间=12÷3=4h。相乘得到36不能表示持续时长。")
            numeric.responseType="number";numeric.numeric = .init(value:4,tolerance:0.001,unit:"h",unitFactors:["h":1,"min":1.0/60],requiresUnit:true)
            numeric.purpose="guided";numeric.skillID=method;numeric.family="duration";numeric.repairSectionID=section
            numeric.hint="用可用总量除以每小时的用量。";numeric.commonErrors=[.init(value:36,feedback:"把总量与每小时用量相乘了。时间应作除法。",errorTag:"method",repairSectionID:section)]
            var multi=Check(id:old.id+"-multiple-v2",prompt:"纯合成多选：容量12份、每小时3份。哪些判断符合题定恒定用量模型？",choices:[.init(id:"A",text:"完整12份可用4小时",feedback:"12÷3=4h。"),.init(id:"B",text:"只允许用一半仍能用4小时",feedback:"只许用6份时为2h。",errorTag:"conditions",repairSectionID:section),.init(id:"C",text:"每小时用量翻倍，可用时间减半",feedback:"总量不变时，时间与每小时用量成反比。")],answerID:"multiple",explanation:"应选第一和第三项。先调整可用总量或每小时用量，再算时间。")
            multi.responseType="multiple";multi.correctChoiceIDs=["A","C"];multi.purpose="independent";multi.skillID=method;multi.family="conditions";multi.repairSectionID=section
            var transfer=old.checks[2];transfer=Check(id:old.id+"-transfer-v2",prompt:transfer.prompt,choices:transfer.choices,answerID:transfer.answerID,explanation:transfer.explanation)
            transfer.purpose="transfer";transfer.skillID=method;transfer.family="changed-rate";transfer.repairSectionID=section
            var sections=old.sections
            for i in sections.indices{sections[i].id="original-\(i)"}
            sections.append(.init(title:"先列条件，再补上计算步骤",body:"允许使用12份，每小时消耗3份。先检查可用范围，再计算12÷3，最后检查得到的是时间。",id:section,example:old.example,checkpointID:numeric.id))
            return Point(id:old.id,title:old.title,goal:old.goal,prerequisites:old.prerequisites,sections:sections,keyFacts:old.keyFacts,example:old.example,checks:[numeric,multi,transfer],sources:old.sources,legacyEvidenceCardIDs:old.legacyEvidenceCardIDs,skills:[.init(id:method,title:"由可用量与速度求持续时间",lessonSectionID:section)],retiredChecks:old.checks,legacyBaseline:.init(checks:old.checks,sectionCount:old.sections.count))
        }
        return .init(format:"knowledge-course-v2",id:base.id,subject:subject,bankSHA256:hash,retiredLegacyCards:true,points:points,questionMappings:base.questionMappings)
    }
    /// Entirely newly authored toy quantities, never copied from private books.
    static func synthetic(subject:ConceptSubject,hash:String,legacyIDs:[String])->Self {
        func check(_ id:String,_ prompt:String,_ right:String,_ wrong:String,_ why:String)->Check {
            .init(id:id,prompt:prompt,choices:[.init(id:"A",text:right,feedback:why),.init(id:"B",text:wrong,feedback:why)],answerID:"A",explanation:why)
        }
        func transfer(_ id:String,_ prompt:String,_ right:String,_ wrong:String,_ why:String)->Check {
            var q=check(id,prompt,right,wrong,why);q.purpose="transfer";q.family=id;return q
        }
        let one="kp-synthetic-"+subject.rawValue+"-quantity",two="kp-synthetic-"+subject.rawValue+"-available"
        let p=Point(id:one,title:"先分清总量与每小时的用量",goal:"把总共有多少、每小时用多少与能用多久分开。",prerequisites:[],
            sections:[.init(title:"先用水箱来理解",body:"水箱里一共有12份水，每小时流出3份。12说的是总共有多少，3说的是每小时用多快，它们不是同一种量。"),.init(title:"再把两个量连起来",body:"能用多久等于可用总量除以每小时的用量。单位也会帮忙：12份除以每小时3份，得到4小时。")],
            keyFacts:["总量与速度是不同的量。","时间=可用总量÷恒定的每小时用量。"],
            example:.init(prompt:"合成例：12份水，每小时用3份，能用多久？",steps:["先找总量12和每小时用量3。","12÷3=4，得到4小时。"],answer:"4小时。"),
            checks:[check(one+"-practice","有12份、每小时用3份，能用多久？","4小时","36小时","12÷3=4；相乘不能得到持续时长。"),check(one+"-review","换成15份、每小时用5份，能用多久？","3小时","5小时","先认总量15与每小时用量5，15÷5=3。"),transfer(one+"-transfer","12份每小时用3份，若每小时用量加倍且总量不变，能用多久？","2小时","8小时","新速度6份/小时，12÷6=2；不是原4小时再翻倍。")],
            sources:[.init(documentID:"synthetic",title:"纯合成演示材料",page:1)],legacyEvidenceCardIDs:Array(legacyIDs.prefix(1)))
        let q=Point(id:two,title:"额定总量不一定全部可用",goal:"先扣除明确不可用的部分，再计算时长。",prerequisites:[one],
            sections:[.init(title:"先看允许用多少",body:"容器里有12份，但题目要求留下一半，真正允许用的只有6份。不能仍把12全放进计算式。"),.init(title:"条件改变，重新列式",body:"可用量从12变成6，每小时仍用3。先算12×一半=6，再算6÷3=2小时。")],
            keyFacts:["先明确可用范围。","条件改变后重新计算。"],
            example:.init(prompt:"合成例：12份只许用一半，每小时用3份。",steps:["允许用12×一半=6份。","6÷3=2小时。"],answer:"2小时。"),
            checks:[check(two+"-practice","12份只许用一半，每小时用3份，可以用多久？","2小时","4小时","能用的只有6份，所以是2小时。"),check(two+"-review","20份必须留下5份，每小时用5份，可以用多久？","3小时","4小时","可用量为20−5=15，15÷5=3小时。"),transfer(two+"-transfer","20份留5份、每小时用5份；再增加5份可用量，持续时间增加多少？","1小时","5小时","新增5份除每小时5份，增加1小时。")],
            sources:[.init(documentID:"synthetic",title:"纯合成演示材料",page:2)],legacyEvidenceCardIDs:Array(legacyIDs.dropFirst().prefix(1)))
        return .init(format:"knowledge-course-v1",id:"synthetic-knowledge-"+subject.rawValue,subject:subject,bankSHA256:hash,retiredLegacyCards:true,points:[p,q],
            questionMappings:[.init(id:"synthetic-basic-1",documentID:"synthetic",book:"基础（合成）",page:1,knowledgeIDs:[one,two],method:"先定可用总量，再除以每小时的用量；一个问题可以用到两个知识点。",status:"supported",questionText:"纯合成题，不是用户题库。",label:"基础合成题1")])
    }
}
extension KnowledgeCourse.Check {
    /// Fixture driver only. It simulates a known response; it is not a learner
    /// test and is never compiled into a Release App.
    var syntheticCorrectResponse:String {
        if type=="structured"{let values=Dictionary(uniqueKeysWithValues:(steps ?? []).map{($0.id,$0.syntheticCorrectResponse)});let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return String(data:try! encoder.encode(values),encoding:.utf8)!}
        if type=="expression"{return expression!.accepted[0]}
        if type=="number"{return String(numeric!.value)+numeric!.unit}
        if type=="multiple"{return correctChoiceIDs!.sorted().joined(separator:"|")}
        return answerID
    }
}
#endif
