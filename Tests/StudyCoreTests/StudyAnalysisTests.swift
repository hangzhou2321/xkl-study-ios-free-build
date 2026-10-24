import Foundation
import XCTest
@testable import StudyCore

final class StudyAnalysisTests: XCTestCase {
    func testFSRSMatchesPinnedPythonReference() throws {
        struct Row: Decodable {
            var day: UInt32; var rating: Int; var stability, difficulty: Double
            var retrievability: Double?; var interval: Int
            var timestampMs: Int64?
        }
        struct Fixture: Decodable { var cases: [[Row]] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fsrs-6.3.2", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for sequence in fixture.cases {
            var memory: FSRS6Shadow.Memory?
            for row in sequence {
                let prediction = try FSRS6Shadow.review(memory, day: row.day, rating: row.rating,timestampMs:row.timestampMs)
                XCTAssertEqual(prediction.memory.stability, row.stability, accuracy: max(1e-11, abs(row.stability)*1e-11))
                XCTAssertEqual(prediction.memory.difficulty, row.difficulty, accuracy: 1e-11)
                XCTAssertEqual(prediction.interval, row.interval)
                if let r = row.retrievability { XCTAssertEqual(try XCTUnwrap(prediction.retrievabilityBefore), r, accuracy: 1e-12) }
                else { XCTAssertNil(prediction.retrievabilityBefore) }
                memory = prediction.memory
            }
        }
    }

    func event(_ seq: UInt32, _ day: UInt32, _ kind: UInt32, word: UInt32 = 1, due: UInt32 = 20800,
               undo: UInt32 = .max) -> StudyEvent {
        StudyEvent(sequence: seq, kind: kind, day: day, word: word,
                   afterCard: due | (2 << 16) | (1 << 20), afterRevision: seq, undoRevision: undo)
    }

    func testShadowStartsAtCutoverAndDoesNotMultiplySameDaySuccesses() throws {
        let events = [event(1,20740,5), event(2,20745,6), event(3,20745,5), event(4,20745,5),
                      event(5,20746,5,due:20999), event(6,20746,5), event(7,20747,10),
                      event(8,20748,7), event(9,20749,5,word:2)]
        let before = try JSONEncoder().encode(events)
        let report = try FSRSShadowReport.evaluate(events: events, firstSequence: 2)
        XCTAssertEqual(report.comparisons.count,4)
        XCTAssertEqual(report.comparisons.map(\.sequence),[2,5,7,9])
        XCTAssertTrue(report.comparisons[0].coldStart)
        XCTAssertNil(report.comparisons[0].predictedRecall)
        XCTAssertEqual(report.comparableCount,2)
        XCTAssertEqual(report.comparisons[2].outcome,"partial")
        XCTAssertEqual(report.comparisons[2].fsrsRating,1) // Incomplete whole-word recall is not Hard.
        XCTAssertEqual(report.comparisons[1].actualDueDay,20800) // Observed final schedule, not FSRS's suggestion.
        XCTAssertEqual(try JSONDecoder().decode([StudyEvent].self,from:before),events)
        let again = try FSRSShadowReport.evaluate(events:events,firstSequence:2)
        XCTAssertEqual(again.comparisons.map(\.stability),report.comparisons.map(\.stability))
        XCTAssertEqual(report.schedulingAuthority,"none: observations only; actual due dates are never changed")
    }

    func testUndoExcludesRetractedGradesBeforeSelectingDailyObservation() throws {
        let events = [event(1,20745,5),event(2,20745,8,undo:1),event(3,20745,6),event(4,20746,5)]
        let report = try FSRSShadowReport.evaluate(events:events,firstSequence:1)
        XCTAssertEqual(report.comparisons.map(\.sequence),[3,4])
        XCTAssertEqual(report.retractedRevisions,[1])
        XCTAssertEqual(report.comparisons[0].fsrsRating,1)
    }

    func testSettingsRoundtripToggleAndCorruptionChecks() throws {
        let stream=String(repeating:"ab",count:16)
        var settings=StudyAnalysisSettings(streamID:stream,nextSequence:28)
        try settings.validate(streamID:stream,logCount:27)
        settings.setEnabled(false,nextSequence:35)
        settings.setEnabled(true,nextSequence:40)
        XCTAssertEqual(settings.shadowFirstSequence,28)
        XCTAssertEqual(settings.conservativeFirstSequence,40)
        try settings.validate(streamID:stream,logCount:39)
        let restored=try JSONDecoder().decode(StudyAnalysisSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(settings,restored)
        XCTAssertThrowsError(try settings.validate(streamID:String(repeating:"cd",count:16),logCount:39))
        XCTAssertThrowsError(try settings.validate(streamID:stream,logCount:25))
        settings.reductions=[ReductionDecision(word:1,day:20745,sequence:39,before:5,after:6,
                                               first:28,recalls:3,gap:7,longGap:1,removed:2)]
        try settings.validate(streamID:stream,logCount:39)
        XCTAssertEqual(settings.savedRepetitions,2)
        settings.reductions.append(settings.reductions[0])
        XCTAssertThrowsError(try settings.validate(streamID:stream,logCount:39))
    }
}
