import Foundation
import XCTest
@testable import StudyCore

final class StudyArchiveTests:XCTestCase {
    func testOmittedMeaningsAreOptionalAndNotSeparateCards() throws {
        let absent=MeaningOmission(sequence:10,word:5,deckVersion:"d",coreCount:3,indices:nil)
        XCTAssertNil(absent.omittedIndices);XCTAssertNil(absent.reportedCount)
        let reported=MeaningOmission(sequence:11,word:5,deckVersion:"d",coreCount:3,indices:[2,0,2])
        XCTAssertEqual(reported.omittedIDs,["5:0","5:2"]);XCTAssertEqual(reported.reportedCount,2)
        var notes=StudyAnnotations();notes.omissions=[absent,reported]
        try notes.validate(logCount:11)
        XCTAssertEqual(try JSONDecoder().decode(StudyAnnotations.self,from:JSONEncoder().encode(notes)),notes)
        notes.omissions[1].omittedIndices=[3]
        XCTAssertThrowsError(try notes.validate(logCount:11))
    }
    func testMissingFeedbackIsNotZeroAndScoresAreIndependent() throws {
        let task=StudyFeedbackPrompt(taskID:"t",sequence:100,day:20745,lesson:1)
        var notes=StudyAnnotations();notes.feedback=[StudyTaskFeedback(task:task,annoyance:0,fatigue:nil)]
        try notes.validate(logCount:100)
        XCTAssertEqual(notes.feedback[0].annoyance,0);XCTAssertNil(notes.feedback[0].fatigue)
        notes.feedback[0].fatigue=11;XCTAssertThrowsError(try notes.validate(logCount:100))
    }
    func testVolumeIndexAndGlobalAnalysisContinueBeyondOneVolume() throws {
        let stream=String(repeating:"ab",count:16)
        var index=StudyArchiveIndex(streamID:stream)
        index.volumes=[StudyVolumeReference(number:1,sha256:String(repeating:"a",count:64),first:1,last:21_740)]
        try index.validate(streamID:stream,activeBase:21_740,logCount:22_100)
        var settings=StudyAnalysisSettings(streamID:stream,nextSequence:10)
        settings.archivedSavedRepetitions=400
        try settings.validate(streamID:stream,logCount:22_100)
        XCTAssertEqual(settings.savedRepetitions,400)
        index.volumes[0].firstSequence=2
        XCTAssertThrowsError(try index.validate(streamID:stream,activeBase:21_740,logCount:22_100))
    }
    func testStreamingZIPInteroperatesWithPythonAndPreservesInputFiles() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let input=dir.appendingPathComponent("input.json"),zip=dir.appendingPathComponent("archive.zip")
        let bytes=Data((0..<200_000).map { UInt8($0%251) });try bytes.write(to:input)
        try StudyZIP.write([.init(name:"manifest.json",data:Data("{}".utf8)),.init(name:"volumes/旧卷.json",file:input)],to:zip)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env")
        process.arguments=["python3","-c","import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; assert z.read('manifest.json')==b'{}'; assert z.read('volumes/旧卷.json')==open(sys.argv[2],'rb').read()",zip.path,input.path]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertEqual(try Data(contentsOf:input),bytes)
        XCTAssertThrowsError(try StudyZIP.write([.init(name:"../bad",data:Data())],to:dir.appendingPathComponent("bad.zip")))
    }
}
