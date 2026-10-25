import Foundation
import XCTest
@testable import StudyClientModel

final class KnowledgeLearningTests:XCTestCase {
    private let day=20_750
    private func date(_ day:Int)->Date{Date(timeIntervalSince1970:Double(day)*86400+43200)}
    private func course()->KnowledgeCourse{.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])}
    private func read(_ engine:inout KnowledgeLearningEngine,now:Date)throws {
        var count=0
        while let p=engine.current,p.phase=="lesson" {count+=1;guard count<12 else{XCTFail("lesson did not reach a diagnostic");return};try engine.readNext(token:p.id,now:now)}
    }
    private func train(_ engine:inout KnowledgeLearningEngine,now:Date)throws {
        try engine.start(now:now);try read(&engine,now:now)
        let p=try XCTUnwrap(engine.current),q=try XCTUnwrap(engine.check)
        try engine.answer(q.answerID,token:p.id,now:now);try engine.finish(token:p.id,now:now)
    }
    func testReadingAndAssistedPracticeNeverBecomeIndependentReview()throws {
        var engine=try KnowledgeLearningEngine.fresh(course());try engine.start(now:date(day))
        let id=try XCTUnwrap(engine.point?.id)
        try read(&engine,now:date(day));XCTAssertNil(engine.trainedDay(id));XCTAssertFalse(engine.reviewPassed(id))
        let p=try XCTUnwrap(engine.current),q=try XCTUnwrap(engine.check)
        try engine.answer(q.answerID,token:p.id,now:date(day));try engine.finish(token:p.id,now:date(day))
        XCTAssertEqual(engine.trainedDay(id),day);XCTAssertFalse(engine.reviewPassed(id))
        XCTAssertEqual(engine.record.events.last?.assisted,true)
        try engine.start(now:date(day+1));let review=try XCTUnwrap(engine.current)
        XCTAssertEqual(review.checkIndex,1);XCTAssertFalse(review.assisted)
        try engine.hint(token:review.id,now:date(day+1))
        try engine.answer(try XCTUnwrap(engine.check?.answerID),token:review.id,now:date(day+1))
        try engine.finish(token:review.id,now:date(day+1));XCTAssertFalse(engine.reviewPassed(id))
        try engine.start(now:date(day+2));let delayed=try XCTUnwrap(engine.current)
        try engine.answer(try XCTUnwrap(engine.check?.answerID),token:delayed.id,now:date(day+2))
        XCTAssertTrue(engine.reviewPassed(id))
        _=try KnowledgeLearningEngine(course:course(),record:engine.record)
    }
    func testDuplicateReadAndAnswerTokensDoNotAdvanceOrCountTwice()throws {
        var engine=try KnowledgeLearningEngine.fresh(course());try engine.start(now:date(day))
        let old=try XCTUnwrap(engine.current);try engine.readNext(token:old.id,now:date(day))
        let saved=engine.record;try engine.readNext(token:old.id,now:date(day));XCTAssertEqual(engine.record,saved)
        try read(&engine,now:date(day));let p=try XCTUnwrap(engine.current),q=try XCTUnwrap(engine.check)
        try engine.answer(q.answerID,token:p.id,now:date(day));let answered=engine.record
        try engine.answer(q.answerID,token:p.id,now:date(day));XCTAssertEqual(engine.record,answered)
        XCTAssertEqual(engine.record.events.filter{$0.kind=="answer"}.count,1)
    }
    func testWrongAnswerReturnsToExplanationAndColdRestoreKeepsChoicesAndBreakpoint()throws {
        var engine=try KnowledgeLearningEngine.fresh(course());try engine.start(now:date(day));try read(&engine,now:date(day))
        let p=try XCTUnwrap(engine.current),q=try XCTUnwrap(engine.check),wrong=try XCTUnwrap(q.choices.first{$0.id != q.answerID})
        try engine.answer(wrong.id,token:p.id,now:date(day));XCTAssertNil(engine.trainedDay(p.pointID))
        var restored=try KnowledgeLearningEngine(course:course(),record:engine.record)
        XCTAssertEqual(restored.current,engine.current)
        try restored.finish(token:p.id,now:date(day));XCTAssertEqual(restored.current?.phase,"lesson")
        XCTAssertNotEqual(restored.current?.id,p.id)
        XCTAssertEqual(restored.record.events.filter{$0.kind=="answer"}.count,1)
    }
    func testExplanationMetadataCanChangeButAnsweredQuestionMeaningCannot()throws {
        var engine=try KnowledgeLearningEngine.fresh(course());try train(&engine,now:date(day))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(course())) as? [String:Any])
        var points=try XCTUnwrap(object["points"] as? [[String:Any]])
        var sections=try XCTUnwrap(points[0]["sections"] as? [[String:Any]]);sections[0]["body"]="A clearer synthetic explanation of the same target."
        points[0]["sections"]=sections;object["points"]=points
        let clearer=try JSONDecoder().decode(KnowledgeCourse.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(try KnowledgeLearningEngine.appending(engine.record,to:clearer),engine.record)
        var checks=try XCTUnwrap(points[0]["checks"] as? [[String:Any]]);checks[0]["prompt"]="A different assessment under the same ID"
        points[0]["checks"]=checks;object["points"]=points
        let changed=try JSONDecoder().decode(KnowledgeCourse.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertThrowsError(try KnowledgeLearningEngine.appending(engine.record,to:changed))
    }
    func testFalseCorrectnessAndBackwardDatesAreRejectedWithoutResettingHistory()throws {
        var engine=try KnowledgeLearningEngine.fresh(course());try train(&engine,now:date(day))
        let saved=engine.record;XCTAssertThrowsError(try engine.start(now:date(day-1)));XCTAssertEqual(engine.record,saved)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(saved)) as? [String:Any])
        var events=try XCTUnwrap(object["events"] as? [[String:Any]])
        let index=try XCTUnwrap(events.firstIndex{$0["kind"] as? String=="answer"});events[index]["correct"]=false;object["events"]=events
        let corrupt=try JSONDecoder().decode(KnowledgeLearningRecord.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertThrowsError(try KnowledgeLearningEngine(course:course(),record:corrupt))
    }
    func testReorderingTeachingMetadataKeepsStableIDsAnswersAndBreakpoint()throws {
        var engine=try KnowledgeLearningEngine.fresh(course());try train(&engine,now:date(day))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(course())) as? [String:Any])
        let points=try XCTUnwrap(object["points"] as? [[String:Any]]);object["points"]=Array(points.reversed())
        let reordered=try JSONDecoder().decode(KnowledgeCourse.self,from:JSONSerialization.data(withJSONObject:object))
        let kept=try KnowledgeLearningEngine.appending(engine.record,to:reordered)
        XCTAssertEqual(kept,engine.record)
        let restored=try KnowledgeLearningEngine(course:reordered,record:kept)
        XCTAssertEqual(restored.current,engine.current)
        XCTAssertEqual(restored.record.events,engine.record.events)
    }
}

#if os(macOS)
final class KnowledgeLearningStoreTests:XCTestCase {
    private func root()throws->URL {
        let r=FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:r,withIntermediateDirectories:true);return r
    }
    @MainActor func testSeparateNamespaceColdResumeAndFailedWriteKeepDurableHistory()throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let legacy=r.appendingPathComponent("ProfessionalRecall/power/current.json")
        try FileManager.default.createDirectory(at:legacy.deletingLastPathComponent(),withIntermediateDirectories:true)
        let old=Data("synthetic immutable legacy archive".utf8);try old.write(to:legacy)
        let c=KnowledgeCourse.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])
        var fail=false
        let store=KnowledgeLearningStore(course:c,baseDirectory:r,writer:{data,url in
            if fail{throw CocoaError(.fileWriteNoPermission)};try DurableFile.write(data,to:url)
        })
        store.start();let p=try XCTUnwrap(store.engine?.current);let current=r.appendingPathComponent("KnowledgeLearning/power/current.json")
        let saved=try Data(contentsOf:current);fail=true;store.readNext(p.id)
        XCTAssertTrue(store.blocked);XCTAssertEqual(try Data(contentsOf:current),saved);XCTAssertEqual(store.engine?.current,p)
        let restored=KnowledgeLearningStore(course:c,baseDirectory:r);XCTAssertFalse(restored.blocked)
        XCTAssertEqual(restored.engine?.current,p);XCTAssertEqual(try Data(contentsOf:legacy),old)
    }
    @MainActor func testStalePageCannotOverwriteNewerKnowledgeProgress()throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let c=KnowledgeCourse.synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[])
        let first=KnowledgeLearningStore(course:c,baseDirectory:r);first.start()
        let stale=KnowledgeLearningStore(course:c,baseDirectory:r)
        first.readNext(try XCTUnwrap(first.engine?.current?.id))
        let current=r.appendingPathComponent("KnowledgeLearning/power/current.json"),saved=try Data(contentsOf:current)
        stale.readNext(try XCTUnwrap(stale.engine?.current?.id))
        XCTAssertTrue(stale.blocked);XCTAssertEqual(try Data(contentsOf:current),saved)
    }
}
#endif
