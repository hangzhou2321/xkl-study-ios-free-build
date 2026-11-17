import Foundation
import XCTest
@testable import StudyClientModel

final class CardLookupSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testExactDeadlineAndFirstReturnSurviveRelaunch() throws {
        var lookup = CardLookupSession(subject: "power", cardID: "card-4", presentationID: UUID(),
                                       startedAt: start, progress: .init(index: 4, target: 6, slotStart: start))
        XCTAssertFalse(lookup.leftApp)
        XCTAssertTrue(lookup.noteDeparture())
        XCTAssertFalse(lookup.noteDeparture())
        XCTAssertEqual(lookup.deadline.timeIntervalSince(start), 90)
        let reopened = try JSONDecoder().decode(CardLookupSession.self, from: JSONEncoder().encode(lookup))
        XCTAssertEqual(reopened, lookup)
        XCTAssertTrue(lookup.noteReturn(at: start + 89))
        XCTAssertFalse(lookup.timedOut)
        XCTAssertFalse(lookup.noteReturn(at: start + 95))
        XCTAssertFalse(lookup.timedOut)
        var expired = reopened
        XCTAssertTrue(expired.noteReturn(at: start + 90))
        XCTAssertTrue(expired.timedOut)
    }

    func testReturnLinkAndIdentityCannotGradeAnotherPresentation() throws {
        let lookup = CardLookupSession(subject: "power", cardID: "card-4", presentationID: UUID(),
                                       startedAt: start, progress: nil)
        let address = "xklstudy://lookup/" + lookup.id.uuidString
        XCTAssertEqual(CardLookupSession.returnID(from: try XCTUnwrap(URL(string: address))), lookup.id)
        XCTAssertNil(CardLookupSession.returnID(from: try XCTUnwrap(URL(string: address + "?pass=1"))))
        XCTAssertNil(CardLookupSession.returnID(from: try XCTUnwrap(URL(string: "xklstudy://hourly/" + lookup.id.uuidString))))
        XCTAssertTrue(lookup.matches(subject: "power", cardID: lookup.cardID, presentationID: lookup.presentationID))
        XCTAssertFalse(lookup.matches(subject: "computer", cardID: lookup.cardID, presentationID: lookup.presentationID))
        XCTAssertFalse(lookup.matches(subject: "power", cardID: lookup.cardID, presentationID: UUID()))
    }

    func testPromptIsBoundedAndEmptyRecapsAreRejected() {
        let text = CardLookupSession.prompt(subject: "电路", title: "电感与相位",
                                           question: "谁\n\t超前", answer: String(repeating: "电", count: 900))
        XCTAssertTrue(text.contains("谁 超前"))
        XCTAssertEqual(text.filter { $0 == "电" }.count, 702)
        XCTAssertTrue(text.contains("用自己的话"))
        XCTAssertFalse(CardLookupSession.validRecap(" ！\n。"))
        XCTAssertFalse(CardLookupSession.validRecap(String(repeating: "长", count: 201)))
        XCTAssertTrue(CardLookupSession.validRecap(" 电感的电压超前电流 90°。"))
    }

    #if os(macOS)
    @MainActor func testRecapCommitsOneRealSelfAssessmentAndSurvivesReopen() async throws {
        for subject in [ConceptSubject.power, .circuit] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-card-lookup-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = HandbookWordStore(subject: subject, baseDirectory: root)
            store.importData(try JSONEncoder().encode(syntheticPackage(subject)))
            let now = Date().addingTimeInterval(3)
            store.start(now: now)
            let original = try XCTUnwrap(store.engine?.presentation)
            XCTAssertFalse(original.revealed)
            var lookup = CardLookupSession(subject: subject.rawValue, cardID: original.cardID, presentationID: original.id,
                                           startedAt: now, progress: nil)
            XCTAssertNil(store.passAfterLookup(lookup, recap: "卡片复述", now: now + 10))
            XCTAssertTrue(lookup.noteReturn(at: now + 25))
            XCTAssertNil(store.passAfterLookup(lookup, recap: "", now: now + 26))
            XCTAssertEqual(store.engine?.presentation?.id, original.id)
            let receipt = try XCTUnwrap(store.passAfterLookup(lookup, recap: "我能说出这个考点。", now: now + 27), store.error ?? "")
            XCTAssertEqual(receipt.itemID, original.cardID)
            XCTAssertNotEqual(store.engine?.presentation?.id, original.id)
            XCTAssertNil(store.passAfterLookup(lookup, recap: "重复回调", now: now + 28))
            let restored = HandbookWordStore(subject: subject, baseDirectory: root)
            let engine = try XCTUnwrap(restored.engine)
            XCTAssertEqual(engine.state.originalCardIDs, ["lookup-test-card"])
            if engine.usesDualFSRS {
                XCTAssertEqual(engine.state.dualFSRS?.events.filter { $0.kind == "grade" }.map(\.cardID),
                               [original.cardID])
            } else {
                XCTAssertEqual(engine.record.attempts.count, 1)
                XCTAssertEqual(engine.record.attempts.first?.remembered, true)
            }
        }
    }

    private func syntheticPackage(_ subject: ConceptSubject) -> HandbookCardPackage {
        .init(id: "synthetic-lookup", subject: subject, title: "Synthetic", revision: "1.0",
              source: .init(title: "Synthetic", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64),
                            pdfPageCount: 1, includedPages: [1]),
              chapters: [.init(id: "chapter", title: "Synthetic")],
              cards: [.init(id: "lookup-test-card", sourceGroupIDs: ["group"], topicNumber: 1, title: "Synthetic",
                            prompt: "Recall", answerSummary: "Source", blocks: [], sourcePages: [1],
                            examples: [], sourceNotes: [], chapterID: "chapter")])
    }
    #endif
}
