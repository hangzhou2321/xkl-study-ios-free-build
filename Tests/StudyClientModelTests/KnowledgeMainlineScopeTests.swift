import Foundation
import XCTest
@testable import StudyClientModel

final class KnowledgeMainlineScopeTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_793_000_000)
    private func base()->KnowledgeCourse { .synthetic(subject:.power,hash:String(repeating:"a",count:64),legacyIDs:[]) }
    private func scoped(_ course:KnowledgeCourse,archiveScope:String="supplemental") -> KnowledgeCourse {
        var c=course
        c.topics=[.init(id:"core",title:"主线专题",scope:"required",pointIDs:[c.points[0].id]),
                  .init(id:"archive",title:"原讲义补充",scope:archiveScope,pointIDs:[c.points[1].id])]
        return c
    }
    private func read(_ e:inout KnowledgeLearningEngine)throws {
        for _ in 0..<20 {
            guard let p=e.current,p.phase=="lesson" else{return}
            try e.readNext(token:p.id,now:now)
        }
        XCTFail("Synthetic lesson did not reach a question")
    }
    private func train(_ e:inout KnowledgeLearningEngine,_ id:String)throws {
        try e.open(id,now:now);try read(&e)
        let p=try XCTUnwrap(e.current),q=try XCTUnwrap(e.check)
        try e.answer(q.answerID,token:p.id,now:now);try e.finish(token:p.id,now:now)
        XCTAssertNotNil(e.trainedDay(id))
    }
    func testLegacyPackageWithoutTopicsKeepsFullOriginalQueue()throws {
        let c=base()
        let restored=try JSONDecoder().decode(KnowledgeCourse.self,from:JSONEncoder().encode(c))
        XCTAssertNil(restored.topics);XCTAssertEqual(restored.requiredPoints,c.points)
        var e=try KnowledgeLearningEngine.fresh(restored)
        try train(&e,c.points[0].id);try e.next(now:now)
        XCTAssertEqual(e.current?.pointID,c.points[1].id)
    }
    func testRequiredQueueSkipsSupplementalAndOutOfScopeEvenWhenReviewIsDue()throws {
        for scope in ["supplemental","out_of_scope"] {
            let c=scoped(base(),archiveScope:scope)
            var e=try KnowledgeLearningEngine.fresh(c)
            try train(&e,c.points[0].id);try train(&e,c.points[1].id)
            try e.next(now:now)
            XCTAssertNil(e.current)
            let tomorrow=now.addingTimeInterval(2*86_400)
            try e.next(now:tomorrow)
            XCTAssertEqual(e.current?.pointID,c.points[0].id)
            try e.deferCurrent(now:tomorrow)
            XCTAssertNil(e.current,"Archived review must not enter the default queue")
            try e.open(c.points[1].id,now:tomorrow)
            XCTAssertEqual(e.current?.pointID,c.points[1].id,"Manual archive access remains available")
        }
    }
    func testMetadataAdoptionKeepsEntireHistoryVersionsAndArchivedDraft()throws {
        let old=base(),updated=scoped(old)
        var e=try KnowledgeLearningEngine.fresh(old)
        try e.open(old.points[1].id,now:now);try read(&e)
        let p=try XCTUnwrap(e.current)
        try e.saveDraft("B",token:p.id)
        let record=e.record
        let appended=try KnowledgeLearningEngine.appending(record,to:updated)
        XCTAssertEqual(appended,record,"Grouping is outside grading and curriculum identity")
        var restored=try KnowledgeLearningEngine(course:updated,record:appended)
        XCTAssertEqual(restored.current,pWithDraft(p,"B"))
        try restored.continueMainline(now:now)
        XCTAssertEqual(restored.current?.pointID,old.points[0].id)
        XCTAssertEqual(restored.record.bookmarks[old.points[1].id],record.bookmarks[old.points[1].id])
        XCTAssertEqual(Array(restored.record.events.prefix(record.events.count)),record.events)
        XCTAssertEqual(restored.record.questionVersions,record.questionVersions)
        XCTAssertEqual(restored.record.curriculumVersions,record.curriculumVersions)
        try restored.open(old.points[1].id,now:now)
        XCTAssertEqual(restored.current?.draftResponse,"B")
        XCTAssertEqual(restored.current?.id,p.id)
    }
    private func pWithDraft(_ p:KnowledgePresentation,_ text:String)->KnowledgePresentation {var p=p;p.draftResponse=text;return p}
    func testReturningToMainlineDuringArchiveRepairPreservesReturnFrameAndBothDrafts()throws {
        let c=scoped(base()),required=c.points[0].id,archive=c.points[1].id
        var e=try KnowledgeLearningEngine.fresh(c)
        try e.open(required,now:now);try read(&e)
        try e.saveDraft("B",token:try XCTUnwrap(e.current?.id))
        let displaced=try XCTUnwrap(e.current)
        try e.open(archive,now:now);try read(&e)
        try e.saveDraft("A",token:try XCTUnwrap(e.current?.id))
        let original=try XCTUnwrap(e.current)
        try e.repairPrerequisite(required,now:now)
        let frames=e.record.returnFrames,probe=try XCTUnwrap(e.current)
        XCTAssertEqual(probe.mode,"probe")
        var manual=e
        try manual.answer(try XCTUnwrap(manual.check?.answerID),token:probe.id,now:now)
        try manual.finish(token:probe.id,now:now)
        XCTAssertEqual(manual.current?.id,original.id,"An explicitly completed archive probe still returns to its original attempt")
        try e.continueMainline(now:now)
        XCTAssertEqual(e.current?.mode,"practice")
        XCTAssertEqual(e.record.returnFrames,frames)
        XCTAssertEqual(e.record.returnFrames?.last?.displaced,displaced)
        XCTAssertEqual(e.record.bookmarks[archive],original)
        XCTAssertEqual(e.record.presentationArchive?[probe.id.uuidString],probe)
        try e.open(archive,now:now)
        XCTAssertEqual(e.current?.id,original.id)
        XCTAssertEqual(e.current?.definitionID,original.definitionID)
        XCTAssertEqual(e.current?.draftResponse,"A")
        XCTAssertEqual(e.record.bookmarks[required],displaced)
        XCTAssertTrue(e.record.returnFrames?.isEmpty==true)
    }
    func testGroupingReorderAndSharedOtherExamSourceDoNotChangeAssessmentIdentity()throws {
        var c=base()
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as? [String:Any])
        var points=try XCTUnwrap(object["points"] as? [[String:Any]])
        var sources=try XCTUnwrap(points[0]["sources"] as? [[String:Any]])
        sources[0]["title"]="南网题标的共同纲内概念";points[0]["sources"]=sources;object["points"]=points
        c=try JSONDecoder().decode(KnowledgeCourse.self,from:JSONSerialization.data(withJSONObject:object))
        var updated=c
        updated.topics=[.init(id:"second",title:"先展示第二专题",scope:"required",pointIDs:[c.points[1].id]),
                        .init(id:"first",title:"共同纲内内容",scope:"required",pointIDs:[c.points[0].id])]
        XCTAssertEqual(updated.requiredPoints.map(\.id),c.points.map(\.id),"Prerequisites come before the displayed topic without rewriting original point order")
        var e=try KnowledgeLearningEngine.fresh(c);try e.start(now:now)
        let appended=try KnowledgeLearningEngine.appending(e.record,to:updated)
        XCTAssertEqual(appended,e.record)
        XCTAssertTrue(updated.isRequired(c.points[0].id))
        XCTAssertEqual(try KnowledgeLearningEngine.digest(updated.points[0]),try KnowledgeLearningEngine.digest(c.points[0]))
    }
    func testInvalidMetadataCannotDropDuplicateOrInventPoints()throws {
        let c=base()
        var missing=c;missing.topics=[.init(id:"one",title:"漏点",scope:"required",pointIDs:[c.points[0].id])]
        XCTAssertThrowsError(try KnowledgeLearningEngine.fresh(missing))
        var duplicate=scoped(c);duplicate.topics![1] = .init(id:"two",title:"重复",scope:"supplemental",pointIDs:[c.points[0].id,c.points[1].id])
        XCTAssertThrowsError(try KnowledgeLearningEngine.fresh(duplicate))
        var invalid=scoped(c,archiveScope:"guess")
        XCTAssertThrowsError(try KnowledgeLearningEngine.fresh(invalid))
        invalid.topics![1] = .init(id:"two",title:"假点",scope:"supplemental",pointIDs:["absent"])
        XCTAssertThrowsError(try KnowledgeLearningEngine.fresh(invalid))
    }
}
