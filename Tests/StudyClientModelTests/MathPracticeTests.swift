import XCTest
import StudyCore
@testable import StudyClientModel

final class MathPracticeTests: XCTestCase {
    func content() -> MathContent {
        MathContent(format:"xkl-math-v1",id:"math",title:"数学",version:"1",
            syllabus:[MathSyllabus(id:22,title:"极限")],
            assets:[MathAsset(id:"page",mimeType:"image/jpeg",width:100,height:100,dataBase64:Data([255,216,1,255,217]).base64EncodedString())],
            questions:[MathQuestion(id:"stable-1",type:"计算",syllabusIDs:[22],prompt:"极限计算",
                questionVisuals:[MathVisual(assetID:"page",normalizedCrop:[0,0,1,0.4])],answerVisuals:[],
                answerText:"1",solutionNote:nil,sourceRefs:["foundation-slot-1 PDF p1"],duplicateAliases:[],sourceKind:"both",reviewStatus:"verified")])
    }
    var start: Date { Date(timeIntervalSince1970:1_790_000_000) }
    func testDailyAuthorityAndIntradayOptionalRetry() throws {
        var e=try MathEngine(archive:MathArchive(content:content()))
        let q=e.archive.content.questions[0]
        try e.present(q,now:start); try e.reveal(now:start.addingTimeInterval(1)); try e.grade(remembered:false,now:start.addingTimeInterval(2))
        let original=e.daily[q.id]!
        XCTAssertTrue(e.queue(now:start.addingTimeInterval(601)).isEmpty)
        XCTAssertEqual(e.queue(now:start.addingTimeInterval(602)).count,1)
        try e.present(q,now:start.addingTimeInterval(603)); try e.reveal(now:start.addingTimeInterval(604)); try e.grade(remembered:true,now:start.addingTimeInterval(605))
        XCTAssertEqual(e.daily[q.id],original)
        XCTAssertNotEqual(e.all[q.id],original)
        XCTAssertFalse(e.archive.events.last!.dailyUpdated!)
        XCTAssertEqual(e.score(allRatings:false).count,0)
        let reload=try MathEngine(archive:JSONDecoder().decode(MathArchive.self,from:JSONEncoder().encode(e.archive)))
        XCTAssertEqual(reload.daily[q.id],original)
        XCTAssertEqual(reload.all[q.id],e.all[q.id])
    }
    func testNoGradeWithoutRevealAndRejectClockRollback() throws {
        var e=try MathEngine(archive:MathArchive(content:content()))
        try e.present(e.archive.content.questions[0],now:start)
        XCTAssertThrowsError(try e.grade(remembered:true,now:start.addingTimeInterval(1)))
        XCTAssertThrowsError(try e.reveal(now:start.addingTimeInterval(-1)))
        XCTAssertEqual(e.archive.events.count,1)
    }
    func testBothModelsUseIdenticalCleanTargets() throws {
        var e=try MathEngine(archive:MathArchive(content:content())); let q=e.archive.content.questions[0]
        try e.present(q,now:start); try e.reveal(now:start.addingTimeInterval(1)); try e.grade(remembered:true,now:start.addingTimeInterval(2))
        let later=start.addingTimeInterval(3*86_400)
        try e.present(q,now:later); try e.reveal(now:later.addingTimeInterval(1)); try e.grade(remembered:false,now:later.addingTimeInterval(2))
        XCTAssertEqual(e.score(allRatings:false).count,1); XCTAssertEqual(e.score(allRatings:true).count,1)
        XCTAssertNotNil(e.archive.events.last!.predictionDaily)
        XCTAssertNotNil(e.archive.events.last!.predictionAll)
    }
    func testKilledAppWithOpenAnswerCannotCreateCleanTarget() throws {
        var e=try MathEngine(archive:MathArchive(content:content())); let q=e.archive.content.questions[0]
        try e.present(q,now:start); try e.reveal(now:start.addingTimeInterval(1)); try e.grade(remembered:true,now:start.addingTimeInterval(2))
        try e.present(q,now:start.addingTimeInterval(100)); try e.reveal(now:start.addingTimeInterval(101))
        var reopened=try MathEngine(archive:e.archive)
        let later=start.addingTimeInterval(3*86_400)
        try reopened.present(q,now:later); try reopened.reveal(now:later.addingTimeInterval(1)); try reopened.grade(remembered:true,now:later.addingTimeInterval(2))
        XCTAssertEqual(reopened.score(allRatings:false).count,0)
        XCTAssertTrue(reopened.archive.events.contains { $0.kind == "exposure-close" })
        XCTAssertNoThrow(try MathEngine(archive:reopened.archive))
    }
    func testContentRejectsMissingImageOutOfBoundsAndBadAnswer() throws {
        var c=content(); c.questions[0].questionVisuals[0].normalizedCrop=[0.8,0,0.5,1]
        XCTAssertThrowsError(try c.validate())
        c=content(); c.assets=[]; XCTAssertThrowsError(try c.validate())
        c=content(); c.questions[0].answerText=nil; XCTAssertThrowsError(try c.validate())
        c.questions[0].reviewStatus="missing-answer"; XCTAssertNoThrow(try c.validate())
        let e=try MathEngine(archive:MathArchive(content:c)); XCTAssertTrue(e.queue(now:start).isEmpty)
    }
    func testRejectTamperedEventSequenceAndDailyUpdate() throws {
        var e=try MathEngine(archive:MathArchive(content:content())); let q=e.archive.content.questions[0]
        try e.present(q,now:start); try e.reveal(now:start.addingTimeInterval(1)); try e.grade(remembered:true,now:start.addingTimeInterval(2))
        var record=e.archive; record.events[0].sequence=9; XCTAssertThrowsError(try MathEngine(archive:record))
        record=e.archive; record.events[2].dailyUpdated=false; XCTAssertThrowsError(try MathEngine(archive:record))
    }
    func testExistingIdentityAndAssetCannotBeRewritten() throws {
        let old=content(); var changed=old
        changed.questions[0].answerText="other"
        XCTAssertThrowsError(try changed.validateUpdate(from:old))
        changed=old; changed.assets[0].dataBase64="different"
        XCTAssertThrowsError(try changed.validateUpdate(from:old))
        changed=old; changed.questions[0].duplicateAliases=["new-alias"]
        XCTAssertThrowsError(try changed.validateUpdate(from:old))
        changed=old; changed.version="2"; XCTAssertNoThrow(try changed.validateUpdate(from:old))
        changed=old; changed.assets[0].width=6000; changed.assets[0].height=6000
        XCTAssertThrowsError(try changed.validate())
    }
    func testQuestionTextParticipatesInFrozenIdentity() throws {
        var old=content(); old.questions[0].questionText="完整题干与选项"
        var changed=old; changed.questions[0].questionText="不同题干"
        XCTAssertThrowsError(try changed.validateUpdate(from:old))
        XCTAssertNoThrow(try old.validateUpdate(from:old))
    }
    func testCorruptForecastAndDayAreRejected() throws {
        var e=try MathEngine(archive:MathArchive(content:content())); let q=e.archive.content.questions[0]
        try e.present(q,now:start); try e.reveal(now:start.addingTimeInterval(1)); try e.grade(remembered:true,now:start.addingTimeInterval(2))
        var record=e.archive; record.events[2].evaluationIncluded=true
        XCTAssertThrowsError(try MathEngine(archive:record))
        record=e.archive; record.events[2].predictionDaily=1.1
        XCTAssertThrowsError(try MathEngine(archive:record))
        record=e.archive; record.events[0].day += 1
        XCTAssertThrowsError(try MathEngine(archive:record))
    }
    func testBothSourceFiltersAndNoFixedRounds() throws {
        let e=try MathEngine(archive:MathArchive(content:content()))
        XCTAssertEqual(e.queue(now:start,source:"foundation").count,1)
        XCTAssertEqual(e.queue(now:start,source:"reinforcement").count,1)
        XCTAssertTrue(e.queue(now:start,syllabus:23).isEmpty)
    }

#if os(macOS)
    @MainActor func testCapturedGradeTokenRejectsDoubleTapAndExpiredCallback() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var c=content(); c.assets[0].width=2; c.assets[0].height=2; c.assets[0].dataBase64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
        var q=c.questions[0]; q.id="stable-2"; c.questions.append(q)
        let package=root.appendingPathComponent("two.xklmath"); try JSONEncoder().encode(c).write(to:package)
        let store=MathStore(directory:root.appendingPathComponent("store")); store.importContent(from:package)
        store.start(); store.reveal(); let oldID=store.engine!.presentation!.id
        store.grade(true,presentationID:oldID)
        XCTAssertEqual(store.engine!.currentQuestion?.id,"stable-2")
        store.grade(false,presentationID:oldID)
        XCTAssertEqual(store.engine!.archive.events.count,4); XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        store.reveal(); let nextID=store.engine!.presentation!.id
        store.grade(false,presentationID:oldID)
        XCTAssertEqual(store.engine!.archive.events.count,5); XCTAssertFalse(store.blocked)
        store.grade(true,presentationID:nextID)
        XCTAssertEqual(store.engine!.archive.events.filter { $0.kind == "grade" }.count,2)
        XCTAssertNil(store.engine!.presentation)
    }
    @MainActor func testMidnightValidationErrorCanRecoverWithoutBlockingStore() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var c=content(); c.assets[0].width=2; c.assets[0].height=2; c.assets[0].dataBase64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
        let package=root.appendingPathComponent("one.xklmath"); try JSONEncoder().encode(c).write(to:package)
        var now=start
        let store=MathStore(directory:root.appendingPathComponent("store"),clock:{ now }); store.importContent(from:package)
        store.start(); store.reveal(); let oldID=store.engine!.presentation!.id
        now=now.addingTimeInterval(86_400)
        store.grade(true,presentationID:oldID)
        XCTAssertNotNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(store.engine!.archive.events.count,2)
        store.leave(); store.start(); store.reveal()
        XCTAssertNil(store.error); XCTAssertNotEqual(store.engine!.presentation!.id,oldID)
        store.grade(true,presentationID:store.engine!.presentation!.id)
        XCTAssertFalse(store.blocked); XCTAssertNil(store.error)
        XCTAssertEqual(store.engine!.archive.events.filter { $0.kind == "grade" }.count,1)
    }
    @MainActor func testAutomaticNextUsesTwoDurableStagesAndStopsAtEnd() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var c=content(); c.assets[0].width=2; c.assets[0].height=2; c.assets[0].dataBase64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
        var second=c.questions[0]; second.id="stable-2"; c.questions.append(second)
        let package=root.appendingPathComponent("two.xklmath"); try JSONEncoder().encode(c).write(to:package)
        for failCount in [0,3,4] {
            let directory=root.appendingPathComponent("store-\(failCount)")
            var injectedFailure: Int? = nil
            let store=MathStore(directory:directory,write:{ data,url in
                if url.lastPathComponent == "archive.json", let fail=injectedFailure,
                   let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                   let events=object["events"] as? [[String:Any]], events.count == fail {
                    throw MathFailure.invalid("injected durable-write failure")
                }
                try DurableFile.write(data,to:url)
            })
            store.importContent(from:package); store.start(); store.reveal()
            let before=try Data(contentsOf:directory.appendingPathComponent("archive.json"))
            injectedFailure=failCount == 0 ? nil:failCount
            store.grade(true,presentationID:store.engine!.presentation!.id)
            if failCount == 0 {
                XCTAssertEqual(store.engine!.currentQuestion?.id,"stable-2")
                XCTAssertEqual(store.engine!.archive.events.count,4)
                XCTAssertEqual(store.engine!.archive.events.filter { $0.kind == "grade" }.count,1)
                store.reveal(); store.grade(true,presentationID:store.engine!.presentation!.id)
                XCTAssertNil(store.engine!.presentation)
                XCTAssertEqual(store.engine!.archive.events.count,6)
                XCTAssertEqual(store.engine!.archive.events.filter { $0.kind == "grade" }.count,2)
                XCTAssertFalse(store.blocked)
            } else if failCount == 3 {
                XCTAssertTrue(store.blocked); XCTAssertNotNil(store.error)
                XCTAssertEqual(store.engine!.archive.events.count,2)
                XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("archive.json")),before)
                XCTAssertFalse(store.engine!.archive.events.contains { $0.questionID == "stable-2" })
            } else {
                XCTAssertTrue(store.blocked); XCTAssertNotNil(store.error)
                XCTAssertEqual(store.engine!.archive.events.count,3)
                XCTAssertNil(store.engine!.presentation)
                let reloaded=MathStore(directory:directory)
                XCTAssertEqual(reloaded.engine!.archive.events.count,3)
                XCTAssertEqual(reloaded.engine!.archive.events.last?.kind,"grade")
                XCTAssertFalse(reloaded.engine!.archive.events.contains { $0.questionID == "stable-2" })
            }
        }
    }
    @MainActor func testStartupConsumesInboxAndSuccessfulRestartIsReadOnly() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let inbox=root.appendingPathComponent("MathInbox"), directory=root.appendingPathComponent("MathPractice")
        try FileManager.default.createDirectory(at:inbox,withIntermediateDirectories:true)
        var c=content(); c.assets[0].width=2; c.assets[0].height=2; c.assets[0].dataBase64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
        let bytes=try JSONEncoder().encode(c)
        try bytes.write(to:inbox.appendingPathComponent("course.xklmath"))
        let request=MathStore.InboxRequest(contentFile:"course.xklmath",expectedSHA256:StudySHA256.hex(bytes),courseID:c.id)
        try JSONEncoder().encode(request).write(to:inbox.appendingPathComponent("request.json"))
        let first=MathStore(directory:directory)
        XCTAssertNil(first.error); XCTAssertNotNil(first.engine)
        let archiveURL=directory.appendingPathComponent("archive.json"), receiptURL=inbox.appendingPathComponent("receipt.json")
        let before=try Data(contentsOf:archiveURL), receiptBefore=try Data(contentsOf:receiptURL)
        let namesBefore=try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted()
        let archiveTime=try archiveURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        let second=MathStore(directory:directory)
        XCTAssertNil(second.error); XCTAssertNotNil(second.engine)
        XCTAssertEqual(try Data(contentsOf:archiveURL),before)
        XCTAssertEqual(try Data(contentsOf:receiptURL),receiptBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted(),namesBefore)
        XCTAssertEqual(try archiveURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,archiveTime)
    }
    @MainActor func testInboxHashPathIDReceiptAndHistoryProtection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let inbox=root.appendingPathComponent("MathInbox"), directory=root.appendingPathComponent("MathPractice")
        try FileManager.default.createDirectory(at:inbox,withIntermediateDirectories:true)
        var c=content(); c.assets[0].width=2; c.assets[0].height=2; c.assets[0].dataBase64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
        let bytes=try JSONEncoder().encode(c), package=inbox.appendingPathComponent("course.xklmath")
        try bytes.write(to:package)
        func request(_ name: String="course.xklmath", _ hash: String?=nil, _ course: String="math") throws {
            let r=MathStore.InboxRequest(contentFile:name,expectedSHA256:hash ?? StudySHA256.hex(bytes),courseID:course)
            try JSONEncoder().encode(r).write(to:inbox.appendingPathComponent("request.json"))
        }
        let store=MathStore(directory:directory)
        try request("../course.xklmath"); store.processInbox(directory:inbox); XCTAssertNil(store.engine)
        try request("course.xklmath",String(repeating:"0",count:64)); store.processInbox(directory:inbox); XCTAssertNil(store.engine)
        try request("course.xklmath",nil,"wrong-course"); store.processInbox(directory:inbox); XCTAssertNil(store.engine)
        try request(); store.processInbox(directory:inbox); XCTAssertNil(store.error); XCTAssertNotNil(store.engine)
        let receipt=try JSONDecoder().decode(MathStore.InboxReceipt.self,from:Data(contentsOf:inbox.appendingPathComponent("receipt.json")))
        XCTAssertTrue(receipt.success); XCTAssertEqual(receipt.contentSHA256,StudySHA256.hex(bytes))
        store.start(); store.reveal(); store.grade(false,presentationID:store.engine!.presentation!.id)
        let count=store.engine!.archive.events.count
        let reopened=MathStore(directory:directory); reopened.processInbox(directory:inbox)
        XCTAssertEqual(reopened.engine!.archive.events.count,count)
        c.questions[0].answerText="changed identity"; let changed=try JSONEncoder().encode(c); try changed.write(to:package)
        try request("course.xklmath",StudySHA256.hex(changed)); reopened.processInbox(directory:inbox)
        XCTAssertNotNil(reopened.error); XCTAssertEqual(reopened.engine!.archive.content.questions[0].answerText,"1")
        XCTAssertEqual(reopened.engine!.archive.events.count,count)
    }
    @MainActor func testTransactionalReimportKeepsHistoryAndCorruptReloadBlocks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var c=content(); c.assets[0].width=2; c.assets[0].height=2
        c.assets[0].dataBase64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
        let input=root.appendingPathComponent("input.xklmath")
        try JSONEncoder().encode(c).write(to:input)
        let directory=root.appendingPathComponent("store")
        let store=MathStore(directory:directory); store.importContent(from:input)
        XCTAssertNil(store.error); store.start(); store.reveal(); store.grade(false,presentationID:store.engine!.presentation!.id)
        let count=store.engine!.archive.events.count
        XCTAssertEqual(count,3)
        store.importContent(from:input)
        XCTAssertEqual(store.engine!.archive.events.count,count)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains { $0.hasPrefix("backup-") })
        var bad=c; bad.questions[0].questionVisuals[0].assetID="missing"
        try JSONEncoder().encode(bad).write(to:input)
        store.importContent(from:input)
        XCTAssertNotNil(store.error); XCTAssertEqual(store.engine!.archive.events.count,count)
        let loaded=MathStore(directory:directory)
        XCTAssertFalse(loaded.blocked); XCTAssertEqual(loaded.engine!.archive.events.count,count)
        try Data("broken".utf8).write(to:directory.appendingPathComponent("archive.json"))
        let corrupt=MathStore(directory:directory); XCTAssertTrue(corrupt.blocked); XCTAssertNil(corrupt.engine)
    }
#endif
}
