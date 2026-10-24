import XCTest
import StudyCore
@testable import StudyClientModel

private func professionalBankBytes(_ bank: ConceptBank) throws -> Data { let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]; return try encoder.encode(bank) }
private func professionalFixture() throws -> (ConceptBank, ConceptTeaching) {
    let qs=(0..<2).map { i in ConceptQuestion(id:"synthetic-q\(i)",type:.single,prompt:"Synthetic question \(i)?",options:[ExamOption(id:"A",text:"First"),ExamOption(id:"B",text:"Second")],answer:["A"],explanation:"Synthetic explanation",sourceIDs:["synthetic-source"],sourceLocation:"Fixture \(i)",verification:"Synthetic verified") }
    let bank=ConceptBank(id:ConceptSubject.computer.bankID,title:"Synthetic",scope:"Synthetic",notice:"Fixture only",sources:[ConceptSource(id:"synthetic-source",title:"Synthetic source",reference:"fixture")],concepts:[StudyConcept(id:"synthetic-concept",title:"Synthetic concept",section:"Fixture",method:"Synthetic method",questions:qs)])
    let hash=StudySHA256.hex(try professionalBankBytes(bank))
    let lesson=ConceptLesson(conceptID:"synthetic-concept",title:"Synthetic lesson",story:"Story",keyIdea:"Idea",workedExample:"Example",commonTrap:"Trap",recallCards:(0..<5).map { RecallCard(id:"synthetic-concept:\($0)",prompt:"Prompt \($0)",answer:"Answer \($0)",detail:"Original detail") })
    return (bank,ConceptTeaching(format:"xkl-teaching-v1",bankSHA256:hash,lessons:[lesson]))
}
private func professionalV5(_ bank: ConceptBank, _ old: ConceptTeaching) throws -> ConceptTeaching {
    var result=old; let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
    result.primaryRecallDeck=deck
    result.studyPlan=ProfessionalStudyPlan(format:"xkl-professional-plan-v1",id:"synthetic-mainline",subject:.computer,basePrimaryDeckSHA256:try deck.hash,mainlineCardIDs:Array(deck.cards.prefix(2).map(\.id)),relatedCardIDs:Array(deck.cards.dropFirst(2).map(\.id)),mainlineSupplementGroupIDs:[],relatedSupplementGroupIDs:[],priorityConceptIDs:["synthetic-concept"],sourceQuestionIDs:["synthetic-q0"])
    result.questionPresentations=bank.concepts.flatMap(\.questions).map { ProfessionalQuestionPresentation(questionID:$0.id,sourceQuestionDigest:$0.professionalDigest,requiredDiagram:false,beforeAnswer:[],afterAnswer:[]) }; result.questionLinks=[]; result.cardCorrections=[]; result.sourceLeaves=[]
    return result
}
private func professionalSupplementFixture() throws -> (ConceptBank, ConceptTeaching, SupplementRecallGroup, ConceptTeaching) {
    let (bank,base)=try professionalFixture()
    let group=SupplementRecallGroup(id:"synthetic-group",title:"Synthetic thirteen-card group",branchID:"main",recallCards:(0..<13).map { RecallCard(id:"synthetic-group:\($0)",prompt:"Group prompt \($0)?",answer:"Group answer \($0)") })
    var legacy=base; legacy.recallGroups=[group]
    let tree=SyllabusFixture.sample()
    legacy.syllabus=ConceptSyllabusTree(version:tree.version,title:tree.title,outlineSource:tree.outlineSource,frequencyNote:tree.frequencyNote,sources:tree.sources,branches:tree.branches,topics:tree.topics.map { ConceptSyllabusTree.Topic(id:$0.id,branchID:$0.branchID,title:$0.title,conceptIDs:["synthetic-concept"],coverageNote:$0.coverageNote) },leaves:tree.leaves)
    try legacy.validate(bank:bank,hash:legacy.bankSHA256)
    var upgraded=try professionalV5(bank,legacy); let old=upgraded.studyPlan!
    upgraded.studyPlan=ProfessionalStudyPlan(format:old.format,id:old.id,subject:old.subject,basePrimaryDeckSHA256:old.basePrimaryDeckSHA256,mainlineCardIDs:old.mainlineCardIDs,relatedCardIDs:old.relatedCardIDs,mainlineSupplementGroupIDs:[group.id],relatedSupplementGroupIDs:[group.id],supplementSelections:[ProfessionalSupplementSelection(groupID:group.id,mainlineCardIDs:Array(group.recallCards.prefix(3).map(\.id)),relatedCardIDs:Array(group.recallCards.dropFirst(3).map(\.id)))],priorityConceptIDs:old.priorityConceptIDs,sourceQuestionIDs:old.sourceQuestionIDs)
    try upgraded.validate(bank:bank,hash:upgraded.bankSHA256)
    return (bank,legacy,group,upgraded)
}
final class ProfessionalStudyPlanTests: XCTestCase {
    func testSwiftSortedKeysInteropWithLocalPythonCandidateEscaping() throws {
        let text="中文😀 / \"quote\"\nline\tcontrol\u{0001}\u{0008}\u{000c}\r\u{2028}\u{2029}"
        let deck=RecallDeck(subject:.computer,bankID:ConceptSubject.computer.bankID,cards:[RecallDeck.Item(conceptID:"synthetic",conceptTitle:"Synthetic / 中文😀",card:RecallCard(id:"synthetic:interop",prompt:text,answer:"Answer / \\ boundary",detail:"https://synthetic.invalid/a/b?x=\"q\"\nnext\u{2028}tail"))])
        let candidate=try XCTUnwrap(Data(base64Encoded:"eyJiYW5rSUQiOiJvdGhlci1lbmdpbmVlcmluZy1jb21wdXRlci0yMDI3LXYxIiwiY2FyZHMiOlt7ImNhcmQiOnsiYW5zd2VyIjoiQW5zd2VyIFwvIFxcIGJvdW5kYXJ5IiwiZGV0YWlsIjoiaHR0cHM6XC9cL3N5bnRoZXRpYy5pbnZhbGlkXC9hXC9iP3g9XCJxXCJcbm5leHTigKh0YWlsIiwiaWQiOiJzeW50aGV0aWM6aW50ZXJvcCIsInByb21wdCI6IuS4reaWh/CfmIAgXC8gXCJxdW90ZVwiXG5saW5lXHRjb250cm9sXHUwMDAxXGJcZlxy4oCo4oCpIn0sImNvbmNlcHRJRCI6InN5bnRoZXRpYyIsImNvbmNlcHRUaXRsZSI6IlN5bnRoZXRpYyBcLyDkuK3mlofwn5iAIn1dLCJzdWJqZWN0IjoiY29tcHV0ZXIifQ=="))
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(deck),candidate)
        XCTAssertEqual(try deck.hash,"5436a7fbd7e813eba8d803b3d48635c34a5f42b5af7c25c8a1108663b1894f19")
    }
    func testSupplementSelectionsPartitionEveryWholeGroupAndRejectUnsupportedJSON() throws {
        let (bank,_,group,teaching)=try professionalSupplementFixture(), deck=teaching.primaryRecallDeck!
        let plan=teaching.studyPlan!
        XCTAssertNoThrow(try plan.validate(bank:bank,teaching:teaching,deck:deck))
        XCTAssertEqual(plan.mainlineSupplementGroupIDs,plan.relatedSupplementGroupIDs)
        var bad=plan
        bad.supplementSelections=[]
        XCTAssertThrowsError(try bad.validate(bank:bank,teaching:teaching,deck:deck))
        bad=plan; bad.supplementSelections=[ProfessionalSupplementSelection(groupID:group.id,mainlineCardIDs:[group.recallCards[0].id],relatedCardIDs:Array(group.recallCards.dropFirst(2).map(\.id)))]
        XCTAssertThrowsError(try bad.validate(bank:bank,teaching:teaching,deck:deck))
        bad=plan; bad.supplementSelections=[ProfessionalSupplementSelection(groupID:group.id,mainlineCardIDs:[group.recallCards[0].id],relatedCardIDs:group.recallCards.map(\.id))]
        XCTAssertThrowsError(try bad.validate(bank:bank,teaching:teaching,deck:deck))
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as? [String:Any]); json.removeValue(forKey:"supplementSelections")
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalStudyPlan.self,from:JSONSerialization.data(withJSONObject:json)))
    }
    func testLegacyNilStateAndEventsRoundTripWithoutSelection() throws {
        let (bank,old)=try professionalFixture(); let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        var e=try RecallEngine(deck:deck); try e.act("start",day:20000,newLimit:5)
        let token=e.record.state.shown!.id
        try e.act("reveal",day:20000,token:token); try e.act("grade",day:20000,token:token,remembered:true)
        XCTAssertNil(e.record.state.selection); XCTAssertNil(e.record.state.parkedQueue)
        XCTAssertTrue(e.record.events.allSatisfy { $0.selectionID == nil && $0.selectedCardIDs == nil && $0.expectedDeckSHA256 == nil })
        let bytes=try JSONEncoder().encode(e.record), json=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertNil((json["state"] as? [String:Any])?["selection"])
        let loaded=try JSONDecoder().decode(RecallRecord.self,from:bytes)
        XCTAssertEqual(try RecallEngine(deck:deck,record:loaded).record,e.record)
        XCTAssertEqual(e.record.state.progress["synthetic-concept:0"]?.dueDay,20001)
    }
    func testSelectionPreservesLiveResultProgressAndParksWithoutLoss() throws {
        let (bank,old)=try professionalFixture(); let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        var e=try RecallEngine(deck:deck); try e.act("start",day:20000,newLimit:5)
        let initial=e.record, token=e.record.state.shown!.id
        try e.act("select-plan",day:20000,selectionID:"main",selectedCardIDs:["synthetic-concept:3","synthetic-concept:4"],expectedDeckSHA256:deck.hash)
        XCTAssertEqual(e.record.state.shown,initial.state.shown); XCTAssertEqual(e.record.state.progress,initial.state.progress)
        XCTAssertEqual(e.record.state.queue,["synthetic-concept:0","synthetic-concept:3","synthetic-concept:4"])
        XCTAssertEqual(e.record.state.parkedQueue,["synthetic-concept:1","synthetic-concept:2"])
        try e.act("reveal",day:20000,token:token); let revealed=e.record.state.shown
        try e.act("select-plan",day:20000,selectionID:"other",selectedCardIDs:["synthetic-concept:1"],expectedDeckSHA256:deck.hash)
        XCTAssertEqual(e.record.state.shown,revealed)
        try e.act("grade",day:20000,token:token,remembered:true)
        let result=e.record.state.result, progress=e.record.state.progress
        try e.act("select-plan",day:20001,selectionID:"all",selectedCardIDs:deck.cards.map(\.id),expectedDeckSHA256:deck.hash)
        XCTAssertEqual(e.record.state.result,result); XCTAssertEqual(e.record.state.progress,progress)
        let combined=e.record.state.queue+(e.record.state.parkedQueue ?? [])
        XCTAssertEqual(Set(combined).count,combined.count); XCTAssertEqual(Set(combined),Set(deck.cards.dropFirst().map(\.id)))
        try e.act("next",day:20001,token:token)
        XCTAssertNotNil(e.record.state.shown)
        XCTAssertEqual(try RecallEngine(deck:deck,record:e.record).record,e.record)
        XCTAssertEqual(Array(e.record.events.prefix(initial.events.count)),initial.events)
    }
    func testRetryQueueSurvivesPlanSwitchWithoutInventingProgress() throws {
        let (bank,old)=try professionalFixture(); let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        var e=try RecallEngine(deck:deck); try e.act("start",day:20000,newLimit:5)
        let token=e.record.state.shown!.id
        try e.act("reveal",day:20000,token:token); try e.act("grade",day:20000,token:token,remembered:false)
        let progress=e.record.state.progress, retries=e.record.state.retries, result=e.record.state.result
        try e.act("select-plan",day:20000,selectionID:"small",selectedCardIDs:["synthetic-concept:1","synthetic-concept:2"],expectedDeckSHA256:deck.hash)
        try e.act("select-plan",day:20000,selectionID:"all",selectedCardIDs:deck.cards.map(\.id),expectedDeckSHA256:deck.hash)
        XCTAssertEqual(e.record.state.progress,progress); XCTAssertEqual(e.record.state.retries,retries); XCTAssertEqual(e.record.state.result,result)
        XCTAssertTrue(e.record.state.parkedQueue!.contains("synthetic-concept:0"))
        try e.act("next",day:20000,token:token)
        let all=e.record.state.queue+(e.record.state.parkedQueue ?? [])
        XCTAssertEqual(Set(all).count,all.count); XCTAssertEqual(Set(all),Set(deck.cards.map(\.id)))
        XCTAssertEqual(try RecallEngine(deck:deck,record:e.record).record,e.record)
    }
    func testAppendingSourceConceptCannotChangeFrozenPrimaryHash() throws {
        let (bank,old)=try professionalFixture(); let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        let qs=(0..<2).map { i in ConceptQuestion(id:"synthetic-new-q\(i)",type:.single,prompt:"New source synthetic \(i)?",options:[ExamOption(id:"A",text:"Alpha"),ExamOption(id:"B",text:"Beta")],answer:["A"],explanation:"Synthetic verified",sourceIDs:["synthetic-source"],sourceLocation:"New \(i)",verification:"Synthetic") }
        let newConcept=StudyConcept(id:"synthetic-new",title:"New source concept",section:"Fixture",method:"Method",questions:qs)
        let appended=ConceptBank(id:bank.id,title:bank.title,scope:bank.scope,notice:bank.notice,sources:bank.sources,concepts:bank.concepts+[newConcept])
        try appended.validateAppendOnly(from:bank)
        let lesson=ConceptLesson(conceptID:newConcept.id,title:"New source lesson",story:"Story",keyIdea:"Idea",workedExample:"Example",commonTrap:"Trap")
        let hash=StudySHA256.hex(try professionalBankBytes(appended))
        var teaching=ConceptTeaching(format:old.format,bankSHA256:hash,lessons:old.lessons+[lesson])
        teaching.primaryRecallDeck=deck
        try teaching.validateAppendOnlyRecall(from:old,bank:bank)
        XCTAssertEqual(try RecallDeck.make(subject:.computer,bank:appended,teaching:teaching).hash,try deck.hash)
        var badLesson=lesson; badLesson.recallCards=[RecallCard(id:"synthetic-new:forbidden",prompt:"Question?",answer:"Answer")]
        let bad=ConceptTeaching(format:old.format,bankSHA256:hash,lessons:old.lessons+[badLesson],primaryRecallDeck:deck)
        XCTAssertThrowsError(try bad.validateAppendOnlyRecall(from:old,bank:bank))
    }
    func testSelectionValidationRejectsUnknownDuplicatesHashAndMixedPayload() throws {
        let (bank,old)=try professionalFixture(); let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        var e=try RecallEngine(deck:deck); let initial=e.record
        XCTAssertThrowsError(try e.act("select-plan",day:20000,selectionID:"main",selectedCardIDs:["unknown"],expectedDeckSHA256:deck.hash))
        XCTAssertThrowsError(try e.act("select-plan",day:20000,selectionID:"main",selectedCardIDs:["synthetic-concept:0","synthetic-concept:0"],expectedDeckSHA256:deck.hash))
        XCTAssertThrowsError(try e.act("select-plan",day:20000,selectionID:"main",selectedCardIDs:[],expectedDeckSHA256:String(repeating:"0",count:64)))
        XCTAssertThrowsError(try e.act("start",day:20000,newLimit:1,selectionID:"hidden"))
        XCTAssertEqual(e.record,initial)
    }
    func testFrozenPrimaryIdentityAndExplicitCorrectionsLeaveBackingDeckUnchanged() throws {
        let (bank,old)=try professionalFixture(); let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        var teaching=try professionalV5(bank,old)
        let card=deck.cards[0].card
        teaching.cardCorrections=[ProfessionalCardCorrection(cardID:card.id,sourceCardDigest:card.professionalDigest,note:"Synthetic correction; original retained.",sourceRef:"synthetic audited source")]
        try teaching.validate(bank:bank,hash:old.bankSHA256); try teaching.validateAppendOnlyRecall(from:old,bank:bank)
        XCTAssertEqual(try RecallDeck.make(subject:.computer,bank:bank,teaching:teaching),deck)
        XCTAssertEqual(try teaching.primaryRecallDeck!.hash,try deck.hash)
        var bad=teaching; bad.primaryRecallDeck=RecallDeck(subject:.computer,bankID:bank.id,cards:Array(deck.cards.reversed()))
        XCTAssertThrowsError(try bad.validatePrimarySnapshot(bank:bank))
        bad=teaching; bad.cardCorrections=[ProfessionalCardCorrection(cardID:card.id,sourceCardDigest:String(repeating:"0",count:64),note:"Wrong target",sourceRef:"synthetic")]
        XCTAssertThrowsError(try bad.validate(bank:bank,hash:old.bankSHA256))
    }
    func testV5RequiresAllTypedFieldsAndCannotHideInV4() throws {
        let (bank,old)=try professionalFixture(); let bankBytes=try professionalBankBytes(bank)
        let content=try JSONEncoder().encode(ConceptContent(format:"xkl-concepts-v1",bankBytes:bankBytes,bankSHA256:old.bankSHA256))
        let teaching=try professionalV5(bank,old)
        let valid=ConceptCourse(format:"xkl-course-v5",subject:.computer,bankContent:content,teaching:teaching)
        XCTAssertNoThrow(try ConceptCourse.load(JSONEncoder().encode(valid),subject:.computer))
        var planJSON=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(teaching.studyPlan!)) as? [String:Any])
        planJSON["hiddenUnsupportedCards"]=["synthetic-unsupported"]
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalStudyPlan.self,from:JSONSerialization.data(withJSONObject:planJSON)))
        let disguised=ConceptCourse(format:"xkl-course-v4",subject:.computer,bankContent:content,teaching:teaching)
        XCTAssertThrowsError(try ConceptCourse.load(JSONEncoder().encode(disguised),subject:.computer))
        var incomplete=teaching; incomplete.sourceLeaves=nil
        XCTAssertThrowsError(try incomplete.validate(bank:bank,hash:old.bankSHA256))
        let oldCourse=ConceptCourse(format:"xkl-course-v4",subject:.computer,bankContent:content,teaching:old)
        XCTAssertNoThrow(try ConceptCourse.load(JSONEncoder().encode(oldCourse),subject:.computer))
    }
}
#if os(macOS)
final class ProfessionalRecallPersistenceTests: XCTestCase {
    @MainActor func testExistingWholeSupplementRecordIsReusedForThreeOfThirteenSelection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (bank,legacy,group,teaching)=try professionalSupplementFixture()
        let original=RecallStore(subject:.computer,bank:bank,teaching:legacy,baseDirectory:root,supplementGroup:group)
        original.act("start",newLimit:13)
        let token=try XCTUnwrap(original.engine?.record.state.shown?.id)
        original.act("reveal",token:token); original.act("grade",token:token,remembered:true)
        let originalBytes=try original.export(), oldRecord=original.engine!.record, fullHash=try original.engine!.deck.hash
        let store=RecallStore(subject:.computer,bank:bank,teaching:teaching,baseDirectory:root,supplementGroup:group)
        XCTAssertFalse(store.blocked); XCTAssertEqual(try store.export(),originalBytes)
        let selection=teaching.studyPlan!.supplementSelections[0]
        store.applySelection(planID:"supplement-main",cardIDs:selection.mainlineCardIDs,expectedDeckSHA256:fullHash)
        XCTAssertEqual(store.engine!.selectedTotal,3); XCTAssertEqual(store.engine!.selectedNewCount,2)
        XCTAssertEqual(store.engine!.newCount,12); XCTAssertEqual(store.engine!.deck.cards.count,13)
        XCTAssertEqual(store.engine!.selectedDueCount(day:oldRecord.state.day+1),1)
        XCTAssertEqual(store.engine!.record.state.progress,oldRecord.state.progress); XCTAssertEqual(store.engine!.record.state.result,oldRecord.state.result)
        XCTAssertEqual(Set(store.engine!.record.state.parkedQueue ?? []),Set(selection.relatedCardIDs))
        store.applySelection(planID:"supplement-related",cardIDs:selection.relatedCardIDs,expectedDeckSHA256:fullHash)
        XCTAssertEqual(store.engine!.selectedTotal,10); XCTAssertEqual(store.engine!.selectedNewCount,10)
        XCTAssertEqual(store.engine!.record.state.progress,oldRecord.state.progress)
        store.applySelection(planID:"supplement-all",cardIDs:group.recallCards.map(\.id),expectedDeckSHA256:fullHash)
        let state=store.engine!.record.state, combined=state.queue+(state.parkedQueue ?? [])
        XCTAssertEqual(Set(combined).count,combined.count); XCTAssertEqual(Set(combined),Set(group.recallCards.dropFirst().map(\.id)))
        XCTAssertEqual(try store.engine!.deck.hash,fullHash)
        XCTAssertEqual(Array(store.engine!.record.events.prefix(oldRecord.events.count)),oldRecord.events)
        let restored=RecallStore(subject:.computer,bank:bank,teaching:teaching,baseDirectory:root,supplementGroup:group)
        XCTAssertEqual(restored.engine!.record,store.engine!.record)
    }
    @MainActor func testSharedReadOnlyPreflightReportsFreshExistingAndRejectsNewHashBeforeWrites() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (bank,old)=try professionalFixture(), deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        XCTAssertEqual(try RecallStore.preflightPrimary(subject:.computer,deck:deck,baseDirectory:root),.freshNoLocalRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        let existing=RecallStore(subject:.computer,bank:bank,teaching:old,baseDirectory:root)
        existing.act("start",newLimit:1)
        let token=try XCTUnwrap(existing.engine?.record.state.shown?.id)
        existing.act("reveal",token:token); existing.act("grade",token:token,remembered:true)
        let original=try existing.export()
        XCTAssertEqual(try RecallStore.preflightPrimary(subject:.computer,deck:deck,baseDirectory:root),.existingMatchingArchive)
        XCTAssertEqual(try existing.export(),original)
        var cards=deck.cards
        let card=cards[0].card
        cards[0]=RecallDeck.Item(conceptID:cards[0].conceptID,conceptTitle:cards[0].conceptTitle,card:RecallCard(id:card.id,prompt:card.prompt,answer:"Changed synthetic answer",detail:card.detail))
        let changed=RecallDeck(subject:.computer,bankID:deck.bankID,cards:cards)
        XCTAssertThrowsError(try RecallStore.preflightPrimary(subject:.computer,deck:changed,baseDirectory:root))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("RecallCards/computer").appendingPathComponent(try changed.hash).path))
        XCTAssertEqual(try existing.export(),original)
        let marker=root.appendingPathComponent("RecallCards/computer").appendingPathComponent(try deck.hash).appendingPathComponent("created.json")
        try JSONEncoder().encode(String(repeating:"0",count:64)).write(to:marker)
        XCTAssertThrowsError(try RecallStore.preflightPrimary(subject:.computer,deck:deck,baseDirectory:root))
        XCTAssertEqual(try existing.export(),original)
    }
    @MainActor func testOrphanCreationMarkerPreventsDifferentFrozenIdentityReset() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (bank,old)=try professionalFixture(), teaching=try professionalV5(bank,old)
        let parent=root.appendingPathComponent("RecallCards/computer"), orphan=parent.appendingPathComponent(String(repeating:"0",count:64))
        try FileManager.default.createDirectory(at:orphan,withIntermediateDirectories:true)
        let marker=try JSONEncoder().encode(String(repeating:"0",count:64))
        try marker.write(to:orphan.appendingPathComponent("created.json"))
        let store=RecallStore(subject:.computer,bank:bank,teaching:teaching,baseDirectory:root)
        XCTAssertTrue(store.blocked); XCTAssertNil(store.engine)
        let target=parent.appendingPathComponent(try teaching.primaryRecallDeck!.hash).appendingPathComponent("recall.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        XCTAssertEqual(try Data(contentsOf:orphan.appendingPathComponent("created.json")),marker)
    }
    @MainActor func testFrozenDeckReusesOriginalPathAndSelectionWriteFailureDoesNotPublish() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (bank,old)=try professionalFixture(), teaching=try professionalV5(bank,old)
        let first=RecallStore(subject:.computer,bank:bank,teaching:old,baseDirectory:root)
        first.act("start",newLimit:5)
        let token=try XCTUnwrap(first.engine?.record.state.shown?.id)
        first.act("reveal",token:token); first.act("grade",token:token,remembered:true)
        let bytes=try first.export(), record=first.engine!.record
        var fail=true
        let next=RecallStore(subject:.computer,bank:bank,teaching:teaching,baseDirectory:root,writer:{ data,url in if fail { throw CocoaError(.fileWriteOutOfSpace) }; try DurableFile.write(data,to:url) })
        XCTAssertFalse(next.blocked); XCTAssertEqual(next.engine!.record,record); XCTAssertEqual(try next.export(),bytes)
        next.applySelection(planID:"main",cardIDs:teaching.studyPlan!.mainlineCardIDs,expectedDeckSHA256:try next.engine!.deck.hash)
        XCTAssertEqual(next.engine!.record,record); XCTAssertEqual(try next.export(),bytes)
        fail=false
        next.applySelection(planID:"main",cardIDs:teaching.studyPlan!.mainlineCardIDs,expectedDeckSHA256:try next.engine!.deck.hash)
        XCTAssertEqual(next.engine!.record.state.progress,record.state.progress); XCTAssertEqual(next.engine!.record.state.result,record.state.result)
        XCTAssertEqual(Array(next.engine!.record.events.prefix(record.events.count)),record.events)
        let restarted=RecallStore(subject:.computer,bank:bank,teaching:teaching,baseDirectory:root)
        XCTAssertEqual(restarted.engine!.record,next.engine!.record)
        let preserved=try restarted.export()
        var missingSnapshot=teaching; missingSnapshot.primaryRecallDeck=nil
        XCTAssertThrowsError(try RecallDeck.make(subject:.computer,bank:bank,teaching:missingSnapshot))
        let incomplete=RecallStore(subject:.computer,bank:bank,teaching:missingSnapshot,baseDirectory:root)
        XCTAssertTrue(incomplete.blocked); XCTAssertNil(incomplete.engine)
        var mismatched=teaching
        mismatched.primaryRecallDeck=RecallDeck(subject:.computer,bankID:bank.id,cards:Array(teaching.primaryRecallDeck!.cards.dropFirst()))
        let refused=RecallStore(subject:.computer,bank:bank,teaching:mismatched,baseDirectory:root)
        XCTAssertTrue(refused.blocked); XCTAssertNil(refused.engine)
        XCTAssertEqual(try restarted.export(),preserved)
    }
}
#endif
