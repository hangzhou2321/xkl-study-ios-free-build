import Foundation
import XCTest
import CPocket
import StudyCore
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
    func testUnindexedContinuationPageStillRecordsDocumentHelpInsteadOfBypassingIt() {
        let c=course()
        XCTAssertEqual(Set(c.affectedPoints(documentID:"synthetic",page:99)),Set(c.points.map(\.id)))
        XCTAssertEqual(Set(c.affectedPoints(documentID:"synthetic",page:1)),Set(c.points.map(\.id))) // The page's mapped composite question also exposes point two.
    }
    func testV2InlineNumberThenMultipleAndTransferRequireSeparateColdEvidence()throws {
        let c=KnowledgeCourse.adaptiveSynthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])
        var e=try KnowledgeLearningEngine.fresh(c);try e.start(now:date(day));try read(&e,at:date(day))
        XCTAssertEqual(e.check?.type,"number");let token=e.current!.id
        try e.answer("240min",token:token,now:date(day));try e.finish(token:token,now:date(day))
        try read(&e,at:date(day));let id=e.point!.id
        XCTAssertEqual(e.current?.phase,"complete");XCTAssertNotNil(e.trainedAt(id));XCTAssertFalse(e.reviewPassed(id))
        try e.open(id,review:true,now:date(day+1));XCTAssertEqual(e.check?.type,"multiple")
        let independent=e.current!.id;try e.answer("A|C",token:independent,now:date(day+1));try e.finish(token:independent,now:date(day+1))
        XCTAssertFalse(e.reviewPassed(id));try e.start(now:date(day+2));XCTAssertEqual(e.check?.purpose,"transfer")
        try e.answer(e.check!.answerID,token:e.current!.id,now:date(day+2));XCTAssertTrue(e.reviewPassed(id))
        _=try KnowledgeLearningEngine(course:c,record:e.record)
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
    func testOpeningTooEarlyThenWaitingDoesNotAcquireDelayedEligibility()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let id=e.point!.id
        let opened=date(day).addingTimeInterval(7200);try e.open(id,review:true,now:opened)
        let p=e.current!;XCTAssertEqual(p.shownAt,opened);XCTAssertEqual(p.eligibleAtShow,false)
        try e.start(now:date(day+2));XCTAssertEqual(e.current?.shownAt,opened)
        try e.answer(e.check!.answerID,token:p.id,now:date(day+2))
        let a=e.record.events.last{$0.kind=="answer"}!
        XCTAssertTrue(a.assisted);XCTAssertEqual(a.eligibleAtShow,false);XCTAssertFalse(e.reviewPassed(id))
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
    }
    func testHelpDuringAttemptCannotExpireWhileQuestionRemainsOpen()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let id=e.point!.id
        try e.open(id,review:true,now:date(day+2));let p=e.current!
        try e.ingest([.init(id:UUID(),courseID:course().id,at:date(day+2).addingTimeInterval(1),pointIDs:[id],kind:"source",reference:"synthetic/1")])
        try e.answer(e.check!.answerID,token:p.id,now:date(day+4))
        XCTAssertTrue(e.record.events.last{$0.kind=="answer"}!.assisted)
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
    }
    func testDisplayWithoutAnswerConsumesNoveltyAndExhaustedPoolDoesNotInventTransfer()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let id=e.point!.id
        try e.open(id,review:true,now:date(day));let first=e.check!.id
        XCTAssertEqual(e.current?.familiarity,"unseen-in-app")
        try e.open(id,review:true,now:date(day));XCTAssertNotEqual(e.check?.id,first)
        let exposed=e.check!.id;XCTAssertEqual(e.current?.familiarity,"unseen-in-app")
        try e.answer(e.check!.answerID,token:e.current!.id,now:date(day));try e.finish(token:e.current!.id,now:date(day))
        XCTAssertTrue(e.unseenTransferPoolEmpty(id))
        try e.open(id,review:true,now:date(day+2));XCTAssertEqual(e.check?.id,first);XCTAssertEqual(e.current?.familiarity,"seen-question")
        try e.answer(e.check!.answerID,token:e.current!.id,now:date(day+2));try e.finish(token:e.current!.id,now:date(day+2))
        try e.start(now:date(day+3));XCTAssertEqual(e.check?.id,exposed);XCTAssertEqual(e.current?.familiarity,"seen-answer")
        try e.answer(e.check!.answerID,token:e.current!.id,now:date(day+3));XCTAssertFalse(e.reviewPassed(id));XCTAssertEqual(e.reviewStatus(id)?.hasTransfer,false)
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
    }
    func testReturningToOldQuestionAfterPrerequisiteReadingRefreshesHelpBeforeGrade()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try train(&e,at:date(day));let parent=try XCTUnwrap(e.point?.id)
        try e.next(now:date(day));try read(&e,at:date(day));let p=e.current!,q=e.check!
        try e.answer(q.answerID,token:p.id,now:date(day));try e.finish(token:p.id,now:date(day));let child=p.pointID
        try e.open(child,review:true,now:date(day+2));let pending=e.current!
        XCTAssertFalse(pending.assisted)
        try e.repairPrerequisite(parent,now:date(day+2).addingTimeInterval(1))
        try e.hint(token:e.current!.id,now:date(day+2).addingTimeInterval(1))
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
    func testAddedMethodAndChangedPrerequisitesDoNotRetroactivelyInvalidateOldEvidenceOrLesson()throws {
        let old=course();var e=try KnowledgeLearningEngine.fresh(old);try train(&e,at:date(day))
        let id=e.point!.id;try e.open(id,review:true,now:date(day+1));try e.answer(e.check!.answerID,token:e.current!.id,now:date(day+1))
        let history=e.record.events,held=e.current!,oldLesson=e.displayPoint!.sections
        let updated=try edit(old){o in
            var ps=o["points"] as! [[String:Any]],qs=ps[0]["checks"] as! [[String:Any]],ss=ps[0]["sections"] as! [[String:Any]]
            ps[0]["prerequisites"]=[ps[1]["id"] as! String];ps[1]["prerequisites"]=[] as [String]
            let added=id+"-added-method"
            for i in qs.indices{qs[i]["skillID"]=id;qs[i]["purpose"]=i==0 ? "guided":(i==1 ? "independent":"transfer")}
            let new=qs.enumerated().map{i,q -> [String:Any] in var v=q;v["id"]=(q["id"] as! String)+"-new-method";v["prompt"]="A newly taught method with different conditions \(i)";v["skillID"]=added;return v}
            ss[0]["body"]="A new revision must not replace the old visible explanation."
            ss.append(["id":"new-method","title":"New method","body":"Additional instruction and worked example"])
            ps[0]["sections"]=ss;ps[0]["checks"]=qs+new
            ps[0]["skills"]=[["id":id,"title":"Original method","lessonSectionID":"section-0"],["id":added,"title":"Added method","lessonSectionID":"new-method"]]
            o["points"]=ps
        }
        let migrated=try KnowledgeLearningEngine.appending(e.record,to:updated),restored=try KnowledgeLearningEngine(course:updated,record:migrated)
        XCTAssertEqual(restored.record.events,history);XCTAssertEqual(restored.current,held);XCTAssertEqual(restored.displayPoint?.sections,oldLesson)
        XCTAssertEqual(restored.learnedSkills(id),1);XCTAssertNil(restored.trainedAt(id)) // The added method is not fabricated as complete.
        XCTAssertTrue(e.record.curriculumVersions!.allSatisfy{migrated.curriculumVersions?[$0.key]==$0.value})
    }
    func testMinimalPrerequisiteProbeRestoresBothPendingDraftsWithoutCompletingParent()throws {
        var e=try KnowledgeLearningEngine.fresh(course());try e.start(now:date(day));try read(&e,at:date(day))
        let parent=e.current!.pointID;try e.saveDraft("A pending parent response",token:e.current!.id);let parentMark=e.current!
        let child=course().points[1].id;try e.open(child,now:date(day));try read(&e,at:date(day))
        try e.saveDraft("A pending child response",token:e.current!.id);let childMark=e.current!
        try e.repairPrerequisite(parent,now:date(day));XCTAssertEqual(e.current?.mode,"probe")
        try e.answer(e.check!.answerID,token:e.current!.id,now:date(day));try e.finish(token:e.current!.id,now:date(day))
        XCTAssertEqual(e.current?.id,childMark.id);XCTAssertEqual(e.current?.draftResponse,childMark.draftResponse)
        XCTAssertEqual(e.record.bookmarks[parent],parentMark);XCTAssertNil(e.trainedAt(parent));XCTAssertNil(e.trainedAt(child))
        XCTAssertTrue(e.record.events.contains{$0.kind=="answer" && $0.purpose=="probe"})
        _=try KnowledgeLearningEngine(course:course(),record:e.record)
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
    func testRealV1ShapeMigratesWithoutConvertingOldGradesOrReplacingVisibleQuestion()throws {
        let original=course(),point=original.points[0],token=UUID(),q=point.checks[1]
        let mark=KnowledgePresentation(id:token,pointID:point.id,phase:"question",page:point.sections.count+1,checkIndex:1,order:Array(q.choices.map(\.id).reversed()),assisted:false,hintVisible:false,selectedID:nil)
        let event=KnowledgeLearningEvent(id:UUID(),sequence:1,day:day,at:date(day),kind:"answer",pointID:point.id,presentationID:UUID(),checkID:point.checks[0].id,selectedID:point.checks[0].answerID,correct:true,assisted:true)
        let old=KnowledgeLearningRecord(format:"knowledge-learning-v1",subject:original.subject,courseID:original.id,pointIDs:original.points.map(\.id),pointDigests:try Dictionary(uniqueKeysWithValues:original.points.map{($0.id,try KnowledgeLearningEngine.digest($0))}),currentID:point.id,bookmarks:[point.id:mark],events:[event],deferredIDs:[])
        let updated=try edit(original){o in
            o["format"]="knowledge-course-v2";var points=o["points"] as! [[String:Any]]
            for i in points.indices {
                let prior=points[i]["checks"] as! [[String:Any]],sections=points[i]["sections"] as! [[String:Any]]
                points[i]["legacyBaseline"]=["checks":prior,"sectionCount":sections.count]
                points[i]["retiredChecks"]=prior;points[i]["skills"]=[["id":"new-method-\(i)","title":"New method","lessonSectionID":"section-0"]]
                points[i]["checks"]=prior.enumerated().map{n,q -> [String:Any] in var q=q;q["id"]=(q["id"] as! String)+"-v2";q["skillID"]="new-method-\(i)";q["purpose"]=n==0 ? "guided":(n==1 ? "independent":"transfer");return q}
                points[i]["sections"]=sections+[["title":"A new worked method","body":"A complete explanation"]]
            };o["points"]=points
        }
        let migrated=try KnowledgeLearningEngine.appending(old,to:updated),restored=try KnowledgeLearningEngine(course:updated,record:migrated)
        XCTAssertEqual(migrated.events,old.events);XCTAssertEqual(migrated.pointDigests,old.pointDigests)
        XCTAssertEqual(restored.current?.id,token);XCTAssertEqual(restored.current?.order,mark.order);XCTAssertEqual(restored.check,q)
        XCTAssertEqual(restored.current?.page,mark.page+1);XCTAssertNil(restored.trainedAt(point.id));XCTAssertFalse(restored.reviewPassed(point.id))
        XCTAssertEqual(try KnowledgeLearningEngine.appending(migrated,to:updated),migrated)
    }
    func testDraftAndWrongAnswerRepairSectionSurviveColdResume()throws {
        let c=try edit(course()){o in
            var points=o["points"] as! [[String:Any]],checks=points[0]["checks"] as! [[String:Any]],choices=checks[0]["choices"] as! [[String:Any]]
            choices[1]["repairSectionID"]="section-1";choices[1]["errorTag"]="conditions";checks[0]["choices"]=choices;points[0]["checks"]=checks;o["points"]=points
        }
        var e=try KnowledgeLearningEngine.fresh(c);try e.start(now:date(day));try read(&e,at:date(day));let p=e.current!
        try e.saveDraft("B",token:p.id);e=try KnowledgeLearningEngine(course:c,record:e.record);XCTAssertEqual(e.current?.draftResponse,"B")
        try e.answer(e.check!.choices[1].id,token:p.id,now:date(day));try e.finish(token:p.id,now:date(day))
        XCTAssertEqual(e.current?.phase,"lesson");XCTAssertEqual(e.current?.page,1)
        XCTAssertEqual(e.record.events.last(where:{$0.kind=="answer"})?.errorTag,"conditions")
        _=try KnowledgeLearningEngine(course:c,record:e.record)
    }
}

#if os(macOS)
final class KnowledgeUpgradeStoreTests:XCTestCase {
    private func root()throws->URL{let u=FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-upgrade-"+UUID().uuidString);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u}
    @MainActor func testLinkedCardUsesSameLedgerAndRejectsForeignCardWithoutInventingAnswers()throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])
        let store=KnowledgeLearningStore(course:c,baseDirectory:r);store.start()
        let current=r.appendingPathComponent("KnowledgeLearning/power/current.json"),before=try Data(contentsOf:current)
        try KnowledgeExposureLedger.recordCard(course:c,cardID:c.points[0].id+":knowledge-v1",baseDirectory:r)
        XCTAssertEqual(try Data(contentsOf:current),before)
        XCTAssertThrowsError(try KnowledgeExposureLedger.recordCard(course:c,cardID:"archived-foreign-card",baseDirectory:r))
        let exposures=try KnowledgeExposureLedger.read(course:c,baseDirectory:r)
        XCTAssertEqual(exposures.count,1);XCTAssertEqual(exposures[0].pointIDs,[c.points[0].id])
        store.start();XCTAssertFalse(store.blocked,store.error ?? "");XCTAssertTrue(store.engine!.record.events.filter{$0.kind=="answer"}.isEmpty)
    }
    @MainActor func testV1MigrationBacksUpExactBytesAndReimportDoesNotRewriteHistory()throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])
        var e=try KnowledgeLearningEngine.fresh(c);try e.start()
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(e.record)) as? [String:Any])
        object["format"]="knowledge-learning-v1"
        for key in ["questionVersions","legacyOrder","exposures","returnPoints"]{object.removeValue(forKey:key)}
        var bookmarks=object["bookmarks"] as! [String:[String:Any]]
        for id in bookmarks.keys {for key in ["definitionID","mode","resumePage","retrySkillID","draftResponse"]{bookmarks[id]!.removeValue(forKey:key)}}
        object["bookmarks"]=bookmarks
        let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted])
        let folder=r.appendingPathComponent("KnowledgeLearning/power"),current=folder.appendingPathComponent("current.json"),initial=folder.appendingPathComponent("initial.json")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try bytes.write(to:initial);try bytes.write(to:current)
        let store=KnowledgeLearningStore(course:c,baseDirectory:r);XCTAssertFalse(store.blocked,store.error ?? "")
        XCTAssertEqual(try Data(contentsOf:initial),bytes)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("before-append-"+StudySHA256.hex(bytes)+".json")),bytes)
        XCTAssertEqual(store.engine?.current?.id,e.current?.id);XCTAssertEqual(store.engine?.record.events,e.record.events)
        let migrated=try Data(contentsOf:current),again=KnowledgeLearningStore(course:c,baseDirectory:r)
        XCTAssertFalse(again.blocked,again.error ?? "");XCTAssertEqual(try Data(contentsOf:current),migrated)
        XCTAssertEqual(try Data(contentsOf:initial),bytes)
    }
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
