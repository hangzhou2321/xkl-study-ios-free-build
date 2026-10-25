import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

private func priorityFixture() throws -> (ConceptBank,ConceptTeaching,[ProfessionalCardPriority]) {
    let qs=(0..<2).map { ConceptQuestion(id:"synthetic-q\($0)",type:.single,prompt:"Synthetic priority exercise \($0)?",options:[ExamOption(id:"A",text:"First"),ExamOption(id:"B",text:"Second")],answer:["A"],explanation:"Synthetic explanation",sourceIDs:["synthetic-source"],sourceLocation:"Synthetic only",verification:"Synthetic verified") }
    let cards=(0..<3).map { RecallCard(id:"synthetic-concept:\($0)",prompt:"Synthetic card \($0)?",answer:"Synthetic answer \($0)") }
    let group=SupplementRecallGroup(id:"synthetic-group",title:"Synthetic supplement",branchID:"main",recallCards:(0..<2).map { RecallCard(id:"synthetic-group:\($0)",prompt:"Synthetic supplement \($0)?",answer:"Synthetic supplement answer") })
    let bank=ConceptBank(id:ConceptSubject.computer.bankID,title:"Synthetic",scope:"Synthetic",notice:"Synthetic only",sources:[ConceptSource(id:"synthetic-source",title:"Synthetic source",reference:"fixture")],concepts:[StudyConcept(id:"synthetic-concept",title:"Synthetic concept",section:"Synthetic",method:"Synthetic method",questions:qs)])
    let stableBankEncoder=JSONEncoder();stableBankEncoder.outputFormatting=[.sortedKeys]
    let bytes=try stableBankEncoder.encode(bank),hash=StudySHA256.hex(bytes)
    let tree=SyllabusFixture.sample()
    var teaching=ConceptTeaching(format:"xkl-teaching-v1",bankSHA256:hash,lessons:[ConceptLesson(conceptID:"synthetic-concept",title:"Synthetic",story:"Story",keyIdea:"Idea",workedExample:"Example",commonTrap:"Trap",recallCards:cards)])
    teaching.syllabus=ConceptSyllabusTree(version:tree.version,title:tree.title,outlineSource:tree.outlineSource,frequencyNote:tree.frequencyNote,sources:tree.sources,branches:tree.branches,topics:tree.topics.map { .init(id:$0.id,branchID:$0.branchID,title:$0.title,conceptIDs:["synthetic-concept"],coverageNote:$0.coverageNote) },leaves:tree.leaves)
    teaching.recallGroups=[group]
    let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:teaching)
    teaching.primaryRecallDeck=deck
    teaching.studyPlan=ProfessionalStudyPlan(format:"xkl-professional-plan-v1",id:"synthetic-priority-plan",subject:.computer,basePrimaryDeckSHA256:try deck.hash,mainlineCardIDs:Array(cards.prefix(2)).map(\.id),relatedCardIDs:[cards[2].id],mainlineSupplementGroupIDs:[group.id],relatedSupplementGroupIDs:[group.id],supplementSelections:[.init(groupID:group.id,mainlineCardIDs:[group.recallCards[0].id],relatedCardIDs:[group.recallCards[1].id])],priorityConceptIDs:["synthetic-concept"],sourceQuestionIDs:qs.map(\.id))
    teaching.questionPresentations=qs.map { .init(questionID:$0.id,sourceQuestionDigest:$0.professionalDigest,requiredDiagram:false,beforeAnswer:[],afterAnswer:[]) }
    teaching.questionLinks=[.init(questionID:qs[0].id,sourceQuestionDigest:qs[0].professionalDigest,primaryCardIDs:Array(cards.prefix(2)).map(\.id),supplementCardIDs:[group.recallCards[0].id],guideConceptIDs:[])]
    let diagram=ConceptDiagram(version:1,title:"Synthetic",width:320,height:160,description:"Synthetic only",shapes:[.init(kind:"rect",x:20,y:20,width:200,height:80,stroke:"ink",fill:"white")],paths:[],labels:[.init(text:"Synthetic",x:30,y:30,width:180,height:30,size:18,color:"ink",align:"leading",bold:false)])
    let visual=ProfessionalQuestionVisual(id:"synthetic-visual",kind:"vector",diagram:diagram)
    teaching.sourceLeaves=[.init(sourceQuestionID:"synthetic-source-q",sourceID:"synthetic-source",page:1,label:"Synthetic original",status:"verified",bankQuestionID:qs[0].id,visual:visual,primaryCardIDs:[cards[0].id],supplementCardIDs:[],sourceStatus:.verified,courseReadiness:.ready,scope:.mainline,reason:"Synthetic verified original")]
    teaching.cardCorrections=[]
    let all=cards+group.recallCards
    let values=all.enumerated().map { index,card in ProfessionalCardPriority(cardID:card.id,sourceCardDigest:card.professionalDigest,level:index == 0 ? "priority":([1,3].contains(index) ? "regular":"extension"),classificationBasis:index == 0 ? "foundation":([1,3].contains(index) ? "local_detail":"extension"),reason:"Synthetic study order only",sourceQuestionIDs:[0,3].contains(index) ? [qs[0].id]:[]) }
    return (bank,teaching,values)
}
private func priorityCopy(_ value:ProfessionalCardPriority,level:String?=nil,basis:String?=nil,digest:String?=nil,reason:String?=nil,ids:[String]?=nil)->ProfessionalCardPriority {
    .init(cardID:value.cardID,sourceCardDigest:digest ?? value.sourceCardDigest,level:level ?? value.level,classificationBasis:basis ?? value.classificationBasis,reason:reason ?? value.reason,sourceQuestionIDs:ids ?? value.sourceQuestionIDs)
}
final class ProfessionalCardPriorityTests:XCTestCase {
    func testOldNilAndMetadataOnlyWithoutBase() throws {
        let (bank,base,values)=try priorityFixture()
        var old=base;old.primaryRecallDeck=nil;old.studyPlan=nil;old.questionPresentations=nil;old.questionLinks=nil;old.cardCorrections=nil;old.sourceLeaves=nil
        XCTAssertNil(old.cardPriorities)
        XCTAssertNoThrow(try old.validate(bank:bank,hash:old.bankSHA256))
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let original=try encoder.encode(old),decoded=try JSONDecoder().decode(ConceptTeaching.self,from:original)
        XCTAssertEqual(try encoder.encode(decoded),original)
        old.cardPriorities=values
        XCTAssertThrowsError(try old.validate(bank:bank,hash:old.bankSHA256))
    }
    func testCompleteMetadataAndDeckAndGradedRecordIdentityRemainUnchanged() throws {
        let (bank,base,values)=try priorityFixture();var labeled=base;labeled.cardPriorities=values
        XCTAssertNoThrow(try labeled.validate(bank:bank,hash:labeled.bankSHA256))
        let oldDeck=try RecallDeck.make(subject:.computer,bank:bank,teaching:base),newDeck=try RecallDeck.make(subject:.computer,bank:bank,teaching:labeled)
        XCTAssertEqual(oldDeck,newDeck);XCTAssertEqual(try oldDeck.hash,try newDeck.hash)
        let group=base.recallGroups![0]
        XCTAssertEqual(try RecallDeck.makeSupplement(subject:.computer,bank:bank,group:group).hash,try RecallDeck.makeSupplement(subject:.computer,bank:bank,group:labeled.recallGroups![0]).hash)
        var engine=try RecallEngine(deck:oldDeck);try engine.act("start",day:20000,newLimit:3)
        let token=try XCTUnwrap(engine.record.state.shown?.id);try engine.act("reveal",day:20000,token:token);try engine.act("grade",day:20000,token:token,remembered:true)
        let stable=JSONEncoder();stable.outputFormatting=[.sortedKeys]
        let bytes=try stable.encode(engine.record)
        let restored=try RecallEngine(deck:newDeck,record:engine.record)
        XCTAssertEqual(restored.record,engine.record)
        XCTAssertEqual(try stable.encode(restored.record),bytes)
        XCTAssertEqual(base.lessons,labeled.lessons);XCTAssertEqual(base.studyPlan,labeled.studyPlan)
    }
    func testCoverageDigestLevelBasisAndReasonRejectInvalidMetadata() throws {
        let (bank,base,values)=try priorityFixture()
        var bad=values;bad.removeLast();XCTAssertThrowsError(try ProfessionalCardPriority.validateAll(bad,bank:bank,teaching:base))
        bad=values;bad[1]=bad[0];XCTAssertThrowsError(try ProfessionalCardPriority.validateAll(bad,bank:bank,teaching:base))
        for changed in [priorityCopy(values[0],level:"high_frequency"),priorityCopy(values[0],basis:"local_detail"),priorityCopy(values[0],digest:String(repeating:"0",count:64)),priorityCopy(values[0],reason:"  "),priorityCopy(values[0],reason:String(repeating:"x",count:301)),priorityCopy(values[0],level:"extension",basis:"extension")] {
            bad=values;bad[0]=changed;XCTAssertThrowsError(try ProfessionalCardPriority.validateAll(bad,bank:bank,teaching:base))
        }
        bad=values
        for index in [0,1,3] { bad[index]=priorityCopy(bad[index],level:"priority",basis:"foundation") }
        // Content distribution quality is independently reviewed, not a schema rejection.
        XCTAssertNoThrow(try ProfessionalCardPriority.validateAll(bad,bank:bank,teaching:base))
    }
    func testReferencesRequireReliableOriginalActualCardLinkAndCanonicalDeduplication() throws {
        let (bank,base,values)=try priorityFixture();var bad=values
        for ids in [["synthetic-q0","synthetic-q0"],["synthetic-q1"],["synthetic-source-q"]] {
            bad=values;bad[0]=priorityCopy(values[0],ids:ids);XCTAssertThrowsError(try ProfessionalCardPriority.validateAll(bad,bank:bank,teaching:base))
        }
        bad=values;bad[2]=priorityCopy(values[2],ids:["synthetic-q0"])
        XCTAssertThrowsError(try ProfessionalCardPriority.validateAll(bad,bank:bank,teaching:base))
        var unreliable=base;unreliable.sourceLeaves![0].scope = .relatedFoundation
        XCTAssertThrowsError(try ProfessionalCardPriority.validateAll(values,bank:bank,teaching:unreliable))
        var aliases=base;var alias=base.sourceLeaves![0]
        alias=ProfessionalSourceLeaf(sourceQuestionID:"synthetic-alias",sourceID:alias.sourceID,page:2,label:"Synthetic alias",status:alias.status,bankQuestionID:alias.bankQuestionID,visual:alias.visual,primaryCardIDs:alias.primaryCardIDs,supplementCardIDs:alias.supplementCardIDs,sourceStatus:alias.sourceStatus,courseReadiness:alias.courseReadiness,scope:alias.scope,reason:alias.reason)
        aliases.sourceLeaves!.append(alias)
        XCTAssertNoThrow(try ProfessionalCardPriority.validateAll(values,bank:bank,teaching:aliases))
        XCTAssertEqual(Set(values[0].sourceQuestionIDs).count,1)
    }
    #if os(macOS)
    @MainActor func testMetadataOnlyCourseImportPreservesActualScoredRecordAndRecallArchiveBytes() throws {
        let (bank,base,values)=try priorityFixture();var labeled=base;labeled.cardPriorities=values
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-priority-identity-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bankBytes=try encoder.encode(bank),hash=StudySHA256.hex(bankBytes)
        XCTAssertEqual(base.bankSHA256,hash,"Teaching and actual persisted bank bytes must share the exact hash")
        let pack=ConceptContent(format:"xkl-concepts-v1",bankBytes:bankBytes,bankSHA256:hash)
        func save(_ teaching:ConceptTeaching,_ filename:String) throws -> URL {
            let course=ConceptCourse(format:"xkl-course-v5",subject:.computer,bankContent:try encoder.encode(pack),teaching:teaching)
            let url=root.appendingPathComponent(filename);try encoder.encode(course).write(to:url);return url
        }
        let store=ConceptStore(subject:.computer,baseDirectory:root)
        store.importContent(try save(base,"base.xklcourse"));XCTAssertNil(store.error)
        store.startQuestion("synthetic-q0",expectedCurrentToken:nil)
        let token=try XCTUnwrap(store.engine?.shown?.id);store.choose("A",token:token);XCTAssertNil(store.error)
        let oldRecord=try encoder.encode(XCTUnwrap(store.engine?.record))
        let recall=RecallStore(subject:.computer,bank:bank,teaching:base,baseDirectory:root)
        recall.act("start",newLimit:1);let recallToken=try XCTUnwrap(recall.engine?.record.state.shown?.id)
        recall.act("reveal",token:recallToken);recall.act("grade",token:recallToken,remembered:true);XCTAssertNil(recall.error)
        let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:base)
        let archive=root.appendingPathComponent("RecallCards/computer/"+(try deck.hash)+"/recall.json")
        let before=try Data(contentsOf:archive)
        store.importContent(try save(labeled,"labeled.xklcourse"));XCTAssertNil(store.error);XCTAssertFalse(store.blocked)
        XCTAssertEqual(try encoder.encode(XCTUnwrap(store.engine?.record)),oldRecord)
        XCTAssertEqual(try Data(contentsOf:archive),before)
        let reopened=RecallStore(subject:.computer,bank:bank,teaching:labeled,baseDirectory:root)
        XCTAssertNil(reopened.error);XCTAssertEqual(reopened.engine?.record,recall.engine?.record)
        XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    #endif
    func testUnknownFrequencyFieldIsRejected() throws {
        let (_,_,values)=try priorityFixture();var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(values[0])) as? [String:Any]);json["examFrequency"]=99
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalCardPriority.self,from:JSONSerialization.data(withJSONObject:json)))
    }
}
