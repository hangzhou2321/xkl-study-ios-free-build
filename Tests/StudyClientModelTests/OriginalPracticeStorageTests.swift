import Foundation
import XCTest
@testable import StudyClientModel
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class OriginalPracticeStorageTests: XCTestCase {
    private func temporary(_ run: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("original-practice-test-" + UUID().uuidString, isDirectory:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        try run(dir)
    }
    func testDurableNamespacesRemainSeparateAndDeletionIsSelective() throws {
        try temporary { dir in
            let store = try OriginalPracticeStorage(directory:dir)
            let keys = ["real-bank-offline-v1:browse","real-bank-offline-v1:browse:circuit","real-bank-offline-v1:browse:mechanics",
                        "real-bank-offline-v1:item/测试-01","beici:corrected-practice:v1:%E6%B5%8B:1",
                        "course-methods-v1:mec:"+String(repeating:"a",count:64)+"/case/demo#1",
                        "course-methods-v1:cir:"+String(repeating:"1",count:64)+"/pos","offline-workout-nov20-v1",
                        "original-course-v1:circuit","original-course-v1:mechanics","original-course-step-v1:测试-01"]
            for (i,k) in keys.enumerated() { try store.apply(key:k,value:"记录#\(i)：\n\"本地😀\"") }
            let initial = store.values; XCTAssertEqual(initial.count,keys.count)
            let reopened = try OriginalPracticeStorage(directory:dir); XCTAssertEqual(reopened.values,initial)
            try reopened.apply(key:keys[1],value:nil)
            var expected=initial; expected.removeValue(forKey:keys[1]); XCTAssertEqual(store.values,expected)
            let file=dir.appendingPathComponent("original-practice-v1.json")
            let before=try Data(contentsOf:file)
            for forbidden in ["unrelated","real-bank-offline-v1:browse:other","original-course-v1:else",
                              "original-course-step-v1:","real-bank-offline-v1:item/with\nnewline"] {
                XCTAssertThrowsError(try store.apply(key:forbidden,value:"0"))
            }
            XCTAssertThrowsError(try store.apply(key:keys[0],value:String(repeating:"中",count:360_000)))
            XCTAssertEqual(try Data(contentsOf:file),before)
        }
    }
    func testHotReaderSeesAtomicReplacementsOfAlternatingSizes() throws {
        try temporary { dir in
            let writer = try OriginalPracticeStorage(directory: dir)
            let hotReader = try OriginalPracticeStorage(directory: dir)
            let key = "real-bank-offline-v1:item/size-transition"
            for i in 0..<12 {
                let current = i.isMultiple(of: 2) ? String(repeating: "大", count: 8192) + String(i) : "短" + String(i)
                try writer.apply(key: key, value: current)
                // This throwing read cannot fall back to the last known good snapshot.
                _ = try hotReader.bootstrapScript()
                XCTAssertEqual(hotReader.values[key], current)
            }
        }
    }

    func testCrossInstanceMergeAndConflictProtection() throws {
        try temporary { dir in
            let a=try OriginalPracticeStorage(directory:dir),b=try OriginalPracticeStorage(directory:dir)
            let item="real-bank-offline-v1:item/fixture",cursor="real-bank-offline-v1:browse:mechanics"
            try a.apply(key:item,value:"A")
            try b.apply(key:cursor,value:"elsewhere")
            XCTAssertThrowsError(try b.apply(key:item,value:"stale"))
            XCTAssertThrowsError(try b.apply(key:item,value:nil))
            XCTAssertEqual(try OriginalPracticeStorage(directory:dir).values,[item:"A",cursor:"elsewhere"])
            _ = try b.bootstrapScript()  // This reader really reopened using the current on-disk snapshot.
            try b.apply(key:item,value:"B")
            XCTAssertEqual(try OriginalPracticeStorage(directory:dir).values[item],"B")
            XCTAssertThrowsError(try a.apply(key:item,value:"old message"))
            try a.apply(key:item,value:"B")  // idempotent pulse from another scene is safe.
        }
    }
    func testConcurrentWritersPreserveEveryIndependentItem() throws {
        try temporary { dir in
            let clients=try (0..<24).map { _ in try OriginalPracticeStorage(directory:dir) }
            DispatchQueue.concurrentPerform(iterations:clients.count) { i in
                do { try clients[i].apply(key:"real-bank-offline-v1:item/fixture-\(i)",value:"\(i)") }
                catch { XCTFail("Independent write \(i) failed: \(error)") }
            }
            let disk=try OriginalPracticeStorage(directory:dir).values
            XCTAssertEqual(disk.count,clients.count)
            for i in clients.indices {XCTAssertEqual(disk["real-bank-offline-v1:item/fixture-\(i)"],"\(i)")}
        }
    }
    func testCorruptionIsNeverReplacedByEmptyStateOrNewEvent() throws {
        try temporary { dir in
            let s=try OriginalPracticeStorage(directory:dir)
            let key="real-bank-offline-v1:browse:circuit"
            try s.apply(key:key,value:"saved")
            let archive=dir.appendingPathComponent("original-practice-v1.json"), damaged=Data("{truncated".utf8)
            try damaged.write(to:archive)
            XCTAssertThrowsError(try OriginalPracticeStorage(directory:dir))
            XCTAssertThrowsError(try s.bootstrapScript())
            XCTAssertThrowsError(try s.apply(key:key,value:"new"))
            XCTAssertEqual(s.values[key],"saved")
            XCTAssertEqual(try Data(contentsOf:archive),damaged)
        }
    }
    func testBootstrapLiteralEscapesScriptData() throws {
        try temporary { dir in
            let s=try OriginalPracticeStorage(directory:dir)
            let v="文字</script><script>throw 42</script>\n\u{2028}\u{2029}🙂"
            try s.apply(key:"real-bank-offline-v1:item/synthetic",value:v)
            let script=try s.bootstrapScript()
            XCTAssertFalse(script.contains("</script>"))
            XCTAssertFalse(script.contains("\u{2028}")); XCTAssertFalse(script.contains("\u{2029}"))
            XCTAssertEqual(s.values["real-bank-offline-v1:item/synthetic"],v)
        }
    }
    #if canImport(JavaScriptCore)
    func testActualBootstrapAPIEnumeratesResumesAndSendsOnlyScopedMessages() throws {
        try temporary { dir in
            let store=try OriginalPracticeStorage(directory:dir),key="real-bank-offline-v1:item/synthetic"
            try store.apply(key:key,value:"汉字\n😀</script>")
            let ctx=try XCTUnwrap(JSContext())
            ctx.exceptionHandler={ _,e in XCTFail("Bootstrap JS: "+(e?.toString() ?? "unknown")) }
            ctx.evaluateScript("""
                var window=this; window.top=window;
                var location={protocol:'study-originals:',host:'bundle'};
                var TextEncoder=function(){}; TextEncoder.prototype.encode=s=>({length:unescape(encodeURIComponent(s)).length});
                var DOMException=Error;
                var posted=[];var webkit={messageHandlers:{originalPracticeStore:{postMessage:o=>posted.push(o)}}};
                """)
            ctx.evaluateScript(try store.bootstrapScript())
            XCTAssertEqual(ctx.evaluateScript("window.__originalPracticeStorageReady").toBool(),true)
            XCTAssertEqual(ctx.evaluateScript("localStorage.getItem('"+key+"')").toString(),"汉字\n😀</script>")
            XCTAssertEqual(ctx.evaluateScript("Object.keys(localStorage).join()").toString(),key)
            ctx.evaluateScript("""
                localStorage.setItem('original-course-v1:circuit','nav');
                localStorage.setItem('original-course-step-v1:test','method-only');
                localStorage.removeItem('original-course-v1:circuit');
                try{localStorage.setItem('unrelated','no');}catch(e){}
                """)
            XCTAssertEqual(ctx.evaluateScript("posted.length").toInt32(),3)
            XCTAssertTrue(ctx.evaluateScript("posted[2].value===null && posted[1].key==='original-course-step-v1:test'").toBool())
            XCTAssertEqual(ctx.evaluateScript("localStorage.length").toInt32(),2)
            XCTAssertTrue(ctx.evaluateScript("localStorage.key(20)===null").toBool())
            ctx.evaluateScript("window.__originalPracticeStorageAbort();try{localStorage.setItem('real-bank-offline-v1:browse','discard');}catch(e){}")
            XCTAssertEqual(ctx.evaluateScript("posted.length").toInt32(),3)
        }
    }
    #endif
}
