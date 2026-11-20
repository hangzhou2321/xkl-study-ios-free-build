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
}
#endif
