import Foundation

public struct ShadowEstimate: Codable, Sendable {
    public var probabilityBeforeAnswer: Double?
    public var suggestedDueDay: UInt32
    public var intervalDays: Int
    public var stability, difficulty: Double
    public var updated: Bool
    public var restartedForClockChange: Bool
    public var state: FSRS6Shadow.Memory
}
public struct DualFSRSRow: Codable, Sendable {
    public var observation: RecallObservation
    public var coreMeaningCount: Int?
    public var previousOutcome: String?
    public var savedForecast: SavedRecallForecast?
    public var firstAnswer: ShadowEstimate?
    public var allRatings: ShadowEstimate?
    public var evaluationIncluded: Bool
    public var evaluationExclusions: [String]
}
public struct CalibrationBin: Codable, Sendable {
    public var lower: Double
    public var count: Int
    public var meanPrediction, observedFullRecall: Double
}
public struct ShadowScore: Codable, Sendable {
    public var count: Int
    public var brier, logLoss: Double?
    public var calibration: [CalibrationBin]
    static func compute(_ rows: [(Double,Bool)]) -> Self {
        guard !rows.isEmpty else { return Self(count:0,brier:nil,logLoss:nil,calibration:[]) }
        let n=Double(rows.count)
        let brier=rows.reduce(0.0) { $0+pow($1.0-($1.1 ? 1.0:0.0),2) }/n
        let loss=rows.reduce(0.0) { sum,row in
            let p=min(1-1e-15,max(1e-15,row.0));return sum-log(row.1 ? p:1-p)
        }/n
        let bins=(0..<10).compactMap { index -> CalibrationBin? in
            let selected=rows.filter { min(9,Int($0.0*10))==index }
            guard !selected.isEmpty else { return nil }
            let count=Double(selected.count)
            return CalibrationBin(lower:Double(index)/10,count:selected.count,
                meanPrediction:selected.reduce(0) { $0+$1.0 }/count,
                observedFullRecall:Double(selected.filter(\.1).count)/count)
        }
        return Self(count:rows.count,brier:brier,logLoss:loss,calibration:bins)
    }
}
public struct DualFSRSReport: Codable, Sendable {
    public var format="xkl-dual-fsrs-v1"
    public var model=FSRS6Shadow.model
    public var referenceCommit="9446cb06605c597a063aeee49f7d188d42e34dc2"
    public var weights=FSRS6Shadow.weights
    public var desiredRetention=FSRS6Shadow.desiredRetention
    public var maximumInterval=FSRS6Shadow.maximumInterval
    public var schedulingAuthority="none; neither model writes due dates or queues"
    public var updateRule="first-answer: first unretracted grade per word/calendar day; all-ratings: every unretracted recall grade; partial/forgotten=Again, full=Good; familiar excluded"
    public var evaluationRule="identical first physical grades for both models, no earlier same-day answer exposure, no undo replacement, observed contact gap >=24h and timestamped prior states; predictions precede updates"
    public var timingRule="whole elapsed 24h periods as in pinned py-fsrs; pre-telemetry history uses labelled calendar fallback and cannot provide scored targets; wall clock across app launches is not independently verified"
    public var costRule="foreground visible study time, including long thinking; background/other tabs excluded; unknown killed-app tail not fabricated; this is not a direct attention measurement"
    public var firstSequence, telemetryFirstSequence, throughSequence: UInt32
    public var rows: [DualFSRSRow]
    public var firstAnswerScore, allRatingsScore: ShadowScore
    public var comparableCount: Int { firstAnswerScore.count }
    /// Called while presenting the question, before the corresponding reveal or
    /// grade exists. The saved values share the atomic write with that PRESENT.
    public static func makeForecast(events: [StudyEvent], timing: StudyTimingJournal,
                                    firstSequence: UInt32, presentation: StudyEvent) throws -> SavedRecallForecast? {
        guard presentation.kind==3,let point=timing.events.first(where:{$0.sequence==presentation.sequence})?.point else { return nil }
        let prefix=events.filter { $0.sequence<presentation.sequence }
        let report=try evaluate(events:prefix,timing:timing,firstSequence:firstSequence)
        let row=report.rows.last { $0.observation.word==presentation.word && $0.allRatings != nil }
        let clockMatches=row?.observation.clockEpoch==point.clockEpoch
        func probability(_ estimate: ShadowEstimate?) -> Double? {
            guard clockMatches,let estimate else { return nil }
            return FSRS6Shadow.recallProbability(estimate.state,day:presentation.day,timestampMs:point.wallMs)
        }
        return SavedRecallForecast(presentation:presentation.sequence,word:presentation.word,day:presentation.day,
            historyThroughSequence:presentation.sequence-1,firstSequence:firstSequence,timestampMs:point.wallMs,
            firstAnswerProbability:probability(row?.firstAnswer),allRatingsProbability:probability(row?.allRatings))
    }
    public static func evaluate(events: [StudyEvent], timing: StudyTimingJournal, firstSequence: UInt32,
                                coreCounts: [UInt32:Int] = [:]) throws -> Self {
        let observations=StudyEvidence.observations(events:events,timing:timing,firstSequence:firstSequence)
        let forecasts=Dictionary(uniqueKeysWithValues:timing.forecasts.map { ($0.presentation,$0) })
        var daily: [UInt32:FSRS6Shadow.Memory]=[:], all: [UInt32:FSRS6Shadow.Memory]=[:]
        var epochs: [UInt32:UInt32]=[:], seen=Set<String>(), previous: [UInt32:String]=[:]
        var rows: [DualFSRSRow]=[]
        var scoresDaily: [(Double,Bool)]=[], scoresAll: [(Double,Bool)]=[]
        for o in observations {
            if Task.isCancelled { throw CancellationError() }
            let key="\(o.word):\(o.day)"
            if o.retracted {
                rows.append(DualFSRSRow(observation:o,coreMeaningCount:coreCounts[o.word],previousOutcome:previous[o.word],
                                       evaluationIncluded:false,evaluationExclusions:o.exclusions))
                continue
            }
            let clockChange=(o.clockEpoch != nil && epochs[o.word] != nil && o.clockEpoch != epochs[o.word]) ||
                (o.timestampMs != nil && all[o.word]?.timestampMs != nil && o.timestampMs!<all[o.word]!.timestampMs!)
            if clockChange { daily.removeValue(forKey:o.word);all.removeValue(forKey:o.word) }
            let beforeDaily=daily[o.word],beforeAll=all[o.word],rating=o.kind==5 ? 3:1
            let a=try FSRS6Shadow.review(beforeDaily,day:o.day,rating:rating,timestampMs:o.timestampMs)
            let b=try FSRS6Shadow.review(beforeAll,day:o.day,rating:rating,timestampMs:o.timestampMs)
            let updateDaily=seen.insert(key).inserted || clockChange
            var exclusions=o.exclusions
            let saved=o.presentation.flatMap { forecasts[$0] }
            let validForecast=saved?.firstSequence==firstSequence && saved?.word==o.word && saved?.day==o.day
            if !validForecast { exclusions.append("no-matching-pre-answer-forecast") }
            if beforeDaily?.timestampMs == nil || beforeAll?.timestampMs == nil { exclusions.append("cold-or-untimed-model-history") }
            if clockChange { exclusions.append("model-restarted-for-clock-discontinuity") }
            let probabilityA=validForecast ? saved?.firstAnswerProbability:a.retrievabilityBefore
            let probabilityB=validForecast ? saved?.allRatingsProbability:b.retrievabilityBefore
            let eligible=exclusions.isEmpty && probabilityA != nil && probabilityB != nil
            if eligible {
                scoresDaily.append((probabilityA!,o.kind==5));scoresAll.append((probabilityB!,o.kind==5))
            }
            func estimate(_ p: FSRS6Shadow.Prediction, probability: Double?, update: Bool, retained: FSRS6Shadow.Memory? = nil) -> ShadowEstimate {
                let m=update ? p.memory:(retained ?? p.memory)
                return ShadowEstimate(probabilityBeforeAnswer:probability,suggestedDueDay:m.dueDay,
                    intervalDays:Int(m.dueDay-m.lastDay),stability:m.stability,difficulty:m.difficulty,
                    updated:update,restartedForClockChange:clockChange,state:m)
            }
            rows.append(DualFSRSRow(observation:o,coreMeaningCount:coreCounts[o.word],previousOutcome:previous[o.word],
                savedForecast:saved,firstAnswer:estimate(a,probability:probabilityA,update:updateDaily,retained:beforeDaily),
                allRatings:estimate(b,probability:probabilityB,update:true),
                evaluationIncluded:eligible,evaluationExclusions:exclusions))
            if updateDaily { daily[o.word]=a.memory }
            all[o.word]=b.memory
            if let epoch=o.clockEpoch { epochs[o.word]=epoch }
            previous[o.word]=o.kind==5 ? "full":(o.kind==10 ? "partial":"forgotten")
        }
        return Self(firstSequence:firstSequence,telemetryFirstSequence:timing.firstSequence,
                    throughSequence:events.last?.sequence ?? 0,rows:rows,
                    firstAnswerScore:ShadowScore.compute(scoresDaily),allRatingsScore:ShadowScore.compute(scoresAll))
    }
}
