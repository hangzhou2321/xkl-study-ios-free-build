import Foundation
import XCTest
import CPocket
@testable import StudyClientModel

final class KnowledgeAdaptiveTests:XCTestCase {
    private func date(_ day:Int)->Date{Date(timeIntervalSince1970:Double(day)*86400+43200)}
    private let day=20_750
    private func course()->KnowledgeCourse{.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])}
    private func read(_ e:inout KnowledgeLearningEngine,at:Date)throws {
        var n=0
        while let p=e.current,p.phase=="lesson"{n+=1;guard n<80 else{XCTFail("lesson loop");return};try e.readNext(token:p.id,now:at)}
    }
    private func train(_ e:inout KnowledgeLearningEngine,at:Date)throws {
        try e.start(now:at);try read(&e,at:at);let p=try XCTUnwrap(e.current),q=try XCTUnwrap(e.check)
        try e.answer(q.answerID,token:p.id,now:at);try e.finish(token:p.id,now:at)
    }
    private func edit(_ c:KnowledgeCourse,_ body:(inout [String:Any])throws->Void)throws->KnowledgeCourse {
        var o=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as? [String:Any]);try body(&o)
        return try JSONDecoder().decode(KnowledgeCourse.self,from:JSONSerialization.data(withJSONObject:o))
    }
    func testIntervalsAreTheActualExistingWordTableAndBoundaryIsReadOnly() {
        XCTAssertEqual((0...10).map{xkl_word_review_interval_days(UInt32($0))},[0,1,2,3,5,7,10,15,30,90,180])
        XCTAssertEqual(xkl_word_review_interval_days(11),0)
    }
    func testMoreThanTwoChecksAreUsedAndReviewContinuesAfterTransferEvidence()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let id=try XCTUnwrap(e.point?.id)
        var seen=Set<String>()
        for offset in [1,2] {
            try e.start(now:date(day+offset));let p=try XCTUnwrap(e.current),q=try XCTUnwrap(e.check)
            XCTAssertFalse(p.assisted);seen.insert(q.id)
            try e.answer(q.answerID,token:p.id,now:date(day+offset));try e.finish(token:p.id,now:date(day+offset))
        }
        XCTAssertEqual(seen.count,2);XCTAssertTrue(e.reviewPassed(id))
        let due=try XCTUnwrap(e.reviewStatus(id)?.dueAt)
        try e.start(now:due);XCTAssertEqual(e.current?.phase,"question")
        XCTAssertEqual(e.current?.mode,"review");XCTAssertFalse(try XCTUnwrap(e.current).assisted)
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
    }
    func testCalendarMidnightDoesNotTurnTwoHoursIntoIndependentEvidence()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day))
        let id=try XCTUnwrap(e.point?.id);try e.open(id,review:true,now:date(day).addingTimeInterval(7200))
        XCTAssertTrue(try XCTUnwrap(e.current).assisted)
        let p=e.current!,q=e.check!;try e.answer(q.answerID,token:p.id,now:date(day).addingTimeInterval(7200))
        XCTAssertFalse(e.reviewPassed(id));XCTAssertEqual(e.record.events.first(where:{$0.presentationID==p.id && $0.kind=="answer"})?.assisted,true)
    }
    func testReturningToOldQuestionAfterPrerequisiteReadingRefreshesHelpBeforeGrade()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let parent=try XCTUnwrap(e.point?.id)
        try e.next(now:date(day));try read(&e,at:date(day));let p=e.current!,q=e.check!
        try e.answer(q.answerID,token:p.id,now:date(day));try e.finish(token:p.id,now:date(day));let child=p.pointID
        try e.open(child,review:true,now:date(day+2));let pending=e.current!
        XCTAssertFalse(pending.assisted)
        try e.repairPrerequisite(parent,now:date(day+2).addingTimeInterval(1))
        try e.open(child,now:date(day+2).addingTimeInterval(2));XCTAssertEqual(e.current?.id,pending.id)
        XCTAssertTrue(e.current!.assisted)
        try e.answer(e.check!.answerID,token:pending.id,now:date(day+2).addingTimeInterval(3))
        XCTAssertTrue(e.record.events.first(where:{$0.presentationID==pending.id && $0.kind=="answer"})!.assisted)
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
    }
    func testExternalHelpFactCannotOverwriteSnapshotAndIsConsumedBeforeAnswer()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let id=e.point!.id
        try e.open(id,review:true,now:date(day+2));let token=e.current!.id
        let exposure=KnowledgeExposure(id:UUID(),courseID:course().id,at:date(day+2).addingTimeInterval(1),pointIDs:[id],kind:"source",reference:"synthetic/1")
        let before=e.record.events;try e.ingest([exposure]);try e.ingest([exposure]);XCTAssertEqual(e.record.exposures?.count,1);XCTAssertEqual(e.record.events,before)
        try e.answer(e.check!.answerID,token:token,now:date(day+2).addingTimeInterval(2))
        XCTAssertTrue(e.record.events.first(where:{$0.presentationID==token && $0.kind=="answer"})!.assisted)
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
    }
    func testAppendChecksAndFeedbackPreserveQuestionVersionsGradesAndPendingChoiceOrder()throws {
        let original=course();var e=try KnowledgeLearningEngine.fresh(original);try train(&e,at:date(day))
        try e.open(e.point!.id,review:true,now:date(day+2));let pending=e.current!,history=e.record.events
        let updated=try edit(original){o in
            var points=o["points"] as! [[String:Any]],qs=points[0]["checks"] as! [[String:Any]]
            var addition=qs[2];addition["id"]=(addition["id"] as! String)+"-new-version";addition["prompt"]="Another newly authored condition";qs.append(addition)
            var options=qs[1]["choices"] as! [[String:Any]];options[0]["feedback"]="A clearer feedback statement";qs[1]["choices"]=options
            points[0]["checks"]=qs;o["points"]=points
        }
        let appended=try KnowledgeLearningEngine.appending(e.record,to:updated),restored=try KnowledgeLearningEngine(course:updated,record:appended)
        XCTAssertEqual(restored.record.events,history);XCTAssertEqual(restored.current,pending)
        XCTAssertGreaterThan(appended.questionVersions!.count,e.record.questionVersions!.count)
        XCTAssertEqual(try KnowledgeLearningEngine.appending(appended,to:updated),appended)
        XCTAssertEqual(restored.check,e.check) // A visible old question is not silently replaced.
    }
    func testNumericUnitsNonfiniteAndIncompleteMultipleAnswersAreObjectivelyChecked()throws {
        var q=KnowledgeCourse.Check(id:"numeric",prompt:"In the stated ideal model, report the output voltage",choices:[],answerID:"number",explanation:"Use the specified ratio")
        q.responseType="number";q.numeric = .init(value:9.5238,tolerance:0.01,unit:"kV",unitFactors:["kV":1,"V":0.001],requiresUnit:true)
        q.commonErrors=[.init(value:10.5,feedback:"The tap ratio was reversed",errorTag:"method",repairSectionID:"ratio")]
        try q.validateResponse();XCTAssertTrue(q.correct("9520V"));XCTAssertTrue(q.correct("9.52kV"))
        for invalid in ["nan","inf","9.52","9.52A","110/11","1e999kV"]{XCTAssertFalse(q.accepts(invalid))}
        XCTAssertEqual(q.errorTag("10.5kV"),"method");XCTAssertEqual(q.repairSection("10.5kV"),"ratio")
        q.responseType="multiple";q.numeric=nil;q.correctChoiceIDs=["A","C"]
        let choices=["A","B","C"].map{KnowledgeCourse.Check.Choice(id:$0,text:$0,feedback:"Check each condition")}
        var o=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(q)) as? [String:Any]);o["choices"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(choices))
        let multi=try JSONDecoder().decode(KnowledgeCourse.Check.self,from:JSONSerialization.data(withJSONObject:o));try multi.validateResponse()
        XCTAssertTrue(multi.correct("C|A"));XCTAssertFalse(multi.correct("A"));XCTAssertFalse(multi.correct("A|B|C"));XCTAssertFalse(multi.accepts("A|A"))
    }
}

#if os(macOS)
final class KnowledgeUpgradeStoreTests:XCTestCase {
    private func root()throws->URL{let u=FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-upgrade-"+UUID().uuidString);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u}
    @MainActor func testGlobalSourceLedgerIsIndependentAndNeverFabricatesQuestionAnswers()throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[]),store=KnowledgeLearningStore(course:c,baseDirectory:r)
        store.start();let path=r.appendingPathComponent("KnowledgeLearning/power/current.json"),before=try Data(contentsOf:path)
        try KnowledgeExposureLedger.record(course:c,pointIDs:[c.points[0].id],kind:"source",reference:"synthetic/page1",baseDirectory:r)
        XCTAssertEqual(try Data(contentsOf:path),before)
        store.start();XCTAssertFalse(store.blocked);XCTAssertEqual(store.engine?.record.exposures?.count,1)
        XCTAssertTrue(store.engine!.record.events.filter{$0.kind=="answer"}.isEmpty)
        let cold=KnowledgeLearningStore(course:c,baseDirectory:r);XCTAssertFalse(cold.blocked);XCTAssertEqual(cold.engine?.record.exposures?.count,1)
    }
    @MainActor func testInvalidNumericInputDoesNotBlockOrWriteAnAnswer()throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[]),store=KnowledgeLearningStore(course:c,baseDirectory:r)
        store.start();while store.engine?.current?.phase=="lesson"{store.readNext(store.engine!.current!.id)}
        let path=r.appendingPathComponent("KnowledgeLearning/power/current.json"),bytes=try Data(contentsOf:path)
        store.answer("not-an-option",token:store.engine!.current!.id)
        XCTAssertFalse(store.blocked);XCTAssertEqual(try Data(contentsOf:path),bytes)
        store.answer(store.engine!.check!.answerID,token:store.engine!.current!.id)
        XCTAssertFalse(store.blocked);XCTAssertNil(store.error);XCTAssertEqual(store.engine!.record.events.filter{$0.kind=="answer"}.count,1)
    }
}
#endif
