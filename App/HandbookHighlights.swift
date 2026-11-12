import Foundation
import StudyCore

/// Keep source content unchanged; this is only its existing mobile presentation.
func handbookDisplayText(_ source: String) -> String {
    var result = "", afterSemicolon = false
    for character in source {
        if afterSemicolon && character != "\n" && character != "\r" && character != "\r\n" { result.append("\n") }
        result.append(character)
        afterSemicolon = character == "；" || character == ";"
    }
    return result
}

/// Personal marks use stable card/field IDs and a hash of the displayed field.
/// Old marks remain in the file if a future course revision changes that field;
/// a mark is never applied to different text merely because an offset fits.
struct HandbookHighlightSpan: Codable, Equatable {
    let cardID: String
    let fieldID: String
    let textSHA256: String
    let location: Int
    let length: Int
}

struct HandbookHighlightState: Codable, Equatable {
    var format = "xkl-handbook-highlights-v1"
    let subject: ConceptSubject
    var spans: [HandbookHighlightSpan] = []

    func validate() throws {
        guard format == "xkl-handbook-highlights-v1", spans.count <= 100_000 else {
            throw ExamError.invalid("个人标红记录格式不正确，已保留原文件。")
        }
        var previous: HandbookHighlightSpan?
        for span in spans {
            guard !span.cardID.isEmpty, span.cardID.count <= 200,
                  !span.fieldID.isEmpty, span.fieldID.count <= 200,
                  span.textSHA256.count == 64,
                  span.textSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  span.location >= 0, span.length > 0,
                  span.location <= 10_000_000, span.length <= 10_000_000 - span.location else {
                throw ExamError.invalid("个人标红范围不正确，已保留原文件。")
            }
            if let old = previous {
                guard Self.before(old, span) else { throw ExamError.invalid("个人标红记录顺序或范围重复。") }
                if Self.sameField(old, span) {
                    guard old.location + old.length < span.location else {
                        throw ExamError.invalid("个人标红范围重叠或未合并。")
                    }
                }
            }
            previous = span
        }
    }

    private static func sameField(_ a: HandbookHighlightSpan, _ b: HandbookHighlightSpan) -> Bool {
        a.cardID == b.cardID && a.fieldID == b.fieldID && a.textSHA256 == b.textSHA256
    }
    private static func before(_ a: HandbookHighlightSpan, _ b: HandbookHighlightSpan) -> Bool {
        if a.cardID != b.cardID { return a.cardID < b.cardID }
        if a.fieldID != b.fieldID { return a.fieldID < b.fieldID }
        if a.textSHA256 != b.textSHA256 { return a.textSHA256 < b.textSHA256 }
        return a.location < b.location
    }
    /// Foundation's NSRange-to-String conversion is not consistent across OS
    /// releases for an offset inside a surrogate pair. Count actual Swift
    /// Characters so both ends are always whole user-visible characters.
    private static func characterBoundary(_ target: Int, in text: String) -> Bool {
        guard target >= 0 else { return false }
        var offset = 0
        if target == 0 { return true }
        for character in text {
            offset += String(character).utf16.count
            if offset == target { return true }
            if offset > target { return false }
        }
        return false
    }
    static func validCharacterRange(_ range: NSRange, in text: String) -> Bool {
        let total = text.utf16.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= total, range.length <= total - range.location else { return false }
        return characterBoundary(range.location, in: text) && characterBoundary(range.location + range.length, in: text)
    }
    static func canonical(_ input: [HandbookHighlightSpan]) -> [HandbookHighlightSpan] {
        var result: [HandbookHighlightSpan] = []
        for item in input.sorted(by: before) {
            if let old = result.last, sameField(old, item), item.location <= old.location + old.length {
                let end = max(old.location + old.length, item.location + item.length)
                result[result.count - 1] = .init(cardID: old.cardID, fieldID: old.fieldID,
                    textSHA256: old.textSHA256, location: old.location, length: end - old.location)
            } else { result.append(item) }
        }
        return result
    }

    /// Adds or removes only the selected intersections with real card fields.
    /// The range is UTF-16, matching iOS text selection; surrogate/grapheme
    /// boundaries are checked before anything is committed.
    func applying(_ document: HandbookHighlightDocument, selection: NSRange, remove: Bool) throws -> Self {
        try validate()
        let total = (document.text as NSString).length
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.location <= total, selection.length <= total - selection.location,
              Self.validCharacterRange(selection, in: document.text), Range(selection, in: document.text) != nil else {
            throw ExamError.invalid("请先选择要标红或取消标红的文字。")
        }
        var next = spans, touched = false
        for field in document.fields {
            let part = NSIntersectionRange(selection, field.range)
            guard part.length > 0 else { continue }
            let local = NSRange(location: part.location - field.range.location, length: part.length)
            guard Self.validCharacterRange(local, in: field.text), Range(local, in: field.text) != nil else {
                throw ExamError.invalid("选中文字不完整，请重新选择。")
            }
            touched = true
            let hash = Self.hash(field.text)
            let addition = HandbookHighlightSpan(cardID: document.cardID, fieldID: field.id,
                textSHA256: hash, location: local.location, length: local.length)
            if !remove { next.append(addition); continue }
            var retained: [HandbookHighlightSpan] = []
            for old in next {
                guard Self.sameField(old, addition) else { retained.append(old); continue }
                let a = old.location, b = old.location + old.length
                let c = addition.location, d = addition.location + addition.length
                if b <= c || d <= a { retained.append(old); continue }
                if a < c { retained.append(.init(cardID: old.cardID, fieldID: old.fieldID,
                    textSHA256: old.textSHA256, location: a, length: c - a)) }
                if d < b { retained.append(.init(cardID: old.cardID, fieldID: old.fieldID,
                    textSHA256: old.textSHA256, location: d, length: b - d)) }
            }
            next = retained
        }
        guard touched else { throw ExamError.invalid("请选择卡片正文中的文字。") }
        var result = self; result.spans = Self.canonical(next); try result.validate(); return result
    }

    static func hash(_ text: String) -> String { StudySHA256.hex(Data(text.utf8)) }

    struct Run: Equatable { let text: String; let red: Bool; var yellow = false }
    /// A caller can restrict output to a visible cue, so hidden answer text is
    /// never passed to SwiftUI or to an accessibility label on the front.
    func runs(cardID: String, fieldID: String, text: String, visible: NSRange? = nil,
              sourceSpans: [HandbookHighlightSpan] = [],
              sourceYellowSpans: [HandbookHighlightSpan] = []) -> [Run] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let view = visible ?? whole
        guard view.location != NSNotFound, view.location >= 0, view.length >= 0,
              view.location <= whole.length, view.length <= whole.length - view.location,
              Self.validCharacterRange(view, in: text), Range(view, in: text) != nil else { return [] }
        let hash = Self.hash(text)
        // The source marks are presentation metadata, never written into the
        // separately persisted, user-controlled highlight file.
        func matching(_ input: [HandbookHighlightSpan]) -> [NSRange] {
            Self.canonical(input.filter {
                $0.cardID == cardID && $0.fieldID == fieldID && $0.textSHA256 == hash
            }).compactMap { span in
                let range = NSRange(location: span.location, length: span.length)
                guard Self.validCharacterRange(range, in: text), Range(range, in: text) != nil else { return nil }
                let clipped = NSIntersectionRange(view, range)
                return clipped.length > 0 ? clipped : nil
            }
        }
        let red = matching(spans + sourceSpans), yellow = matching(sourceYellowSpans)
        let boundaries = Set([view.location, view.location + view.length] +
            (red + yellow).flatMap { [$0.location, $0.location + $0.length] }).sorted()
        var runs: [Run] = []
        for (a, b) in zip(boundaries, boundaries.dropFirst()) where b > a {
            let range = NSRange(location: a, length: b - a)
            guard let indexRange = Range(range, in: text) else { continue }
            let isRed = red.contains { NSLocationInRange(a, $0) }
            let isYellow = yellow.contains { NSLocationInRange(a, $0) }
            let part = String(text[indexRange])
            if let last = runs.last, last.red == isRed && last.yellow == isYellow {
                runs[runs.count - 1] = .init(text: last.text + part, red: isRed, yellow: isYellow)
            } else { runs.append(.init(text: part, red: isRed, yellow: isYellow)) }
        }
        return runs
    }
}

struct HandbookHighlightDocument {
    struct Field { let id: String; let text: String; let range: NSRange }
    let cardID: String
    private(set) var text = ""
    private(set) var fields: [Field] = []

    init(card: HandbookCard, guide: HandbookCardPackage.MemoryGuide?) {
        cardID = card.id
        appendLabel("卡片标题\n"); append(card.title, "title"); appendLabel("\n\n")
        if let guide {
            appendLabel("核心内容\n")
            if let explanation = guide.explanation, !explanation.isEmpty {
                append(explanation, "guide.explanation"); appendLabel("\n")
            }
            for (index, row) in guide.rows.enumerated() {
                append(row.cue, "guide.rows.\(index).cue"); appendLabel("：")
                append(row.answer, "guide.rows.\(index).answer"); appendLabel("\n")
            }
            if let mnemonic = guide.mnemonic, !mnemonic.isEmpty {
                appendLabel("记忆提示："); append(mnemonic, "guide.mnemonic"); appendLabel("\n")
            }
            appendLabel("\n")
        }
        appendLabel("完整内容\n")
        if guide == nil { append(card.prompt, "prompt"); appendLabel("\n") }
        if card.answerSummary != "讲义原文" { append(card.answerSummary, "summary"); appendLabel("\n") }
        for (index, block) in card.blocks.enumerated() {
            let base = "blocks.\(index)"
            if !block.title.isEmpty { append(block.title, base + ".title"); appendLabel("\n") }
            if block.kind == "text", let value = block.text { append(value, base + ".text"); appendLabel("\n") }
            if ["bullets", "steps", "diagram"].contains(block.kind) {
                for (i, item) in (block.items ?? []).enumerated() { append(item, base + ".items.\(i)"); appendLabel("\n") }
            }
            if ["table", "keyValues"].contains(block.kind) {
                if block.kind == "table", let columns = block.columns {
                    for (i, value) in columns.enumerated() { append(value, base + ".columns.\(i)"); appendLabel(i + 1 == columns.count ? "\n" : "　") }
                }
                for (i, row) in (block.rows ?? []).enumerated() {
                    for (j, value) in row.enumerated() { append(value, base + ".rows.\(i).\(j)"); appendLabel(j + 1 == row.count ? "\n" : "：") }
                }
            }
        }
        for (index, example) in card.examples.enumerated() {
            let base = "examples.\(index)"
            appendLabel("\n原例\n"); append(example.title, base + ".title"); appendLabel("\n")
            append(example.prompt, base + ".prompt"); appendLabel("\n")
            for (i, step) in example.steps.enumerated() { append(step, base + ".steps.\(i)"); appendLabel("\n") }
            append(example.answer, base + ".answer"); appendLabel("\n")
            if let note = example.sourceIssueNote { append(note, base + ".note"); appendLabel("\n") }
        }
        for (i, note) in card.sourceNotes.enumerated() { append(note, "sourceNotes.\(i)"); appendLabel("\n") }
    }
    private mutating func appendLabel(_ value: String) { text.append(value) }
    private mutating func append(_ raw: String, _ id: String) {
        let value = handbookDisplayText(raw)
        guard !value.isEmpty else { return }
        let range = NSRange(location: (text as NSString).length, length: (value as NSString).length)
        fields.append(.init(id: id, text: value, range: range)); text.append(value)
    }
}
