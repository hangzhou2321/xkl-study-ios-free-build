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

    static func prompt(subject: String, title: String, question: String, answer: String) -> String {
        func compact(_ value: String, limit: Int) -> String {
            let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        return """
        我在复习\(compact(subject, limit: 30))的「\(compact(title, limit: 120))」。
        卡片问法：\(compact(question, limit: 420))
        卡片答案：\(compact(answer, limit: 700))

        请用中文快速帮我弄懂这张卡。先用一句话讲核心，再说最容易弄混的条件。需要公式时说明各符号。最后给一个让我用自己的话回答的短问题。
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
