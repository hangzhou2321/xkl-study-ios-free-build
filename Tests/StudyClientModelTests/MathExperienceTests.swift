import XCTest
import StudyCore
@testable import StudyClientModel

private let syntheticPackageHash=StudySHA256.hex(Data("new synthetic package bytes for regression only".utf8))
private func experienceFixture() -> MathContent {
    MathContent(format:"xkl-math-v1",id:"synthetic-math-course",title:"Synthetic",version:"1",syllabus:[MathSyllabus(id:22,title:"Synthetic")],assets:[MathAsset(id:"page",mimeType:"image/jpeg",width:100,height:100,dataBase64:Data([255,216,1,255,217]).base64EncodedString())],questions:[MathQuestion(id:"stable-1",type:"Synthetic",syllabusIDs:[22],prompt:"Synthetic",questionText:"x+1=2",questionVisuals:[MathVisual(assetID:"page",normalizedCrop:[0,0,1,1])],answerVisuals:[],answerText:"1",solutionNote:nil,sourceRefs:["synthetic"],duplicateAliases:[],sourceKind:"both",reviewStatus:"verified")])
}
private func experienceBaseline() throws -> MathArchive {
    let t=Date(timeIntervalSince1970:1790000000)
    var old=try MathEngine(archive:MathArchive(content:experienceFixture()))
    try old.present(old.archive.content.questions[0],now:t); try old.reveal(now:t.addingTimeInterval(1)); try old.grade(remembered:true,now:t.addingTimeInterval(2)); return old.archive
}
private func experienceGuide(_ content: MathContent) -> MathGuide {
    MathGuide(format:"xkl-math-guide-v1",id:"synthetic-math-guide",version:"synthetic-version-1",baseCourseID:content.id,basePackageSHA256:syntheticPackageHash,cards:[],questions:[MathGuideQuestion(questionID:"stable-1",sourceTextSHA256:MathGuide.sourceDigest(content.questions[0]),stem:[MathRichBlock(kind:.text,value:"Synthetic")],options:[],answer:[MathRichBlock(kind:.math,value:"1")],keyStep:[],details:[],hint:[],cardIDs:[],requiresDiagram:false,diagramVisuals:[],notes:[])])
}
final class MathExperienceTests: XCTestCase {
    let t=Date(timeIntervalSince1970:1790000000)
    func base() throws -> MathArchive {
        try experienceBaseline()
    }
    func testInheritedMemoryAndRawOutcomesUndo() throws {
        let baseline=try base(), old=try MathEngine(archive:baseline)
        var e=try MathExperienceEngine(baseline:baseline)
        XCTAssertEqual(e.daily,old.daily); XCTAssertEqual(e.all,old.all)
        let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.hint(now:later.addingTimeInterval(1)); try e.reveal(now:later.addingTimeInterval(2))
        XCTAssertThrowsError(try e.grade(.independentCorrect,now:later.addingTimeInterval(3)))
        try e.grade(.assistedCorrect,now:later.addingTimeInterval(4)); XCTAssertTrue(e.cleanTargets.isEmpty)
        XCTAssertEqual(e.events.last?.outcome,.assistedCorrect)
        XCTAssertNotEqual(e.all,old.all)
        try e.undo(now:later.addingTimeInterval(5))
        XCTAssertEqual(e.daily,old.daily); XCTAssertEqual(e.all,old.all)
        XCTAssertTrue(e.current!.answerShown); XCTAssertTrue(e.current!.hintShown)
        try e.grade(.incorrect,now:later.addingTimeInterval(6))
        XCTAssertEqual(e.events.filter { $0.kind == "grade" }.count,2)
        XCTAssertTrue(e.cleanTargets.isEmpty)
        let reload=try MathExperienceEngine(baseline:baseline,events:e.events)
        XCTAssertEqual(reload.all,e.all)
        XCTAssertEqual(try JSONEncoder().encode(baseline.events).count,try JSONEncoder().encode(e.baseline.events).count)
    }
    func testFamiliarSpotCheckAndRestoreNeverInventGrade() throws {
        var e=try MathExperienceEngine(baseline:base()); let memory=e.daily
        try e.present(questionID:"stable-1",now:t.addingTimeInterval(10)); try e.markFamiliar(now:t.addingTimeInterval(11))
        XCTAssertEqual(e.daily,memory); XCTAssertTrue(e.queue(now:t.addingTimeInterval(30*86400)).isEmpty)
        try e.present(questionID:"stable-1",now:t.addingTimeInterval(12),spotCheck:true)
        try e.reveal(now:t.addingTimeInterval(13)); try e.grade(.incorrect,now:t.addingTimeInterval(14))
        XCTAssertTrue(e.familiar.contains("stable-1"))
        try e.restore(questionID:"stable-1",now:t.addingTimeInterval(15)); XCTAssertFalse(e.familiar.contains("stable-1"))
    }
    func testPauseRestartAndIndependentCardProfile() throws {
        var e=try MathExperienceEngine(baseline:base(),cardIDs:["c1"]); let memory=e.all
        try e.present(questionID:"stable-1",now:t.addingTimeInterval(10)); try e.hint(now:t.addingTimeInterval(11)); try e.pause(now:t.addingTimeInterval(12))
        let id=e.current!.id
        e=try MathExperienceEngine(baseline:e.baseline,events:e.events,cardIDs:["c1"])
        XCTAssertEqual(e.current?.id,id); XCTAssertTrue(e.current!.hintShown)
        try e.resume(now:t.addingTimeInterval(13)); try e.openCard("c1",now:t.addingTimeInterval(14)); XCTAssertTrue(e.cardMemories.isEmpty)
        try e.queueCard("c1",now:t.addingTimeInterval(15)); try e.startCardRecall("c1",now:t.addingTimeInterval(16))
        let cardID=e.currentCard!.id
        try e.revealCard(sessionID:cardID,now:t.addingTimeInterval(17)); try e.gradeCard("c1",remembered:true,sessionID:cardID,now:t.addingTimeInterval(18))
        XCTAssertNotNil(e.cardMemories["c1"]); XCTAssertEqual(e.all,memory)
    }
    func testCleanTargetsAndUndoCorrectionNotNewRecall() throws {
        var e=try MathExperienceEngine(baseline:base()); let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.reveal(now:later.addingTimeInterval(1)); try e.grade(.independentCorrect,now:later.addingTimeInterval(2))
        XCTAssertEqual(e.cleanTargets.count,1)
        try e.undo(now:later.addingTimeInterval(3)); XCTAssertEqual(e.cleanTargets.count,0)
        try e.grade(.incorrect,now:later.addingTimeInterval(4)); XCTAssertEqual(e.cleanTargets.count,0)
        XCTAssertThrowsError(try e.undo(now:later.addingTimeInterval(30)))
    }
    func testIsolatedQuestionsCannotBecomeFamiliarOrBeScored() throws {
        var b=try base(); b.events=[]; b.content.questions[0].reviewStatus="needs-review"
        var e=try MathExperienceEngine(baseline:b)
        XCTAssertThrowsError(try e.present(questionID:"stable-1",now:t)); XCTAssertNil(e.current)
        XCTAssertThrowsError(try e.restore(questionID:"stable-1",now:t))
    }
    func testLaterAssistanceBlocksUndoAndTamperedChainIsRejected() throws {
        var e=try MathExperienceEngine(baseline:base()); let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.reveal(now:later.addingTimeInterval(1)); try e.grade(.incorrect,now:later.addingTimeInterval(2))
        try e.present(questionID:"stable-1",now:later.addingTimeInterval(3)); try e.hint(now:later.addingTimeInterval(4))
        XCTAssertThrowsError(try e.undo(now:later.addingTimeInterval(5)))
        var events=e.events; events[events.count-1].session?.assisted=false
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
    }
    func testCrossDayAndRestartAreExcludedAndDailyFirstIsPreserved() throws {
        var e=try MathExperienceEngine(baseline:base()); let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.reveal(now:later.addingTimeInterval(1))
        try e.interrupted(now:later.addingTimeInterval(86400)); try e.grade(.independentCorrect,now:later.addingTimeInterval(86401))
        XCTAssertTrue(e.cleanTargets.isEmpty)
        let memory=e.daily
        try e.present(questionID:"stable-1",now:later.addingTimeInterval(86402)); try e.reveal(now:later.addingTimeInterval(86403)); try e.grade(.incorrect,now:later.addingTimeInterval(86404))
        XCTAssertEqual(e.daily,memory); XCTAssertNotEqual(e.all,memory)
    }
    func testSelfReportedAssistanceIsNeverACleanTarget() throws {
        var e=try MathExperienceEngine(baseline:base()); let before=e.all; let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.reveal(now:later.addingTimeInterval(1)); try e.grade(.assistedCorrect,now:later.addingTimeInterval(2))
        XCTAssertTrue(e.cleanTargets.isEmpty); XCTAssertNotEqual(e.all,before)
        let expected=try FSRS6Shadow.review(before["stable-1"],day:MathEngine.day(later.addingTimeInterval(2)),rating:1,timestampMs:MathEngine.ms(later.addingTimeInterval(2))).memory
        XCTAssertEqual(e.all["stable-1"],expected); XCTAssertEqual(e.daily["stable-1"],expected)
    }
    func testStrictReplayRejectsForgedSessionTransitionsAndPayloads() throws {
        var e=try MathExperienceEngine(baseline:base()); let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.hint(now:later.addingTimeInterval(1)); try e.reveal(now:later.addingTimeInterval(2)); try e.grade(.assistedCorrect,now:later.addingTimeInterval(3)); try e.undo(now:later.addingTimeInterval(4))
        var events=e.events; events[0].session!.answerShown=true
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
        events=e.events; events[0].session!.shownAt=later.addingTimeInterval(-1)
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
        events=e.events; events[1].kind="resume"
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
        events=e.events; events[2].kind="expanded"
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
        events=e.events; events[events.count-1].session!.assisted=false
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
        events=e.events; events[0].remembered=true
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
        events=e.events; events[0].questionID="unknown-synthetic"
        XCTAssertThrowsError(try MathExperienceEngine(baseline:e.baseline,events:events))
    }
    func testCardsRequireKnownQueueRecallRevealAndFreshToken() throws {
        var e=try MathExperienceEngine(baseline:base(),cardIDs:["synthetic-card"]); let memory=e.all
        XCTAssertThrowsError(try e.queueCard("unknown-card",now:t.addingTimeInterval(10)))
        XCTAssertThrowsError(try e.startCardRecall("synthetic-card",now:t.addingTimeInterval(10)))
        try e.queueCard("synthetic-card",now:t.addingTimeInterval(11)); try e.startCardRecall("synthetic-card",now:t.addingTimeInterval(12))
        let id=e.currentCard!.id
        XCTAssertThrowsError(try e.gradeCard("synthetic-card",remembered:true,sessionID:id,now:t.addingTimeInterval(13)))
        XCTAssertThrowsError(try e.revealCard(sessionID:UUID(),now:t.addingTimeInterval(13)))
        try e.revealCard(sessionID:id,now:t.addingTimeInterval(14))
        let restored=try MathExperienceEngine(baseline:e.baseline,events:e.events,cardIDs:e.knownCardIDs)
        XCTAssertEqual(restored.currentCard,e.currentCard)
        try e.gradeCard("synthetic-card",remembered:true,sessionID:id,now:t.addingTimeInterval(15))
        XCTAssertThrowsError(try e.gradeCard("synthetic-card",remembered:true,sessionID:id,now:t.addingTimeInterval(16)))
        XCTAssertEqual(e.all,memory); XCTAssertEqual(e.cardMemories.count,1)
    }
    func testEngineRejectsCardRecallDuringUnassistedQuestion() throws {
        var e=try MathExperienceEngine(baseline:base(),cardIDs:["synthetic-card"])
        try e.present(questionID:"stable-1",now:t.addingTimeInterval(10)); try e.queueCard("synthetic-card",now:t.addingTimeInterval(11))
        XCTAssertThrowsError(try e.startCardRecall("synthetic-card",now:t.addingTimeInterval(12)))
        try e.openCard("synthetic-card",now:t.addingTimeInterval(13)); try e.startCardRecall("synthetic-card",now:t.addingTimeInterval(14))
        try e.revealCard(sessionID:e.currentCard!.id,now:t.addingTimeInterval(15)); try e.reveal(now:t.addingTimeInterval(16))
        XCTAssertThrowsError(try e.grade(.independentCorrect,now:t.addingTimeInterval(17)))
        try e.grade(.assistedCorrect,now:t.addingTimeInterval(18)); XCTAssertTrue(e.cleanTargets.isEmpty)
    }
    func testSpotCheckReturnsOriginalSessionAndUndoAfterReturnKeepsItOnce() throws {
        var b=try base(); var q=b.content.questions[0]; q.id="synthetic-second"; b.content.questions.append(q)
        var e=try MathExperienceEngine(baseline:b); let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:q.id,now:later); let original=e.current!.id
        try e.suspend(now:later.addingTimeInterval(1)); try e.present(questionID:"stable-1",now:later.addingTimeInterval(2),spotCheck:true)
        let check=e.current!.id
        try e.reveal(now:later.addingTimeInterval(3)); try e.grade(.independentCorrect,now:later.addingTimeInterval(4)); try e.returnToSuspended(now:later.addingTimeInterval(5))
        XCTAssertEqual(e.current?.id,original); XCTAssertTrue(e.suspended.isEmpty)
        try e.undo(now:later.addingTimeInterval(6)); XCTAssertEqual(e.current?.id,check); XCTAssertEqual(e.suspended.map(\.id),[original])
        try e.grade(.incorrect,now:later.addingTimeInterval(7)); try e.returnToSuspended(now:later.addingTimeInterval(8))
        XCTAssertEqual(e.current?.id,original); XCTAssertTrue(e.suspended.isEmpty)
        let reload=try MathExperienceEngine(baseline:b,events:e.events); XCTAssertEqual(reload.current,e.current)
    }
    func testPauseCannotBecomeCleanAndRecordedTimezoneControlsReplay() throws {
        var e=try MathExperienceEngine(baseline:base()); let later=t.addingTimeInterval(3*86400)
        try e.present(questionID:"stable-1",now:later); try e.pause(now:later.addingTimeInterval(1)); try e.resume(now:later.addingTimeInterval(2)); try e.reveal(now:later.addingTimeInterval(3)); try e.grade(.independentCorrect,now:later.addingTimeInterval(4))
        XCTAssertTrue(e.cleanTargets.isEmpty)
        var clean=try MathExperienceEngine(baseline:base())
        try clean.present(questionID:"stable-1",now:later); try clean.reveal(now:later.addingTimeInterval(1)); try clean.grade(.independentCorrect,now:later.addingTimeInterval(2))
        var events=clean.events
        events[0].utcOffsetSeconds=events[0].utcOffsetSeconds == 0 ? 3600 : 0
        events[0].day=UInt32(floor((events[0].timestamp.timeIntervalSince1970+Double(events[0].utcOffsetSeconds))/86400))
        let moved=try MathExperienceEngine(baseline:clean.baseline,events:events)
        XCTAssertTrue(moved.cleanTargets.isEmpty)
    }
    func testGuideBlockPreservesBaselineAndCurrentButRejectsFuturePractice() throws {
        let b=try base(); let old=try MathEngine(archive:b); let later=t.addingTimeInterval(3*86400)
        var e=try MathExperienceEngine(baseline:b,blockedQuestionIDs:["stable-1"])
        XCTAssertEqual(e.daily,old.daily); XCTAssertTrue(e.queue(now:later).isEmpty)
        XCTAssertThrowsError(try e.present(questionID:"stable-1",now:later,spotCheck:true)); XCTAssertTrue(e.events.isEmpty)
        e=try MathExperienceEngine(baseline:b); try e.present(questionID:"stable-1",now:later); try e.reveal(now:later.addingTimeInterval(1))
        let original=e.current, rawCount=e.events.count
        e.configureBlockedQuestions(["stable-1"])
        XCTAssertThrowsError(try e.grade(.independentCorrect,now:later.addingTimeInterval(2)))
        XCTAssertThrowsError(try e.markFamiliar(now:later.addingTimeInterval(2)))
        XCTAssertEqual(e.current,original); XCTAssertEqual(e.events.count,rawCount); XCTAssertEqual(e.daily,old.daily)
        let restored=try MathExperienceEngine(baseline:b,events:e.events,blockedQuestionIDs:["stable-1"])
        XCTAssertEqual(restored.current,original); XCTAssertEqual(restored.daily,old.daily)
        var guide=experienceGuide(b.content); XCTAssertTrue(guide.questions[0].practiceAllowed)
        guide.questions[0].practiceBlockedReason="Synthetic ambiguous condition; read only."
        XCTAssertFalse(guide.questions[0].practiceAllowed)
        XCTAssertNoThrow(try guide.validate(content:b.content,packageSHA256:syntheticPackageHash))
        let encoded=try JSONEncoder().encode(guide); let decoded=try JSONDecoder().decode(MathGuide.self,from:encoded)
        XCTAssertEqual(decoded.questions[0].practiceBlockedReason,guide.questions[0].practiceBlockedReason)
    }
    func testGuideRejectsAlteredBaselineSourceReferencesAndCrops() throws {
        let content=experienceFixture(); let valid=experienceGuide(content)
        XCTAssertNoThrow(try valid.validate(content:content,packageSHA256:syntheticPackageHash))
        var nextVersion=valid; nextVersion.id="another-synthetic-guide"; nextVersion.version="next-synthetic-version"
        XCTAssertNoThrow(try nextVersion.validate(content:content,packageSHA256:syntheticPackageHash))
        nextVersion.version=""; XCTAssertThrowsError(try nextVersion.validate(content:content,packageSHA256:syntheticPackageHash))
        var changed=valid; changed.basePackageSHA256=String(repeating:"0",count:64)
        XCTAssertThrowsError(try changed.validate(content:content,packageSHA256:syntheticPackageHash))
        changed=valid; changed.questions[0].sourceTextSHA256=String(repeating:"0",count:64)
        XCTAssertThrowsError(try changed.validate(content:content,packageSHA256:syntheticPackageHash))
        changed=valid; changed.questions[0].cardIDs=["unknown"]
        XCTAssertThrowsError(try changed.validate(content:content,packageSHA256:syntheticPackageHash))
        changed=valid; changed.questions[0].requiresDiagram=true
        XCTAssertThrowsError(try changed.validate(content:content,packageSHA256:syntheticPackageHash))
        changed.questions[0].diagramVisuals=[MathVisual(assetID:"page",normalizedCrop:[0.8,0,0.5,1])]
        XCTAssertThrowsError(try changed.validate(content:content,packageSHA256:syntheticPackageHash))
        XCTAssertThrowsError(try valid.validate(content:content,packageSHA256:String(repeating:"0",count:64)))
    }
    func testGuideDigestIncludesAllSourceFields() throws {
        var q=try base().content.questions[0]; let digest=MathGuide.sourceDigest(q)
        q.questionText="synthetic changed"; XCTAssertNotEqual(MathGuide.sourceDigest(q),digest)
        let d=MathGuide.sourceDigest(q); q.solutionNote="synthetic note"; XCTAssertNotEqual(MathGuide.sourceDigest(q),d)
    }
}
#if os(macOS)
@MainActor final class MathExperiencePersistenceTests: XCTestCase {
    func testFailedWriteDoesNotAdvanceAndOldBytesAreUntouched() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let legacy=root.appendingPathComponent("MathPractice"), destination=root.appendingPathComponent("MathExperience")
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        let b=try experienceBaseline(), bytes=try JSONEncoder().encode(b.content), hash=StudySHA256.hex(bytes)
        try bytes.write(to:legacy.appendingPathComponent(hash+".xklmath"))
        let archive=try JSONSerialization.data(withJSONObject:["format":"xkl-math-disk-v1","contentSHA256":hash,"importedPackageSHA256":syntheticPackageHash,"events":JSONSerialization.jsonObject(with:JSONEncoder().encode(b.events))])
        try archive.write(to:legacy.appendingPathComponent("archive.json"))
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let guide=experienceGuide(b.content)
        try JSONEncoder().encode(guide).write(to:destination.appendingPathComponent("guide.json"))
        var fail=false
        let store=MathExperienceStore(directory:destination,legacyDirectory:legacy,clock:{ Date(timeIntervalSince1970:1791000000) },write:{ data,url in if fail { throw CocoaError(.fileWriteOutOfSpace) }; try data.write(to:url,options:.atomic) })
        XCTAssertFalse(store.blocked); fail=true; store.spotCheck("stable-1"); XCTAssertNil(store.engine?.current); XCTAssertNotNil(store.error)
        fail=false; store.spotCheck("stable-1"); XCTAssertNotNil(store.engine?.current); XCTAssertNil(store.error)
        store.grade(.independentCorrect,sessionID:store.engine!.current!.id); XCTAssertNotNil(store.error); XCTAssertFalse(store.blocked)
        store.reveal(sessionID:store.engine!.current!.id); XCTAssertNil(store.error)
        let stale=store.engine!.current!.id
        store.spotCheck("stable-1"); let countBeforeStale=store.engine!.events.count
        store.hint(sessionID:stale); XCTAssertNotNil(store.error); XCTAssertEqual(store.engine!.events.count,countBeforeStale)
        store.familiar(sessionID:stale); XCTAssertEqual(store.engine!.events.count,countBeforeStale)
        XCTAssertEqual(try Data(contentsOf:legacy.appendingPathComponent("archive.json")),archive)
        var blockedGuide=guide; blockedGuide.questions[0].practiceBlockedReason="Synthetic nonunique answer; read only."
        try JSONEncoder().encode(blockedGuide).write(to:destination.appendingPathComponent("guide.json"))
        let blockedStore=MathExperienceStore(directory:destination,legacyDirectory:legacy,clock:{ Date(timeIntervalSince1970:1791000001) })
        XCTAssertEqual(blockedStore.practiceQuestionCount,0); XCTAssertNotNil(blockedStore.currentPracticeBlockedReason)
        let retained=blockedStore.engine!.current, blockedCount=blockedStore.engine!.events.count
        blockedStore.grade(.independentCorrect,sessionID:retained!.id); blockedStore.familiar(sessionID:retained!.id); blockedStore.spotCheck("stable-1")
        XCTAssertEqual(blockedStore.engine!.current,retained); XCTAssertEqual(blockedStore.engine!.events.count,blockedCount)
        XCTAssertEqual(try Data(contentsOf:legacy.appendingPathComponent("archive.json")),archive)
        try Data("changed".utf8).write(to:legacy.appendingPathComponent("archive.json"))
        let count=store.engine!.events.count; store.hint(sessionID:store.engine!.current!.id); XCTAssertTrue(store.blocked); XCTAssertEqual(store.engine!.events.count,count)
        let restarted=MathExperienceStore(directory:destination,legacyDirectory:legacy)
        XCTAssertTrue(restarted.blocked)
    }
}
#endif
