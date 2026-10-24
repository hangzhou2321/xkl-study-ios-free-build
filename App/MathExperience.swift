import Foundation
import StudyCore

enum MathOutcome: String, Codable { case independentCorrect, assistedCorrect, incorrect; var rating: Int { self == .independentCorrect ? 3 : 1 } }
struct MathExperienceSession: Codable, Equatable {
    var id = UUID(); var questionID: String; var shownAt: Date
    var hintShown = false; var answerShown = false; var detailsExpanded = false; var paused = false; var assisted = false
    var interrupted = false
}
struct MathExperienceEvent: Codable {
    var id = UUID(); var utcOffsetSeconds: Int = TimeZone.current.secondsFromGMT(); var sequence: Int; var kind: String; var timestamp: Date; var day: UInt32
    var questionID: String?; var session: MathExperienceSession?; var outcome: MathOutcome?; var target: UUID?; var cardID: String?; var remembered: Bool?; var spotCheck: Bool? = nil; var cardSession: MathCardRecallSession? = nil
}
struct MathCardRecallSession: Codable, Equatable { var id = UUID(); var cardID: String; var shownAt: Date; var answerShown = false }
struct MathCleanTarget { var eventID: UUID; var daily: Double; var all: Double; var correct: Bool }
struct MathExperienceEngine {
    let baseline: MathArchive
    private(set) var knownCardIDs: Set<String>
    private(set) var practiceBlockedIDs: Set<String>
    private(set) var currentCard: MathCardRecallSession?
    private(set) var suspended: [MathExperienceSession] = []
    private(set) var events: [MathExperienceEvent]
    private(set) var daily: [String: FSRS6Shadow.Memory] = [:]
    private(set) var all: [String: FSRS6Shadow.Memory] = [:]
    private(set) var cardMemories: [String: FSRS6Shadow.Memory] = [:]
    private(set) var cardQueue = Set<String>()
    private(set) var familiar = Set<String>()
    private(set) var current: MathExperienceSession?
    private(set) var cleanTargets: [MathCleanTarget] = []
    var currentQuestion: MathQuestion? { baseline.content.questions.first { $0.id == current?.questionID } }
    init(baseline: MathArchive, events: [MathExperienceEvent] = [], cardIDs: Set<String> = [], blockedQuestionIDs: Set<String> = []) throws {
        self.baseline=baseline; self.events=events; self.knownCardIDs=cardIDs; self.practiceBlockedIDs=blockedQuestionIDs; try replay()
    }
    private mutating func replay() throws {
        let old=try MathEngine(archive:baseline); daily=old.daily; all=old.all
        familiar=[]; current=nil; currentCard=nil; suspended=[]; cleanTargets=[]; cardQueue=[]; cardMemories=[:]
        guard Set(events.map(\.id)).count == events.count else { throw MathFailure.invalid("事件ID重复。") }
        var undone=Set<UUID>(), previous: Date? = baseline.events.last?.timestamp
        for (i,e) in events.enumerated() {
            guard e.sequence == i+1, e.timestamp.timeIntervalSince1970.isFinite, (1_555_027_200...4_320_172_800).contains(e.timestamp.timeIntervalSince1970), (18_000...50_000).contains(e.day), (-50400...50400).contains(e.utcOffsetSeconds), UInt32(floor((e.timestamp.timeIntervalSince1970+Double(e.utcOffsetSeconds))/86400)) == e.day, previous == nil || e.timestamp >= previous! else { throw MathFailure.invalid("新体验事件链无效。") }
            previous=e.timestamp
            if e.kind == "undo" {
                guard let target=e.target, let index=events.prefix(i).lastIndex(where: { ["grade","familiar"].contains($0.kind) }), events[index].id == target,
                      e.timestamp.timeIntervalSince(events[index].timestamp) <= 15, events[index].session?.id == e.session?.id, e.session?.interrupted == true,
                      !events[(index+1)..<i].contains(where: { !["present","pause","resume","return"].contains($0.kind) }), undone.insert(target).inserted else { throw MathFailure.invalid("撤销引用无效。") }
            }
        }
        var days=Set(baseline.events.filter { $0.kind == "grade" }.map { "\($0.questionID)|\($0.day)" })
        var lastContact: [String: Date] = [:]
        for e in baseline.events { lastContact[e.questionID]=e.timestamp }
        var unknownExposure=Set(baseline.events.filter { e in e.kind == "reveal" && !baseline.events.contains { $0.presentationID == e.presentationID && ["grade","exposure-close"].contains($0.kind) } }.map(\.questionID))
        var starts: [UUID:(Double?,Double?,Bool,UInt32,Int)] = [:]
        var cardSessionIDs=Set<UUID>()
        for e in events {
            if let q=e.questionID { guard baseline.content.questions.contains(where: { $0.id == q }) else { throw MathFailure.invalid("未知原题引用。") } }
            let sessionKinds=["present","hint","reveal","details","card-open","pause","resume","expanded","interrupted","grade","familiar","undo","suspend","return"]
            guard (e.kind == "grade" || e.outcome == nil), (e.kind == "undo" || e.target == nil),
                  (e.kind == "card-grade" || e.remembered == nil), (e.kind == "present" || e.spotCheck == nil),
                  (["card-recall","card-reveal","card-grade","card-close"].contains(e.kind) || e.cardSession == nil),
                  (sessionKinds.contains(e.kind) || e.session == nil),
                  (e.kind == "card-open" || e.kind.hasPrefix("card-") || e.cardID == nil),
                  (!e.kind.hasPrefix("card-") || e.kind == "card-open" || e.questionID == nil) else { throw MathFailure.invalid("事件携带无关状态。") }
            switch e.kind {
            case "present":
                guard current == nil, let s=e.session, e.questionID == s.questionID, s.shownAt == e.timestamp,
                      !s.hintShown, !s.answerShown, !s.detailsExpanded, !s.paused, !s.assisted, !s.interrupted,
                      starts[s.id] == nil, !familiar.contains(s.questionID) || e.spotCheck == true,
                      baseline.content.questions.first(where: { $0.id == s.questionID })?.eligible == true else { throw MathFailure.invalid("呈现会话或隔离状态无效。") }
                let gap=lastContact[s.questionID].map { e.timestamp.timeIntervalSince($0) >= 86400 } ?? false
                starts[s.id]=(daily[s.questionID].flatMap { FSRS6Shadow.recallProbability($0,day:e.day,timestampMs:MathEngine.ms(e.timestamp)) },all[s.questionID].flatMap { FSRS6Shadow.recallProbability($0,day:e.day,timestampMs:MathEngine.ms(e.timestamp)) },gap && !unknownExposure.contains(s.questionID),e.day,e.utcOffsetSeconds)
                current=s
            case "hint", "reveal", "details", "card-open", "pause", "resume", "expanded", "interrupted":
                guard var expected=current, e.questionID == expected.questionID else { throw MathFailure.invalid("题目会话引用无效。") }
                switch e.kind {
                case "hint": expected.hintShown=true; expected.assisted=true
                case "reveal": expected.answerShown=true
                case "details": guard expected.answerShown else { throw MathFailure.invalid("解析缺少揭晓。") }; expected.detailsExpanded=true
                case "card-open": guard let c=e.cardID, knownCardIDs.contains(c) else { throw MathFailure.invalid("未知知识卡。") }; expected.assisted=true
                case "pause": expected.paused=true; expected.interrupted=true; unknownExposure.insert(expected.questionID)
                case "resume": expected.paused=false
                case "expanded": guard expected.answerShown, let s=e.session else { throw MathFailure.invalid("展开状态缺少揭晓。") }; expected.detailsExpanded=s.detailsExpanded
                case "interrupted": expected.interrupted=true; unknownExposure.insert(expected.questionID)
                default: break
                }
                guard e.session == expected else { throw MathFailure.invalid("题目会话状态与事件不一致。") }; current=expected
            case "grade":
                guard let q=e.questionID, let s=e.session, s == current, s.questionID == q, s.answerShown, let outcome=e.outcome, !(s.assisted && outcome == .independentCorrect) else { throw MathFailure.invalid("评分缺少揭示或辅助标记。") }
                if !undone.contains(e.id) {
                    let key="\(q)|\(e.day)", first=days.insert(key).inserted
                    if let f=starts[s.id], first, f.2, outcome != .assistedCorrect, !s.assisted, !s.interrupted, f.3 == e.day, f.4 == e.utcOffsetSeconds, let d=f.0, let a=f.1 { cleanTargets.append(MathCleanTarget(eventID:e.id,daily:d,all:a,correct:outcome == .independentCorrect)) }
                    if first { daily[q]=try FSRS6Shadow.review(daily[q],day:e.day,rating:outcome.rating,timestampMs:MathEngine.ms(e.timestamp)).memory }
                    all[q]=try FSRS6Shadow.review(all[q],day:e.day,rating:outcome.rating,timestampMs:MathEngine.ms(e.timestamp)).memory
                }
                unknownExposure.remove(q); current=nil
            case "familiar":
                guard let s=e.session, s == current, s.questionID == e.questionID else { throw MathFailure.invalid("熟悉操作会话无效。") }
                if !undone.contains(e.id), let q=e.questionID { familiar.insert(q) }; unknownExposure.remove(s.questionID); current=nil
            case "suspend":
                guard var expected=current else { throw MathFailure.invalid("没有可暂存会话。") }; expected.paused=true; expected.interrupted=true
                guard e.session == expected, e.questionID == expected.questionID else { throw MathFailure.invalid("暂存会话无效。") }
                suspended.append(expected); unknownExposure.insert(expected.questionID); current=nil
            case "return":
                guard current == nil, var expected=suspended.last else { throw MathFailure.invalid("没有可恢复会话。") }; expected.paused=false
                guard e.session == expected, e.questionID == expected.questionID else { throw MathFailure.invalid("返回会话无效。") }
                suspended.removeLast(); current=expected
            case "restore":
                guard let q=e.questionID, baseline.content.questions.first(where: { $0.id == q })?.eligible == true else { throw MathFailure.invalid("隔离题不可恢复。") }; familiar.remove(q)
            case "undo":
                guard let target=events.first(where: { $0.id == e.target }), var restored=target.session else { throw MathFailure.invalid("撤销缺少原会话。") }
                restored.interrupted=true
                guard e.session == restored, e.questionID == restored.questionID else { throw MathFailure.invalid("撤销不能改写暴露事实。") }
                if var abandoned=current, abandoned.id != restored.id { lastContact[abandoned.questionID]=e.timestamp; unknownExposure.insert(abandoned.questionID); abandoned.interrupted=true; abandoned.paused=true; suspended.append(abandoned) }
                unknownExposure.insert(restored.questionID); current=restored
            case "card-queue": guard let c=e.cardID, knownCardIDs.contains(c) else { throw MathFailure.invalid("未知知识卡。") }; cardQueue.insert(c)
            case "card-view": guard current?.assisted != false, let c=e.cardID, knownCardIDs.contains(c), e.questionID == nil else { throw MathFailure.invalid("未知知识卡浏览。") }
            case "card-recall":
                guard current?.assisted != false, currentCard == nil, let c=e.cardID, knownCardIDs.contains(c), cardQueue.contains(c), let s=e.cardSession, s.cardID == c, s.shownAt == e.timestamp, !s.answerShown, cardSessionIDs.insert(s.id).inserted else { throw MathFailure.invalid("知识卡回忆未入队或会话无效。") }; currentCard=s
            case "card-close":
                guard let s=e.cardSession, s == currentCard, e.cardID == s.cardID else { throw MathFailure.invalid("知识卡关闭会话无效。") }; currentCard=nil
            case "card-reveal":
                guard current?.assisted != false, var expected=currentCard, e.cardID == expected.cardID else { throw MathFailure.invalid("知识卡揭晓缺少回忆。") }; expected.answerShown=true
                guard e.cardSession == expected else { throw MathFailure.invalid("知识卡揭晓状态无效。") }; currentCard=expected
            case "card-grade":
                guard current?.assisted != false, let c=e.cardID, knownCardIDs.contains(c), cardQueue.contains(c), let remembered=e.remembered, let s=e.cardSession, currentCard == s, s.cardID == c, s.answerShown else { throw MathFailure.invalid("知识卡评分缺少显式回忆与揭晓。") }
                cardMemories[c]=try FSRS6Shadow.review(cardMemories[c],day:e.day,rating:remembered ? 3 : 1,timestampMs:MathEngine.ms(e.timestamp)).memory; currentCard=nil
            default: throw MathFailure.invalid("未知新体验事件。")
            }
            if let q=e.questionID { lastContact[q]=e.timestamp }
        }
    }
    func queue(now: Date) -> [MathQuestion] {
        baseline.content.questions.filter { $0.eligible && !practiceBlockedIDs.contains($0.id) && !familiar.contains($0.id) && (daily[$0.id]?.dueDay ?? MathEngine.day(now)) <= MathEngine.day(now) }.sorted { (daily[$0.id]?.dueDay ?? 0,$0.id) < (daily[$1.id]?.dueDay ?? 0,$1.id) }
    }
    private mutating func append(_ kind: String, now: Date, session: MathExperienceSession? = nil, questionID: String? = nil, outcome: MathOutcome? = nil, target: UUID? = nil, cardID: String? = nil, remembered: Bool? = nil, spotCheck: Bool? = nil, cardSession: MathCardRecallSession? = nil) throws {
        guard (18_000...50_000).contains(MathEngine.day(now)), events.last == nil || now >= events.last!.timestamp else { throw MathFailure.invalid("请核对系统时间。") }
        let previous=self
        events.append(MathExperienceEvent(utcOffsetSeconds:TimeZone.current.secondsFromGMT(for:now),sequence:events.count+1,kind:kind,timestamp:now,day:MathEngine.day(now),questionID:questionID ?? session?.questionID,session:session,outcome:outcome,target:target,cardID:cardID,remembered:remembered,spotCheck:spotCheck,cardSession:cardSession))
        do { try replay() } catch { self=previous; throw error }
    }
    mutating func present(questionID: String, now: Date, spotCheck: Bool = false) throws {
        guard !practiceBlockedIDs.contains(questionID) else { throw MathFailure.invalid("此题导学暂不可评分，请查看核验说明。") }
        guard current == nil, !familiar.contains(questionID) || spotCheck else { throw MathFailure.invalid("请继续当前题，或显式抽查熟悉题。") }
        try append("present",now:now,session:MathExperienceSession(questionID:questionID,shownAt:now),spotCheck:spotCheck)
    }
    private mutating func update(_ kind: String, now: Date, transform: (inout MathExperienceSession) -> Void) throws {
        guard var s=current else { throw MathFailure.invalid("没有当前题。") }; transform(&s); try append(kind,now:now,session:s)
    }
    mutating func hint(now: Date) throws { try update("hint",now:now) { $0.hintShown=true; $0.assisted=true } }
    mutating func reveal(now: Date) throws { try update("reveal",now:now) { $0.answerShown=true } }
    mutating func details(now: Date) throws { guard current?.answerShown == true else { throw MathFailure.invalid("请先揭晓答案。") }; try update("details",now:now) { $0.detailsExpanded=true } }
    mutating func setExpanded(_ expanded: Bool, now: Date) throws { try update("expanded",now:now) { $0.detailsExpanded=expanded } }
    mutating func openCard(_ id: String, now: Date) throws { guard var s=current else { try append("card-view",now:now,cardID:id); return }; s.assisted=true; try append("card-open",now:now,session:s,cardID:id) }
    mutating func pause(now: Date) throws { guard current != nil else { return }; try update("pause",now:now) { $0.paused=true; $0.interrupted=true } }
    mutating func resume(now: Date) throws { guard current != nil else { return }; try update("resume",now:now) { $0.paused=false } }
    mutating func interrupted(now: Date) throws { guard current != nil else { return }; try update("interrupted",now:now) { $0.interrupted=true } }
    mutating func grade(_ outcome: MathOutcome, now: Date) throws {
        guard let s=current, !practiceBlockedIDs.contains(s.questionID), s.answerShown, !(s.assisted && outcome == .independentCorrect) else { throw MathFailure.invalid("已求助题请选辅助做对或没做对。") }
        try append("grade",now:now,session:s,outcome:outcome)
    }
    mutating func markFamiliar(now: Date) throws { guard let s=current, !practiceBlockedIDs.contains(s.questionID) else { throw MathFailure.invalid("没有当前题。") }; try append("familiar",now:now,session:s) }
    mutating func restore(questionID: String, now: Date) throws { guard !practiceBlockedIDs.contains(questionID), baseline.content.questions.first(where: { $0.id == questionID })?.eligible == true else { throw MathFailure.invalid("隔离题不能恢复评分。") }; try append("restore",now:now,questionID:questionID) }
    mutating func undo(now: Date) throws {
        guard let i=events.lastIndex(where: { ["grade","familiar"].contains($0.kind) }), let s=events[i].session, now.timeIntervalSince(events[i].timestamp) <= 15,
              !events.suffix(from:i+1).contains(where: { !["present","pause","resume","return"].contains($0.kind) }) else { throw MathFailure.invalid("本次操作已不能撤销。") }
        var retained=s; retained.interrupted=true
        try append("undo",now:now,session:retained,target:events[i].id)
    }
    mutating func queueCard(_ id: String, now: Date) throws { try append("card-queue",now:now,cardID:id) }
    mutating func suspend(now: Date) throws { guard var s=current else { throw MathFailure.invalid("没有当前题。") }; s.paused=true; s.interrupted=true; try append("suspend",now:now,session:s) }
    mutating func returnToSuspended(now: Date) throws { guard var s=suspended.last else { throw MathFailure.invalid("没有暂存题。") }; s.paused=false; try append("return",now:now,session:s) }
    mutating func configureBlockedQuestions(_ ids: Set<String>) { practiceBlockedIDs=ids }
    mutating func configureCards(_ ids: Set<String>) throws { let previous=self; knownCardIDs=ids; do { try replay() } catch { self=previous; throw error } }
    mutating func startCardRecall(_ id: String, now: Date) throws { try append("card-recall",now:now,cardID:id,cardSession:MathCardRecallSession(cardID:id,shownAt:now)) }
    mutating func closeCard(sessionID: UUID, now: Date) throws { guard let s=currentCard, s.id == sessionID else { throw MathFailure.invalid("知识卡回忆会话已改变。") }; try append("card-close",now:now,cardID:s.cardID,cardSession:s) }
    mutating func revealCard(sessionID: UUID, now: Date) throws { guard var s=currentCard, s.id == sessionID else { throw MathFailure.invalid("知识卡回忆会话已改变。") }; s.answerShown=true; try append("card-reveal",now:now,cardID:s.cardID,cardSession:s) }
    mutating func gradeCard(_ id: String, remembered: Bool, sessionID: UUID, now: Date) throws { guard let s=currentCard, s.id == sessionID else { throw MathFailure.invalid("知识卡回忆会话已改变。") }; try append("card-grade",now:now,cardID:id,remembered:remembered,cardSession:s) }
}
