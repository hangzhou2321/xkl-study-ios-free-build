import Foundation
import XCTest
@testable import StudyClientModel

final class CombinedHandbookQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func sample(subject: ConceptSubject, joinedEdition: Bool) -> HandbookCardPackage {
        let source = HandbookCardPackage.Source(title: "Synthetic", fileName: "synthetic.pdf",
            sha256: String(repeating: "b", count: 64), pdfPageCount: 1, includedPages: [1])
        let short = "sf2-\(subject.rawValue)"
        let ids = [short + "-a", "long-a", short + "-b", "long-b", "unrelated"]
        var result = HandbookCardPackage(id: "synthetic-combined", subject: subject, title: "Synthetic",
            revision: joinedEdition ? "1.35.9.1" : "1.0", source: source,
            chapters: [.init(id: "c", title: "Synthetic")],
            cards: ids.map {
                .init(id: $0, sourceGroupIDs: [$0], topicNumber: 1, title: "Synthetic", prompt: "Recall",
                    answerSummary: "Synthetic answer", blocks: [], sourcePages: [1],
                    examples: [], sourceNotes: [], chapterID: "c",
                    sourceReferences: $0.hasPrefix(short) ? [.init(sourceID: "BAODIAN2", page: 1)] : nil)
            })
        result.additionalSources = [.init(id: "BAODIAN2", source: source)]
        if joinedEdition { result.mainCardIDs = ["long-a", "long-b"] }
        return result
    }

    @MainActor func testActivationPreservesFrozenCardHistoryAndExtraArchives() async throws {
        for subject in [ConceptSubject.computer, .power] {
            let source = try HandbookWordEngine(package: sample(subject: subject, joinedEdition: false), now: now)
            try source.start(now: now)
            let alreadyLearned = try XCTUnwrap(source.presentation)
            XCTAssertTrue(alreadyLearned.cardID.hasPrefix("sf2-"))
            try source.reveal(token: alreadyLearned.id, now: now)
            try source.rate(remembered: true, token: alreadyLearned.id, now: now)
            try source.updatePackage(sample(subject: subject, joinedEdition: true), now: now)
            let current = try XCTUnwrap(source.presentation)
            try source.reveal(token: current.id, now: now)
            let shown = source.presentation
            let previous = source.state
            XCTAssertEqual(source.stats(on: now).total, 2)
            try source.includeShortBook(now: now)

            XCTAssertEqual(source.presentation, shown)
            XCTAssertEqual(source.state.originalCardIDs, previous.originalCardIDs)
            XCTAssertEqual(source.record.attempts, previous.word.attempts)
            XCTAssertEqual(source.package, previous.package)
            XCTAssertEqual(source.stats(on: now).total, 4)
            XCTAssertTrue(source.isInMainScope(alreadyLearned.cardID))
            XCTAssertFalse(source.isFirstPass(alreadyLearned.cardID))
            XCTAssertFalse(source.isInMainScope("unrelated"))
            XCTAssertFalse(source.usesDualFSRS)

            let updated = source.state
            try source.includeShortBook(now: now + 60)
            XCTAssertEqual(source.state, updated)
            let reopened = try HandbookWordEngine(state: updated)
            XCTAssertEqual(reopened.presentation, shown)
            XCTAssertEqual(reopened.shortBookScope.active.count, 2)
        }
    }

    #if os(macOS)
    @MainActor func testStoreArchivesCurrentBytesBeforeMakingTwoSizesStudyable() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = HandbookWordStore(subject: .power, baseDirectory: temp, now: now)
        let initial = sample(subject: .power, joinedEdition: true)
        store.importData(try JSONEncoder().encode(initial))
        let storeDir = temp.appendingPathComponent("HandbookWordRecall/power")
        let current = storeDir.appendingPathComponent("current.json")
        let before = try Data(contentsOf: current)
        store.start(now: now + 60)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.engine?.stats(on: now + 60).total, 4)
        let archives = try FileManager.default.contentsOfDirectory(at: storeDir.appendingPathComponent("revisions"),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(try archives.contains { try Data(contentsOf: $0) == before })
        let resumed = HandbookWordStore(subject: .power, baseDirectory: temp)
        XCTAssertEqual(resumed.engine?.presentation, store.engine?.presentation)
        XCTAssertEqual(resumed.engine?.shortBookScope.active.count, 2)
    }
    #endif
}
