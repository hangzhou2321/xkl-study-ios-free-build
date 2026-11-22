import Foundation

struct CardLookupSession: Codable, Equatable, Identifiable {
    static let duration: TimeInterval = 90

    struct Progress: Codable, Equatable {
        let index: Int
        let target: Int
        let slotStart: Date
    }

    let id: UUID
    let subject: String
    let cardID: String
    let presentationID: UUID
    let startedAt: Date
    let progress: Progress?
    private(set) var leftApp = false
    private(set) var returnedAt: Date?

    var deadline: Date { startedAt.addingTimeInterval(Self.duration) }
    var timedOut: Bool { returnedAt.map { $0 >= deadline } ?? false }

    init(id: UUID = UUID(), subject: String, cardID: String, presentationID: UUID,
         startedAt: Date, progress: Progress?) {
        self.id = id
        self.subject = subject
        self.cardID = cardID
        self.presentationID = presentationID
        self.startedAt = startedAt
        self.progress = progress
    }

    @discardableResult mutating func noteDeparture() -> Bool {
        guard !leftApp, returnedAt == nil else { return false }
        leftApp = true
        return true
    }

    @discardableResult mutating func noteReturn(at now: Date) -> Bool {
        guard returnedAt == nil else { return false }
        returnedAt = max(startedAt, now)
        return true
    }

    func matches(subject: String, cardID: String, presentationID: UUID) -> Bool {
        self.subject == subject && self.cardID == cardID && self.presentationID == presentationID
    }

    static func returnID(from url: URL) -> UUID? {
        guard url.scheme == "xklstudy", url.host == "lookup", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    var notificationID: String { "card-lookup-" + id.uuidString }

    enum PromptPurpose { case explain, rewrite }

    static func prompt(subject: String, title: String, question: String, answer: String,
                       purpose: PromptPurpose = .explain) -> String {
        func compact(_ value: String, limit: Int) -> String {
            let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        let instruction: String
        switch purpose {
        case .explain:
            instruction = "先用一句人话解释。点明题干给了什么条件、第一时间该想到哪一步。用一个最小例子讲原因，保留公式和适用条件。最后给一道只改一个条件的短题，让我用自己的话回答，等我作答后再给答案。"
        case .rewrite:
            instruction = "把现有内容改写成一张国网备考短卡。输出「题干线索」「第一反应」「答案」，必要时加「适用条件」。只考一个可独立回答的判断，保留术语、公式及条件。用一句话讲清就停。遇到图、表或精确数值，明确应保留的出处与内容。材料没给出的结论标待核。"
        }
        return """
        我在复习\(compact(subject, limit: 30))的「\(compact(title, limit: 120))」。
        卡片问法：\(compact(question, limit: 420))
        卡片答案：\(compact(answer, limit: 700))

        \(instruction)
        """
    }

    static func validRecap(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 200 && clean.rangeOfCharacter(from: .alphanumerics) != nil
    }
}

/// Explicit requests for old assisted grades identified from a separate audit.
struct LookupRecoveryInbox: Codable {
    struct Entry: Codable, Equatable {
        let subject: String
        let cardID: String
        let attemptID: UUID
    }
    let format: String
    let entries: [Entry]

    static func load(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw InvalidRequest() }
        let file = try JSONDecoder().decode(Self.self, from: data)
        guard file.format == "xkl-lookup-recovery-v1", (1...250).contains(file.entries.count),
              Set(file.entries.map(\.attemptID)).count == file.entries.count,
              file.entries.allSatisfy({ ($0.subject == "computer" || $0.subject == "power")
                  && (1...200).contains($0.cardID.count) }) else { throw InvalidRequest() }
        return file
    }

    struct InvalidRequest: LocalizedError {
        var errorDescription: String? { "这份旧查卡恢复清单无法读取。" }
    }
}
