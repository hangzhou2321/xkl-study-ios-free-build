import Foundation
import StudyCore

enum MathFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
struct MathSyllabus: Codable, Identifiable { var id: Int; var title: String }
struct MathAsset: Codable, Identifiable { var id: String; var mimeType: String; var width: Int; var height: Int; var dataBase64: String }
struct MathVisual: Codable { var assetID: String; var normalizedCrop: [Double] }
struct MathQuestion: Codable, Identifiable {
    var id: String; var type: String; var syllabusIDs: [Int]; var prompt: String
    var questionText: String? = nil
    var questionVisuals: [MathVisual]; var answerVisuals: [MathVisual]
    var answerText: String?; var solutionNote: String?
    var sourceRefs: [String]; var duplicateAliases: [String]
    var sourceKind: String; var reviewStatus: String
    var eligible: Bool { reviewStatus == "verified" && (!answerVisuals.isEmpty || !(answerText ?? "").isEmpty) }
}
struct MathContent: Codable {
    static let maximumBytes = 256 * 1_024 * 1_024
    var format: String; var id: String; var title: String; var version: String
    var syllabus: [MathSyllabus]; var assets: [MathAsset]; var questions: [MathQuestion]
    static func load(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw MathFailure.invalid("数学包超过256MiB。") }
        let bank = try JSONDecoder().decode(Self.self, from: data); try bank.validate(); return bank
    }
    func validateUpdate(from old: MathContent) throws {
        guard id == old.id else { throw MathFailure.invalid("另一课程不能覆盖既有数学记录。") }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let newQuestions=Dictionary(uniqueKeysWithValues:questions.map { ($0.id,$0) })
        let newAssets=Dictionary(uniqueKeysWithValues:assets.map { ($0.id,$0) })
        let oldAssets=Dictionary(uniqueKeysWithValues:old.assets.map { ($0.id,$0) })
        for q in old.questions {
            guard let updated=newQuestions[q.id], try encoder.encode(q) == encoder.encode(updated) else { throw MathFailure.invalid("已有稳定题ID内容或别名改变，必须使用新ID且不能沿用旧记忆。") }
            for v in q.questionVisuals+q.answerVisuals {
                guard let a=newAssets[v.assetID], let b=oldAssets[v.assetID], try encoder.encode(a) == encoder.encode(b) else { throw MathFailure.invalid("已有题目的源图发生改变，拒绝沿用旧进度。") }
            }
        }
    }
    func validate() throws {
        guard format == "xkl-math-v1", !id.isEmpty, !version.isEmpty, !title.isEmpty,
              !questions.isEmpty, questions.count <= 50_000, Set(questions.map(\.id)).count == questions.count,
              Set(assets.map(\.id)).count == assets.count, Set(syllabus.map(\.id)).count == syllabus.count,
              syllabus.allSatisfy({ (22...34).contains($0.id) }) else { throw MathFailure.invalid("数学包标识或目录无效。") }
        let images = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let nodes = Set(syllabus.map(\.id))
        var aliases = Set(questions.map(\.id))
        for asset in assets {
            guard !asset.id.isEmpty, asset.mimeType == "image/jpeg", (1...6_000).contains(asset.width),
                  (1...6_000).contains(asset.height), asset.width * asset.height <= 12_000_000, let bytes = Data(base64Encoded: asset.dataBase64),
                  bytes.count > 4, bytes.prefix(2) == Data([255,216]), bytes.suffix(2) == Data([255,217]) else {
                throw MathFailure.invalid("数学源图缺失或JPEG无效。")
            }
        }
        for q in questions {
            guard !q.id.isEmpty, !q.type.isEmpty, !q.prompt.isEmpty, !q.questionVisuals.isEmpty,
                  !q.syllabusIDs.isEmpty, Set(q.syllabusIDs).isSubset(of: nodes),
                  ["foundation","reinforcement","both"].contains(q.sourceKind),
                  ["verified","needs-review","missing-answer"].contains(q.reviewStatus),
                  !q.sourceRefs.isEmpty,
                  q.reviewStatus != "verified" || q.eligible else { throw MathFailure.invalid("题目标识、考纲或答案状态无效。") }
            for alias in q.duplicateAliases {
                guard !alias.isEmpty, aliases.insert(alias).inserted else { throw MathFailure.invalid("重复题别名冲突。") }
            }
            for v in q.questionVisuals + q.answerVisuals {
                let c = v.normalizedCrop
                guard images[v.assetID] != nil, c.count == 4, c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                      c[2] > 0, c[3] > 0, c[0]+c[2] <= 1.000001, c[1]+c[3] <= 1.000001 else {
                    throw MathFailure.invalid("题图裁剪越界或引用了缺失源图。")
                }
            }
        }
    }
}
struct MathEvent: Codable {
    var utcOffsetSeconds: Int = TimeZone.current.secondsFromGMT()
    var sequence: Int; var questionID: String; var kind: String; var timestamp: Date; var day: UInt32
    var presentationID: UUID; var grade: Int?; var dailyUpdated: Bool?
    var predictionDaily: Double?; var predictionAll: Double?; var evaluationIncluded: Bool?
    var exclusions: [String]?
}
struct MathArchive: Codable {
    var format = "xkl-math-records-v1"
    var content: MathContent
    var events: [MathEvent] = []
}
struct MathPresentation {
    var id = UUID(); var questionID: String; var shownAt: Date; var day: UInt32
    var dailyPrediction: Double?; var allPrediction: Double?; var exclusions: [String]
    var revealed = false
}
struct MathScore { var count: Int; var brier: Double?; var logLoss: Double? }
struct MathEngine {
    var archive: MathArchive
    private(set) var daily: [String: FSRS6Shadow.Memory] = [:]
    private(set) var all: [String: FSRS6Shadow.Memory] = [:]
    private(set) var presentation: MathPresentation?
    init(archive: MathArchive) throws {
        try archive.content.validate()
        guard archive.format == "xkl-math-records-v1" else { throw MathFailure.invalid("数学档案版本无效。") }
        self.archive = archive
        var lastTime: Date?
        let ids = Set(archive.content.questions.map(\.id))
        var revealed = Set<UUID>(), presented: [UUID:String] = [:], graded = Set<UUID>()
        var presentedDays: [UUID:UInt32] = [:]
        var forecasts: [UUID:(Double?,Double?,[String])] = [:]
        for (index,e) in archive.events.enumerated() {
            guard e.sequence == index+1, ids.contains(e.questionID), e.timestamp.timeIntervalSince1970.isFinite, (1_555_027_200...4_320_172_800).contains(e.timestamp.timeIntervalSince1970),
                  lastTime == nil || e.timestamp >= lastTime!, (18_000...50_000).contains(e.day),
                  ["present","reveal","grade","answer-page","exposure-close"].contains(e.kind) else { throw MathFailure.invalid("数学事件链无效，原记录保留。") }
            guard (-50_400...50_400).contains(e.utcOffsetSeconds),
                  UInt32(floor((e.timestamp.timeIntervalSince1970+Double(e.utcOffsetSeconds))/86_400)) == e.day else { throw MathFailure.invalid("数学事件日期与时区不一致。") }
            lastTime = e.timestamp
            if e.kind == "present" { guard presented[e.presentationID] == nil else { throw MathFailure.invalid("重复呈现事件。") }; presented[e.presentationID] = e.questionID
                presentedDays[e.presentationID]=e.day
                guard archive.content.questions.first(where: { $0.id == e.questionID })?.eligible == true else { throw MathFailure.invalid("待核题不能进入数学评分呈现。") }
                var reasons: [String] = []
                if daily[e.questionID] == nil || all[e.questionID] == nil { reasons.append("cold-start") }
                let prefix=archive.events.prefix(index)
                if let contact=prefix.last(where: { $0.questionID == e.questionID }), e.timestamp.timeIntervalSince(contact.timestamp) < 86_400 { reasons.append("contact-gap-under-24h") }
                if prefix.contains(where: { $0.questionID == e.questionID && $0.day == e.day && ["reveal","answer-page","grade","exposure-close"].contains($0.kind) }) { reasons.append("same-day-exposure") }
                forecasts[e.presentationID]=(daily[e.questionID].flatMap { FSRS6Shadow.recallProbability($0,day:e.day,timestampMs:Self.ms(e.timestamp)) },all[e.questionID].flatMap { FSRS6Shadow.recallProbability($0,day:e.day,timestampMs:Self.ms(e.timestamp)) },reasons)
            }
            else { guard presented[e.presentationID] == e.questionID else { throw MathFailure.invalid("数学事件缺少呈现。") } }
            if e.kind == "reveal" { revealed.insert(e.presentationID) }
            if e.kind == "grade" {
                guard presentedDays[e.presentationID] == e.day, revealed.contains(e.presentationID), graded.insert(e.presentationID).inserted,
                      let g=e.grade, [1,3].contains(g) else { throw MathFailure.invalid("数学评分缺少揭示或重复。") }
                let first = !archive.events.prefix(index).contains { $0.kind == "grade" && $0.questionID == e.questionID && $0.day == e.day }
                guard let forecast=forecasts[e.presentationID],
                      e.predictionDaily == forecast.0, e.predictionAll == forecast.1,
                      e.exclusions == forecast.2,
                      e.evaluationIncluded == (first && forecast.2.isEmpty && forecast.0 != nil && forecast.1 != nil),
                      (e.predictionDaily == nil || (e.predictionDaily!.isFinite && (0...1).contains(e.predictionDaily!))),
                      (e.predictionAll == nil || (e.predictionAll!.isFinite && (0...1).contains(e.predictionAll!))) else { throw MathFailure.invalid("数学预测快照或评价边界与回放不一致。") }
                guard first == e.dailyUpdated else { throw MathFailure.invalid("数学每日评分边界无效。") }
                if first { daily[e.questionID] = try FSRS6Shadow.review(daily[e.questionID],day:e.day,rating:g,timestampMs:Self.ms(e.timestamp)).memory }
                all[e.questionID] = try FSRS6Shadow.review(all[e.questionID],day:e.day,rating:g,timestampMs:Self.ms(e.timestamp)).memory
            }
        }
    }
    mutating func clearPresentation() { presentation=nil }
    static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    static func day(_ date: Date, calendar: Calendar = .current) -> UInt32 {
        guard date.timeIntervalSince1970.isFinite, (1_555_027_200...4_320_172_800).contains(date.timeIntervalSince1970) else { return 0 }
        let c=calendar.dateComponents([.year,.month,.day], from:date)
        var utc=Calendar(identifier:.gregorian); utc.timeZone=TimeZone(secondsFromGMT:0)!
        guard let midnight=utc.date(from:c) else { return 0 }
        return UInt32(max(0, midnight.timeIntervalSince1970 / 86_400))
    }
    var currentQuestion: MathQuestion? { archive.content.questions.first { $0.id == presentation?.questionID } }
    func queue(now: Date, syllabus: Int? = nil, source: String? = nil, wrongOnly: Bool = false) -> [MathQuestion] {
        let day=Self.day(now)
        return archive.content.questions.filter { q in
            guard q.eligible, syllabus == nil || q.syllabusIDs.contains(syllabus!), source == nil || q.sourceKind == source || q.sourceKind == "both" else { return false }
            let grades=archive.events.filter { $0.questionID == q.id && $0.kind == "grade" }
            if wrongOnly && grades.last?.grade != 1 { return false }
            if grades.isEmpty { return true }
            if let last=grades.last, last.day == day { return last.grade == 1 && now.timeIntervalSince(last.timestamp) >= 600 }
            return (daily[q.id]?.dueDay ?? day) <= day
        }.sorted { a,b in
            let am=daily[a.id],bm=daily[b.id]
            if (am == nil) != (bm == nil) { return am == nil }
            if am?.dueDay != bm?.dueDay { return (am?.dueDay ?? 0) < (bm?.dueDay ?? 0) }
            return a.id < b.id
        }
    }
    mutating func present(_ q: MathQuestion, now: Date) throws {
        guard q.eligible, archive.content.questions.contains(where: { $0.id == q.id }) else { throw MathFailure.invalid("此题待核，不能评分。") }
        try checkClock(now)
        // A reveal left open by a killed app has unknown exposure end. Close
        // it conservatively at this new contact, so it cannot create a clean target.
        let reveals=archive.events.filter { $0.questionID == q.id && $0.kind == "reveal" }
        for exposure in reveals where !archive.events.contains(where: { $0.presentationID == exposure.presentationID && ["grade","exposure-close"].contains($0.kind) }) {
            archive.events.append(MathEvent(utcOffsetSeconds:TimeZone.current.secondsFromGMT(for:now),sequence:archive.events.count+1,questionID:q.id,kind:"exposure-close",timestamp:now,day:Self.day(now),presentationID:exposure.presentationID))
        }
        let d=Self.day(now), prior=archive.events.last { $0.questionID == q.id }
        var reasons: [String] = []
        if daily[q.id] == nil || all[q.id] == nil { reasons.append("cold-start") }
        if let prior, now.timeIntervalSince(prior.timestamp) < 86_400 { reasons.append("contact-gap-under-24h") }
        if archive.events.contains(where: { $0.questionID == q.id && $0.day == d && ["reveal","answer-page","grade","exposure-close"].contains($0.kind) }) { reasons.append("same-day-exposure") }
        let p=MathPresentation(questionID:q.id,shownAt:now,day:d,
            dailyPrediction:daily[q.id].flatMap { FSRS6Shadow.recallProbability($0,day:d,timestampMs:Self.ms(now)) },
            allPrediction:all[q.id].flatMap { FSRS6Shadow.recallProbability($0,day:d,timestampMs:Self.ms(now)) },exclusions:reasons)
        presentation=p; append(kind:"present",now:now,p:p)
    }
    mutating func reveal(now: Date) throws {
        try checkClock(now); guard var p=presentation, !p.revealed else { return }; p.revealed=true; presentation=p
        append(kind:"reveal",now:now,p:p)
    }
    mutating func answerPage(now: Date) throws {
        try checkClock(now); guard let p=presentation, p.revealed else { throw MathFailure.invalid("先独立作答，再翻解析。") }
        append(kind:"answer-page",now:now,p:p)
    }
    mutating func grade(remembered: Bool, now: Date) throws {
        try checkClock(now)
        guard let p=presentation, p.revealed, Self.day(now) == p.day else { throw MathFailure.invalid("请重新打开此题并独立作答后评分。") }
        let rating=remembered ? 3:1
        let first = !archive.events.contains { $0.questionID == p.questionID && $0.day == p.day && $0.kind == "grade" }
        if first { daily[p.questionID] = try FSRS6Shadow.review(daily[p.questionID],day:p.day,rating:rating,timestampMs:Self.ms(now)).memory }
        all[p.questionID] = try FSRS6Shadow.review(all[p.questionID],day:p.day,rating:rating,timestampMs:Self.ms(now)).memory
        var e=event(kind:"grade",now:now,p:p); e.grade=rating; e.dailyUpdated=first
        e.predictionDaily=p.dailyPrediction; e.predictionAll=p.allPrediction
        e.exclusions=p.exclusions; e.evaluationIncluded=first && p.exclusions.isEmpty && p.dailyPrediction != nil && p.allPrediction != nil
        archive.events.append(e); presentation=nil
    }
    func score(allRatings: Bool) -> MathScore {
        let rows=archive.events.filter { $0.kind == "grade" && $0.evaluationIncluded == true }
        let pairs=rows.compactMap { e -> (Double,Double)? in guard let p=allRatings ? e.predictionAll:e.predictionDaily else { return nil }; return (p,e.grade == 3 ? 1:0) }
        guard !pairs.isEmpty else { return MathScore(count:0,brier:nil,logLoss:nil) }
        let n=Double(pairs.count)
        return MathScore(count:pairs.count,brier:pairs.reduce(0) { $0+pow($1.0-$1.1,2) }/n,
            logLoss:pairs.reduce(0) { $0-log($1.1 == 1 ? max(1e-15,$1.0):max(1e-15,1-$1.0)) }/n)
    }
    private func checkClock(_ now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, (18_000...50_000).contains(Self.day(now)),
              archive.events.last == nil || now >= archive.events.last!.timestamp else { throw MathFailure.invalid("数学记录检测到时间倒退，请核对手机日期。") }
    }
    private func event(kind: String, now: Date, p: MathPresentation) -> MathEvent {
        MathEvent(utcOffsetSeconds:TimeZone.current.secondsFromGMT(for:now),sequence:archive.events.count+1,questionID:p.questionID,kind:kind,timestamp:now,day:Self.day(now),presentationID:p.id)
    }
    private mutating func append(kind: String, now: Date, p: MathPresentation) { archive.events.append(event(kind:kind,now:now,p:p)) }
}
