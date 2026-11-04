import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

final class HandbookHighlightTests: XCTestCase {
    private func fixture(_ id: String = "synthetic-card") -> (HandbookCard, HandbookCardPackage.MemoryGuide) {
        let card = HandbookCard(id: id, sourceGroupIDs: ["synthetic-group"], topicNumber: 1,
            title: "示例标题", prompt: "为什么需要😀设备？", answerSummary: "范围：甲；条件：乙",
            blocks: [
                .init(title: "列表", kind: "bullets", items: ["第一条", "第二条"]),
                .init(title: "表", kind: "table", columns: ["名称", "说明"], rows: [["甲", "甲的内容"], ["乙", "乙的内容"]]),
                .init(title: "关系图", kind: "diagram", text: "branch", items: ["根", "左", "右"], collapsed: true)
            ], sourcePages: [1], examples: [.init(title: "示例", prompt: "问题", steps: ["步骤一"], answer: "结果", sourcePage: 1)],
            sourceNotes: ["原书注记"], chapterID: "chapter")
        let guide = HandbookCardPackage.MemoryGuide(cardID: id, explanation: "先理解", rows: [
            .init(cue: "名称", answer: "变压器"), .init(cue: "条件", answer: "甲😀乙")], mnemonic: "记忆提示")
        return (card, guide)
    }
    private func field(_ document: HandbookHighlightDocument, _ id: String) throws -> HandbookHighlightDocument.Field {
        try XCTUnwrap(document.fields.first { $0.id == id })
    }
    private func selected(_ field: HandbookHighlightDocument.Field, _ text: String) throws -> NSRange {
        let local = (field.text as NSString).range(of: text)
        guard local.location != NSNotFound else { throw ExamError.invalid("synthetic selection missing") }
        return NSRange(location: field.range.location + local.location, length: local.length)
    }

    func testFieldMappingAndCrossFieldSelectionPreserveEveryOriginalText() throws {
        let (card, guide) = fixture(), before = card
        let doc = HandbookHighlightDocument(card: card, guide: guide)
        let names = Set(doc.fields.map(\.id))
        XCTAssertEqual(names.count, doc.fields.count)
        for id in ["title", "guide.explanation", "guide.rows.0.cue", "guide.rows.0.answer",
                   "guide.mnemonic", "summary", "blocks.0.items.1", "blocks.1.columns.0",
                   "blocks.1.rows.1.1", "blocks.2.items.2", "examples.0.steps.0", "sourceNotes.0"] {
            XCTAssertTrue(names.contains(id), id)
        }
        XCTAssertFalse(names.contains("prompt")) // a card with a guide does not show its generic prompt
        XCTAssertTrue(HandbookHighlightDocument(card: card, guide: nil).fields.contains { $0.id == "prompt" })
        XCTAssertEqual(try field(doc, "summary").text, "范围：甲；\n条件：乙")
        let cue = try field(doc, "guide.rows.0.cue"), answer = try field(doc, "guide.rows.0.answer")
        let selection = NSRange(location: cue.range.location, length: answer.range.location + answer.range.length - cue.range.location)
        let state = try HandbookHighlightState(subject: .computer).applying(doc, selection: selection, remove: false)
        XCTAssertEqual(state.spans.count, 2)
        XCTAssertEqual(state.runs(cardID: card.id, fieldID: cue.id, text: cue.text), [.init(text: "名称", red: true)])
        XCTAssertEqual(state.runs(cardID: card.id, fieldID: answer.id, text: answer.text), [.init(text: "变压器", red: true)])
        XCTAssertEqual(card, before)
    }

    func testAddOverlapRemovePartAndRepeatedSelectionAreDeterministic() throws {
        let (card, guide) = fixture(), doc = HandbookHighlightDocument(card: card, guide: guide)
        let f = try field(doc, "guide.rows.0.answer")
        var state = HandbookHighlightState(subject: .computer)
        state = try state.applying(doc, selection: selected(f, "变压"), remove: false)
        state = try state.applying(doc, selection: selected(f, "压器"), remove: false)
        XCTAssertEqual(state.spans.count, 1)
        XCTAssertEqual(state.runs(cardID: card.id, fieldID: f.id, text: f.text), [.init(text: "变压器", red: true)])
        let once = state
        state = try state.applying(doc, selection: selected(f, "压器"), remove: false)
        XCTAssertEqual(state, once)
        state = try state.applying(doc, selection: selected(f, "压"), remove: true)
        XCTAssertEqual(state.runs(cardID: card.id, fieldID: f.id, text: f.text), [
            .init(text: "变", red: true), .init(text: "压", red: false), .init(text: "器", red: true)])
        state = try state.applying(doc, selection: selected(f, "变压器"), remove: true)
        XCTAssertTrue(state.spans.isEmpty)
    }

    func testUnicodeBoundariesFieldCardAndChangedContentAreIsolated() throws {
        let (card, guide) = fixture(), doc = HandbookHighlightDocument(card: card, guide: guide)
        let f = try field(doc, "guide.rows.1.answer")
        var state = try HandbookHighlightState(subject: .power).applying(doc, selection: selected(f, "😀"), remove: false)
        XCTAssertEqual(state.runs(cardID: card.id, fieldID: f.id, text: f.text), [
            .init(text: "甲", red: false), .init(text: "😀", red: true), .init(text: "乙", red: false)])
        let keep = state
        let emoji = try selected(f, "😀")
        XCTAssertThrowsError(try state.applying(doc, selection: NSRange(location: emoji.location + 1, length: 1), remove: false))
        XCTAssertEqual(state, keep)
        // A syntactically valid but externally damaged span must never split
        // a surrogate pair during display, even on a permissive Foundation.
        let localEmoji = (f.text as NSString).range(of: "😀")
        var damaged = HandbookHighlightState(subject: .power)
        damaged.spans = [.init(cardID: card.id, fieldID: f.id, textSHA256: HandbookHighlightState.hash(f.text),
                               location: localEmoji.location + 1, length: 1)]
        try damaged.validate()
        XCTAssertEqual(damaged.runs(cardID: card.id, fieldID: f.id, text: f.text), [.init(text: f.text, red: false)])
        XCTAssertFalse(state.runs(cardID: "other", fieldID: f.id, text: f.text).contains(where: \.red))
        XCTAssertFalse(state.runs(cardID: card.id, fieldID: "other-field", text: f.text).contains(where: \.red))
        XCTAssertFalse(state.runs(cardID: card.id, fieldID: f.id, text: f.text + "新").contains(where: \.red))
        XCTAssertEqual(state, keep) // stale marks are retained for the old text, not reassigned
        state = try state.applying(doc, selection: emoji, remove: true)
        XCTAssertTrue(state.spans.isEmpty)
    }

    func testCombiningCharacterCannotBePartiallyHighlighted() throws {
        let (card, _) = fixture()
        let guide = HandbookCardPackage.MemoryGuide(cardID: card.id, explanation: nil,
            rows: [.init(cue: "组合", answer: "甲e\u{301}乙")], mnemonic: nil)
        let doc = HandbookHighlightDocument(card: card, guide: guide), f = try field(doc, "guide.rows.0.answer")
        let combined = try selected(f, "e\u{301}")
        XCTAssertEqual(combined.length, 2)
        let empty = HandbookHighlightState(subject: .computer)
        XCTAssertThrowsError(try empty.applying(doc, selection: NSRange(location: combined.location, length: 1), remove: false))
        let marked = try empty.applying(doc, selection: combined, remove: false)
        XCTAssertEqual(marked.runs(cardID: card.id, fieldID: f.id, text: f.text), [
            .init(text: "甲", red: false), .init(text: "e\u{301}", red: true), .init(text: "乙", red: false)])
    }

    func testVisibleCueNeverReturnsHiddenAnswerText() throws {
        let (card, guide) = fixture(), doc = HandbookHighlightDocument(card: card, guide: guide)
        let f = try field(doc, "summary")
        let state = try HandbookHighlightState(subject: .power).applying(doc, selection: selected(f, "甲"), remove: false)
        let visible = (f.text as NSString).range(of: "范围：")
        let runs = state.runs(cardID: card.id, fieldID: f.id, text: f.text, visible: visible)
        XCTAssertEqual(runs.map(\.text).joined(), "范围：")
        XCTAssertFalse(runs.map(\.text).joined().contains("甲"))
        XCTAssertFalse(runs.contains(where: \.red))
    }

    func testInvalidSelectionAndDamagedOrFutureStateFailClosed() throws {
        let (card, guide) = fixture(), doc = HandbookHighlightDocument(card: card, guide: guide)
        let state = HandbookHighlightState(subject: .computer)
        XCTAssertThrowsError(try state.applying(doc, selection: NSRange(location: NSNotFound, length: 0), remove: false))
        XCTAssertThrowsError(try state.applying(doc, selection: NSRange(location: 0, length: 1), remove: false)) // generated label
        var invalid = state; invalid.format = "future-format"
        XCTAssertThrowsError(try invalid.validate())
        invalid = state
        invalid.spans = [.init(cardID: card.id, fieldID: "title", textSHA256: String(repeating: "0", count: 64), location: 2, length: -1)]
        XCTAssertThrowsError(try invalid.validate())
    }
}
