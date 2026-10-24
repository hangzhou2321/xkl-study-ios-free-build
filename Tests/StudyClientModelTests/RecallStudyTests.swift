import XCTest
@testable import StudyClientModel

final class RecallStudyTests: XCTestCase {
    private func deck(_ count: Int = 5) -> RecallDeck {
        RecallDeck(subject: .computer, bankID: ConceptSubject.computer.bankID,
            cards: (0..<count).map { .init(conceptID: "sample", conceptTitle: "Synthetic concept",
                card: RecallCard(id: "sample:\($0)", prompt: "Question \($0)?", answer: "Answer \($0)")) })
    }
    private func grade(_ engine: inout RecallEngine, day: Int, remembered: Bool) throws {
        let id = try XCTUnwrap(engine.record.state.shown?.id)
        try engine.act("reveal", day: day, token: id)
        try engine.act("grade", day: day, token: id, remembered: remembered)
    }
    func testMustRevealAndStaleTokenCannotDoubleGrade() throws {
        var e = try RecallEngine(deck: deck(1)); try e.act("start", day: 20_000, newLimit: 1)
        let id = try XCTUnwrap(e.record.state.shown?.id)
        XCTAssertThrowsError(try e.act("grade", day: 20_000, token: id, remembered: true))
        XCTAssertTrue(e.record.state.progress.isEmpty)
        try grade(&e, day: 20_000, remembered: true)
        let record = e.record
        XCTAssertThrowsError(try e.act("grade", day: 20_000, token: id, remembered: true))
        XCTAssertEqual(e.record, record)
        XCTAssertEqual(e.record.state.progress["sample:0"]?.dueDay, 20_001)
    }
    func testForgottenCardRetriesAfterThreeOthersWithoutSameDayPromotion() throws {
        var e = try RecallEngine(deck: deck()); try e.act("start", day: 20_000, newLimit: 5)
        try grade(&e, day: 20_000, remembered: false)
        XCTAssertEqual(e.record.state.queue, ["sample:1", "sample:2", "sample:3", "sample:0", "sample:4"])
        for expected in ["sample:1", "sample:2", "sample:3"] {
            let token = try XCTUnwrap(e.record.state.result?.presentation.id)
            try e.act("next", day: 20_000, token: token)
            XCTAssertEqual(e.item?.id, expected); try grade(&e, day: 20_000, remembered: true)
        }
        try e.act("next", day: 20_000, token: e.record.state.result!.presentation.id)
        XCTAssertEqual(e.item?.id, "sample:0")
        try grade(&e, day: 20_000, remembered: true)
        XCTAssertEqual(e.record.state.progress["sample:0"]?.level, 0)
        XCTAssertEqual(e.record.state.progress["sample:0"]?.dueDay, 20_001)
        XCTAssertFalse(e.record.state.queue.contains("sample:0"))
        _ = try RecallEngine(deck: e.deck, record: e.record)
    }
    func testShortTailWaitsUntilTomorrowAndMidnightResultIsPreserved() throws {
        var e = try RecallEngine(deck: deck(1)); try e.act("start", day: 20_000, newLimit: 1)
        try grade(&e, day: 20_000, remembered: false)
        XCTAssertTrue(e.record.state.queue.isEmpty)
        let result = try XCTUnwrap(e.record.state.result)
        try e.act("refresh", day: 20_001)
        XCTAssertEqual(e.record.state.result, result)
        try e.act("next", day: 20_001, token: result.presentation.id)
        XCTAssertEqual(e.item?.id, "sample:0")
        XCTAssertFalse(e.record.state.shown!.revealed)
        try grade(&e, day: 20_001, remembered: true)
        XCTAssertEqual(e.record.state.progress["sample:0"]?.level, 1)
        XCTAssertEqual(e.record.state.progress["sample:0"]?.dueDay, 20_002)
    }
    func testDueAdmissionDoesNotReplaceLiveCardOrRepeatAnsweredToday() throws {
        var e = try RecallEngine(deck: deck(2)); try e.act("start", day: 20_000, newLimit: 2)
        try grade(&e, day: 20_000, remembered: true)
        try e.act("next", day: 20_000, token: e.record.state.result!.presentation.id)
        let live = e.record.state.shown
        try e.act("refresh", day: 20_001)
        XCTAssertEqual(e.record.state.shown, live)
        XCTAssertEqual(e.record.state.queue, ["sample:1", "sample:0"])
        let record = e.record; try e.act("refresh", day: 20_001)
        XCTAssertEqual(e.record, record)
        XCTAssertThrowsError(try e.act("refresh", day: 20_000))
    }
    func testArchiveRoundtripRejectsStateTamperAndMissingEvent() throws {
        var e = try RecallEngine(deck: deck(1)); try e.act("start", day: 20_000, newLimit: 1)
        try grade(&e, day: 20_000, remembered: true)
        let bytes = try JSONEncoder().encode(e.record)
        let restored = try JSONDecoder().decode(RecallRecord.self, from: bytes)
        XCTAssertEqual(try RecallEngine(deck: e.deck, record: restored).record, e.record)
        var bad = restored; bad.state.progress["sample:0"]!.level = 9
        XCTAssertThrowsError(try RecallEngine(deck: e.deck, record: bad))
        bad = restored; bad.events.remove(at: 1)
        XCTAssertThrowsError(try RecallEngine(deck: e.deck, record: bad))
        var changed = e.deck.cards
        changed[0] = .init(conceptID: "sample", conceptTitle: "Synthetic concept", card: RecallCard(id: "sample:0", prompt: "Changed", answer: "Changed"))
        XCTAssertThrowsError(try RecallEngine(deck: RecallDeck(subject: .computer, bankID: e.deck.bankID, cards: changed), record: restored))
    }
    func testIntervalsAdvanceOnlyAcrossDaysAndCapWithoutDroppingHistory() throws {
        var e = try RecallEngine(deck: deck(1)); var day = 20_000
        for index in 0..<12 {
            try e.act("start", day: day, newLimit: 1)
            try grade(&e, day: day, remembered: true)
            let progress = e.record.state.progress["sample:0"]!
            XCTAssertEqual(progress.level, min(index + 1, 10))
            XCTAssertEqual(progress.dueDay, day + RecallEngine.gaps[min(index, 9)])
            try e.act("next", day: day, token: e.record.state.result!.presentation.id)
            day = progress.dueDay
        }
        XCTAssertEqual(e.record.state.progress["sample:0"]?.remembered, 12)
        _ = try RecallEngine(deck: e.deck, record: e.record)
    }
}
