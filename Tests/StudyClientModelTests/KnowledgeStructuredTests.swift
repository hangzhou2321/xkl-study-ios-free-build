import Foundation
import XCTest
@testable import StudyClientModel

final class KnowledgeStructuredTests:XCTestCase {
    private let day=20_750
    private func date(_ d:Int)->Date{Date(timeIntervalSince1970:Double(d)*86400+43200)}
    private func course()->KnowledgeCourse{.structuredSynthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])}
    private func train(_ e:inout KnowledgeLearningEngine,at now:Date)throws {
        try e.start(now:now);var n=0
        while let p=e.current,p.phase != "complete" {
            n+=1;guard n<80 else{XCTFail("Structured teaching did not finish");return}
            if p.phase=="lesson"{try e.readNext(token:p.id,now:now)}
            else if p.phase=="question"{try e.answer(e.check!.syntheticCorrectResponse,token:p.id,now:now)}
            else{try e.finish(token:p.id,now:now)}
        }
    }
    private func response(_ q:KnowledgeCourse.Check,_ changes:[String:String])->String {
        var values=q.stepResponses(q.syntheticCorrectResponse)!
        for (k,v) in changes{values[k]=v}
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return String(data:try! e.encode(values),encoding:.utf8)!
    }
    func testAlgebraAcceptsEquivalentRelationsWithoutEvaluatingCode() {
        let vars=["i","p","u","c","r","dp","ps","t","es"]
        for (a,b,lhs) in [("p=√3*u*i*c","i=p/(sqrt(3)*u*c)","i"),("p/u/c/√3","i=√3*p/(3*u*c)","i"),("dp=r*i*i*3","dp=3*i²*r","dp"),("1000*es=t*p+t*dp","es=(p+dp)*t/1000","es")] {
            XCTAssertEqual(KnowledgeFormula.equivalent(a,to:b,variables:vars,lhs:lhs),true,a)
        }
        XCTAssertEqual(KnowledgeFormula.equivalent("-i^2",to:"i^2",variables:vars,lhs:nil),false)
        XCTAssertEqual(KnowledgeFormula.equivalent("(-i)^2",to:"i²",variables:vars,lhs:nil),true)
        for unsafe in ["__import__('os')","eval(1)","i=p/0","sqrt(u)",String(repeating:"(",count:301)] {
            XCTAssertNil(KnowledgeFormula.equivalent(unsafe,to:"i=p/u",variables:vars,lhs:"i"))
        }
    }
    func testCorrectFinalNumberWithKnownWrongMethodCannotPass()throws {
        let q=course().points[0].checks[1];try q.validateResponse()
        let raw=response(q,["relation":"t=e*p"])
        XCTAssertTrue(q.accepts(raw));XCTAssertFalse(q.correct(raw))
        let scores=q.stepScores(raw)!
        XCTAssertEqual(scores.map(\.status),["correct","wrong","correct"])
        XCTAssertEqual(scores[1].errorTag,"method")
    }
    func testMixedRelationsAcceptAnyOrderButRejectDuplicateCoverage()throws {
        let q=course().points[0].checks.last!;try q.validateResponse()
        XCTAssertNotNil(q.distinctExpressionIDs)
        var values=q.stepResponses(q.syntheticCorrectResponse)!
        let a=values["model1"]!;values["model1"]=values["model3"];values["model3"]=a
        func raw()->String{String(data:try! JSONEncoder().encode(values),encoding:.utf8)!}
        XCTAssertTrue(q.accepts(raw()));XCTAssertTrue(q.correct(raw()))
        values["model2"]=values["model1"]
        XCTAssertTrue(q.accepts(raw()));XCTAssertFalse(q.correct(raw()))
        XCTAssertEqual(q.stepScores(raw())?.filter{$0.status=="wrong"}.count,1)
        XCTAssertTrue(q.feedback(raw()).contains("重复"))
    }
    func testOriginalChoiceIsReachableBesideProcessTasksWithoutAdvancingMethodLevel()throws {
        let base=course(),p=base.points[0],old=KnowledgeCourse.synthetic(subject:base.subject,hash:base.bankSHA256,legacyIDs:[]).points[0].checks[1]
        var original=KnowledgeCourse.Check(id:p.id+"-original-check",prompt:old.prompt,choices:old.choices,answerID:old.answerID,explanation:old.explanation)
        original.purpose="original";original.skillID=p.skills!.first!.id;original.family="source-occurrence";original.originalQuestionID=base.questionMappings[0].id
        let changed=KnowledgeCourse.Point(id:p.id,title:p.title,goal:p.goal,prerequisites:p.prerequisites,sections:p.sections,keyFacts:p.keyFacts,example:p.example,checks:p.checks+[original],sources:p.sources,legacyEvidenceCardIDs:p.legacyEvidenceCardIDs,skills:p.skills,retiredChecks:p.retiredChecks,legacyBaseline:p.legacyBaseline)
        let c=KnowledgeCourse(format:base.format,id:base.id,subject:base.subject,bankSHA256:base.bankSHA256,retiredLegacyCards:true,points:[changed,base.points[1]],questionMappings:base.questionMappings)
        var e=try KnowledgeLearningEngine.fresh(c);try train(&e,at:date(day))
        for d in [day+1,day+2,day+4] {try e.open(p.id,review:true,now:date(d));XCTAssertNotEqual(e.check?.purpose,"original");try e.answer(e.check!.syntheticCorrectResponse,token:e.current!.id,now:date(d));try e.finish(token:e.current!.id,now:date(d))}
        let level=e.reviewStatus(p.id)!.level
        try e.open(p.id,review:true,now:date(day+7));XCTAssertEqual(e.check?.id,original.id)
        try e.answer(original.answerID,token:e.current!.id,now:date(day+7))
        XCTAssertEqual(e.evidenceCounts(p.id)["original"],1)
        XCTAssertEqual(e.reviewStatus(p.id)?.level,level) // It checks the original choice, not the full method.
        _=try KnowledgeLearningEngine(course:c,record:e.record)
    }
    func testMixedWrongRelationWithRightNumberRetainsRawStepsAfterColdRestore()throws {
        let c=course();var e=try KnowledgeLearningEngine.fresh(c);try train(&e,at:date(day));let id=c.points[0].id
        for d in [day+1,day+2] {
            try e.open(id,review:true,now:date(d));try e.answer(e.check!.syntheticCorrectResponse,token:e.current!.id,now:date(d));try e.finish(token:e.current!.id,now:date(d))
        }
        try e.open(id,review:true,now:date(day+4));XCTAssertEqual(e.check?.purpose,"mixed")
        var values=e.check!.stepResponses(e.check!.syntheticCorrectResponse)!;values["model3"]="t=e/p2"
        let raw=String(data:try JSONEncoder().encode(values),encoding:.utf8)!
        try e.answer(raw,token:e.current!.id,now:date(day+4))
        let answer=e.record.events.last{$0.kind=="answer"}!
        XCTAssertEqual(answer.correct,false);XCTAssertEqual(answer.stepScores?.last?.status,"correct")
        XCTAssertEqual(answer.stepScores?.filter{$0.status=="wrong"}.count,1)
        let restored=try KnowledgeLearningEngine(course:c,record:e.record);XCTAssertEqual(restored.record.events.last{$0.kind=="answer"},answer)
    }
    func testUnrecognizedAlternativeRemainsPendingRatherThanBecomingWrong()throws {
        let q=course().points[0].checks[1]
        let raw=response(q,["relation":"t^2=e^2/p^2"])
        XCTAssertFalse(q.accepts(raw));XCTAssertEqual(q.stepScores(raw)?[1].status,"pending")
        XCTAssertTrue(q.inputIssue(raw).contains("待确认"))
        let equivalent=response(q,["relation":"p*t=e"])
        XCTAssertTrue(q.accepts(equivalent));XCTAssertTrue(q.correct(equivalent))
    }
    func testChangingLayoutCannotMakeTheSameStemUnseenAgain()throws {
        let original=course(),p=original.points[0];var checks=p.checks
        checks[2].stemID=checks[0].id
        let changed=KnowledgeCourse.Point(id:p.id,title:p.title,goal:p.goal,prerequisites:p.prerequisites,sections:p.sections,keyFacts:p.keyFacts,example:p.example,checks:checks,sources:p.sources,legacyEvidenceCardIDs:p.legacyEvidenceCardIDs,skills:p.skills,retiredChecks:p.retiredChecks,legacyBaseline:p.legacyBaseline)
        let c=KnowledgeCourse(format:original.format,id:original.id,subject:original.subject,bankSHA256:original.bankSHA256,retiredLegacyCards:true,points:[changed,original.points[1]],questionMappings:original.questionMappings)
        var e=try KnowledgeLearningEngine.fresh(c);try train(&e,at:date(day))
        XCTAssertGreaterThan(e.encounterCount(checks[2].id),0)
        try e.open(p.id,review:true,now:date(day+1))
        if e.check?.id==checks[2].id{XCTAssertNotEqual(e.current?.familiarity,"unseen-in-app")}
        _=try KnowledgeLearningEngine(course:c,record:e.record)
    }
    func testContentRollbackInNewRuntimeRetainsNewAnswersAndPendingProcessDefinition()throws {
        let c=course();var e=try KnowledgeLearningEngine.fresh(c);try train(&e,at:date(day))
        try e.open(c.points[0].id,review:true,now:date(day+1));let pending=e.current!,question=e.check!
        try e.saveDraft(question.syntheticCorrectResponse,token:pending.id)
        let old=KnowledgeCourse.synthetic(subject:c.subject,hash:c.bankSHA256,legacyIDs:[])
        var rolled=try KnowledgeLearningEngine(course:old,record:KnowledgeLearningEngine.appending(e.record,to:old))
        XCTAssertEqual(rolled.record.events,e.record.events);XCTAssertEqual(rolled.current,e.current);XCTAssertEqual(rolled.check,question)
        XCTAssertEqual(rolled.displayPoint?.sections,e.displayPoint?.sections)
        try rolled.answer(question.syntheticCorrectResponse,token:pending.id,now:date(day+1))
        let forward=try KnowledgeLearningEngine(course:c,record:KnowledgeLearningEngine.appending(rolled.record,to:c))
        XCTAssertEqual(forward.record.events,rolled.record.events);XCTAssertEqual(forward.current?.selectedID,question.syntheticCorrectResponse)
        XCTAssertEqual(forward.record.events.filter{$0.kind=="answer"}.count,3)
    }
    func testHighScaffoldAloneDoesNotCompleteMethodAndAllStagesColdRestore()throws {
        let c=course();var e=try KnowledgeLearningEngine.fresh(c);try e.start(now:date(day))
        while e.current?.phase=="lesson"{try e.readNext(token:e.current!.id,now:date(day))}
        let id=e.current!.pointID
        XCTAssertEqual(e.check?.practiceStage,"scaffold-high")
        try e.answer(e.check!.syntheticCorrectResponse,token:e.current!.id,now:date(day))
        try e.finish(token:e.current!.id,now:date(day));XCTAssertNil(e.trainedAt(id));XCTAssertEqual(e.learnedSkills(id),0)
        e=try KnowledgeLearningEngine(course:c,record:e.record)
        var n=0
        while e.current?.phase != "complete" {
            n+=1;guard n<30 else{XCTFail("Low scaffold stuck");return}
            let p=e.current!
            if p.phase=="lesson"{try e.readNext(token:p.id,now:date(day))}
            else if p.phase=="question"{XCTAssertEqual(e.check?.practiceStage,"scaffold-low");try e.answer(e.check!.syntheticCorrectResponse,token:p.id,now:date(day))}
            else{try e.finish(token:p.id,now:date(day))}
        }
        XCTAssertNotNil(e.trainedAt(id));XCTAssertEqual(e.record.events.filter{$0.kind=="answer"}.count,2)
        _=try KnowledgeLearningEngine(course:c,record:e.record)
    }
    func testStructuredWrongAnswerKeepsSeparateStepEvidenceAcrossColdRestore()throws {
        let c=course();var e=try KnowledgeLearningEngine.fresh(c);try train(&e,at:date(day));let id=e.current!.pointID
        try e.open(id,review:true,now:date(day+1));let raw=response(e.check!,["relation":"t=e*p"])
        try e.answer(raw,token:e.current!.id,now:date(day+1))
        let event=e.record.events.last{$0.kind=="answer"}!
        XCTAssertEqual(event.correct,false);XCTAssertEqual(event.stepScores?.map(\.status),["correct","wrong","correct"])
        XCTAssertFalse(e.reviewPassed(id))
        let restored=try KnowledgeLearningEngine(course:c,record:e.record)
        XCTAssertEqual(restored.record.events.last{$0.kind=="answer"},event)
    }
    func testUnsubmittedStructuredDraftCanReturnFromExplanationWithoutGainingIndependence()throws {
        let c=course();var e=try KnowledgeLearningEngine.fresh(c);try train(&e,at:date(day));let id=e.current!.pointID
        try e.open(id,review:true,now:date(day+1));let old=e.current!,raw=response(e.check!,["relation":"p*t=e"])
        try e.saveDraft(raw,token:old.id);try e.explainAgain(now:date(day+1))
        XCTAssertEqual(e.current?.resumeAttemptID,old.id)
        try e.resumeAttempt(old.id,now:date(day+1).addingTimeInterval(1))
        XCTAssertEqual(e.current?.draftResponse,raw);XCTAssertEqual(e.current?.shownAt,old.shownAt);XCTAssertTrue(e.current!.assisted)
        XCTAssertEqual(e.record.events.filter{$0.kind=="answer"}.count,2)
        _=try KnowledgeLearningEngine(course:c,record:e.record)
    }
}

#if os(macOS)
final class KnowledgeStructuredStoreTests:XCTestCase {
    @MainActor func testCompleteArchivePreservesUnknownRawFieldsAndRejectsOverwrite()throws {
        let r=FileManager.default.temporaryDirectory.appendingPathComponent("archive-source-"+UUID().uuidString),target=FileManager.default.temporaryDirectory.appendingPathComponent("archive-target-"+UUID().uuidString)
        defer{for folder in [r,target] where FileManager.default.fileExists(atPath:folder.path){try? FileManager.default.removeItem(at:folder)}}
        let c=KnowledgeCourse.structuredSynthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])
        let s=KnowledgeLearningStore(course:c,baseDirectory:r);s.start()
        let path=r.appendingPathComponent("KnowledgeLearning/power/current.json")
        var object=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
        object["futureMetadata"]=["literal":"keep me","version":88]
        let raw=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);try raw.write(to:path)
        let cold=KnowledgeLearningStore(course:c,baseDirectory:r);XCTAssertFalse(cold.blocked,cold.error ?? "")
        cold.readNext(cold.engine!.current!.id);XCTAssertFalse(cold.blocked,cold.error ?? "")
        let archive:Data
        do{archive=try cold.exportArchive()}catch{XCTFail("Source export: "+error.localizedDescription);return}
        let decoded=try JSONDecoder().decode(KnowledgeArchive.self,from:archive)
        let alias=r.appendingPathComponent("KnowledgeLearning/power/.",isDirectory:true)
        XCTAssertEqual(try KnowledgeArchive.make(course:c,root:alias),archive)
        XCTAssertTrue(decoded.files.contains{$0.bytes==raw && $0.name.hasPrefix("before-raw-")})
        do{try KnowledgeArchive.restore(archive,course:c,baseDirectory:target)}catch{XCTFail("Clean restore: "+error.localizedDescription);return}
        let restored=KnowledgeLearningStore(course:c,baseDirectory:target)
        XCTAssertFalse(restored.blocked,restored.error ?? "");XCTAssertEqual(restored.engine?.record,cold.engine?.record)
        XCTAssertEqual(try restored.exportArchive(),archive)
        XCTAssertThrowsError(try KnowledgeArchive.restore(archive,course:c,baseDirectory:target))
        XCTAssertEqual(try restored.exportArchive(),archive)
    }
    @MainActor func testUnknownEventCannotBeSilentlyDiscarded()throws {
        let r=FileManager.default.temporaryDirectory.appendingPathComponent("unknown-event-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.structuredSynthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[]),s=KnowledgeLearningStore(course:c,baseDirectory:r);s.start()
        let path=r.appendingPathComponent("KnowledgeLearning/power/current.json")
        var object=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any],events=object["events"] as! [[String:Any]]
        events[0]["kind"]="future-assessment-kind";object["events"]=events
        let raw=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);try raw.write(to:path)
        let cold=KnowledgeLearningStore(course:c,baseDirectory:r);XCTAssertTrue(cold.blocked)
        XCTAssertEqual(try Data(contentsOf:path),raw)
    }
    @MainActor func testPendingFormulaSavesDraftWithoutGradeAndColdRestoresExactVersion()throws {
        let r=FileManager.default.temporaryDirectory.appendingPathComponent("structured-store-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.structuredSynthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[]),s=KnowledgeLearningStore(course:c,baseDirectory:r)
        s.start();var n=0
        while let p=s.engine?.current {
            n+=1;guard n<50 else{XCTFail("Fixture did not reach low scaffold");return}
            if p.phase=="question",s.engine?.check?.practiceStage=="scaffold-low"{break}
            if p.phase=="lesson"{s.readNext(p.id)}else if p.phase=="question"{s.answer(s.engine!.check!.syntheticCorrectResponse,token:p.id)}else{s.finish(p.id)}
        }
        let token=s.engine!.current!.id,question=s.engine!.check!,count=s.engine!.record.events.filter{$0.kind=="answer"}.count
        var values=question.stepResponses(question.syntheticCorrectResponse)!;values["relation"]="t^2=e^2/p^2"
        let raw=String(data:try JSONEncoder().encode(values),encoding:.utf8)!
        s.answer(raw,token:token);XCTAssertFalse(s.blocked,s.error ?? "");XCTAssertTrue(s.error?.contains("待确认")==true)
        XCTAssertEqual(s.engine?.record.events.filter{$0.kind=="answer"}.count,count)
        let cold=KnowledgeLearningStore(course:c,baseDirectory:r)
        XCTAssertFalse(cold.blocked,cold.error ?? "");XCTAssertEqual(cold.engine?.current?.id,token);XCTAssertEqual(cold.engine?.current?.draftResponse,raw)
        XCTAssertEqual(cold.engine?.check,question)
    }
}
#endif
