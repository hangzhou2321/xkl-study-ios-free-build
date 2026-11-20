#if canImport(Combine)
import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

final class RefinedMemoryStoreTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1_799_500_000)
    private func data(_ name:String, variant:String="") throws -> Data {
        let rows:[[String:Any]]=[
            ["ref":"unit#1","q":"先看哪个条件"+variant,"a":"先看边界","how":"A","kind":"直接认","note":"","colors":[["field":"a","color":"red","text":"边界","location":2]]],
            ["ref":"unit#3","q":"下一个条件","a":"再看方向","how":"B","kind":"判断","note":"","colors":[],"core":["方向"]],
            ["ref":"unit#extra-a","q":"第三个条件","a":"检查是否满足","how":"C","kind":"换问","note":"","colors":[]]
        ]
        let raw:[String:Any]=["subject":name,"baseSHA256":String(repeating:"a",count:64),
                               "cards":[["key":"unit","title":"合成单元","chapter":"练习章",
                                         "evidence":["label":"示例","detail":"仅测试使用"],"rows":rows]]]
        return try JSONSerialization.data(withJSONObject:raw,options:.sortedKeys)
    }
    private func workspace() throws -> URL {
        let f=FileManager.default.temporaryDirectory.appendingPathComponent("refined-memory-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:f,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:f) }
        return f
    }
    private func supplement(for base:Data, ref:String="unit#brief", group:String="unit") throws -> Data {
        let row:[String:Any]=["ref":ref,"q":"换个条件时看哪里","a":"先检查位置","kind":"判断","how":"B","note":"","colors":[]]
        let extra:[String:Any]=["subject":"power","baseSHA256":StudySHA256.hex(base),
                               "additions":[["group":group,"row":row,"source":"合成讲义第1页"]]]
        return try JSONSerialization.data(withJSONObject:extra,options:.sortedKeys)
    }
    private func twoGroups() throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data("电力系统")) as? [String:Any])
        var groups = try XCTUnwrap(json["cards"] as? [[String:Any]])
        let row:[String:Any] = ["ref":"other#1","q":"另组的条件","a":"角度","kind":"判断","how":"A","note":"","colors":[]]
        groups.append(["key":"other","title":"第二组","chapter":"下一章","evidence":["label":"示例","detail":"合成内容"],"rows":[row]])
        json["cards"]=groups
        return try JSONSerialization.data(withJSONObject:json,options:.sortedKeys)
    }
    @MainActor func testDirectoryAndActualFirstLearningStayInTeachingOrderAfterMigrationAndReopen() async throws {
        let raw=try twoGroups(),extra=try supplement(for:raw)
        let expected=["unit#1","unit#3","unit#extra-a","unit#brief","other#1"]
        for hasPreviousCourse in [false,true] {
            let root=try workspace()
            if hasPreviousCourse {
                let old=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now);ready(old)
            }
            var current=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now)
            ready(current);XCTAssertEqual(current.entries.map(\.id),expected)
            let slots=hasPreviousCourse ? ["unit#1","unit#3","unit#extra-a","other#1","unit#brief"] : expected
            XCTAssertEqual(current.engine?.record.cardIDs,slots.map { "refined-power:"+$0 })
            current.start(now:now);ready(current)
            for (index,ref) in expected.enumerated() {
                XCTAssertEqual(current.current?.id,ref)
                let token=try XCTUnwrap(current.presentation).id
                if index==3 {
                    current.reveal(token:token,now:now)
                    current=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now)
                    ready(current);XCTAssertEqual(current.presentation?.id,token);XCTAssertTrue(current.presentation?.revealed == true)
                }
                current.markFamiliar(token:token,now:now);ready(current)
                XCTAssertEqual(current.familiarRefs,Set(expected.prefix(index+1)))
                XCTAssertEqual(current.firstPassRemaining,expected.count-index-1)
            }
        }
    }
    @MainActor func testMatchedRevisionKeepsTheOriginalIdentityAndRelocatesOriginalBookMark() async throws {
        let raw=try data("电力系统"), root=try workspace()
        let original=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now);ready(original)
        original.start(now:now);let shown=try XCTUnwrap(original.presentation)
        original.reveal(token:shown.id,now:now)
        let row=try XCTUnwrap(original.current).row
        let currentURL=pointer(root,"power"), before=try Data(contentsOf:currentURL)
        func overlay(old:String,answer:String) throws -> Data {
            let revision=["ref":row.ref,"oldQ":row.q,"oldA":old,"q":row.q,"a":answer,"source":"合成课本第2页"]
            let document:[String:Any]=["subject":"power","baseSHA256":StudySHA256.hex(raw),"additions":[],"revisions":[revision]]
            return try JSONSerialization.data(withJSONObject:document,options:.sortedKeys)
        }
        for bad in [try overlay(old:"错版",answer:"先检查边界"),try overlay(old:row.a,answer:"改看其他"),
                    try overlay(old:row.a,answer:"原边界和新边界")] {
            let skipped=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:bad,now:now)
            XCTAssertTrue(skipped.blocked);XCTAssertEqual(try Data(contentsOf:currentURL),before)
        }
        let valid=try overlay(old:row.a,answer:"先检查边界")
        let revised=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:valid,now:now)
        ready(revised);XCTAssertEqual(revised.presentation,original.presentation)
        XCTAssertEqual(revised.current?.row.a,"先检查边界");XCTAssertEqual(revised.current?.row.colors.first?.location,3)
        XCTAssertEqual(revised.current?.group.evidence.detail,"合成课本第2页")
        XCTAssertEqual(revised.engine?.record,original.engine?.record)
        XCTAssertEqual(revised.engine?.deck.cards.first?.card.answer,row.a)
        revised.grade(remembered:false,token:shown.id,now:now);ready(revised)
        XCTAssertEqual(revised.engine?.record.attempts.count,1)
    }
    @MainActor private func ready(_ s:RefinedMemoryStore,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertFalse(s.blocked,s.error ?? "",file:file,line:line);XCTAssertNil(s.error,file:file,line:line)
        XCTAssertNotNil(s.engine,file:file,line:line)
    }
    private func pointer(_ root:URL,_ subject:String)->URL {
        root.appendingPathComponent("RefinedMemory/"+subject+"/current.json")
    }
    @MainActor func testSeparateRowsResumeBeforeGradeAndOneActualAttempt() async throws {
        let root=try workspace(), raw=try data("计算机"), powerRaw=try data("电力系统")
        let power=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:powerRaw,now:now);ready(power)
        let powerBytes=try Data(contentsOf:pointer(root,"power")), old=root.appendingPathComponent("HandbookWordRecall/computer/current.json")
        try FileManager.default.createDirectory(at:old.deletingLastPathComponent(),withIntermediateDirectories:true)
        let sentinel=Data("untouched legacy-state".utf8);try sentinel.write(to:old)
        let s=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:raw,now:now);ready(s)
        XCTAssertEqual(s.entries.map(\.id),["unit#1","unit#3","unit#extra-a"])
        XCTAssertEqual(s.stats(on:now)?.total,3);XCTAssertEqual(s.firstPassRemaining,3)
        XCTAssertEqual(s.engine?.record.migration.sourceRecords,[])
        s.start(now:now);ready(s)
        let shown=try XCTUnwrap(s.presentation), item=try XCTUnwrap(s.current)
        XCTAssertEqual(shown.cardID,"refined-computer:"+item.id)
        s.grade(remembered:true,token:shown.id,now:now);XCTAssertNotNil(s.error)
        XCTAssertEqual(s.engine?.record.attempts.count,0)
        s.reveal(token:shown.id,now:now);ready(s);XCTAssertEqual(s.presentation?.revealed,true)
        let currentFile=pointer(root,"computer"), checkpoint=try Data(contentsOf:currentFile)
        let resumed=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:raw,now:now);ready(resumed)
        XCTAssertEqual(try Data(contentsOf:currentFile),checkpoint)
        XCTAssertEqual(resumed.presentation?.id,shown.id);XCTAssertEqual(resumed.current?.row.ref,item.row.ref)
        let tomorrow=now.addingTimeInterval(86_400)
        resumed.start(now:tomorrow); ready(resumed);XCTAssertEqual(resumed.presentation?.id,shown.id)
        XCTAssertEqual(resumed.presentation?.revealed,true);XCTAssertEqual(resumed.engine?.record.attempts.count,0)
        resumed.grade(remembered:false,token:shown.id,now:tomorrow);ready(resumed)
        let one=try XCTUnwrap(resumed.engine).record.attempts
        XCTAssertEqual(one.count,1);XCTAssertFalse(one[0].remembered);XCTAssertEqual(one[0].cardID,shown.cardID)
        XCTAssertEqual(one[0].day,UInt32(try ConceptCalendar.studyDay(tomorrow)))
        XCTAssertEqual(resumed.firstPassRemaining,2)
        let graded=try Data(contentsOf:currentFile)
        resumed.grade(remembered:false,token:shown.id,now:tomorrow)
        XCTAssertEqual(try Data(contentsOf:currentFile),graded)
        s.grade(remembered:true,token:shown.id,now:tomorrow);XCTAssertTrue(s.blocked)
        XCTAssertEqual(try Data(contentsOf:currentFile),graded)
        XCTAssertEqual(try Data(contentsOf:pointer(root,"power")),powerBytes);XCTAssertEqual(try Data(contentsOf:old),sentinel)
    }
    @MainActor func testFamiliarPostponeAndRequeueRemainDistinct() async throws {
        let root=try workspace(),raw=try data("电力系统")
        let s=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now);ready(s)
        s.start(now:now);ready(s)
        let a=try XCTUnwrap(s.presentation), firstRef=try XCTUnwrap(s.current).id
        s.postpone(token:a.id,now:now);ready(s);XCTAssertNotEqual(s.presentation?.id,a.id)
        XCTAssertTrue(s.engine?.record.attempts.isEmpty == true)
        let b=try XCTUnwrap(s.presentation), bRef=try XCTUnwrap(s.current).id
        XCTAssertNotEqual(firstRef,bRef)
        s.markFamiliar(token:b.id,now:now);ready(s)
        XCTAssertTrue(s.familiarRefs.contains(bRef)); XCTAssertTrue(s.engine?.record.attempts.isEmpty == true)
        s.requeue(ref:bRef,now:now);ready(s)
        XCTAssertFalse(s.familiarRefs.contains(bRef)); XCTAssertTrue(s.engine?.record.attempts.isEmpty == true)
        let reopened=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now);ready(reopened)
        XCTAssertEqual(reopened.engine?.record,s.engine?.record)
    }
    @MainActor func testDamagedOrChangedCourseCannotOverwriteCurrent() async throws {
        let root=try workspace(), course=try data("计算机")
        let s=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:course,now:now);ready(s)
        let url=pointer(root,"computer"), bytes=try Data(contentsOf:url)
        let changed=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:try data("计算机",variant:"?"),now:now)
        XCTAssertTrue(changed.blocked);XCTAssertEqual(try Data(contentsOf:url),bytes)
        let wrong=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:course,now:now)
        XCTAssertTrue(wrong.blocked);XCTAssertFalse(FileManager.default.fileExists(atPath:pointer(root,"power").path))
        let broken=Data("{broken".utf8);try broken.write(to:url)
        let reload=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:course,now:now)
        XCTAssertTrue(reload.blocked);XCTAssertNil(reload.engine)
        s.start(now:now);XCTAssertTrue(s.blocked);XCTAssertEqual(try Data(contentsOf:url),broken)
    }
    @MainActor func testWriteFailureBeforeOrAfterRenameDoesNotCount() async throws {
        for afterRename in [false,true] {
            let root=try workspace(), raw=try data("计算机")
            let initial=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:raw,now:now)
            initial.start(now:now);ready(initial);let p=try XCTUnwrap(initial.presentation)
            initial.reveal(token:p.id,now:now);ready(initial)
            let url=pointer(root,"computer"), before=try Data(contentsOf:url)
            let fail=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:raw,now:now) { d,u in
                if afterRename { try DurableFile.write(d,to:u) }
                throw NSError(domain:"SyntheticWriteFailure",code:1)
            };ready(fail)
            fail.grade(remembered:true,token:p.id,now:now);XCTAssertTrue(fail.blocked)
            XCTAssertEqual(fail.engine?.record.attempts.count,0);XCTAssertEqual(try Data(contentsOf:url),before)
            let relaunch=RefinedMemoryStore(subject:.computer,baseDirectory:root,courseData:raw,now:now)
            ready(relaunch);XCTAssertEqual(relaunch.presentation?.id,p.id);XCTAssertEqual(relaunch.presentation?.revealed,true)
            XCTAssertEqual(relaunch.engine?.record.attempts.count,0)
        }
    }

    @MainActor func testAdditionsKeepLiveTaskAndAppendUnlearnedQuestionOnlyOnce() async throws {
        let root=try workspace(), raw=try data("电力系统"), extra=try supplement(for:raw)
        let old=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now)
        old.start(now:now);ready(old)
        old.markFamiliar(token:try XCTUnwrap(old.presentation).id,now:now)
        let recall=try XCTUnwrap(old.presentation)
        old.reveal(token:recall.id,now:now);old.grade(remembered:false,token:recall.id,now:now);ready(old)
        let pending=try XCTUnwrap(old.presentation)
        old.reveal(token:pending.id,now:now);ready(old)
        let url=pointer(root,"power"), before=try Data(contentsOf:url), previous=try XCTUnwrap(old.engine)
        let updated=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now)
        ready(updated)
        let engine=try XCTUnwrap(updated.engine), newID="refined-power:unit#brief"
        XCTAssertEqual(engine.record.cardIDs,previous.record.cardIDs+[newID])
        XCTAssertEqual(updated.entries.map(\.id),old.entries.map(\.id)+["unit#brief"])
        XCTAssertEqual(updated.entries.last?.group.evidence.detail,"合成讲义第1页")
        XCTAssertTrue(old.supplementRefs.isEmpty);XCTAssertEqual(updated.supplementRefs,["unit#brief"])
        XCTAssertEqual(updated.course?.cards[0].rows.count,4)
        XCTAssertEqual(updated.presentation,old.presentation);XCTAssertEqual(updated.presentation?.revealed,true)
        XCTAssertEqual(updated.familiarRefs,old.familiarRefs);XCTAssertEqual(updated.firstPassRemaining,old.firstPassRemaining+1)
        XCTAssertEqual(engine.record.attempts,previous.record.attempts)
        for id in previous.record.cardIDs { XCTAssertEqual(try engine.packedCard(id:id),try previous.packedCard(id:id)) }
        XCTAssertEqual(try engine.packedCard(id:newID),0)
        XCTAssertEqual(engine.record.contentChanges?.last?.beforeSnapshot,previous.record.snapshot)
        let backup=url.deletingLastPathComponent().appendingPathComponent("before-additions-"+StudySHA256.hex(before)+".json")
        XCTAssertEqual(try Data(contentsOf:backup),before)
        let migrated=try Data(contentsOf:url)
        let resumed=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now)
        ready(resumed);XCTAssertEqual(try Data(contentsOf:url),migrated)
        XCTAssertEqual(resumed.engine?.record,engine.record)
        old.grade(remembered:true,token:pending.id,now:now);XCTAssertTrue(old.blocked)
        XCTAssertEqual(try Data(contentsOf:url),migrated)
        resumed.grade(remembered:true,token:pending.id,now:now);ready(resumed)
        XCTAssertEqual(resumed.engine?.record.attempts.count,previous.record.attempts.count+1)
        let later=try Data(contentsOf:url)
        let downgrade=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now)
        XCTAssertTrue(downgrade.blocked);XCTAssertEqual(try Data(contentsOf:url),later)
        XCTAssertEqual(try Data(contentsOf:backup),before)
    }

    @MainActor func testInvalidOrFailedAdditionLeavesOldJournalAvailableForRetry() async throws {
        let root=try workspace(),raw=try data("电力系统"),extra=try supplement(for:raw)
        let old=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now);ready(old)
        let url=pointer(root,"power"), before=try Data(contentsOf:url)
        for invalid in [try supplement(for:raw,ref:"unit#1"),try supplement(for:raw,group:"unknown"),
                        try supplement(for:Data("different".utf8))] {
            let refused=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:invalid,now:now)
            XCTAssertTrue(refused.blocked);XCTAssertNil(refused.engine)
            XCTAssertEqual(try Data(contentsOf:url),before)
        }
        let failed=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now) { bytes,destination in
            try DurableFile.write(bytes,to:destination)
            if destination==url { throw NSError(domain:"SyntheticAfterRename",code:1) }
        }
        XCTAssertTrue(failed.blocked);XCTAssertEqual(try Data(contentsOf:url),before)
        let retry=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now)
        ready(retry);XCTAssertEqual(retry.stats(on:now)?.unintroduced,4)
        let fresh=RefinedMemoryStore(subject:.power,baseDirectory:try workspace(),courseData:raw,supplementData:extra,now:now)
        ready(fresh);XCTAssertEqual(fresh.engine?.record.cardIDs,retry.engine?.record.cardIDs)
        XCTAssertEqual(fresh.engine?.record.contentChanges?.count ?? 0,0)
    }

    @MainActor func testLearnerFinishedBaseGetsOnlyTheAddedQuestionNext() async throws {
        let root=try workspace(),raw=try data("电力系统"),extra=try supplement(for:raw)
        let base=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now)
        base.start(now:now)
        for _ in base.entries { base.markFamiliar(token:try XCTUnwrap(base.presentation).id,now:now) }
        XCTAssertEqual(base.firstPassRemaining,0)
        let grown=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:extra,now:now)
        ready(grown);XCTAssertEqual(grown.firstPassRemaining,1)
        grown.start(now:now);ready(grown)
        XCTAssertEqual(grown.current?.id,"unit#brief");XCTAssertEqual(grown.presentation?.revealed,false)
        XCTAssertEqual(grown.familiarRefs,base.familiarRefs);XCTAssertTrue(grown.engine?.record.attempts.isEmpty == true)
    }

    @MainActor func testVerifiedPreviousSupplementResumesItsRecordedSlotsAndGrades() async throws {
        let root=try workspace(), raw=try twoGroups()
        func overlay(_ rows:[[String:Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject:["subject":"power","baseSHA256":StudySHA256.hex(raw),"additions":rows],options:.sortedKeys)
        }
        func addition(_ suffix:String)->[String:Any] {
            ["group":"unit","source":"合成证据","proof":["sourcePage":3],
             "row":["ref":"unit#"+suffix,"q":"检查"+suffix,"a":"比较条件","kind":"判断","how":"B","note":"","colors":[]] as [String:Any]]
        }
        let first=addition("before"), second=addition("after"), oldExtra=try overlay([first]), newExtra=try overlay([first,second])
        let original=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,now:now);ready(original)
        let old=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:oldExtra,now:now);ready(old)
        old.start(now:now)
        old.markFamiliar(token:try XCTUnwrap(old.presentation).id,now:now)
        let next=try XCTUnwrap(old.presentation)
        old.reveal(token:next.id,now:now);old.grade(remembered:false,token:next.id,now:now);ready(old)
        let pending=try XCTUnwrap(old.presentation)
        old.reveal(token:pending.id,now:now)
        let file=pointer(root,"power"), before=try Data(contentsOf:file), oldRecord=try XCTUnwrap(old.engine).record
        var changedSource=first;changedSource["proof"]=["sourcePage":4]
        var alteredBytes=oldExtra;alteredBytes.append(0x0a)
        for (resource,prior) in [(try overlay([changedSource,second]),oldExtra),(try overlay([second,first]),oldExtra),
                                 (try overlay([second]),oldExtra),(newExtra,alteredBytes)] {
            let refused=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:resource,previousSupplementData:prior,now:now)
            XCTAssertTrue(refused.blocked);XCTAssertEqual(try Data(contentsOf:file),before)
        }
        let updated=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:newExtra,previousSupplementData:oldExtra,now:now)
        ready(updated)
        XCTAssertEqual(updated.engine?.record.cardIDs,oldRecord.cardIDs+["refined-power:unit#after"])
        XCTAssertEqual(updated.presentation,old.presentation);XCTAssertEqual(updated.familiarRefs,old.familiarRefs)
        XCTAssertEqual(updated.engine?.record.attempts,oldRecord.attempts);XCTAssertEqual(updated.firstPassRemaining,old.firstPassRemaining+1)
        XCTAssertEqual(updated.engine?.record.contentChanges?.last?.beforeSnapshot,oldRecord.snapshot)
        let backup=file.deletingLastPathComponent().appendingPathComponent("before-additions-"+StudySHA256.hex(before)+".json")
        XCTAssertEqual(try Data(contentsOf:backup),before)
        let checkpoint=try Data(contentsOf:file)
        let reopened=RefinedMemoryStore(subject:.power,baseDirectory:root,courseData:raw,supplementData:newExtra,previousSupplementData:oldExtra,now:now)
        ready(reopened);XCTAssertEqual(try Data(contentsOf:file),checkpoint)
        reopened.grade(remembered:true,token:pending.id,now:now);ready(reopened)
        XCTAssertEqual(reopened.engine?.record.attempts.count,oldRecord.attempts.count+1)
    }
}
#endif
