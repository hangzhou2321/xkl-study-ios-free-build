import Foundation

public struct StudyTimePoint: Codable, Equatable, Sendable {
    public var wallMs: Int64
    public var uptimeMs: Double
    public var foregroundMs: Double
    public var launchID: String
    public var clockEpoch: UInt32
    public var utcOffsetSeconds: Int
}

/// Visible study time is an observable proxy, not a claim that attention was
/// continuous. Long thinking is retained; no idle-time heuristic is applied.
public struct StudyActivityClock: Sendable {
    public var foregroundMs: Double
    public var running = false
    public var launchID = UUID().uuidString
    public var clockEpoch: UInt32
    private var previousWall: Int64?
    private var previousUptime: Double?
    public init(foregroundMs: Double = 0, clockEpoch: UInt32 = 0) {
        self.foregroundMs=foregroundMs; self.clockEpoch=clockEpoch
    }
    public mutating func stamp(wallMs: Int64, uptimeMs: Double, utcOffsetSeconds: Int) -> StudyTimePoint {
        if let previousUptime, let previousWall {
            let delta=uptimeMs-previousUptime
            if delta < 0 || abs(Double(wallMs-previousWall)-delta)>5_000 { clockEpoch &+= 1 }
            if running && delta >= 0 { foregroundMs += delta }
        }
        previousWall=wallMs; previousUptime=uptimeMs
        return StudyTimePoint(wallMs:wallMs,uptimeMs:uptimeMs,foregroundMs:foregroundMs,
                              launchID:launchID,clockEpoch:clockEpoch,utcOffsetSeconds:utcOffsetSeconds)
    }
}

public struct StudyTimedEvent: Codable, Equatable, Sendable {
    public var sequence: UInt32
    public var point: StudyTimePoint
    public var precision: String
}
public struct StudyVisibilityBoundary: Codable, Equatable, Sendable {
    public var afterSequence: UInt32
    public var point: StudyTimePoint
    public var visible: Bool
    public var word: UInt32?
    public var answerVisible: Bool
    public var reason: String
}
public struct SavedRecallForecast: Codable, Equatable, Sendable {
    public var presentation, word, day, historyThroughSequence, firstSequence: UInt32
    public var timestampMs: Int64
    public var firstAnswerProbability, allRatingsProbability: Double?
    public var referenceCommit="9446cb06605c597a063aeee49f7d188d42e34dc2"
    public var parameterSet="FSRS-6-default-6.3.2-retention0.90-max180-no-fuzz"
}
public struct StudyTimingJournal: Codable, Equatable, Sendable {
    public var version = 1
    public var streamID: String
    public var firstSequence: UInt32
    public var events: [StudyTimedEvent] = []
    public var boundaries: [StudyVisibilityBoundary] = []
    public var forecasts: [SavedRecallForecast] = []
    public var boundaryLimitReached = false
    public init(streamID: String, firstSequence: UInt32) { self.streamID=streamID; self.firstSequence=firstSequence }
    public var latestPoint: StudyTimePoint? {
        if let a=events.last, let b=boundaries.last { return a.sequence>b.afterSequence ? a.point:b.point }
        return events.last?.point ?? boundaries.last?.point
    }
    public mutating func capture(_ appended: [StudyEvent], at point: StudyTimePoint, running: Bool) {
        for e in appended where e.sequence >= firstSequence {
            guard events.last?.sequence ?? 0 < e.sequence else { continue }
            var p=point
            let lag=e.uptimeMs.flatMap { $0 == .max ? nil : point.uptimeMs-Double($0) }
            let aligned=lag.map { $0 >= 0 && $0 < 60_000 } ?? false
            if aligned, let lag {
                p.wallMs -= Int64(lag); p.uptimeMs -= lag
                if running { p.foregroundMs=max(0,p.foregroundMs-lag) }
            }
            events.append(StudyTimedEvent(sequence:e.sequence,point:p,
                precision:aligned ? "engine-request-aligned" : "operation-completion-approximation"))
        }
    }
    public mutating func boundary(after sequence: UInt32, point: StudyTimePoint, visible: Bool,
                                  word: UInt32?, answerVisible: Bool, reason: String) {
        guard boundaries.count < 100_000 else { boundaryLimitReached=true; return }
        boundaries.append(StudyVisibilityBoundary(afterSequence:sequence,point:point,visible:visible,
                                                  word:word,answerVisible:answerVisible,reason:reason))
    }
    public func validate(streamID: String, logCount: UInt32) throws {
        guard version == 1, self.streamID == streamID, firstSequence>0, firstSequence<=logCount+1,
              events.count<=21_802, boundaries.count<=100_000,forecasts.count<=21_802,
              events.allSatisfy({ $0.sequence>=firstSequence && $0.sequence<=logCount }),
              zip(events,events.dropFirst()).allSatisfy({ $0.sequence<$1.sequence }),
              boundaries.allSatisfy({ $0.afterSequence<=logCount && ($0.word == nil || $0.word!<25_644) }) else {
            throw AnalysisError.invalidSettings
        }
        for p in events.map(\.point)+boundaries.map(\.point) {
            guard p.wallMs>0, p.uptimeMs.isFinite, p.uptimeMs>=0, p.foregroundMs.isFinite,
                  p.foregroundMs>=0, !p.launchID.isEmpty else { throw AnalysisError.invalidSettings }
        }
        guard Set(forecasts.map(\.presentation)).count==forecasts.count,
              forecasts.allSatisfy({ $0.presentation>=firstSequence && $0.presentation<=logCount &&
                  $0.historyThroughSequence<UInt32.max && $0.historyThroughSequence+1==$0.presentation && $0.word<25_644 &&
                  [$0.firstAnswerProbability,$0.allRatingsProbability].allSatisfy { $0 == nil || ($0!.isFinite && (0...1).contains($0!)) } }) else {
            throw AnalysisError.invalidSettings
        }
    }
}

public struct RecallObservation: Codable, Sendable {
    public var sequence, word, day: UInt32
    public var presentation: UInt32?
    public var kind: UInt32
    public var timestampMs: Int64?
    public var cohort: String
    public var observedInterdayRecalls: Int
    public var firstPhysicalGradeOfDay: Bool
    public var retracted: Bool
    public var clockEpoch: UInt32?
    public var gapWallMs: Int64?
    public var gapForegroundMs: Double?
    public var distinctOtherWords: Int
    public var gapAcrossLaunches: Bool
    public var thinkingForegroundMs, answerForegroundMs: Double?
    public var totalForegroundMs: Double?
    public var answerWallMs, thinkingWallMs: Int64?
    public var actualDueDay: UInt32?
    public var actualReviewEligible: Bool
    public var exclusions: [String]
    public var cleanDelayedTarget: Bool { exclusions.isEmpty }
}

public enum StudyEvidence {
    /// Analysis only: exposure and undo never modify the actual learning queue.
    public static func observations(events: [StudyEvent], timing: StudyTimingJournal,
                                    firstSequence: UInt32) -> [RecallObservation] {
        let times=Dictionary(uniqueKeysWithValues:timing.events.map { ($0.sequence,$0.point) })
        let retracted=Set(events.filter { $0.kind==8 && $0.undoRevision != .max }.map(\.undoRevision))
        let unknownUndo=events.filter { $0.kind==8 && $0.undoRevision == .max }
        var lastContact: [UInt32: StudyTimePoint] = [:], lastGradeDay: [UInt32: UInt32] = [:]
        var contacts: [UInt32: Int] = [:], gradedWords: [UInt32] = []
        var presents: [UInt32: (StudyTimePoint?, StudyTimePoint?, Int)] = [:]
        var reveals: [UInt32: StudyTimePoint] = [:], revealedDay=Set<String>(), contaminated=Set<UInt32>()
        var openExposures=Set<UInt32>()
        var firstGrades=Set<String>(), cohorts: [UInt32: String] = [:], crossDays: [UInt32: Int] = [:]
        var result: [RecallObservation] = []
        var boundaryIndex=0
        func activeDifference(_ end: StudyTimePoint?, _ start: StudyTimePoint?) -> Double? {
            guard let end, let start, end.launchID==start.launchID, end.foregroundMs>=start.foregroundMs else { return nil }
            return end.foregroundMs-start.foregroundMs
        }
        func wallDifference(_ end: StudyTimePoint?, _ start: StudyTimePoint?) -> Int64? {
            guard let end, let start, end.clockEpoch==start.clockEpoch, end.wallMs>=start.wallMs else { return nil }
            return end.wallMs-start.wallMs
        }
        for e in events {
            while boundaryIndex<timing.boundaries.count && timing.boundaries[boundaryIndex].afterSequence<e.sequence {
                let b=timing.boundaries[boundaryIndex];boundaryIndex+=1
                if b.answerVisible, let word=b.word {
                    lastContact[word]=b.point;contacts[word]=gradedWords.count
                    if b.visible { openExposures.insert(word) } else { openExposures.remove(word) }
                }
            }
            guard e.word<25_644 else { continue }
            let key="\(e.word):\(e.day)", point=times[e.sequence]
            if e.kind==3 {
                presents[e.sequence]=(point,openExposures.contains(e.word) ? nil : lastContact[e.word],contacts[e.word] ?? gradedWords.count)
                if revealedDay.contains(key) { contaminated.insert(e.sequence) }
            } else if e.kind==4 {
                if let presentation=e.presentation, let point { reveals[presentation]=point }
                revealedDay.insert(key)
                openExposures.insert(e.word)
            }
            if e.graded {
                let first=firstGrades.insert(key).inserted
                let undone=retracted.contains(e.afterRevision) || unknownUndo.contains { $0.word==e.word && $0.sequence>e.sequence }
                let presentation=e.presentation.flatMap { presents[$0] }
                let presented=presentation?.0, previous=presentation?.1
                let reveal=e.presentation.flatMap { reveals[$0] }
                let gap=wallDifference(presented,previous)
                let startIndex=presentation?.2 ?? gradedWords.count
                let distinct=Set(gradedWords.dropFirst(startIndex).filter { $0 != e.word }).count
                let exposed=e.presentation.map { contaminated.contains($0) } ?? true
                if cohorts[e.word] == nil && e.sequence>=firstSequence {
                    cohorts[e.word]=(e.beforeCard==0 && e.stage==0) ? "first-seen-in-app-after-activation" : "inherited-history-incomplete"
                }
                var exclusions: [String]=[]
                if !first { exclusions.append("not-first-physical-grade-of-day") }
                if undone { exclusions.append("grade-retracted") }
                if exposed { exclusions.append("earlier-answer-exposure-this-day") }
                if gap == nil { exclusions.append("unobserved-or-discontinuous-contact-gap") }
                else if gap!<86_400_000 { exclusions.append("contact-gap-under-24h") }
                if point==nil { exclusions.append("missing-wall-timestamp") }
                if timing.boundaryLimitReached { exclusions.append("incomplete-visibility-log") }
                if e.sequence>=firstSequence, !undone {
                    if let priorDay=lastGradeDay[e.word], priorDay<e.day { crossDays[e.word,default:0]+=1 }
                    lastGradeDay[e.word]=e.day
                }
                if e.sequence>=firstSequence {
                    let level=(e.afterCard>>16)&15, familiar=(e.afterCard&(1<<21)) != 0
                    result.append(RecallObservation(sequence:e.sequence,word:e.word,day:e.day,presentation:e.presentation,kind:e.kind,
                        timestampMs:point?.wallMs,cohort:cohorts[e.word] ?? "inherited-history-incomplete",
                        observedInterdayRecalls:crossDays[e.word,default:0],firstPhysicalGradeOfDay:first,
                        retracted:undone,clockEpoch:point?.clockEpoch,gapWallMs:gap,
                        gapForegroundMs:activeDifference(presented,previous),distinctOtherWords:distinct,
                        gapAcrossLaunches:presented != nil && previous != nil && presented!.launchID != previous!.launchID,
                        thinkingForegroundMs:activeDifference(reveal,presented),answerForegroundMs:activeDifference(point,reveal),
                        totalForegroundMs:activeDifference(point,presented),answerWallMs:wallDifference(point,reveal),
                        thinkingWallMs:wallDifference(reveal,presented),actualDueDay:level>0 && !familiar ? e.afterCard&65535 : nil,
                        actualReviewEligible:level>0 && !familiar && (e.afterCard&(1<<20)) != 0,exclusions:exclusions))
                }
                gradedWords.append(e.word)
            }
            // A retracted answer still exposed content. Familiar without reveal
            // is not counted as meaning exposure, but grading always ends contact.
            if e.graded || (e.kind==7 && (e.flags ?? 0)&1 != 0) {
                if let point { lastContact[e.word]=point } else { lastContact.removeValue(forKey:e.word) }
                contacts[e.word]=gradedWords.count
                openExposures.remove(e.word)
            }
        }
        return result
    }
}
