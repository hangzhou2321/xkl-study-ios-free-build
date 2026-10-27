import Foundation

/// Display-only cues. Hidden answers are never passed to a Text or accessibility label.
/// This projection neither edits a card definition nor creates a smaller scheduled unit.
enum HandbookRecallCue {
    struct Line: Equatable {
        let prefix: String
        let hidesAnswer: Bool
    }
    enum Cell: Equatable {
        case visible(String)
        case hidden
    }

    static func lines(_ source: String) -> [Line] {
        var pieces: [String] = [], piece = "", closers: [Character] = []
        let pairs: [Character: Character] = ["（": "）", "(": ")", "[": "]", "【": "】", "{": "}", "「": "」", "『": "』"]
        for character in source {
            piece.append(character)
            if let close = pairs[character] { closers.append(close) }
            else if closers.last == character { closers.removeLast() }
            if closers.isEmpty && ["；", ";", "\n"].contains(character) {
                pieces.append(piece); piece = ""
            }
        }
        pieces.append(piece)
        return pieces.compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != ";", text != "；" else { return nil }
            let characters = Array(text)
            var nested: [Character] = []
            for (index, character) in characters.enumerated() {
                if let close = pairs[character] { nested.append(close); continue }
                if nested.last == character { nested.removeLast(); continue }
                guard nested.isEmpty, index > 0, character == "：" || character == ":" else { continue }
                // A ratio, time or URL delimiter is answer text, not a source label.
                if character == ":", index + 1 < characters.count,
                   (characters[index + 1] == "/" || (characters[index - 1].isNumber && characters[index + 1].isNumber)) { continue }
                let suffix = String(characters.dropFirst(index + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return Line(prefix: String(characters.prefix(index + 1)), hidesAnswer: !suffix.isEmpty)
            }
            return Line(prefix: "", hidesAnswer: true)
        }
    }

    static func cell(_ source: String, column: Int) -> Cell {
        // Keep the row label and all original blank cells; hide every answer column.
        column == 0 || source.isEmpty ? .visible(source) : .hidden
    }
}
