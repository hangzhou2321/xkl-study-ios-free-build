import Foundation
import XCTest
@testable import StudyClientModel

final class StudyNovelTests: XCTestCase {
    private func attempt(_ index: Int, card: Int? = nil, day: UInt32 = 20_742, remembered: Bool = true) -> ProfessionalRecallAttempt {
        .init(id: UUID(), cardID: "synthetic-\(card ?? index)", presentationID: UUID(),
              remembered: remembered, at: Date(timeIntervalSince1970: Double(index)), day: day,
              engineSequence: UInt32(index), beforeRevision: UInt32(index), afterRevision: UInt32(index + 1))
    }

    func testParsesFullNumberedChaptersInOrder() throws {
        let raw = Data("\u{FEFF}封面\r\n  第一回 灯火\r\n第一段。\r\n\r\n第二段。\r\n第 2 章 风雨\r\n第二章正文。".utf8)
        let novel = try StudyNovel.parse(raw, title: "试读")
        XCTAssertEqual(novel.chapters.map(\.title), ["第一回 灯火", "第 2 章 风雨"])
        XCTAssertEqual(novel.chapters.map(\.text), ["第一段。\n\n第二段。", "第二章正文。"])
        XCTAssertThrowsError(try StudyNovel.parse(Data("没有章节的正文".utf8), title: "试读"))
    }

    func testParsesUTF16WithByteOrderMark() throws {
        let raw = try XCTUnwrap("第一章 山路\n完整正文。".data(using: .utf16))
        let novel = try StudyNovel.parse(raw, title: "试读")
        XCTAssertEqual(novel.chapters.first?.text, "完整正文。")
    }

    func testLocalBookWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["XKL_NOVEL_VALIDATION_FILE"] else {
            throw XCTSkip("Optional local public-domain book fixture")
        }
        let novel = try StudyNovel.parse(Data(contentsOf: URL(fileURLWithPath: path)), title: "西游记")
        XCTAssertEqual(novel.chapters.count, 100)
        XCTAssertTrue(novel.chapters.first?.title.hasPrefix("第一回") == true)
        XCTAssertTrue(novel.chapters.last?.title.hasPrefix("第一〇〇回") == true)
        XCTAssertTrue(novel.chapters.allSatisfy { $0.text.count > 1_000 })
    }

    func testOnlyNewSavedRatingsCountAndTwentyFifthUnlocksOnceAfterRestart() throws {
        var ratings = [attempt(0)]
        var progress = StudyNovelProgress()
        progress.startFrom(["computer": ratings, "power": []])
        ratings += (1...24).map { attempt($0, remembered: $0.isMultiple(of: 2)) }
        try progress.consume(["computer": ratings, "power": []], chapterCount: 2)
        XCTAssertEqual(progress.cardsInChapter.count, 24)
        XCTAssertEqual(progress.unlocked, 0)
        progress = try JSONDecoder().decode(StudyNovelProgress.self, from: JSONEncoder().encode(progress))
        ratings.append(attempt(25, card: 24))
        let power = [attempt(26, card: 24, remembered: false)]
        try progress.consume(["computer": ratings, "power": power], chapterCount: 2)
        try progress.consume(["computer": ratings, "power": power], chapterCount: 2)
        XCTAssertEqual(progress.unlocked, 1)
        XCTAssertEqual(progress.cardsInChapter.count, 0)
        try progress.validate(chapterCount: 2)
    }

    func testSameDayRepetitionDoesNotStartAnotherRewardAndNextDayReviewCanCount() throws {
        var progress = StudyNovelProgress()
        progress.startFrom(["power": []])
        var ratings = (1...25).map { attempt($0) }
        ratings.append(attempt(26, card: 1))
        try progress.consume(["power": ratings], chapterCount: 2)
        XCTAssertEqual(progress.unlocked, 1)
        XCTAssertTrue(progress.cardsInChapter.isEmpty)
        ratings.append(attempt(27, card: 1, day: 20_743))
        try progress.consume(["power": ratings], chapterCount: 2)
        XCTAssertEqual(progress.cardsInChapter.count, 1)
        progress.open(1)
        progress.bookmark(1, paragraph: 3)
        XCTAssertNil(progress.lastOpened)
        XCTAssertNil(progress.readingPositions[1])
        progress.open(0)
        progress.bookmark(0, paragraph: 4)
        XCTAssertEqual(progress.readingPositions[0], 4)
        progress.finish(0)
        XCTAssertEqual(progress.readChapters, [0])
        XCTAssertNil(progress.readingPositions[0])
    }

    func testReadingTheFinalChapterDoesNotAccumulateUnusedProgress() throws {
        var progress = StudyNovelProgress()
        progress.startFrom(["computer": []])
        let ratings = (1...28).map { attempt($0) }
        try progress.consume(["computer": ratings], chapterCount: 1)
        XCTAssertEqual(progress.unlocked, 1)
        XCTAssertTrue(progress.cardsInChapter.isEmpty)
        try progress.validate(chapterCount: 1)
    }

    @MainActor func testShelfReopensBookAndKeepsProgressWhenTheSameTextIsImportedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("试读.txt")
        try Data("第一章 山路\n完整正文。\n第二章 风雨\n下一段。".utf8).write(to: file)
        let store = StudyNovelStore(baseDirectory: directory)
        store.importText(file, records: ["computer": []])
        XCTAssertNil(store.error)
        let records = ["computer": (1...25).map { attempt($0) }]
        store.sync(records)
        store.open(0)
        store.bookmark(0, paragraph: 2)

        let reopened = StudyNovelStore(baseDirectory: directory)
        reopened.importText(file, records: records)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.active?.progress.unlocked, 1)
        XCTAssertEqual(reopened.active?.progress.readingPositions[0], 2)
        XCTAssertEqual(reopened.novel?.chapters.first?.text, "完整正文。")
    }
}
