import XCTest
import Foundation
import StudyCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
@testable import StudyClientModel

/// Entirely synthetic question source and raster fixtures; never reads private courses.
final class ProfessionalQuestionTests: XCTestCase {
    private let hash=String(repeating:"a",count:64)
    private func fixture(append:Bool=false) throws -> (ConceptBank,ConceptTeaching,ConceptCourse) {
        let bank=ConceptBank(id:ConceptSubject.computer.bankID,title:"Synthetic",scope:"Test",notice:"Fiction only",
            sources:[.init(id:"s",title:"Synthetic",reference:"generated")],
            concepts:(0..<2).map { c in
                StudyConcept(id:"c\(c)",title:"Concept \(c)",section:"Test",method:"Compare",
                    questions:(0..<(append && c==0 ? 3:2)).map { q in
                        ConceptQuestion(id:"c\(c)q\(q)",type:.single,prompt:"Synthetic distinct \(c)-\(q)",
                            options:[.init(id:"A",text:"One"),.init(id:"B",text:"Two")],answer:["A"],
                            explanation:"Synthetic explanation",sourceIDs:["s"],sourceLocation:"Generated page1",verification:"Fictional verified fixture")
                    })
            })
        let bytes=try GuidanceFixture.encode(bank),digest=StudySHA256.hex(bytes)
        let teaching=ConceptTeaching(format:"xkl-teaching-v1",bankSHA256:digest,lessons:bank.concepts.map { c in
            ConceptLesson(conceptID:c.id,title:"Lesson",story:"Story",keyIdea:"Idea",workedExample:"Example",commonTrap:"Trap",
                recallCards:[.init(id:c.id+":card",prompt:"Prompt",answer:"Answer")])
        })
        let pack=ConceptContent(format:"xkl-concepts-v1",bankBytes:bytes,bankSHA256:digest)
        let course=ConceptCourse(format:"xkl-course-v4",subject:.computer,bankContent:try GuidanceFixture.encode(pack),teaching:teaching)
        return (bank,teaching,course)
    }
    private func presentation(_ q:ConceptQuestion,required:Bool=false,visuals:[ProfessionalQuestionVisual]=[]) -> ProfessionalQuestionPresentation {
        .init(questionID:q.id,sourceQuestionDigest:q.professionalDigest,requiredDiagram:required,beforeAnswer:visuals,afterAnswer:[])
    }
    private func v5(_ bank:ConceptBank,_ old:ConceptTeaching,_ course:ConceptCourse,deck:RecallDeck?=nil,withLinks:Bool=false) throws -> ConceptCourse {
        var t=old
        let d=try deck ?? RecallDeck.make(subject:.computer,bank:bank,teaching:old)
        t.primaryRecallDeck=d
        t.studyPlan=ProfessionalStudyPlan(format:"xkl-professional-plan-v1",id:"synthetic",subject:.computer,
            basePrimaryDeckSHA256:try d.hash,mainlineCardIDs:d.cards.map(\.id),relatedCardIDs:[],mainlineSupplementGroupIDs:[],
            relatedSupplementGroupIDs:[],priorityConceptIDs:[],sourceQuestionIDs:bank.concepts.flatMap(\.questions).map(\.id))
        t.questionPresentations=bank.concepts.flatMap(\.questions).map{presentation($0)}
        if withLinks {
            let q=bank.concepts[0].questions[0]
            t.questionLinks=[ProfessionalQuestionLinks(questionID:q.id,sourceQuestionDigest:q.professionalDigest,
                primaryCardIDs:["c0:card"],supplementCardIDs:[],guideConceptIDs:[])]
        } else { t.questionLinks=[] }
        t.sourceLeaves=[];t.cardCorrections=[]
        return ConceptCourse(format:"xkl-course-v5",subject:.computer,bankContent:course.bankContent,teaching:t)
    }
    func testStartQuestionPreservesLiveTokenSelectionResultAndConsumedIDs() throws {
        let (bank,_,_)=try fixture();var e=try ConceptEngine(bank:bank,hash:hash)
        try e.startQuestion(questionID:"c0q1",day:21_000)
        let shown=try XCTUnwrap(e.shown)
        XCTAssertEqual(e.record.queue,["c0"])
        try e.startQuestion(questionID:"c0q1",day:21_000)
        XCTAssertEqual(e.shown,shown)
        XCTAssertThrowsError(try e.startQuestion(questionID:"c1q0",day:21_000))
        XCTAssertEqual(e.shown,shown)
        try e.answer("A",token:shown.id,day:21_000)
        let result=e.record.review
        try e.startQuestion(questionID:"c0q1",day:21_000)
        XCTAssertEqual(e.record.review,result)
        XCTAssertEqual(e.record.progress["c0"]?.usedQuestionIDs,["c0q1"])
        XCTAssertEqual(e.record.attempts.count,1)
        e.next(token:shown.id)
        XCTAssertThrowsError(try e.startQuestion(questionID:"c0q1",day:21_000))
        XCTAssertEqual(e.record.progress["c0"]?.usedQuestionIDs,["c0q1"])
        XCTAssertEqual(e.record.attempts.count,1)
        try e.record.validate(bank:bank,hash:hash)
    }
    func testSourceEntryKeepsOtherQueuedConceptAndRefusesInactiveFamiliar() throws {
        let (bank,_,_)=try fixture();var e=try ConceptEngine(bank:bank,hash:hash)
        e.record.queue=["c1"]
        try e.startQuestion(questionID:"c0q0",day:21_000)
        XCTAssertEqual(e.record.queue,["c0","c1"])
        XCTAssertTrue(e.record.progress.isEmpty)
        XCTAssertTrue(e.record.attempts.isEmpty)
        var f=try ConceptEngine(bank:bank,hash:hash)
        f.record.progress["c0"]=ConceptProgress(familiar:true)
        XCTAssertThrowsError(try f.startQuestion(questionID:"c0q0",day:21_000))
        XCTAssertNil(f.shown)
        var scoped=bank
        scoped.studyScope = .init(id:"test",title:"Test",sourceReference:"test",includedQuestionIDs:["c1q0","c1q1"],excludedQuestionReasons:["c0q0":"excluded","c0q1":"excluded"])
        var g=try ConceptEngine(bank:scoped,hash:hash)
        XCTAssertThrowsError(try g.startQuestion(questionID:"c0q0",day:21_000))
        XCTAssertEqual(g.record.day,0)
    }
    func testExplicitSourceOptionOrderPersistsInActualPresentationAndLegacyNilIsOmitted() throws {
        let (bank,_,_)=try fixture();let old=bank.concepts[0].questions[0]
        let encoded=try GuidanceFixture.encode(old)
        let oldObject=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNil(oldObject["preserveOptionOrder"])
        XCTAssertNil(try JSONDecoder().decode(ConceptQuestion.self,from:encoded).preserveOptionOrder)
        var fixed=old;fixed.preserveOptionOrder=true
        XCTAssertNotEqual(fixed.professionalDigest,old.professionalDigest)
        var changedObject=oldObject;changedObject["preserveOptionOrder"]=true
        let explicit=try JSONDecoder().decode(ConceptQuestion.self,from:JSONSerialization.data(withJSONObject:changedObject))
        XCTAssertEqual(explicit.professionalDigest,fixed.professionalDigest)
        let concept=bank.concepts[0]
        let replacement=StudyConcept(id:concept.id,title:concept.title,section:concept.section,method:concept.method,
            questions:[fixed]+Array(concept.questions.dropFirst()))
        let ordered=ConceptBank(id:bank.id,title:bank.title,scope:bank.scope,notice:bank.notice,sources:bank.sources,
            concepts:[replacement]+Array(bank.concepts.dropFirst()))
        var direct=try ConceptEngine(bank:ordered,hash:hash)
        try direct.startQuestion(questionID:fixed.id,day:21_000)
        XCTAssertEqual(direct.shown?.order,fixed.options.map(\.id))
        var ordinary=try ConceptEngine(bank:ordered,hash:hash)
        try ordinary.start(day:21_000,newLimit:1)
        XCTAssertEqual(ordinary.shown?.questionID,fixed.id)
        XCTAssertEqual(ordinary.shown?.order,fixed.options.map(\.id))
        let decoded=try JSONDecoder().decode(ConceptRecord.self,from:GuidanceFixture.encode(ordinary.record))
        XCTAssertEqual(decoded.presentation?.order,fixed.options.map(\.id))
        XCTAssertThrowsError(try ordered.validateAppendOnly(from:bank)) // Never retrofit historical nil IDs.
    }
    func testQuestionDigestBindsExactAnswerSourceAndOptionOrder() throws {
        let (bank,_,_)=try fixture();let q=bank.concepts[0].questions[0]
        let encoded=try GuidanceFixture.encode(q)
        XCTAssertEqual(try JSONDecoder().decode(ConceptQuestion.self,from:encoded).professionalDigest,q.professionalDigest)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        for field in ["answer","sourceLocation","prompt"] {
            var changed=object
            if field == "answer" { changed[field] = ["B"] } else { changed[field] = "Changed" }
            let r=try JSONDecoder().decode(ConceptQuestion.self,from:JSONSerialization.data(withJSONObject:changed))
            XCTAssertNotEqual(r.professionalDigest,q.professionalDigest)
        }
        object["options"]=(object["options"] as! [[String:Any]]).reversed().map{$0}
        XCTAssertNotEqual(try JSONDecoder().decode(ConceptQuestion.self,from:JSONSerialization.data(withJSONObject:object)).professionalDigest,q.professionalDigest)
    }
    func testNecessaryDiagramMustAppearBeforeAnswerAndAllBindingsValidated() throws {
        let (bank,_,_)=try fixture();let q=bank.concepts[0].questions[0]
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validateAll([presentation(q,required:true)],bank:bank))
        let visual=ProfessionalQuestionVisual(id:"v",kind:"vector",diagram:DiagramFixture.sample)
        let good=presentation(q,required:true,visuals:[visual])
        XCTAssertNoThrow(try ProfessionalQuestionPresentation.validateAll([good],bank:bank))
        let afterOnly=ProfessionalQuestionPresentation(questionID:q.id,sourceQuestionDigest:q.professionalDigest,requiredDiagram:true,beforeAnswer:[],afterAnswer:[visual])
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validateAll([afterOnly],bank:bank))
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validateAll([good,good],bank:bank))
        let bad=ProfessionalQuestionPresentation(questionID:q.id,sourceQuestionDigest:hash,requiredDiagram:false,beforeAnswer:[],afterAnswer:[])
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validateAll([bad],bank:bank))
    }
    func testLinksAndPendingSourceLeavesCannotInventCardsOrScorableQuestion() throws {
        let (bank,t,c)=try fixture();let v=try v5(bank,t,c);let q=bank.concepts[0].questions[0]
        let good=ProfessionalQuestionLinks(questionID:q.id,sourceQuestionDigest:q.professionalDigest,primaryCardIDs:["c0:card"],supplementCardIDs:[],guideConceptIDs:[])
        XCTAssertNoThrow(try ProfessionalQuestionLinks.validateAll([good],bank:bank,teaching:v.teaching))
        let unknown=ProfessionalQuestionLinks(questionID:q.id,sourceQuestionDigest:q.professionalDigest,primaryCardIDs:["missing"],supplementCardIDs:[],guideConceptIDs:[])
        XCTAssertThrowsError(try ProfessionalQuestionLinks.validateAll([unknown],bank:bank,teaching:v.teaching))
        let visual=ProfessionalQuestionVisual(id:"leaf",kind:"vector",diagram:DiagramFixture.sample)
        let pending=ProfessionalSourceLeaf(sourceQuestionID:"pending",sourceID:"s",page:1,label:"Pending image",status:"pending",visual:visual,primaryCardIDs:["c0:card"],supplementCardIDs:[])
        XCTAssertNoThrow(try ProfessionalSourceLeaf.validateAll([pending],bank:bank,teaching:v.teaching))
        let illegal=ProfessionalSourceLeaf(sourceQuestionID:"pending",sourceID:"s",page:1,label:"Pending image",status:"pending",bankQuestionID:q.id,visual:visual,primaryCardIDs:[],supplementCardIDs:[])
        XCTAssertThrowsError(try ProfessionalSourceLeaf.validateAll([illegal],bank:bank,teaching:v.teaching))
    }
    func testV5RequiresEveryActivePresentationAndExplicitSourceKind() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        XCTAssertNoThrow(try ConceptCourse.load(GuidanceFixture.encode(valid),subject:.computer))
        var missing=valid.teaching
        missing.questionPresentations=Array((missing.questionPresentations ?? []).dropLast())
        XCTAssertThrowsError(try missing.validate(bank:bank,hash:t.bankSHA256))
        let entry=try XCTUnwrap(valid.teaching.questionPresentations?.first)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:GuidanceFixture.encode(entry)) as? [String:Any])
        object.removeValue(forKey:"sourceKind")
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalQuestionPresentation.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testRuntimePreflightRejectsIncompleteOrInvalidNextQuestionBeforeRollover() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        let all=try XCTUnwrap(valid.teaching.questionPresentations)
        XCTAssertNoThrow(try ProfessionalQuestionPresentation.validatePracticeContent(all,bank:bank))
        // An idle engine has no shown ID: validating only the old current pointer would miss this.
        var idle=try ConceptEngine(bank:bank,hash:hash)
        XCTAssertNil(idle.shown)
        let incomplete=Array(all.dropFirst())
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validatePracticeContent(incomplete,bank:bank))
        try idle.start(day:21_000,newLimit:1)
        XCTAssertNotNil(idle.shown)
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validatePracticeContent(incomplete,bank:bank))
        let first=all[0]
        let missingDiagram=ProfessionalQuestionPresentation(questionID:first.questionID,sourceQuestionDigest:first.sourceQuestionDigest,
            requiredDiagram:true,beforeAnswer:[],afterAnswer:[])
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validatePracticeContent([missingDiagram]+Array(all.dropFirst()),bank:bank))
        var invalidKind=first;invalidKind.sourceKind="unreviewed"
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validatePracticeContent([invalidKind]+Array(all.dropFirst()),bank:bank))
    }
    func testSourceFileReferencesAreMetadataOnlyUniqueBudgetedAndForbiddenInPractice() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        let file=ProfessionalSourceFileAsset(sha256:hash,mimeType:"image/jpeg",byteCount:3*1_024*1_024,
            pixelWidth:4032,pixelHeight:3024,crop:.init(x:0,y:0,width:1,height:1),altText:"Synthetic metadata only")
        func leaf(_ id:String,_ asset:ProfessionalSourceFileAsset) -> ProfessionalSourceLeaf {
            .init(sourceQuestionID:id,sourceID:"s",page:1,label:"Synthetic source",status:"pending",
                visual:.init(id:id,kind:"sourceFile",sourceFile:asset),primaryCardIDs:[],supplementCardIDs:[],
                sourceStatus:.verified,courseReadiness:.awaitingCard,scope:.mainline,reason:"源题已核，课程卡尚不充分。")
        }
        // No assets exist: course metadata validation must not open any file, even 800 references.
        let repeated=(0..<800).map{leaf("leaf\($0)",file)}
        XCTAssertNoThrow(try ProfessionalSourceLeaf.validateAll(repeated,bank:bank,teaching:valid.teaching))
        let altered=ProfessionalSourceFileAsset(sha256:hash,mimeType:file.mimeType,byteCount:file.byteCount-1,
            pixelWidth:file.pixelWidth,pixelHeight:file.pixelHeight,crop:file.crop,altText:file.altText)
        XCTAssertThrowsError(try ProfessionalSourceLeaf.validateAll([leaf("a",file),leaf("b",altered)],bank:bank,teaching:valid.teaching))
        let unique=(0..<33).map { i -> ProfessionalSourceLeaf in
            let digest=String(repeating:"0",count:62)+String(format:"%02x",i)
            let asset=ProfessionalSourceFileAsset(sha256:digest,mimeType:"image/png",byteCount:4*1_024*1_024,
                pixelWidth:4096,pixelHeight:4096,crop:file.crop,altText:"Synthetic metadata")
            return leaf("unique\(i)",asset)
        }
        XCTAssertNoThrow(try ProfessionalSourceLeaf.validateAll(Array(unique.prefix(32)),bank:bank,teaching:valid.teaching))
        XCTAssertThrowsError(try ProfessionalSourceLeaf.validateAll(unique,bank:bank,teaching:valid.teaching))
        let q=bank.concepts[0].questions[0],visual=ProfessionalQuestionVisual(id:"forbidden",kind:"sourceFile",sourceFile:file)
        XCTAssertThrowsError(try ProfessionalQuestionPresentation.validateAll([presentation(q,required:true,visuals:[visual])],bank:bank))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:GuidanceFixture.encode(file)) as? [String:Any])
        object["path"]="/arbitrary/image.jpg"
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalSourceFileAsset.self,from:JSONSerialization.data(withJSONObject:object)))
        let encoded=try GuidanceFixture.encode(repeated[0])
        let restored=try JSONDecoder().decode(ProfessionalSourceLeaf.self,from:encoded)
        XCTAssertEqual(restored.sourceStatus,.verified);XCTAssertEqual(restored.courseReadiness,.awaitingCard)
        XCTAssertEqual(restored.scope,.mainline);XCTAssertEqual(restored.status,"pending");XCTAssertNil(restored.bankQuestionID)
    }
    func testCrossPageSourceMetadataIncludesAllPagesInSharedBudgetAndLimits() throws {
        let (bank,t,c)=try fixture();let course=try v5(bank,t,c)
        let visuals=(0..<33).map { i -> ProfessionalQuestionVisual in
            let digest=String(repeating:"0",count:62)+String(format:"%02x",i)
            return .init(id:"page\(i)",kind:"sourceFile",sourceFile:.init(sha256:digest,mimeType:"image/png",
                byteCount:4*1_024*1_024,pixelWidth:4096,pixelHeight:4096,crop:.init(x:0,y:0,width:1,height:1),altText:"Synthetic continuation page \(i)"))
        }
        func leaves(_ count:Int)->[ProfessionalSourceLeaf] {
            stride(from:0,to:count,by:5).map { start in
                let chunk=Array(visuals[start..<min(start+5,count)])
                return .init(sourceQuestionID:"multi\(start)",sourceID:"s",page:1,label:"Cross-page source",status:"pending",
                    visual:chunk[0],primaryCardIDs:[],supplementCardIDs:[],additionalVisuals:Array(chunk.dropFirst()))
            }
        }
        XCTAssertNoThrow(try ProfessionalSourceLeaf.validateAll(leaves(32),bank:bank,teaching:course.teaching))
        XCTAssertThrowsError(try ProfessionalSourceLeaf.validateAll(leaves(33),bank:bank,teaching:course.teaching))
        var oversized=leaves(5)[0];oversized.additionalVisuals.append(visuals[5])
        XCTAssertThrowsError(try ProfessionalSourceLeaf.validateAll([oversized],bank:bank,teaching:course.teaching))
        var duplicate=leaves(1)[0];duplicate.additionalVisuals=[duplicate.visual]
        XCTAssertThrowsError(try ProfessionalSourceLeaf.validateAll([duplicate],bank:bank,teaching:course.teaching))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:GuidanceFixture.encode(leaves(1)[0])) as? [String:Any])
        object.removeValue(forKey:"additionalVisuals")
        XCTAssertTrue(try JSONDecoder().decode(ProfessionalSourceLeaf.self,from:JSONSerialization.data(withJSONObject:object)).additionalVisuals.isEmpty)
    }
    func testLegacyCoachingEventsKeepMissingHelpFieldsAndRoundTrip() throws {
        let (bank,_,_)=try fixture()
        let legacy=ConceptCoachingEvent(id:UUID(),sequence:1,kind:"story",conceptID:"c0",questionID:"c0q0",presentationID:UUID(),
            attemptID:nil,reason:nil,automatic:false,beforeAnswer:true,teachingSHA256:hash,recordedAt:Date(timeIntervalSince1970:1_800_000_000))
        let bytes=try GuidanceFixture.encode(legacy)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        for key in ["linkedPrimaryCardIDs","linkedSupplementCardIDs","linkedGuideConceptIDs"] { XCTAssertNil(object[key]) }
        let decoded=try JSONDecoder().decode(ConceptCoachingEvent.self,from:bytes)
        XCTAssertEqual(decoded,legacy);XCTAssertEqual(try GuidanceFixture.encode(decoded),bytes)
        let record=ConceptCoachingRecord(bankSHA256:hash,nextSequence:2,events:[decoded])
        XCTAssertNoThrow(try record.validate(bank:bank,hash:hash))
    }
    func testRasterRejectsUnknownFieldsBadHashCropFormatAndDimensions() throws {
        let bytes=Data([137,80,78,71,13,10,26,10])
        let asset=ProfessionalRasterAsset(mimeType:"image/png",bytes:bytes,sha256:StudySHA256.hex(bytes),pixelWidth:1,pixelHeight:1,
            crop:.init(x:0,y:0,width:1,height:1),altText:"Synthetic incomplete image")
        XCTAssertThrowsError(try asset.validate()) // Header alone is not a decodable image.
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:GuidanceFixture.encode(asset)) as? [String:Any])
        object["url"]="https://example.invalid/a.png"
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalRasterAsset.self,from:JSONSerialization.data(withJSONObject:object)))
        XCTAssertThrowsError(try ProfessionalNormalizedCrop(x:0.9,y:0,width:0.2,height:1).validate())
        XCTAssertThrowsError(try ProfessionalNormalizedCrop(x:0,y:0,width:.infinity,height:1).validate())
        let oversize=ProfessionalRasterAsset(mimeType:"image/png",bytes:bytes,sha256:StudySHA256.hex(bytes),pixelWidth:8192,pixelHeight:8192,crop:asset.crop,altText:"Oversize")
        XCTAssertThrowsError(try oversize.validate())
    }
    #if canImport(ImageIO)
    func testSourceFileOpenValidatesActualBytesPixelsSymlinksAndMissingAssets() throws {
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        let pixels=Data(repeating:255,count:64),provider=try XCTUnwrap(CGDataProvider(data:pixels as CFData))
        let image=try XCTUnwrap(CGImage(width:4,height:4,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes=data as Data,digest=StudySHA256.hex(bytes)
        let asset=ProfessionalSourceFileAsset(sha256:digest,mimeType:"image/png",byteCount:bytes.count,pixelWidth:4,pixelHeight:4,
            crop:.init(x:0,y:0,width:0.5,height:1),altText:"Synthetic native PNG")
        let assets=root.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true)
        XCTAssertNoThrow(try asset.validateMetadata())
        XCTAssertThrowsError(try asset.croppedCGImage(assetRoot:assets))
        XCTAssertFalse(FileManager.default.fileExists(atPath:assets.path)) // Reads never create an asset directory.
        try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
        let file=assets.appendingPathComponent(digest+".png")
        try bytes.write(to:file)
        XCTAssertEqual(try asset.croppedCGImage(assetRoot:assets).width,2)
        let (bank,t,c)=try fixture();let course=try v5(bank,t,c)
        let second=ProfessionalSourceFileAsset(sha256:hash,mimeType:"image/png",byteCount:bytes.count,pixelWidth:4,pixelHeight:4,
            crop:asset.crop,altText:"Synthetic missing continuation page")
        let leaf=ProfessionalSourceLeaf(sourceQuestionID:"cross-page",sourceID:"s",page:1,label:"Two-page synthetic source",status:"pending",
            visual:.init(id:"first",kind:"sourceFile",sourceFile:asset),primaryCardIDs:[],supplementCardIDs:[],
            additionalVisuals:[.init(id:"second",kind:"sourceFile",sourceFile:second)])
        XCTAssertNoThrow(try ProfessionalSourceLeaf.validateAll([leaf],bank:bank,teaching:course.teaching))
        XCTAssertEqual(leaf.allVisuals.count,2)
        XCTAssertEqual(try XCTUnwrap(leaf.allVisuals[0].sourceFile).croppedCGImage(assetRoot:assets).width,2)
        XCTAssertThrowsError(try XCTUnwrap(leaf.allVisuals[1].sourceFile).croppedCGImage(assetRoot:assets))
        XCTAssertNoThrow(try ProfessionalSourceLeaf.validateAll([leaf],bank:bank,teaching:course.teaching))
        XCTAssertNil(leaf.bankQuestionID);XCTAssertEqual(try Data(contentsOf:file),bytes)
        let wrongPixels=ProfessionalSourceFileAsset(sha256:digest,mimeType:"image/png",byteCount:bytes.count,pixelWidth:3,pixelHeight:4,
            crop:asset.crop,altText:asset.altText)
        XCTAssertThrowsError(try wrongPixels.croppedCGImage(assetRoot:assets))
        var corrupt=bytes;corrupt[corrupt.count-1] ^= 1;try corrupt.write(to:file)
        XCTAssertThrowsError(try asset.croppedCGImage(assetRoot:assets))
        let outside=root.appendingPathComponent("outside.png");try bytes.write(to:outside)
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        XCTAssertThrowsError(try asset.croppedCGImage(assetRoot:assets))
        XCTAssertEqual(try Data(contentsOf:outside),bytes)
    }
    func testSyntheticPNGActualDecodeHashPixelAndCropContract() throws {
        let pixels=Data(repeating:255,count:4*4*4)
        let provider=try XCTUnwrap(CGDataProvider(data:pixels as CFData))
        let image=try XCTUnwrap(CGImage(width:4,height:4,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let data=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes=data as Data
        let asset=ProfessionalRasterAsset(mimeType:"image/png",bytes:bytes,sha256:StudySHA256.hex(bytes),pixelWidth:4,pixelHeight:4,crop:.init(x:0,y:0,width:0.5,height:1),altText:"Synthetic white square")
        XCTAssertNoThrow(try asset.validate())
        XCTAssertEqual(try asset.croppedCGImage().width,2)
        let mismatch=ProfessionalRasterAsset(mimeType:asset.mimeType,bytes:bytes,sha256:asset.sha256,pixelWidth:3,pixelHeight:4,crop:asset.crop,altText:asset.altText)
        XCTAssertThrowsError(try mismatch.validate())
    }
    #endif
    #if os(macOS)
    @MainActor
    func testStoreStaleTokenAndWriteFailureDoNotPublishSourcePresentation() throws {
        let (bank,t,c)=try fixture();let v=try v5(bank,t,c)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        var reject=false
        let store=ConceptStore(baseDirectory:root,writer:{ data,url in
            if reject && url.lastPathComponent=="current.json" { throw ExamError.invalid("Injected write failure") }
            try data.write(to:url,options:.atomic)
        })
        let input=root.appendingPathComponent("synthetic.course");try GuidanceFixture.encode(v).write(to:input)
        store.importContent(input);XCTAssertNil(store.error)
        store.startQuestion("c0q0",expectedCurrentToken:UUID())
        XCTAssertNil(store.engine?.shown)
        reject=true;store.startQuestion("c0q0",expectedCurrentToken:nil)
        XCTAssertNil(store.engine?.shown)
        XCTAssertTrue(store.blocked)
        let restarted=ConceptStore(baseDirectory:root)
        XCTAssertNil(restarted.engine?.shown)
        XCTAssertTrue(restarted.engine?.record.attempts.isEmpty ?? false)
    }
    @MainActor
    func testLinkedCardHelpPersistsExactExposureWithoutQuestionOrRecallGradeWrites() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c,withLinks:true)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        let recall=RecallStore(subject:.computer,bank:bank,teaching:t,baseDirectory:root)
        recall.act("start",newLimit:1)
        let recallToken=try XCTUnwrap(recall.engine?.record.state.shown?.id)
        recall.act("reveal",token:recallToken);recall.act("grade",token:recallToken,remembered:true)
        let deck=try RecallDeck.make(subject:.computer,bank:bank,teaching:t)
        let recallURL=root.appendingPathComponent("RecallCards/computer/"+(try deck.hash)+"/recall.json")
        let recallBefore=try Data(contentsOf:recallURL)
        var writes:[String]=[]
        let store=ConceptStore(baseDirectory:root,writer:{ data,url in writes.append(url.lastPathComponent);try data.write(to:url,options:.atomic) })
        let input=root.appendingPathComponent("synthetic.course");try GuidanceFixture.encode(valid).write(to:input)
        store.importContent(input);XCTAssertNil(store.error)
        store.startQuestion("c0q0",expectedCurrentToken:nil)
        let token=try XCTUnwrap(store.engine?.shown?.id),bankHash=try XCTUnwrap(store.engine?.record.bankSHA256)
        let base=root.appendingPathComponent(ConceptSubject.computer.directoryName).appendingPathComponent(bankHash)
        let stateURL=base.appendingPathComponent("current.json"),stateBefore=try Data(contentsOf:stateURL)
        XCTAssertFalse(store.currentQuestionUsedCardHelp)
        let count=writes.count
        XCTAssertFalse(store.openLinkedCardHelp(token:UUID()))
        XCTAssertEqual(writes.count,count);XCTAssertTrue(store.coachingEvents.isEmpty)
        XCTAssertTrue(store.openLinkedCardHelp(token:token))
        XCTAssertTrue(store.currentQuestionUsedCardHelp)
        let event=try XCTUnwrap(store.coachingEvents.last)
        XCTAssertEqual(event.kind,"linked-card-help");XCTAssertTrue(event.beforeAnswer)
        XCTAssertEqual(event.presentationID,token);XCTAssertEqual(event.questionID,"c0q0")
        XCTAssertEqual(event.linkedPrimaryCardIDs,["c0:card"])
        XCTAssertEqual(event.linkedSupplementCardIDs,[]);XCTAssertEqual(event.linkedGuideConceptIDs,[])
        XCTAssertEqual(event.teachingSHA256,StudySHA256.hex(try GuidanceFixture.encode(valid.teaching)))
        XCTAssertNil(event.attemptID);XCTAssertNil(event.automatic);XCTAssertNil(event.reason)
        XCTAssertEqual(try Data(contentsOf:stateURL),stateBefore)
        XCTAssertEqual(try Data(contentsOf:recallURL),recallBefore)
        XCTAssertEqual(Array(writes.dropFirst(count)),["coaching-created.json","coaching-current.json"])
        let duplicateCount=writes.count
        XCTAssertTrue(store.openLinkedCardHelp(token:token));XCTAssertEqual(writes.count,duplicateCount)
        let restarted=ConceptStore(baseDirectory:root)
        XCTAssertFalse(restarted.blocked);XCTAssertTrue(restarted.currentQuestionUsedCardHelp)
        XCTAssertEqual(restarted.coachingEvents,[event])
        restarted.choose("A",token:token)
        XCTAssertEqual(restarted.engine?.record.attempts.count,1)
        XCTAssertTrue(restarted.currentQuestionUsedCardHelp)
        XCTAssertFalse(restarted.openLinkedCardHelp(token:token)) // Answered card is direct read-only lookup.
        XCTAssertEqual(try Data(contentsOf:recallURL),recallBefore)
    }
    @MainActor
    func testLinkedCardHelpWriteFailureIsNotSuccessfulExposure() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c,withLinks:true)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        var reject=false
        let store=ConceptStore(baseDirectory:root,writer:{ data,url in
            if reject && url.lastPathComponent=="coaching-current.json" { throw ExamError.invalid("Injected help write failure") }
            try data.write(to:url,options:.atomic)
        })
        let input=root.appendingPathComponent("synthetic.course");try GuidanceFixture.encode(valid).write(to:input)
        store.importContent(input);store.startQuestion("c0q0",expectedCurrentToken:nil)
        let token=try XCTUnwrap(store.engine?.shown?.id),before=try GuidanceFixture.encode(store.engine?.record)
        reject=true
        XCTAssertFalse(store.openLinkedCardHelp(token:token))
        XCTAssertTrue(store.blocked);XCTAssertFalse(store.currentQuestionUsedCardHelp)
        XCTAssertTrue(store.coachingEvents.isEmpty)
        XCTAssertEqual(try GuidanceFixture.encode(store.engine?.record),before)
        let restarted=ConceptStore(baseDirectory:root)
        XCTAssertTrue(restarted.blocked) // Existing created marker with missing current log never resets history.
    }
    @MainActor
    func testMissingActivePointerWithExistingCourseEvidenceRefusesFreshV5WithoutWrites() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        let old=ConceptStore(baseDirectory:root)
        let input=root.appendingPathComponent("synthetic.course")
        try GuidanceFixture.encode(c).write(to:input);old.importContent(input)
        old.start(newLimit:1)
        let token=try XCTUnwrap(old.engine?.shown?.id);old.choose("A",token:token)
        XCTAssertEqual(old.engine?.record.attempts.count,1)
        let hash=try XCTUnwrap(old.engine?.record.bankSHA256)
        let subject=root.appendingPathComponent(ConceptSubject.computer.directoryName),base=subject.appendingPathComponent(hash)
        let current=base.appendingPathComponent("current.json"),content=base.appendingPathComponent("content.xklconcepts")
        let currentBefore=try Data(contentsOf:current),contentBefore=try Data(contentsOf:content)
        try FileManager.default.removeItem(at:subject.appendingPathComponent("active.json"))
        var writes=0
        let reopened=ConceptStore(baseDirectory:root,writer:{ data,url in writes+=1;try data.write(to:url,options:.atomic) })
        XCTAssertNil(reopened.engine);XCTAssertFalse(reopened.blocked)
        let count=writes
        try GuidanceFixture.encode(valid).write(to:input);reopened.importContent(input)
        XCTAssertEqual(writes,count);XCTAssertNil(reopened.engine);XCTAssertNotNil(reopened.error)
        XCTAssertEqual(try Data(contentsOf:current),currentBefore)
        XCTAssertEqual(try Data(contentsOf:content),contentBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath:subject.appendingPathComponent("active.json").path))
    }
    @MainActor
    func testNoLoadedCourseStillChecksExistingPrimaryRecallEvidenceBeforeV5Writes() throws {
        let (bank,t,c)=try fixture()
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        let recall=RecallStore(subject:.computer,bank:bank,teaching:t,baseDirectory:root)
        XCTAssertFalse(recall.blocked)
        recall.act("start",newLimit:1)
        let token=try XCTUnwrap(recall.engine?.record.state.shown?.id)
        recall.act("reveal",token:token);recall.act("grade",token:token,remembered:true)
        let oldDeck=try RecallDeck.make(subject:.computer,bank:bank,teaching:t)
        let archive=root.appendingPathComponent("RecallCards/computer/"+(try oldDeck.hash)+"/recall.json")
        let before=try Data(contentsOf:archive)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:GuidanceFixture.encode(t)) as? [String:Any])
        var lessons=object["lessons"] as! [[String:Any]],cards=lessons[0]["recallCards"] as! [[String:Any]]
        cards[0]["answer"]="A changed synthetic answer";lessons[0]["recallCards"]=cards;object["lessons"]=lessons
        let changed=try JSONDecoder().decode(ConceptTeaching.self,from:JSONSerialization.data(withJSONObject:object))
        let incoming=try v5(bank,changed,c)
        XCTAssertNoThrow(try ConceptCourse.load(GuidanceFixture.encode(incoming),subject:.computer))
        var writes=0
        let store=ConceptStore(baseDirectory:root,writer:{ data,url in writes+=1;try data.write(to:url,options:.atomic) })
        XCTAssertNil(store.engine)
        let input=root.appendingPathComponent("synthetic.course");try GuidanceFixture.encode(incoming).write(to:input)
        let count=writes;store.importContent(input)
        XCTAssertNotNil(store.error);XCTAssertNil(store.engine);XCTAssertEqual(writes,count)
        XCTAssertEqual(try Data(contentsOf:archive),before)
    }
    @MainActor
    func testRequiredMarkerBlocksMissingPointerMissingTeachingAndMalformedMarker() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        let store=ConceptStore(baseDirectory:root)
        let input=root.appendingPathComponent("synthetic.course")
        try GuidanceFixture.encode(valid).write(to:input);store.importContent(input);XCTAssertNil(store.error)
        let bankHash=try XCTUnwrap(store.engine?.record.bankSHA256)
        let base=root.appendingPathComponent(ConceptSubject.computer.directoryName).appendingPathComponent(bankHash)
        let state=base.appendingPathComponent("current.json"),before=try Data(contentsOf:state)
        let marker=base.appendingPathComponent("professional-v5-required.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        let pointer=base.appendingPathComponent("teaching-active.json"),pointerBytes=try Data(contentsOf:pointer)
        try FileManager.default.removeItem(at:pointer)
        let missingPointer=ConceptStore(baseDirectory:root)
        XCTAssertTrue(missingPointer.blocked);XCTAssertNil(missingPointer.engine)
        XCTAssertEqual(try Data(contentsOf:state),before)
        try pointerBytes.write(to:pointer,options:.atomic)
        let teachingHash=try JSONDecoder().decode(String.self,from:pointerBytes)
        let teachingURL=base.appendingPathComponent("teaching/"+teachingHash+".json")
        let teachingBytes=try Data(contentsOf:teachingURL)
        try FileManager.default.removeItem(at:teachingURL)
        let missingTeaching=ConceptStore(baseDirectory:root)
        XCTAssertTrue(missingTeaching.blocked);XCTAssertNil(missingTeaching.engine)
        XCTAssertEqual(try Data(contentsOf:state),before)
        try teachingBytes.write(to:teachingURL,options:.atomic)
        try Data("{}".utf8).write(to:marker,options:.atomic)
        XCTAssertTrue(ConceptStore(baseDirectory:root).blocked)
        XCTAssertEqual(try Data(contentsOf:state),before)
    }
    @MainActor
    func testValidLegacyV5BackfillsOnlyRequiredMarkerWithoutResettingProgress() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        let store=ConceptStore(baseDirectory:root)
        let input=root.appendingPathComponent("synthetic.course")
        try GuidanceFixture.encode(valid).write(to:input);store.importContent(input)
        store.startQuestion("c0q0",expectedCurrentToken:nil)
        let token=try XCTUnwrap(store.engine?.shown?.id);store.choose("A",token:token)
        let bankHash=try XCTUnwrap(store.engine?.record.bankSHA256)
        let base=root.appendingPathComponent(ConceptSubject.computer.directoryName).appendingPathComponent(bankHash)
        let state=base.appendingPathComponent("current.json"),before=try Data(contentsOf:state)
        let marker=base.appendingPathComponent("professional-v5-required.json")
        try FileManager.default.removeItem(at:marker)
        let failed=ConceptStore(baseDirectory:root,writer:{ data,url in
            if url.lastPathComponent=="professional-v5-required.json" { throw ExamError.invalid("Injected backfill failure") }
            try data.write(to:url,options:.atomic)
        })
        XCTAssertTrue(failed.blocked);XCTAssertNil(failed.engine)
        XCTAssertEqual(try Data(contentsOf:state),before)
        var writes:[String]=[]
        let loaded=ConceptStore(baseDirectory:root,writer:{ data,url in writes.append(url.lastPathComponent);try data.write(to:url,options:.atomic) })
        XCTAssertFalse(loaded.blocked)
        XCTAssertEqual(writes,["professional-v5-required.json"])
        XCTAssertEqual(try Data(contentsOf:state),before)
        XCTAssertEqual(loaded.engine?.record.attempts.count,1)
        XCTAssertEqual(loaded.engine?.record.review?.presentation.id,token)
    }
    @MainActor
    func testMarkerAndActivePointerFailuresPreserveOriginalDirectoryAndPublishedCourse() throws {
        for failingName in ["professional-v5-required.json","active.json"] {
            let (bank,t,c)=try fixture(),(appendedBank,appendedTeaching,appendedCourse)=try fixture(append:true)
            let oldDeck=try RecallDeck.make(subject:.computer,bank:bank,teaching:t)
            let next=try v5(appendedBank,appendedTeaching,appendedCourse,deck:oldDeck)
            let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
            var reject=false
            let store=ConceptStore(baseDirectory:root,writer:{ data,url in
                if reject && url.lastPathComponent==failingName { throw ExamError.invalid("Injected marker/pointer failure") }
                try data.write(to:url,options:.atomic)
            })
            let input=root.appendingPathComponent("synthetic.course")
            try GuidanceFixture.encode(c).write(to:input);store.importContent(input);XCTAssertNil(store.error)
            let oldHash=try XCTUnwrap(store.engine?.record.bankSHA256),oldTeaching=store.teaching
            let subjectFolder=root.appendingPathComponent(ConceptSubject.computer.directoryName)
            let oldBase=subjectFolder.appendingPathComponent(oldHash)
            func snapshot() throws -> [String:Data] {
                let iterator=try XCTUnwrap(FileManager.default.enumerator(at:oldBase,includingPropertiesForKeys:[.isRegularFileKey]))
                var result:[String:Data]=[:]
                for case let file as URL in iterator {
                    if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                        result[String(file.path.dropFirst(oldBase.path.count))]=try Data(contentsOf:file)
                    }
                }
                return result
            }
            let before=try snapshot(),activeBefore=try Data(contentsOf:subjectFolder.appendingPathComponent("active.json"))
            reject=true;try GuidanceFixture.encode(next).write(to:input);store.importContent(input)
            XCTAssertTrue(store.blocked);XCTAssertNotNil(store.error)
            XCTAssertEqual(store.engine?.record.bankSHA256,oldHash);XCTAssertEqual(store.teaching,oldTeaching)
            XCTAssertEqual(try snapshot(),before)
            XCTAssertEqual(try Data(contentsOf:subjectFolder.appendingPathComponent("active.json")),activeBefore)
            let restarted=ConceptStore(baseDirectory:root)
            XCTAssertFalse(restarted.blocked);XCTAssertEqual(restarted.engine?.record.bankSHA256,oldHash)
        }
    }
    @MainActor
    func testV5CannotDowngradeToLegacyTeachingOrBareBankBeforeWrite() throws {
        let (bank,t,c)=try fixture();let valid=try v5(bank,t,c)
        let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        var writes=0
        let store=ConceptStore(baseDirectory:root,writer:{ data,url in writes+=1;try data.write(to:url,options:.atomic) })
        let input=root.appendingPathComponent("synthetic.course")
        try GuidanceFixture.encode(valid).write(to:input);store.importContent(input);XCTAssertNil(store.error)
        let retained=store.teaching
        for bytes in [try GuidanceFixture.encode(c),c.bankContent] {
            let before=writes
            try bytes.write(to:input);store.importContent(input)
            XCTAssertNotNil(store.error);XCTAssertEqual(writes,before)
            XCTAssertEqual(store.teaching,retained);XCTAssertFalse(store.blocked)
        }
    }
    @MainActor
    func testV5FrozenDeckMismatchRefusedBeforeAnyWrite() throws {
        let (bank,t,c)=try fixture();let root=try GuidanceFixture.root();defer{try? FileManager.default.removeItem(at:root)}
        var writes=0
        let store=ConceptStore(baseDirectory:root,writer:{ data,url in writes+=1;try data.write(to:url,options:.atomic) })
        let input=root.appendingPathComponent("synthetic.course");try GuidanceFixture.encode(c).write(to:input)
        store.importContent(input);XCTAssertNil(store.error)
        let oldHash=store.engine?.record.bankSHA256
        let original=try RecallDeck.make(subject:.computer,bank:bank,teaching:t)
        let reordered=RecallDeck(subject:.computer,bankID:bank.id,cards:Array(original.cards.reversed()))
        let bad=try v5(bank,t,c,deck:reordered)
        let before=writes
        try GuidanceFixture.encode(bad).write(to:input);store.importContent(input)
        XCTAssertNotNil(store.error);XCTAssertEqual(writes,before)
        XCTAssertEqual(store.engine?.record.bankSHA256,oldHash)
        XCTAssertFalse(store.blocked)
    }
    #endif
}
