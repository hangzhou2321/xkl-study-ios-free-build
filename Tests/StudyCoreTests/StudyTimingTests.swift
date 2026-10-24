import Foundation
import XCTest
@testable import StudyCore

final class StudyTimingTests: XCTestCase {
    let stream=String(repeating:"ab",count:16)
    let base: Int64=1_792_368_000_000
    struct Trace {
        var events: [StudyEvent]=[]
        var timing=StudyTimingJournal(streamID:String(repeating:"ab",count:16),firstSequence:1)
        var seq: UInt32 { UInt32(events.count+1) }
        mutating func append(_ e: StudyEvent, time: Int64, active: Double, epoch: UInt32=0) {
            events.append(e)
            timing.events.append(StudyTimedEvent(sequence:e.sequence,point:StudyTimePoint(
                wallMs:time,uptimeMs:Double(time),foregroundMs:active,launchID:"test",
                clockEpoch:epoch,utcOffsetSeconds:0),precision:"synthetic-oracle"))
        }
        @discardableResult mutating func answer(day: UInt32,time: Int64,kind: UInt32,
                                                word: UInt32=1,before: UInt32=0,epoch: UInt32=0) -> UInt32 {
            let presentation=seq
            let active=Double(events.count)*5_000
            append(StudyEvent(sequence:seq,kind:3,day:day,word:word,presentation:presentation),time:time,active:active,epoch:epoch)
            if let forecast=try? DualFSRSReport.makeForecast(events:events,timing:timing,
                    firstSequence:1,presentation:events.last!) { timing.forecasts.append(forecast) }
            append(StudyEvent(sequence:seq,kind:4,day:day,word:word,presentation:presentation),time:time+5_000,active:active+5_000,epoch:epoch)
            let grade=seq
            append(StudyEvent(sequence:seq,kind:kind,day:day,word:word,beforeCard:before,
                              afterCard:day+1 | (1<<16) | (1<<20),afterRevision:grade,
                              presentation:presentation),time:time+10_000,active:active+10_000,epoch:epoch)
            return grade
        }
        mutating func undo(_ revision: UInt32,day: UInt32,time: Int64,word: UInt32=1) {
            append(StudyEvent(sequence:seq,kind:8,day:day,word:word,undoRevision:revision),time:time,active:Double(events.count)*5_000)
        }
    }

    func testForegroundClockExcludesBackgroundButRetainsLongThinkingAndDetectsClockJump() {
        var clock=StudyActivityClock()
        _=clock.stamp(wallMs:base,uptimeMs:100,utcOffsetSeconds:0)
        clock.running=true
        let first=clock.stamp(wallMs:base+120_000,uptimeMs:120_100,utcOffsetSeconds:0)
        XCTAssertEqual(first.foregroundMs,120_000)
        clock.running=false
        let hidden=clock.stamp(wallMs:base+1_920_000,uptimeMs:1_920_100,utcOffsetSeconds:0)
        XCTAssertEqual(hidden.foregroundMs,120_000)
        clock.running=true
        let longThink=clock.stamp(wallMs:base+2_520_000,uptimeMs:2_520_100,utcOffsetSeconds:0)
        XCTAssertEqual(longThink.foregroundMs,720_000)
        let changed=clock.stamp(wallMs:base+9_520_000,uptimeMs:2_520_200,utcOffsetSeconds:0)
        XCTAssertEqual(changed.clockEpoch,1)
        XCTAssertEqual(changed.foregroundMs,720_100)
    }

    func testTwoShadowsUpdateDifferentlyButScoreIdenticalDelayedTargets() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:6,before:1<<16)
        t.answer(day:20745,time:base+60_000,kind:5)
        t.answer(day:20745,time:base+600_000,kind:5)
        t.answer(day:20747,time:base+172_800_000,kind:5)
        let raw=t.events, saved=t.timing
        let report=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1,coreCounts:[1:3])
        XCTAssertEqual(report.rows.count,4)
        XCTAssertEqual(report.rows.filter { $0.firstAnswer?.updated == true }.count,2)
        XCTAssertEqual(report.rows.filter { $0.allRatings?.updated == true }.count,4)
        XCTAssertNotEqual(report.rows[2].firstAnswer?.stability,report.rows[2].allRatings?.stability)
        XCTAssertEqual(report.firstAnswerScore.count,1)
        XCTAssertEqual(report.allRatingsScore.count,1)
        XCTAssertTrue(report.rows[3].evaluationIncluded)
        XCTAssertEqual(report.rows[3].coreMeaningCount,3)
        XCTAssertEqual(report.rows[3].observation.cohort,"inherited-history-incomplete")
        XCTAssertEqual(report.rows[3].observation.observedInterdayRecalls,1)
        XCTAssertEqual(t.events,raw);XCTAssertEqual(t.timing,saved)
        let p=try XCTUnwrap(report.rows[3].firstAnswer?.probabilityBeforeAnswer)
        XCTAssertEqual(try XCTUnwrap(report.firstAnswerScore.brier),pow(1-p,2),accuracy:1e-12)
        let replay=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertEqual(replay.allRatingsScore.brier,report.allRatingsScore.brier)
    }

    func testUndoCannotTurnExposedRepeatIntoCleanFirstAnswer() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:5)
        let bad=t.answer(day:20747,time:base+172_800_000,kind:5)
        t.undo(bad,day:20747,time:base+172_811_000)
        t.answer(day:20747,time:base+172_812_000,kind:5)
        let report=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertTrue(report.rows[1].observation.retracted)
        XCTAssertFalse(report.rows[2].observation.firstPhysicalGradeOfDay)
        XCTAssertTrue(report.rows[2].evaluationExclusions.contains("earlier-answer-exposure-this-day"))
        XCTAssertEqual(report.comparableCount,0)
    }

    func testMidnightIsNotTwentyFourHoursAndClockDiscontinuityIsExcluded() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:5)
        t.answer(day:20746,time:base+120_000,kind:5)
        t.answer(day:20748,time:base+172_800_000,kind:5,epoch:1)
        let report=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertTrue(report.rows[1].evaluationExclusions.contains("contact-gap-under-24h"))
        XCTAssertEqual(report.rows[1].allRatings?.probabilityBeforeAnswer,1)
        XCTAssertTrue(report.rows[2].allRatings!.restartedForClockChange)
        XCTAssertEqual(report.comparableCount,0)
    }

    func testPredictionsPrecedeCurrentAnswerAndPartialKeepsDistinctLabel() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:10)
        t.answer(day:20747,time:base+172_800_000,kind:5)
        let good=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        t.events[t.events.count-1].kind=6
        let wrong=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertEqual(good.rows[1].previousOutcome,"partial")
        XCTAssertEqual(good.rows[1].allRatings?.probabilityBeforeAnswer,wrong.rows[1].allRatings?.probabilityBeforeAnswer)
        XCTAssertNotEqual(good.rows[1].allRatings?.stability,wrong.rows[1].allRatings?.stability)
        XCTAssertEqual(good.rows[1].observation.thinkingForegroundMs,5_000)
        XCTAssertEqual(good.rows[1].observation.answerForegroundMs,5_000)
    }

    func testRestartAndUntimedHistoryAreExplicitInsteadOfFabricated() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:6)
        t.answer(day:20747,time:base+172_800_000,kind:5)
        t.timing.firstSequence=4;t.timing.events.removeFirst(3)
        t.timing.forecasts.removeAll { $0.presentation<4 }
        let report=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertNil(report.rows[0].observation.timestampMs)
        XCTAssertTrue(report.rows[1].evaluationExclusions.contains("cold-or-untimed-model-history"))
        XCTAssertEqual(report.comparableCount,0)
        try t.timing.validate(streamID:stream,logCount:UInt32(t.events.count))
        let roundtrip=try JSONDecoder().decode(StudyTimingJournal.self,from:JSONEncoder().encode(t.timing))
        XCTAssertEqual(roundtrip,t.timing)
    }

    func testAnUnfinishedAnswerExposureDoesNotProduceCleanGapAfterRestart() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:5)
        let presentation=t.seq
        t.append(StudyEvent(sequence:t.seq,kind:3,day:20746,word:1,presentation:presentation),time:base+86_400_000,active:15_000)
        t.append(StudyEvent(sequence:t.seq,kind:4,day:20746,word:1,presentation:presentation),time:base+86_405_000,active:20_000)
        t.answer(day:20748,time:base+259_200_000,kind:5)
        let report=try DualFSRSReport.evaluate(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertNil(report.rows.last!.observation.gapWallMs)
        XCTAssertFalse(report.rows.last!.evaluationIncluded)
    }

    func testBoundaryClosesExposureAndDistinctCountExcludesFamiliar() throws {
        var t=Trace()
        t.answer(day:20745,time:base,kind:6)
        t.answer(day:20745,time:base+60_000,kind:5,word:2)
        t.answer(day:20745,time:base+120_000,kind:5,word:2)
        t.answer(day:20745,time:base+180_000,kind:7,word:3)
        t.answer(day:20747,time:base+172_800_000,kind:5)
        let rows=StudyEvidence.observations(events:t.events,timing:t.timing,firstSequence:1)
        XCTAssertEqual(rows.last!.distinctOtherWords,1)
        XCTAssertEqual(rows.last!.gapWallMs,172_790_000)
    }

    func testForegroundBoundaryTracksReadingUntilHiddenAndSavedForecastIsPriorToReveal() throws {
        var t=Trace()
        let presentation=t.seq
        t.append(StudyEvent(sequence:t.seq,kind:3,day:20745,word:1,presentation:presentation),time:base,active:0)
        t.append(StudyEvent(sequence:t.seq,kind:4,day:20745,word:1,presentation:presentation),time:base+5_000,active:5_000)
        let end=StudyTimePoint(wallMs:base+20_000,uptimeMs:20_000,foregroundMs:20_000,launchID:"test",clockEpoch:0,utcOffsetSeconds:0)
        t.timing.boundary(after:2,point:end,visible:false,word:1,answerVisible:true,reason:"study-hidden")
        t.answer(day:20747,time:base+172_800_000,kind:5)
        let observation=StudyEvidence.observations(events:t.events,timing:t.timing,firstSequence:1).last!
        XCTAssertEqual(observation.gapWallMs,172_780_000)
        let forecast=try XCTUnwrap(t.timing.forecasts.last)
        XCTAssertEqual(forecast.historyThroughSequence,2)
        XCTAssertEqual(forecast.presentation,3)
        XCTAssertEqual(forecast.timestampMs,base+172_800_000)
        XCTAssertLessThan(forecast.timestampMs,try XCTUnwrap(observation.timestampMs))
    }
}
