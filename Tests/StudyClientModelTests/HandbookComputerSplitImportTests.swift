#if canImport(Combine)
import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

/// Only synthetic cards, grades and red marks are used. These tests exercise the
/// real computer/Pocket import path, never the professional dual-FSRS adapter.
final class HandbookComputerSplitImportTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-computer-split-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func package(oldCount: Int, extraCount: Int) -> HandbookCardPackage {
        let total = oldCount + extraCount
        let cards = (0..<total).map { index in
            HandbookCard(id: "synthetic-card-\(index)", sourceGroupIDs: ["synthetic-group-\(index)"], topicNumber: 1,
                title: "Synthetic title \(index)", prompt: "Synthetic prompt \(index)",
                answerSummary: "Synthetic summary \(index)", blocks: [], sourcePages: [1], examples: [],
                sourceNotes: [], chapterID: "synthetic-chapter")
        }
        let guides = cards.map { card in
            HandbookCardPackage.MemoryGuide(cardID: card.id, explanation: nil,
                rows: [.init(cue: "Synthetic cue", answer: "Synthetic answer for \(card.id)")], mnemonic: nil)
        }
        return .init(id: "synthetic-computer-book", subject: .computer, title: "Synthetic book",
            revision: extraCount == 0 ? "1.0" : "1.1",
            source: .init(title: "Synthetic source", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64), pdfPageCount: 1, includedPages: [1]),
            chapters: [.init(id: "synthetic-chapter", title: "Synthetic chapter")], cards: cards, memoryGuides: guides)
    }

    private func packed(_ snapshot: Data, count: Int) throws -> [UInt32] {
        let pointer = try XCTUnwrap(snapshot.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
        defer { xkl_engine_free(pointer) }
        return (0..<count).map { xkl_engine_card(pointer, UInt32($0)) }
    }

    private func pending(_ snapshot: Data, count: Int) throws -> [[UInt32]] {
        let pointer = try XCTUnwrap(snapshot.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
        defer { xkl_engine_free(pointer) }
        return (0..<count).map { index in
            var failed: UInt32 = 0
            let stages = xkl_engine_pending_stages(pointer, UInt32(index), &failed)
            return [stages, failed]
        }
    }

    @MainActor private func events(_ record: ProfessionalRecallRecord) throws -> [StudyEvent] {
        try (record.volumes.map(\.snapshot) + [record.snapshot]).flatMap { snapshot in
            let engine = try PocketEngine(snapshot: snapshot)
            return try engine.events(from: engine.logBase + 1)
        }
    }

    private func info(_ snapshot: Data) throws -> xkl_info_t {
        let pointer = try XCTUnwrap(snapshot.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
        defer { xkl_engine_free(pointer) }
        var value = xkl_info_t()
        XCTAssertTrue(xkl_engine_info(pointer, &value))
        return value
    }

    private func markSelection(_ document: HandbookHighlightDocument) throws -> NSRange {
        let field = try XCTUnwrap(document.fields.first { $0.id == "guide.rows.0.answer" })
        let local = (field.text as NSString).range(of: "Synthetic")
        XCTAssertNotEqual(local.location, NSNotFound)
        return NSRange(location: field.range.location + local.location, length: local.length)
    }

    @MainActor func testAppendPreservesPocketStreamActiveQueueFrozenAnswerAndVisibleRedMark() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = package(oldCount: 30, extraCount: 0), next = package(oldCount: 30, extraCount: 9)
        XCTAssertEqual(Array(next.cards.prefix(old.cards.count)), old.cards)
        XCTAssertEqual(Array(try XCTUnwrap(next.memoryGuides).prefix(old.cards.count)), try XCTUnwrap(old.memoryGuides))
        let oldRaw = try JSONEncoder().encode(old), nextRaw = try JSONEncoder().encode(next)
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        store.importData(oldRaw); XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertFalse(try XCTUnwrap(store.engine).usesDualFSRS)
        store.start(now: now)
        let first = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: first, now: now); store.rate(remembered: false, token: first, now: now)
        let second = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: second, now: now); store.rate(remembered: true, token: second, now: now)
        let current = try XCTUnwrap(store.engine?.presentation)
        store.reveal(token: current.id, now: now)
        let before = try XCTUnwrap(store.engine?.state)
        let beforeEvents = try events(before.word)
        let beforeStream = try PocketEngine(snapshot: before.word.snapshot).streamID
        let beforeInfo = try info(before.word.snapshot)
        let beforeQueue = try XCTUnwrap(store.engine).fork()
        let shownCard = try XCTUnwrap(store.engine?.currentCard)
        let shownGuide = try XCTUnwrap(store.engine?.currentMemoryGuide)
        let document = HandbookHighlightDocument(card: shownCard, guide: shownGuide)
        let highlights = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        highlights.apply(document: document, selection: try markSelection(document), remove: false)
        XCTAssertNil(highlights.error); XCTAssertEqual(highlights.state.spans.count, 1)
        let directory = root.appendingPathComponent("HandbookWordRecall/computer")
        let currentURL = directory.appendingPathComponent("current.json")
        let markURL = directory.appendingPathComponent("personal-highlights/current.json")
        let originalFile = try Data(contentsOf: currentURL), markFile = try Data(contentsOf: markURL)
        let initialFile = try Data(contentsOf: directory.appendingPathComponent("initial.json"))
        let legacyFile = try Data(contentsOf: directory.appendingPathComponent("legacy-baseline.json"))
        let sentinel = root.appendingPathComponent("synthetic-other-subject.json")
        let sentinelData = Data("other subject untouched".utf8); try sentinelData.write(to: sentinel)

        store.importData(nextRaw); XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        let after = try XCTUnwrap(store.engine?.state)
        XCTAssertEqual(after.originalCardIDs, before.originalCardIDs + (30..<39).map { "synthetic-card-\($0)" })
        XCTAssertEqual(after.word.cardIDs, before.word.cardIDs + (30..<39).map { "handbook:\($0)" })
        XCTAssertEqual(try packed(after.word.snapshot, count: 30), try packed(before.word.snapshot, count: 30))
        XCTAssertEqual(Array(try packed(after.word.snapshot, count: 39).suffix(9)), Array(repeating: UInt32(0), count: 9))
        XCTAssertEqual(try pending(after.word.snapshot, count: 30), try pending(before.word.snapshot, count: 30))
        XCTAssertEqual(after.word.attempts, before.word.attempts)
        XCTAssertEqual(after.word.analysis, before.word.analysis)
        XCTAssertEqual(after.word.migration, before.word.migration)
        XCTAssertEqual(after.word.volumes, before.word.volumes)
        XCTAssertEqual(Array(try events(after.word).prefix(beforeEvents.count)), beforeEvents)
        XCTAssertTrue(try events(after.word).dropFirst(beforeEvents.count).allSatisfy { [1, 2, 3, 4].contains($0.kind) })
        XCTAssertEqual(try PocketEngine(snapshot: after.word.snapshot).streamID, beforeStream)
        XCTAssertEqual(after.word.contentChanges?.last?.beforeSnapshot, before.word.snapshot)
        XCTAssertEqual(store.engine?.currentCard, shownCard)
        XCTAssertEqual(store.engine?.currentMemoryGuide, shownGuide)
        XCTAssertEqual(store.engine?.presentation?.id, current.id)
        XCTAssertEqual(store.engine?.presentation?.revealed, true)
        let afterInfo = try info(after.word.snapshot)
        XCTAssertEqual(afterInfo.word, beforeInfo.word); XCTAssertEqual(afterInfo.stage, beforeInfo.stage)
        XCTAssertEqual(afterInfo.total_remaining, beforeInfo.total_remaining)
        XCTAssertEqual(afterInfo.can_undo, 0, "The existing engine closes undo at a collection boundary")
        XCTAssertEqual(try Data(contentsOf: markURL), markFile)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("initial.json")), initialFile)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("legacy-baseline.json")), legacyFile)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("revisions/\(StudySHA256.hex(originalFile)).json")), originalFile)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        let restoredMarks = HandbookHighlightStore(subject: .computer, baseDirectory: root)
        XCTAssertEqual(restoredMarks.state, highlights.state)
        let afterCard = try XCTUnwrap(next.cards.first { $0.id == shownCard.id })
        let afterGuide = try XCTUnwrap(next.memoryGuide(for: afterCard))
        let afterDocument = HandbookHighlightDocument(card: afterCard, guide: afterGuide)
        let answer = try XCTUnwrap(afterDocument.fields.first { $0.id == "guide.rows.0.answer" })
        XCTAssertTrue(restoredMarks.state.runs(cardID: afterCard.id, fieldID: answer.id, text: answer.text).contains { $0.red })

        let importedFile = try Data(contentsOf: currentURL)
        store.importData(nextRaw); XCTAssertNil(store.error); XCTAssertEqual(try Data(contentsOf: currentURL), importedFile)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(reopened.blocked, reopened.error ?? ""); XCTAssertEqual(reopened.engine?.state, after)
        reopened.importData(nextRaw); XCTAssertNil(reopened.error); XCTAssertEqual(try Data(contentsOf: currentURL), importedFile)

        // Replaying identical synthetic self-ratings on two isolated forks checks
        // that every pending current-task presentation remains in the same order.
        let afterQueue = try XCTUnwrap(reopened.engine).fork()
        var checked = 0
        while let left = beforeQueue.presentation {
            let right = try XCTUnwrap(afterQueue.presentation)
            XCTAssertEqual(beforeQueue.currentCard?.id, afterQueue.currentCard?.id)
            XCTAssertEqual(left.revealed, right.revealed)
            if !left.revealed { try beforeQueue.reveal(token: left.id, now: now) }
            if !right.revealed { try afterQueue.reveal(token: right.id, now: now) }
            try beforeQueue.rate(remembered: true, token: left.id, now: now)
            try afterQueue.rate(remembered: true, token: right.id, now: now)
            checked += 1; XCTAssertLessThan(checked, 500)
            if checked >= 500 { break }
        }
        XCTAssertNil(afterQueue.presentation); XCTAssertGreaterThan(checked, 0)
    }

    @MainActor func testAllOldCardsFamiliarNewCardsStartFreshWithoutInheritedGrades() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = package(oldCount: 3, extraCount: 0), next = package(oldCount: 3, extraCount: 2)
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        store.importData(try JSONEncoder().encode(old)); store.start(now: now)
        var steps = 0
        while let shown = store.engine?.presentation {
            store.markFamiliar(token: shown.id, now: now); XCTAssertNil(store.error)
            steps += 1; XCTAssertLessThan(steps, 20)
            if steps >= 20 { break }
        }
        XCTAssertEqual(steps, 3)
        let before = try XCTUnwrap(store.engine?.state), beforeEvents = try events(before.word)
        let oldUndo = try info(before.word.snapshot).can_undo
        XCTAssertEqual(oldUndo, 1, "A first-known or familiar step can be undoable internally before import")
        let nextRaw = try JSONEncoder().encode(next)
        store.importData(nextRaw); XCTAssertNil(store.error)
        let after = try XCTUnwrap(store.engine?.state)
        XCTAssertEqual(try packed(after.word.snapshot, count: 3), try packed(before.word.snapshot, count: 3))
        XCTAssertEqual(Array(try packed(after.word.snapshot, count: 5).suffix(2)), [0, 0])
        XCTAssertEqual(after.word.attempts, before.word.attempts)
        XCTAssertEqual(Array(try events(after.word).prefix(beforeEvents.count)), beforeEvents)
        XCTAssertEqual(try info(after.word.snapshot).can_undo, 0)
        XCTAssertNil(store.engine?.presentation)
        store.start(now: now); XCTAssertNil(store.error)
        XCTAssertTrue(["synthetic-card-3", "synthetic-card-4"].contains(try XCTUnwrap(store.engine?.currentCard?.id)))
        XCTAssertEqual(store.engine?.record.attempts, before.word.attempts)
    }

    @MainActor func testNineRelatedQuestionsImportWithoutScoresAndSubmitOnceInSeparateStore() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), old = package(oldCount: 5, extraCount: 0)
        var next = package(oldCount: 5, extraCount: 9)
        next.relatedQuestions = (0..<9).map { index in
            HandbookRelatedQuestion(id: "synthetic-question-\(index)", cardID: "synthetic-card-\(5 + index)",
                type: .single, prompt: "Synthetic question \(index)",
                options: [.init(id: "A", text: "Synthetic option A"), .init(id: "B", text: "Synthetic option B")],
                answer: ["A"], explanation: "Synthetic explanation", sourcePage: 1, sourceLabel: "Synthetic source")
        }
        let raw = try JSONEncoder().encode(next)
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        store.importData(try JSONEncoder().encode(old)); store.start(now: now)
        let shown = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: shown, now: now); store.rate(remembered: false, token: shown, now: now)
        let before = try XCTUnwrap(store.engine?.state)
        let oldEvents = try events(before.word)
        let oldQuestionsFolder = root.appendingPathComponent("ProfessionalQuestions/computer", isDirectory: true)
        try FileManager.default.createDirectory(at: oldQuestionsFolder, withIntermediateDirectories: true)
        let oldQuestionRecords = oldQuestionsFolder.appendingPathComponent("synthetic-history.json")
        let sentinel = Data("old question bank records are not migrated".utf8); try sentinel.write(to: oldQuestionRecords)
        let relatedFolder = root.appendingPathComponent("HandbookWordRecall/computer/related-question-events", isDirectory: true)
        store.importData(raw); XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(store.package?.relatedQuestions?.count, 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relatedFolder.path), "Importing questions must not fabricate attempts")
        XCTAssertEqual(store.engine?.record.attempts, before.word.attempts)
        let afterImportEvents = try events(XCTUnwrap(store.engine?.record))
        XCTAssertEqual(Array(afterImportEvents.prefix(oldEvents.count)), oldEvents)
        XCTAssertTrue(afterImportEvents.dropFirst(oldEvents.count).allSatisfy { [1, 2, 3, 4].contains($0.kind) })
        XCTAssertEqual(try Data(contentsOf: oldQuestionRecords), sentinel)
        let currentURL = root.appendingPathComponent("HandbookWordRecall/computer/current.json")
        let afterImportBytes = try Data(contentsOf: currentURL)
        store.importData(raw); XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: currentURL), afterImportBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relatedFolder.path))

        let question = try XCTUnwrap(store.package?.relatedQuestions?.first)
        let practice = HandbookRelatedQuestionStore(subject: .computer, baseDirectory: root)
        let attemptID = UUID()
        let first = try XCTUnwrap(practice.submit(question: question, selected: ["A"], cardAnswerWasVisible: true, id: attemptID, at: now))
        XCTAssertTrue(first.correct); XCTAssertTrue(first.cardAnswerWasVisible)
        XCTAssertEqual(practice.submit(question: question, selected: ["A"], cardAnswerWasVisible: true, id: attemptID, at: now), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relatedFolder.path).count, 1)
        XCTAssertEqual(try Data(contentsOf: currentURL), afterImportBytes, "An original-question attempt is not a flashcard grade")
        XCTAssertEqual(try Data(contentsOf: oldQuestionRecords), sentinel, "Original-question-bank history is a separate store")
        store.importData(raw); XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: currentURL), afterImportBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relatedFolder.path).count, 1)
        let reopened = HandbookRelatedQuestionStore(subject: .computer, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
    }

    @MainActor func testFailedCommitRetainsOldStateAndCanRetryAfterReopen() async throws {
        enum SyntheticFailure: Error { case beforeReplace }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), old = package(oldCount: 4, extraCount: 0), next = package(oldCount: 4, extraCount: 2)
        var shouldFail = false
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now,
            writer: { data, url in
                if shouldFail && url.lastPathComponent == "current.json" { throw SyntheticFailure.beforeReplace }
                try DurableFile.write(data, to: url)
            })
        store.importData(try JSONEncoder().encode(old)); store.start(now: now)
        let shown = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: shown, now: now); store.rate(remembered: false, token: shown, now: now)
        let before = try XCTUnwrap(store.engine?.state)
        let path = root.appendingPathComponent("HandbookWordRecall/computer/current.json")
        let beforeBytes = try Data(contentsOf: path), raw = try JSONEncoder().encode(next)
        shouldFail = true
        store.importData(raw); XCTAssertTrue(store.blocked); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: path), beforeBytes)
        XCTAssertEqual(store.engine?.state, before)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(reopened.blocked, reopened.error ?? ""); XCTAssertEqual(reopened.engine?.state, before)
        reopened.importData(raw); XCTAssertNil(reopened.error); XCTAssertFalse(reopened.blocked)
        XCTAssertEqual(reopened.engine?.record.attempts, before.word.attempts)
        let afterBytes = try Data(contentsOf: path)
        reopened.importData(raw); XCTAssertNil(reopened.error); XCTAssertEqual(try Data(contentsOf: path), afterBytes)
    }
}
#endif
