import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

final class PersonalContentTests: XCTestCase {
    func content() throws -> PersonalContent {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources")
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("deck.json").path) else {
            throw XCTSkip("Private content is local-only")
        }
        return PersonalContent(format: "xkl-ios-content-v1", deckBytes: try Data(contentsOf: resources.appendingPathComponent("deck.json")),
                               personalState: try Data(contentsOf: resources.appendingPathComponent("personal-state.bin")),
                               manifest: try JSONDecoder().decode(ContentManifest.self, from: Data(contentsOf: resources.appendingPathComponent("resource-manifest.json"))))
    }

    func testRejectUnknownOrTruncatedContent() throws {
        XCTAssertThrowsError(try PersonalContent.load(Data("{}".utf8)))
        XCTAssertThrowsError(try PersonalContent.load(Data("{\"format\":\"unknown\"}".utf8)))
    }

    func testContentRevisionBoundariesAndUnknownVersions() throws {
        let revisions=try ContentRevision.reconciled(nil,incoming:PersonalContent.revisedDeckHash,
                                                     logCount:266,existingArchive:true)
        XCTAssertEqual(revisions.map(\.firstSequence),[1,267])
        XCTAssertEqual(revisions.map(\.deckSHA256),[PersonalContent.deckHash,PersonalContent.revisedDeckHash])
        XCTAssertEqual(try ContentRevision.reconciled(revisions,incoming:PersonalContent.revisedDeckHash,
                                                      logCount:280,existingArchive:true),revisions)
        XCTAssertThrowsError(try ContentRevision.reconciled(revisions,incoming:PersonalContent.revisedDeckHash,
                                                            logCount:200,existingArchive:true))
        XCTAssertThrowsError(try ContentRevision.reconciled(nil,incoming:String(repeating:"0",count:64),
                                                            logCount:266,existingArchive:true))
        let blank=try ContentRevision.reconciled(nil,incoming:PersonalContent.revisedDeckHash,
                                                 logCount:0,existingArchive:false)
        XCTAssertEqual(blank.count,1)
        XCTAssertEqual(blank.first?.deckSHA256,PersonalContent.revisedDeckHash)
        XCTAssertEqual(ContentRevision.comparisonFirstSequence(base:30,revisions:revisions),267)
        XCTAssertEqual(ContentRevision.comparisonFirstSequence(base:30,revisions:blank),30)
    }

    @MainActor func testProjectTranslationsKeepFormsAndOriginalProgress() async throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url=root.appendingPathComponent("PrivateFixtures/translated-content.xklcontent")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Private English-source translation package") }
        let (updated,deck)=try PersonalContent.load(Data(contentsOf:url))
        XCTAssertEqual(updated.manifest.deckSHA256,PersonalContent.translatedDeckHash)
        XCTAssertEqual(deck.words.filter{$0.meaningPending==true}.count,4628)
        XCTAssertEqual(deck.words.filter{$0.sourceLabel=="韦氏英文 · 项目译义"}.count,275)
        XCTAssertTrue(deck.words.first{$0.word=="sat"}?.core.first?.meaning.contains("坐") == true)
        XCTAssertTrue(deck.words.first{$0.word=="sat"}?.expanded.contains("卫星") == true)
        XCTAssertTrue(deck.words.first{$0.word=="don't"}?.core.first?.meaning.contains("do not") == true)
        XCTAssertTrue(deck.words.first{$0.word=="divestiture"}?.supportingEnglish?.contains("government order") == true)
        let original=try content()
        XCTAssertEqual(updated.personalState,original.personalState)
        XCTAssertEqual(deck.words.map(\.word),try WordDeck.load(original.deckBytes).words.map(\.word))
        let originalEngine=try PocketEngine(seed:original.personalState,stream:UUID())
        try originalEngine.start(day:20746);try originalEngine.reveal();try originalEngine.answer(3)
        let snapshot=try originalEngine.snapshot(),log=try originalEngine.rawLog()
        _ = try PersonalContent.load(Data(contentsOf:url))
        XCTAssertEqual(try originalEngine.snapshot(),snapshot)
        XCTAssertEqual(try originalEngine.rawLog(),log)
    }
    @MainActor func testRevisedPrivateContentPreservesLatestPhoneSnapshot() async throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contentURL=root.appendingPathComponent("PrivateFixtures/revised-content.xklcontent")
        let backup=root.appendingPathComponent("PrivateFixtures/phone-study-state.json")
        guard FileManager.default.fileExists(atPath:contentURL.path),
              FileManager.default.fileExists(atPath:backup.path) else { throw XCTSkip("Private update and backup are local-only") }
        let (updated,deck)=try PersonalContent.load(Data(contentsOf:contentURL))
        XCTAssertEqual(updated.manifest.deckSHA256,PersonalContent.revisedDeckHash)
        XCTAssertEqual(deck.words.filter{$0.meaningPending==true}.count,4903)
        XCTAssertEqual(deck.words.first{$0.word=="lethargic"}?.sourceLabel,"柯林斯释义")
        XCTAssertEqual(deck.words.first{$0.word=="abstain"}?.core.count,2)
        XCTAssertEqual(deck.words.first{$0.word=="benevolent"}?.core.count,1)
        XCTAssertEqual(deck.words.first{$0.word=="bolster"}?.core.count,1)
        XCTAssertTrue(deck.words.first{$0.word=="bolster"}?.expanded.contains("枕") == true)
        let old=try content()
        let oldDeck=try WordDeck.load(old.deckBytes)
        XCTAssertEqual(deck.words.map(\.word),oldDeck.words.map(\.word))
        XCTAssertEqual(updated.personalState,old.personalState)
        let raw=try Data(contentsOf:backup)
        var archive=try JSONDecoder().decode(AppDiskRecord.self,from:raw)
        let originalState=archive.syncStateJSON
        let state=try JSONDecoder().decode(SyncState.self,from:originalState)
        let engine=try PocketEngine(snapshot:state.snapshot)
        let log=try engine.rawLog()
        archive.contentRevisions=try ContentRevision.reconciled(nil,incoming:updated.manifest.deckSHA256,
                                                              logCount:engine.info.log_records,existingArchive:true)
        let roundtrip=try JSONDecoder().decode(AppDiskRecord.self,from:JSONEncoder().encode(archive))
        XCTAssertEqual(roundtrip.syncStateJSON,originalState)
        XCTAssertEqual(try engine.snapshot(),state.snapshot)
        XCTAssertEqual(try engine.rawLog(),log)
        XCTAssertEqual(try engine.info.log_records,266)
        XCTAssertEqual(try Data(contentsOf:backup),raw)
    }

    func testContentHandshakeRejectsDifferentMeaningsWithSameWordIDs() throws {
        var a=DeviceHello(protocolVersion:1,deviceID:"a",profileID:"p",deckVersion:"d",algorithm:3,schema:7)
        var b=DeviceHello(protocolVersion:1,deviceID:"b",profileID:"p",deckVersion:"d",algorithm:3,schema:7)
        a.contentSHA256=PersonalContent.deckHash;b.contentSHA256=PersonalContent.revisedDeckHash
        XCTAssertFalse(a.compatible(with:b))
        b.contentSHA256=a.contentSHA256
        XCTAssertTrue(a.compatible(with:b))
    }

    @MainActor func testActualAppModelImportsFullDeckAndPreservesProgress() async throws {
        let c = try content()
        let (decoded, deck) = try PersonalContent.load(JSONEncoder().encode(c))
        XCTAssertEqual(deck.words.count, 25644)
        XCTAssertEqual(deck.words[0].word, "abandon")
        XCTAssertEqual(deck.words.reduce(0) { $0 + $1.core.count }, 43668)
        XCTAssertEqual(sha256(decoded.personalState), PersonalContent.baselineHash)
        let engine = try PocketEngine(seed: decoded.personalState, stream: UUID())
        let before = try engine.snapshot()
        let roundtrip = try PocketEngine(snapshot: before)
        XCTAssertEqual(try roundtrip.snapshot(), before)
        try engine.start(day: 20745)
        XCTAssertThrowsError(try engine.answer(0))
        try engine.reveal()
        try engine.answer(3)
        XCTAssertNotEqual(try engine.snapshot(), before)
        XCTAssertGreaterThan(try engine.rawLog().count, 4096)
    }

    func testSingleByteCorruptionRejectedBeforeImport() throws {
        let c = try content()
        var bytes = c.deckBytes
        bytes[bytes.count / 2] ^= 1
        let bad = PersonalContent(format: c.format, deckBytes: bytes, personalState: c.personalState, manifest: c.manifest)
        XCTAssertThrowsError(try PersonalContent.load(JSONEncoder().encode(bad)))
    }

    @MainActor func testLegacyPhoneArchiveMigrationPreservesAllSnapshotAndLogBytes() async throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url=root.appendingPathComponent("PrivateFixtures/earlier-phone-study-state.json")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Private phone backup is local-only") }
        let original=try Data(contentsOf:url)
        let legacy=try JSONDecoder().decode(AppDiskRecord.self,from:original)
        XCTAssertEqual(legacy.format,1)
        let state=try JSONDecoder().decode(SyncState.self,from:legacy.syncStateJSON)
        let engine=try PocketEngine(snapshot:state.snapshot)
        let log=try engine.rawLog()
        XCTAssertEqual(try engine.info.log_records,27)
        let settings=try legacy.validatedAnalysis(engine:engine)
        XCTAssertEqual(settings.shadowFirstSequence,28)
        XCTAssertTrue(try engine.events(from:28).isEmpty)
        let upgraded=AppDiskRecord(format:2,syncStateJSON:legacy.syncStateJSON,
                                  pairedPeripherals:legacy.pairedPeripherals,provisioningSnapshot:legacy.provisioningSnapshot,
                                  savedAt:Date(),analysis:settings,legacyBackupSHA256:sha256(original))
        let decoded=try JSONDecoder().decode(AppDiskRecord.self,from:JSONEncoder().encode(upgraded))
        XCTAssertEqual(try decoded.validatedAnalysis(engine:engine),settings)
        XCTAssertEqual(decoded.syncStateJSON,legacy.syncStateJSON)
        XCTAssertEqual(try engine.snapshot(),state.snapshot)
        XCTAssertEqual(try engine.rawLog(),log)
        XCTAssertEqual(try Data(contentsOf:url),original)
        let timing=try decoded.validatedTiming(engine:engine)
        XCTAssertEqual(timing.firstSequence,28)
        XCTAssertTrue(timing.events.isEmpty)
        let v3=AppDiskRecord(format:3,syncStateJSON:decoded.syncStateJSON,pairedPeripherals:decoded.pairedPeripherals,
                            provisioningSnapshot:decoded.provisioningSnapshot,savedAt:Date(),analysis:settings,
                            legacyBackupSHA256:decoded.legacyBackupSHA256,timing:timing,timingBackupSHA256:sha256(original))
        let v3Reload=try JSONDecoder().decode(AppDiskRecord.self,from:JSONEncoder().encode(v3))
        XCTAssertEqual(try v3Reload.validatedTiming(engine:engine),timing)
        XCTAssertEqual(v3Reload.syncStateJSON,legacy.syncStateJSON)
    }

    func testPolicyHandshakeRejectsOldClient() throws {
        let old=DeviceHello(protocolVersion:1,deviceID:"old",profileID:"p",deckVersion:"d",algorithm:3,schema:7)
        var current=DeviceHello(protocolVersion:1,deviceID:"current",profileID:"p",deckVersion:"d",algorithm:3,schema:7)
        current.learningPolicyVersion=1
        XCTAssertFalse(current.compatible(with:old))
        var peer=old;peer.learningPolicyVersion=1
        XCTAssertTrue(current.compatible(with:peer))
    }

    @MainActor func testClosedVolumeReloadPreservesHistoryAndRejectsCorruption() async throws {
        let c=try content(),engine=try PocketEngine(seed:c.personalState,stream:UUID())
        try engine.start(day:20745);try engine.reveal();try engine.answer(3)
        let original=try engine.snapshot(),events=try engine.events(from:1),stream=try engine.streamID
        let state=try SyncState.initial(profileID:PersonalContent.baselineHash,deviceID:"test",deckVersion:WordDeck.expectedVersion,snapshot:original,active:true)
        let settings=StudyAnalysisSettings(streamID:stream,nextSequence:1)
        let timing=StudyTimingJournal(streamID:stream,firstSequence:1)
        var index=StudyArchiveIndex(streamID:stream)
        let record=AppDiskRecord(format:4,syncStateJSON:try JSONEncoder().encode(state),pairedPeripherals:[:],
            provisioningSnapshot:original,savedAt:Date(),analysis:settings,timing:timing,history:index,annotations:StudyAnnotations())
        let bytes=try JSONEncoder().encode(record)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let ref=try StudyHistoryFiles.seal(bytes,number:1,first:1,last:try engine.info.log_records,directory:dir,
                                         write:{try $0.write(to:$1,options:.atomic)})
        index.volumes.append(ref)
        let rotated=try engine.rotated(policyFirst:1)
        XCTAssertEqual(try engine.snapshot(),original)
        try index.validate(streamID:stream,activeBase:rotated.logBase,logCount:rotated.info.log_records)
        let loaded=try StudyHistoryFiles.load(index,directory:dir)
        XCTAssertEqual(loaded.events,events)
        try rotated.reveal();try rotated.answer(0)
        let next=try rotated.events(from:rotated.logBase+1)
        XCTAssertEqual(next.first?.sequence,UInt32(events.count+1))
        XCTAssertEqual(Set((loaded.events+next).map(\.sequence)).count,events.count+next.count)
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent(ref.filename)),bytes)
        var corrupt=bytes;corrupt[corrupt.count/2]^=1;try corrupt.write(to:dir.appendingPathComponent(ref.filename))
        XCTAssertThrowsError(try StudyHistoryFiles.load(index,directory:dir))
    }

    @MainActor func testVolumeSealFailureDoesNotOverwriteAndRetryIsIdempotent() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let bytes=Data("original immutable record".utf8)
        XCTAssertThrowsError(try StudyHistoryFiles.seal(bytes,number:1,first:1,last:10,directory:dir,write:{_,_ in throw CocoaError(.fileWriteOutOfSpace)}))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path).count,0)
        XCTAssertThrowsError(try StudyHistoryFiles.seal(bytes,number:1,first:1,last:10,directory:dir,write:{ data,url in
            try data.write(to:url,options:.atomic);throw CocoaError(.fileWriteUnknown)
        }))
        let ref=try StudyHistoryFiles.seal(bytes,number:1,first:1,last:10,directory:dir,write:{_,_ in XCTFail("Already sealed; must not write again")})
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent(ref.filename)),bytes)
    }
}
