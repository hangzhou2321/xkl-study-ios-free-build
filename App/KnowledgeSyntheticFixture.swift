#if DEBUG
import Foundation

extension KnowledgeCourse {
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
#endif
