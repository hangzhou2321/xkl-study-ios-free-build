import Foundation
import CoreFoundation
import StudyCore

enum StudyNovelError: LocalizedError {
    case unreadableText, noChapters, invalidFile, inconsistentAttempts

    var errorDescription: String? {
        switch self {
        case .unreadableText: return "无法读取小说。请选择 UTF-8、UTF-16 或 GB18030 编码的 TXT。"
        case .noChapters: return "没找到章节。请让“第1章 标题”这样的章节名单独占一行。"
        case .invalidFile: return "小说或阅读进度文件无法核对。"
        case .inconsistentAttempts: return "学习记录已变化，请重新打开 App 核对追更进度。"
        }
    }
}

struct StudyNovel: Equatable, Identifiable {
    struct Chapter: Equatable {
        let title: String
        let text: String
    }

    static let maximumFileSize = 16 * 1024 * 1024
    let id: String
    let title: String
    let chapters: [Chapter]

    private static let numerals = Set("0123456789０１２３４５６７８９零〇一二三四五六七八九十百千万萬两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟")

    private static func isHeading(_ line: String) -> Bool {
        guard let last = line.last, line.count <= 88, !"。．，、；”」』".contains(last) else { return false }
        if line == "楔子" || line == "序章" || line == "终章" || line == "終章" || line == "尾声" || line == "尾聲" {
            return true
        }
        guard line.first == "第" else { return false }
        let remainder = line.dropFirst().drop(while: \.isWhitespace)
        let number = remainder.prefix(while: numerals.contains)
        guard !number.isEmpty,
              let unit = remainder.dropFirst(number.count).drop(while: \.isWhitespace).first else { return false }
        return "章节節回".contains(unit)
    }

    static func parse(_ data: Data, title: String) throws -> Self {
        guard !data.isEmpty, data.count <= maximumFileSize else { throw StudyNovelError.invalidFile }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let decoded = hasUTF16BOM ? String(data: data, encoding: .utf16) :
            (String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb))
        guard let decoded, !decoded.contains("\0") else { throw StudyNovelError.unreadableText }
        let hardWrapped = decoded.contains("*** START OF THE PROJECT GUTENBERG EBOOK")
        var chapters = [Chapter]()
        var chapterTitle: String?
        var lines = [String]()

        func appendChapter() {
            guard let chapterTitle else { return }
            var body = ""
            var previousLineWasEmpty = true
            for line in lines {
                let empty = line.trimmingCharacters(in: .whitespaces).isEmpty
                if !hardWrapped || empty || previousLineWasEmpty || line.first?.isWhitespace == true {
                    body.append("\n")
                }
                body.append(line)
                previousLineWasEmpty = empty
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { chapters.append(.init(title: chapterTitle, text: body)) }
        }

        decoded.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if trimmed.hasPrefix("*** END OF THE PROJECT GUTENBERG EBOOK") {
                stop = true
            } else if isHeading(trimmed) {
                appendChapter()
                chapterTitle = trimmed
                lines.removeAll(keepingCapacity: true)
            } else if chapterTitle != nil {
                lines.append(line)
            }
        }
        appendChapter()
        guard !chapters.isEmpty else { throw StudyNovelError.noChapters }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(id: StudySHA256.hex(data), title: name.isEmpty ? "未命名小说" : name, chapters: chapters)
    }
}

/// The identity and date of a saved learning action, without copying its grade.
struct StudyNovelActivity {
    let id: UUID
    let itemID: String
    let at: Date
    private let recordedDay: UInt32?

    var day: UInt32? {
        recordedDay ?? (try? ConceptCalendar.studyDay(at)).map(UInt32.init)
    }

    init(_ rating: ProfessionalRecallAttempt, subject: String) {
        id = rating.id
        itemID = subject + ":" + rating.cardID
        at = rating.at
        recordedDay = rating.day
    }

    init?(publicAnswer: ExamAttempt) {
        guard publicAnswer.mode == "answer", !publicAnswer.selectedOptions.isEmpty,
              publicAnswer.grade != nil, let gradedAt = publicAnswer.gradedAt else { return nil }
        id = publicAnswer.id
        itemID = "publicQuestions:" + publicAnswer.bankID + ":" + publicAnswer.questionID
        at = gradedAt
        recordedDay = nil
    }
}

struct StudyNovelProgress: Codable, Equatable {
    typealias Records = [String: [StudyNovelActivity]]

    static let cardsPerChapter = 25

    struct Cursor: Codable, Equatable {
        let count: Int
        let lastAttempt: UUID?

        init(_ attempts: [StudyNovelActivity]) {
            count = attempts.count
            lastAttempt = attempts.last?.id
        }
    }

    private(set) var cursors: [String: Cursor] = [:]
    private(set) var cardsInChapter: Set<String> = []
    private var countedToday: Set<String> = []
    private var studyDay: UInt32?
    private(set) var unlocked = 0
    private(set) var readChapters: Set<Int> = []
    private(set) var lastOpened: Int?
    private(set) var readingPositions: [Int: Int] = [:]

    mutating func startFrom(_ records: Records) {
        cursors = records.mapValues(Cursor.init)
    }

    mutating func consume(_ records: Records, chapterCount: Int) throws {
        guard unlocked < chapterCount else { return }
        var pending: [(source: String, index: Int, activity: StudyNovelActivity)] = []
        var updated = cursors
        for (source, attempts) in records {
            updated[source] = Cursor(attempts)
            guard let cursor = cursors[source] else { continue }
            guard cursor.count >= 0, cursor.count <= attempts.count,
                  (cursor.count == 0 ? nil : attempts[cursor.count - 1].id) == cursor.lastAttempt else {
                throw StudyNovelError.inconsistentAttempts
            }
            pending += (cursor.count..<attempts.count).map { (source, $0, attempts[$0]) }
        }

        pending.sort {
            if $0.activity.at != $1.activity.at { return $0.activity.at < $1.activity.at }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.index < $1.index
        }
        cursors = updated
        for (_, _, attempt) in pending {
            guard let day = attempt.day else { continue }
            if let studyDay, day < studyDay { continue }
            if studyDay != day {
                studyDay = day
                countedToday.removeAll(keepingCapacity: true)
            }
            guard countedToday.insert(attempt.itemID).inserted else { continue }
            cardsInChapter.insert(attempt.itemID)
            if cardsInChapter.count == Self.cardsPerChapter {
                unlocked += 1
                cardsInChapter.removeAll(keepingCapacity: true)
                if unlocked == chapterCount { break }
            }
        }
    }

    mutating func open(_ index: Int) {
        if (0..<unlocked).contains(index) { lastOpened = index }
    }

    mutating func finish(_ index: Int) {
        if (0..<unlocked).contains(index) {
            readChapters.insert(index)
            readingPositions[index] = nil
        }
    }

    mutating func bookmark(_ index: Int, paragraph: Int) {
        if (0..<unlocked).contains(index), paragraph >= 0, !readChapters.contains(index) {
            readingPositions[index] = paragraph
        }
    }

    func validate(chapterCount: Int) throws {
        guard (0...chapterCount).contains(unlocked), cardsInChapter.count < Self.cardsPerChapter,
              readChapters.allSatisfy({ (0..<unlocked).contains($0) }),
              readingPositions.allSatisfy({ (0..<unlocked).contains($0.key) && $0.value >= 0 }),
              lastOpened.map({ (0..<unlocked).contains($0) }) ?? true,
              cursors.values.allSatisfy({ $0.count >= 0 && ($0.count == 0) == ($0.lastAttempt == nil) }) else {
            throw StudyNovelError.invalidFile
        }
    }
}
