import Foundation

/// Read-only projection of the original algorithm-3 binary log.
public struct StudyEvent: Codable, Equatable, Sendable {
    public var sequence, kind, day, word, stage, beforeCard, afterCard: UInt32
    public var beforeRevision, afterRevision, undoRevision: UInt32
    public var presentation, session, uptimeMs, revealMs, answerMs, flags: UInt32?
    public init(sequence: UInt32, kind: UInt32, day: UInt32, word: UInt32, stage: UInt32 = 0,
                beforeCard: UInt32 = 0, afterCard: UInt32 = 0, beforeRevision: UInt32 = 0,
                afterRevision: UInt32 = 0, undoRevision: UInt32 = .max,
                presentation: UInt32? = nil, session: UInt32? = nil, uptimeMs: UInt32? = nil,
                revealMs: UInt32? = nil, answerMs: UInt32? = nil, flags: UInt32? = nil) {
        self.sequence=sequence; self.kind=kind; self.day=day; self.word=word; self.stage=stage
        self.beforeCard=beforeCard; self.afterCard=afterCard; self.beforeRevision=beforeRevision
        self.afterRevision=afterRevision; self.undoRevision=undoRevision
        self.presentation=presentation; self.session=session; self.uptimeMs=uptimeMs
        self.revealMs=revealMs; self.answerMs=answerMs; self.flags=flags
    }
    public var graded: Bool { kind == 5 || kind == 6 || kind == 10 }
}

public struct ReductionDecision: Codable, Equatable, Sendable {
    public var policyVersion, word, day, answerSequence, beforeRevision, afterRevision: UInt32
    public var firstSequence, qualifiedRecalls, distinctGap, longGap, removed: UInt32
    public init(word: UInt32, day: UInt32, sequence: UInt32, before: UInt32, after: UInt32,
                first: UInt32, recalls: UInt32, gap: UInt32, longGap: UInt32, removed: UInt32) {
        policyVersion=1; self.word=word; self.day=day; answerSequence=sequence
        beforeRevision=before; afterRevision=after; firstSequence=first
        qualifiedRecalls=recalls; distinctGap=gap; self.longGap=longGap; self.removed=removed
    }
}

public struct PolicyChange: Codable, Equatable, Sendable {
    public var firstSequence: UInt32
    public var enabled: Bool
    public var changedAt: Date
}

public struct StudyAnalysisSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var streamID: String
    public var conservativeEnabled = true
    public var conservativeFirstSequence: UInt32
    public var shadowFirstSequence: UInt32
    public var activatedAt: Date
    public var changes: [PolicyChange]
    public var reductions: [ReductionDecision] = []
    public var archivedSavedRepetitions: UInt64? = nil

    public init(streamID: String, nextSequence: UInt32, now: Date = Date()) {
        self.streamID=streamID; conservativeFirstSequence=nextSequence; shadowFirstSequence=nextSequence
        activatedAt=now; changes=[PolicyChange(firstSequence: nextSequence, enabled: true, changedAt: now)]
    }
    public var savedRepetitions: UInt64 { (archivedSavedRepetitions ?? 0)+reductions.reduce(0) { $0+UInt64($1.removed) } }
    public func validate(streamID: String, logCount: UInt32) throws {
        guard logCount < UInt32.max, version == 1, self.streamID == streamID, streamID.count == 32,
              streamID.allSatisfy({ $0.isHexDigit }),
              shadowFirstSequence > 0, shadowFirstSequence <= logCount + 1,
              conservativeFirstSequence >= shadowFirstSequence, conservativeFirstSequence <= logCount + 1,
              changes.count <= 10_000, reductions.count <= 21_802,
              (archivedSavedRepetitions ?? 0)<=UInt64(logCount)*6,
              changes.allSatisfy({ $0.firstSequence >= shadowFirstSequence && $0.firstSequence <= logCount + 1 }),
              reductions.allSatisfy({ $0.policyVersion == 1 && $0.word < 25_644 && $0.removed > 0 && $0.removed <= 6 &&
                  $0.firstSequence >= shadowFirstSequence && $0.firstSequence <= $0.answerSequence &&
                  $0.answerSequence <= logCount && $0.qualifiedRecalls >= 3 && $0.distinctGap >= 3 && $0.longGap == 1 &&
                  $0.beforeRevision < UInt32.max && $0.afterRevision == $0.beforeRevision + 1 }),
              Set(reductions.map(\.answerSequence)).count == reductions.count else { throw AnalysisError.invalidSettings }
    }
    public mutating func setEnabled(_ enabled: Bool, nextSequence: UInt32, now: Date = Date()) {
        guard conservativeEnabled != enabled else { return }
        conservativeEnabled=enabled; conservativeFirstSequence=nextSequence
        changes.append(PolicyChange(firstSequence: nextSequence, enabled: enabled, changedAt: now))
    }
}

public enum AnalysisError: Error { case invalidSettings, invalidObservation }

/// FSRS-6 review equations, ported from MIT-licensed py-fsrs 6.3.2,
/// commit 9446cb06605c597a063aeee49f7d188d42e34dc2. See docs/FSRS-LICENSE.txt.
/// This type has no scheduling/engine write API. It only returns predictions.
public enum FSRS6Shadow {
    public static let model = "FSRS-6 / py-fsrs 6.3.2 / default parameters"
    public static let desiredRetention = 0.9
    public static let maximumInterval = 180
    public static let weights: [Double] = [0.212,1.2931,2.3065,8.2956,6.4133,0.8334,3.0194,0.001,
        1.8722,0.1666,0.796,1.4835,0.0614,0.2629,1.6483,0.6014,1.8729,0.5425,0.0912,0.0658,0.1542]
    public struct Memory: Codable, Equatable, Sendable {
        public var stability, difficulty: Double
        public var lastDay, dueDay: UInt32
        public var timestampMs: Int64? = nil
    }
    public struct Prediction: Codable, Equatable, Sendable {
        public var memory: Memory
        public var retrievabilityBefore: Double?
        public var interval: Int
    }
    public static func recallProbability(_ previous: Memory, day: UInt32, timestampMs: Int64?) -> Double? {
        let elapsed: Double
        if let timestampMs,let old=previous.timestampMs {
            guard timestampMs>=old else { return nil }
            elapsed=floor(Double(timestampMs-old)/86_400_000)
        } else {
            guard day>=previous.lastDay else { return nil };elapsed=Double(day-previous.lastDay)
        }
        let decay = -weights[20],factor=pow(0.9,1/decay)-1
        return pow(1+factor*elapsed/previous.stability,decay)
    }
    public static func review(_ previous: Memory?, day: UInt32, rating: Int, timestampMs: Int64? = nil) throws -> Prediction {
        guard (1...4).contains(rating), (18_000...50_000).contains(day),
              previous == nil || (previous!.lastDay <= day && previous!.stability.isFinite &&
                  previous!.stability >= 0.001 && (1...10).contains(previous!.difficulty)) else {
            throw AnalysisError.invalidObservation
        }
        let w=weights, decay = -w[20], factor=pow(0.9, 1 / decay)-1
        func initialDifficulty(_ grade: Int) -> Double { w[4] - exp(w[5] * Double(grade-1)) + 1 }
        let s: Double, d: Double, probability: Double?
        if let old=previous {
            let elapsed: Double
            if let timestampMs, let oldTime=old.timestampMs {
                guard timestampMs >= oldTime else { throw AnalysisError.invalidObservation }
                elapsed=floor(Double(timestampMs-oldTime)/86_400_000)
            } else { elapsed=Double(day-old.lastDay) }
            let r=pow(1+factor*elapsed/old.stability, decay)
            probability=r
            if elapsed < 1 {
                var growth=exp(w[17] * (Double(rating)-3+w[18])) * pow(old.stability, -w[19])
                if rating >= 2 { growth=max(growth,1) }
                s=max(0.001,old.stability*growth)
            } else if rating == 1 {
                let longTerm=w[11]*pow(old.difficulty,-w[12])*(pow(old.stability+1,w[13])-1)*exp((1-r)*w[14])
                s=max(0.001,min(longTerm,old.stability/exp(w[17]*w[18])))
            } else {
                let hard=rating == 2 ? w[15] : 1, easy=rating == 4 ? w[16] : 1
                s=max(0.001,old.stability*(1+exp(w[8])*(11-old.difficulty)*pow(old.stability,-w[9])*(exp((1-r)*w[10])-1)*hard*easy))
            }
            let delta = -w[6]*Double(rating-3)
            d=min(10,max(1,w[7]*initialDifficulty(4)+(1-w[7])*(old.difficulty+(10-old.difficulty)*delta/9)))
        } else {
            probability=nil; s=max(0.001,w[rating-1]); d=min(10,max(1,initialDifficulty(rating)))
        }
        guard s.isFinite, d.isFinite else { throw AnalysisError.invalidObservation }
        // Python round uses ties-to-even. Fuzzing and intraday learning steps
        // are disabled, and both compared schedules use the 180-day ceiling.
        let days=s/factor*(pow(desiredRetention,1/decay)-1)
        let interval=Int(min(Double(maximumInterval),max(1,days.rounded(.toNearestOrEven))))
        return Prediction(memory: Memory(stability:s,difficulty:d,lastDay:day,dueDay:day+UInt32(interval),timestampMs:timestampMs),
                          retrievabilityBefore:probability,interval:interval)
    }
}

public struct FSRSComparison: Codable, Sendable {
    public var sequence, word, day: UInt32
    public var outcome: String
    public var fsrsRating: Int
    public var fullRecall: Bool
    public var coldStart: Bool
    public var predictedRecall: Double?
    public var suggestedDueDay: UInt32
    public var suggestedInterval: Int
    public var actualDueDay: UInt32?
    public var actualReviewEligible: Bool
    public var stability, difficulty: Double
}

public struct FSRSShadowReport: Codable, Sendable {
    public var model = FSRS6Shadow.model
    public var desiredRetention = FSRS6Shadow.desiredRetention
    public var maximumInterval = FSRS6Shadow.maximumInterval
    public var weights = FSRS6Shadow.weights
    public var schedulingAuthority = "none: observations only; actual due dates are never changed"
    public var observationRule = "first unretracted graded encounter per word per calendar day; correct=Good, wrong/partial=Again; familiar excluded"
    public var firstSequence, throughSequence: UInt32
    public var comparisons: [FSRSComparison]
    public var retractedRevisions: [UInt32]
    public var comparableCount: Int { comparisons.filter { !$0.coldStart }.count }

    public static func evaluate(events: [StudyEvent], firstSequence: UInt32) throws -> Self {
        let input=events.filter { $0.sequence >= firstSequence }
        let undone=Set(input.filter { $0.kind == 8 && $0.undoRevision != .max }.map(\.undoRevision))
        let unknownUndo=input.filter { $0.kind == 8 && $0.undoRevision == .max }
        var finalCards: [String: UInt32] = [:]
        for e in input where e.word < 25_644 && (e.graded || e.kind == 7 || e.kind == 8) {
            finalCards["\(e.word):\(e.day)"]=e.afterCard
        }
        var memories: [UInt32: FSRS6Shadow.Memory] = [:], seen=Set<String>(), rows: [FSRSComparison] = []
        for e in input where e.graded && e.word < 25_644 {
            if Task.isCancelled { throw CancellationError() }
            guard !undone.contains(e.afterRevision),
                  !unknownUndo.contains(where: { $0.word == e.word && $0.sequence > e.sequence }) else { continue }
            let key="\(e.word):\(e.day)"
            guard seen.insert(key).inserted else { continue }
            let rating=e.kind == 5 ? 3 : 1
            let old=memories[e.word], prediction=try FSRS6Shadow.review(old,day:e.day,rating:rating)
            memories[e.word]=prediction.memory
            let actual=finalCards[key] ?? e.afterCard
            let level=(actual >> 16)&15, learned=(actual & (1 << 20)) != 0, familiar=(actual & (1 << 21)) != 0
            let due: UInt32? = level > 0 && !familiar ? actual & 65535 : nil
            rows.append(FSRSComparison(sequence:e.sequence,word:e.word,day:e.day,
                outcome:e.kind == 5 ? "full" : (e.kind == 10 ? "partial" : "forgotten"),fsrsRating:rating,
                fullRecall:e.kind == 5,coldStart:old == nil,predictedRecall:prediction.retrievabilityBefore,
                suggestedDueDay:prediction.memory.dueDay,suggestedInterval:prediction.interval,
                actualDueDay:due,actualReviewEligible:learned && level > 0 && !familiar,
                stability:prediction.memory.stability,difficulty:prediction.memory.difficulty))
        }
        return Self(firstSequence:firstSequence,throughSequence:events.last?.sequence ?? 0,
                    comparisons:rows,retractedRevisions:undone.sorted())
    }
}
