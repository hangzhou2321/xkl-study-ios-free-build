import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

#if canImport(Combine)
/// These use only synthetic cards and an isolated temporary App Support directory.
/// The v1 envelope is assembled exactly as the released store wrote it, rather
/// than asking the new store to manufacture its own migration input.
final class HandbookDualFSRSStoreTests: XCTestCase {
    // Fixed in the past so importData's production Date() cannot precede the
    // fixture even when the tests run on a build machine in another timezone.
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let root: URL
        let directory: URL
        let currentURL: URL
        let rawPackage: Data
        let currentBytes: Data
        let legacyState: HandbookWordState
        let firstKnownCardID: String
        let familiarCardID: String
        let markers: [URL: Data]
    }

    private struct Export: Decodable {
        let files: [String: Data]
        let currentLegacyFiles: [String: Data]
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func package(_ subject: ConceptSubject = .computer, count: Int = 6,
                         revision: String = "1.0") -> HandbookCardPackage {
        var result = HandbookCardPackage(id: "synthetic-dual-\(subject.rawValue)", subject: subject,
            title: "Synthetic handbook", revision: revision,
            source: .init(title: "Synthetic", fileName: "synthetic.pdf",
                          sha256: String(repeating: "a", count: 64), pdfPageCount: 1, includedPages: [1]),
            chapters: [.init(id: "chapter", title: "Synthetic")], cards: (0..<count).map {
                .init(id: "synthetic-card-\($0)", sourceGroupIDs: ["synthetic-group-\($0)"], topicNumber: 1,
                      title: "Synthetic \($0)", prompt: "Recall synthetic \($0)", answerSummary: "Synthetic answer \($0)",
                      blocks: [], sourcePages: [1], examples: [], sourceNotes: [], chapterID: "chapter")
            })
        result.memoryGuides = result.cards.map {
            .init(cardID: $0.id, explanation: "Synthetic explanation",
                  rows: [.init(cue: "Synthetic cue", answer: "Synthetic answer")], mnemonic: nil)
        }
        return result
    }

    @MainActor private func fixture(_ subject: ConceptSubject = .computer, revealFinal: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("synthetic-dual-store-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("HandbookWordRecall/\(subject.rawValue)", isDirectory: true)
        try fm.createDirectory(at: directory.appendingPathComponent("imports"), withIntermediateDirectories: true)
        let package = package(subject)
        let raw = try encode(package)
        let old = try HandbookWordEngine(package: package, now: time)
        let initial = try encode(old.state)
        XCTAssertNil(old.state.dualFSRS)

        // Preserve a real first-known rating, an unfinished wrong-answer queue,
        // an explicitly postponed card and a separately marked familiar card.
        // Leave another card shown and its answer revealed at the cutover.
        try old.start(now: time, conservative: false)
        let first = try XCTUnwrap(old.presentation?.id)
        let firstKnownCardID = try XCTUnwrap(old.currentCard?.id)
        try old.reveal(token: first, now: time)
        try old.rate(remembered: true, token: first, now: time)
        let wrong = try XCTUnwrap(old.presentation?.id)
        try old.reveal(token: wrong, now: time.addingTimeInterval(1))
        try old.rate(remembered: false, token: wrong, now: time.addingTimeInterval(1))
        let delayed = try XCTUnwrap(old.presentation?.id)
        try old.postpone(token: delayed, now: time.addingTimeInterval(2))
        let familiar = try XCTUnwrap(old.presentation?.id)
        let familiarCardID = try XCTUnwrap(old.currentCard?.id)
        try old.markFamiliar(token: familiar, now: time.addingTimeInterval(3))
        let shown = try XCTUnwrap(old.presentation?.id)
        XCTAssertNotEqual(shown, first)
        if revealFinal { try old.reveal(token: shown, now: time.addingTimeInterval(4)) }
        let state = old.state
        XCTAssertEqual(state.word.attempts.map(\.remembered), [true, false])
        XCTAssertEqual(state.word.postponements?.count, 1)
        XCTAssertEqual(state.frozenToken, shown)
        XCTAssertEqual(state.word.presentation?.revealed, revealFinal)
        XCTAssertNotNil(state.frozenCard)
        XCTAssertNotNil(state.frozenGuide)

        let baseline = try JSONSerialization.data(withJSONObject: [
            "format": "xkl-handbook-word-baseline-v1", "subject": subject.rawValue,
            "mappingPolicy": "synthetic-legacy-fixture", "legacyFiles": [String: String]()
        ], options: [.sortedKeys])
        let rawHash = StudySHA256.hex(raw)
        try baseline.write(to: directory.appendingPathComponent("legacy-baseline.json"))
        try initial.write(to: directory.appendingPathComponent("initial.json"))
        try raw.write(to: directory.appendingPathComponent("imports/\(rawHash).xklflashcards"))
        let stateObject = try JSONSerialization.jsonObject(with: encode(state))
        let disk: [String: Any] = [
            "format": "xkl-handbook-word-store-v1", "subject": subject.rawValue,
            "baselineSHA256": StudySHA256.hex(baseline), "initialSHA256": StudySHA256.hex(initial),
            "state": stateObject, "rawImports": [rawHash], "revisions": [String]()
        ]
        let bytes = try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys])
        let current = directory.appendingPathComponent("current.json")
        try bytes.write(to: current)
        let markerPaths = ["Study/synthetic.bin", "QuestionBank/synthetic.bin", "Math/synthetic.bin",
                           "HandbookCards/\(subject == .computer ? "power" : "computer")/synthetic.bin"]
        var markers: [URL: Data] = [:]
        for path in markerPaths {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("protected synthetic \(path)".utf8)
            try data.write(to: url)
            markers[url] = data
        }
        return Fixture(root: root, directory: directory, currentURL: current, rawPackage: raw,
                       currentBytes: bytes, legacyState: state, firstKnownCardID: firstKnownCardID,
                       familiarCardID: familiarCardID, markers: markers)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor private func fixtureWithRealDeferredCQueue() throws -> Fixture {
        let f = try fixture()
        let ids = f.legacyState.originalCardIDs
        let cards = ids.indices.map { index in
            RecallDeck.Item(conceptID: "handbook", conceptTitle: "Handbook slot",
                card: .init(id: "handbook:\(index)", prompt: "slot \(index)", answer: "slot \(index)"))
        }
        let full = RecallDeck(subject: .computer, bankID: ConceptSubject.computer.bankID, cards: cards)
        let donorDeck = RecallDeck(subject: .computer, bankID: ConceptSubject.computer.bankID, cards: [cards.last!])
        let receiver = try ProfessionalRecallEngine.fresh(deck: full, now: time)
        let donor = try ProfessionalRecallEngine.fresh(deck: donorDeck, now: time)
        let day = UInt32(try ConceptCalendar.studyDay(time))
        try receiver.start(day: day, now: time)
        try donor.start(day: day, now: time)
        let donorToken = try XCTUnwrap(donor.record.presentation?.id)
        try donor.reveal(token: donorToken, now: time)
        try donor.grade(remembered: false, token: donorToken, now: time.addingTimeInterval(1))
        let id = try XCTUnwrap(cards.last?.id)
        let transfer = try XCTUnwrap(donor.transferState(for: id, sourceScope: "synthetic-deferred"))
        XCTAssertEqual(transfer.stageMask, 254)
        let subset = RecallDeck(subject: .computer, bankID: ConceptSubject.computer.bankID, cards: Array(cards.dropLast()))
        try receiver.reconcile(to: subset, now: time.addingTimeInterval(2))
        try receiver.reconcile(to: full, importing: [id: transfer], now: time.addingTimeInterval(3))
        XCTAssertEqual(receiver.record.deferredCards?[id]?.stageMask, 254)
        let shown = try XCTUnwrap(receiver.record.presentation)
        try receiver.reveal(token: shown.id, now: time.addingTimeInterval(4))
        let slot = try XCTUnwrap(receiver.record.cardIDs.firstIndex(of: shown.cardID))
        var state = f.legacyState
        state.word = receiver.record
        state.frozenToken = shown.id
        state.frozenCard = try XCTUnwrap(state.package.cards.first { $0.id == ids[slot] })
        state.frozenGuide = state.package.memoryGuide(for: try XCTUnwrap(state.frozenCard))
        state.dualFSRS = nil
        _ = try HandbookWordEngine(state: state)
        var disk = try object(f.currentBytes)
        disk["state"] = try JSONSerialization.jsonObject(with: encode(state))
        let bytes = try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys])
        try bytes.write(to: f.currentURL, options: .atomic)
        return Fixture(root: f.root, directory: f.directory, currentURL: f.currentURL, rawPackage: f.rawPackage,
                       currentBytes: bytes, legacyState: state, firstKnownCardID: f.firstKnownCardID,
                       familiarCardID: f.familiarCardID, markers: f.markers)
    }

    private func assertMarkers(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for (url, expected) in fixture.markers {
            XCTAssertEqual(try Data(contentsOf: url), expected, file: file, line: line)
        }
    }

    @MainActor func testV1MigrationArchivesExactBytesPreservesBreakpointAndIsIdempotent() async throws {
        for subject in [ConceptSubject.computer, .power] {
            let f = try fixture(subject)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let store = HandbookWordStore(subject: subject, baseDirectory: f.root, documentsDirectory: f.root,
                                          now: time.addingTimeInterval(10))
            XCTAssertFalse(store.blocked, store.error ?? "")
            let engine = try XCTUnwrap(store.engine)
            let migrated = engine.state
            XCTAssertNotNil(migrated.dualFSRS)
            let dual = try XCTUnwrap(migrated.dualFSRS)
            XCTAssertEqual(dual.legacyRatings.map(\.remembered), [true, false])
            XCTAssertEqual(dual.legacyRatings.first?.cardID, f.firstKnownCardID)
            XCTAssertNotNil(dual.daily[f.firstKnownCardID])
            XCTAssertNotNil(dual.all[f.firstKnownCardID])
            XCTAssertTrue(dual.familiar.contains(f.familiarCardID))
            XCTAssertNotEqual(try XCTUnwrap(dual.legacyPacked[f.familiarCardID]) & (1 << 21), 0)
            XCTAssertEqual(migrated.package, f.legacyState.package)
            XCTAssertEqual(migrated.originalCardIDs, f.legacyState.originalCardIDs)
            XCTAssertEqual(migrated.word, f.legacyState.word)
            XCTAssertEqual(migrated.word.snapshot, f.legacyState.word.snapshot)
            XCTAssertEqual(migrated.word.attempts, f.legacyState.word.attempts)
            XCTAssertEqual(migrated.frozenToken, f.legacyState.frozenToken)
            XCTAssertEqual(migrated.frozenCard, f.legacyState.frozenCard)
            XCTAssertEqual(migrated.frozenGuide, f.legacyState.frozenGuide)
            XCTAssertEqual(engine.presentation?.id, f.legacyState.frozenToken)
            XCTAssertEqual(engine.presentation?.revealed, true)
            XCTAssertEqual(engine.currentCard, f.legacyState.frozenCard)

            let oldHash = StudySHA256.hex(f.currentBytes)
            let archiveURL = f.directory.appendingPathComponent("revisions/\(oldHash).json")
            XCTAssertEqual(try Data(contentsOf: archiveURL), f.currentBytes)
            let migratedBytes = try Data(contentsOf: f.currentURL)
            XCTAssertEqual(try object(migratedBytes)["format"] as? String, "xkl-handbook-word-store-v2-dual-fsrs")
            let exported = try JSONDecoder().decode(Export.self, from: store.exportRecords())
            XCTAssertEqual(exported.files["revisions/\(oldHash).json"], f.currentBytes)
            XCTAssertEqual(exported.files["current.json"], migratedBytes)
            try assertMarkers(f)

            // Reopening is a no-op; it neither replays old ratings again nor
            // creates another cutover archive.
            let reopened = HandbookWordStore(subject: subject, baseDirectory: f.root, documentsDirectory: f.root,
                                             now: time.addingTimeInterval(11))
            XCTAssertFalse(reopened.blocked, reopened.error ?? "")
            XCTAssertEqual(reopened.engine?.state, migrated)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), migratedBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archiveURL.deletingLastPathComponent().path), ["\(oldHash).json"])
            try assertMarkers(f)
        }
    }

    @MainActor func testRepeatImportAndAppendedContentRetainHistoryAndFrozenPresentation() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(10))
        XCTAssertFalse(store.blocked, store.error ?? "")
        let before = try XCTUnwrap(store.engine?.state)
        let beforeBytes = try Data(contentsOf: f.currentURL)
        let token = try XCTUnwrap(store.engine?.presentation?.id)
        store.importData(f.rawPackage)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), beforeBytes)
        XCTAssertEqual(store.engine?.state, before)

        let next = package(count: 7, revision: "1.1")
        let nextRaw = try encode(next)
        store.importData(nextRaw)
        XCTAssertNil(store.error)
        let updated = try XCTUnwrap(store.engine?.state)
        XCTAssertEqual(Array(updated.originalCardIDs.prefix(before.originalCardIDs.count)), before.originalCardIDs)
        XCTAssertEqual(updated.originalCardIDs.last, "synthetic-card-6")
        XCTAssertEqual(updated.word, before.word)
        XCTAssertEqual(updated.frozenCard, before.frozenCard)
        XCTAssertEqual(updated.frozenToken, before.frozenToken)
        XCTAssertEqual(updated.frozenGuide, before.frozenGuide)
        XCTAssertEqual(store.engine?.presentation?.id, token)
        XCTAssertEqual(store.engine?.presentation?.revealed, true)
        let afterImport = try Data(contentsOf: f.currentURL)
        store.importData(nextRaw)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), afterImport)
        XCTAssertEqual(store.engine?.state, updated)
        try assertMarkers(f)

        let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                         now: time.addingTimeInterval(12))
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.state, updated)
    }

    @MainActor func testRealNewRatingPersistsInDualStateWithoutChangingLegacyAttempts() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(10))
        let before = try XCTUnwrap(store.engine?.state)
        let beforeDual = try encode(XCTUnwrap(before.dualFSRS))
        let token = try XCTUnwrap(store.engine?.presentation?.id)
        let cardID = try XCTUnwrap(store.engine?.presentation?.cardID)
        XCTAssertEqual(store.engine?.presentation?.revealed, true)
        let ratedAt = time.addingTimeInterval(11)
        store.rate(remembered: true, token: token, now: ratedAt)
        XCTAssertNil(store.error)
        let after = try XCTUnwrap(store.engine?.state)
        XCTAssertEqual(after.word, before.word, "The old Pocket history is archived, not rewritten as an FSRS grade.")
        XCTAssertEqual(after.originalCardIDs, before.originalCardIDs)
        XCTAssertNotEqual(try encode(XCTUnwrap(after.dualFSRS)), beforeDual)
        let previous = try XCTUnwrap(before.dualFSRS)
        let dual = try XCTUnwrap(after.dualFSRS)
        let day = UInt32(try ConceptCalendar.studyDay(ratedAt))
        let expected = try FSRS6Shadow.review(nil, day: day, rating: 3,
            timestampMs: Int64(ratedAt.timeIntervalSince1970 * 1_000)).memory
        XCTAssertNil(previous.daily[cardID])
        XCTAssertNil(previous.all[cardID])
        XCTAssertEqual(dual.daily[cardID], expected, "The real user self-rating must update the daily-first model.")
        XCTAssertEqual(dual.all[cardID], expected, "The same real self-rating must update the all-ratings model.")
        XCTAssertEqual(dual.events.count, previous.events.count + 1)
        XCTAssertEqual(dual.events.last?.kind, "grade")
        XCTAssertEqual(dual.events.last?.presentationID, token)
        let afterBytes = try Data(contentsOf: f.currentURL)
        store.rate(remembered: true, token: token, now: time.addingTimeInterval(12))
        XCTAssertEqual(try Data(contentsOf: f.currentURL), afterBytes, "A stale presentation token must not grade twice.")
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                         now: time.addingTimeInterval(13))
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.state, after)
        try assertMarkers(f)
    }

    @MainActor func testMigrationWriteFailureLeavesV1AndRetryKeepsExactArchive() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let failed = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
            now: time.addingTimeInterval(10), writer: { data, url in
                if url.lastPathComponent == "current.json" { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            })
        XCTAssertTrue(failed.blocked)
        XCTAssertNil(failed.engine)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
        let archive = f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(f.currentBytes)).json")
        XCTAssertEqual(try Data(contentsOf: archive), f.currentBytes)
        let retry = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(11))
        XCTAssertFalse(retry.blocked, retry.error ?? "")
        XCTAssertNotNil(retry.engine?.state.dualFSRS)
        XCTAssertEqual(try Data(contentsOf: archive), f.currentBytes)
        XCTAssertEqual(retry.engine?.state.word, f.legacyState.word)
        try assertMarkers(f)
    }

    @MainActor func testArchiveFailureNeverTouchesCurrentOrPublishesEngine() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let failed = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
            now: time.addingTimeInterval(10), writer: { data, url in
                if url.deletingLastPathComponent().lastPathComponent == "revisions" { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            })
        XCTAssertTrue(failed.blocked)
        XCTAssertNil(failed.engine)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
        try assertMarkers(f)
    }

    @MainActor func testConcurrentLegacyChangeIsNotOverwrittenAtCutover() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Trailing JSON whitespace represents a different, still-valid current
        // pointer observed after archiving; it does not fabricate an answer.
        let concurrent = f.currentBytes + Data(" \n".utf8)
        var injected = false
        let failed = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
            now: time.addingTimeInterval(10), writer: { data, url in
                try data.write(to: url, options: .atomic)
                if !injected && url.deletingLastPathComponent().lastPathComponent == "revisions" {
                    injected = true
                    try concurrent.write(to: f.currentURL, options: .atomic)
                }
            })
        XCTAssertTrue(injected)
        XCTAssertTrue(failed.blocked)
        XCTAssertNil(failed.engine)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), concurrent)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(f.currentBytes)).json")), f.currentBytes)
        let retry = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(11))
        XCTAssertFalse(retry.blocked, retry.error ?? "")
        XCTAssertEqual(retry.engine?.state.word, f.legacyState.word)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(concurrent)).json")), concurrent)
        try assertMarkers(f)
    }

    @MainActor func testCommittedWriteThenErrorBlocksAndReopensExactlyOnce() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let uncertain = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
            now: time.addingTimeInterval(10), writer: { data, url in
                try data.write(to: url, options: .atomic)
                if url.lastPathComponent == "current.json" { throw CocoaError(.fileWriteUnknown) }
            })
        XCTAssertTrue(uncertain.blocked)
        XCTAssertNil(uncertain.engine)
        let saved = try Data(contentsOf: f.currentURL)
        XCTAssertEqual(try object(saved)["format"] as? String, "xkl-handbook-word-store-v2-dual-fsrs")
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                         now: time.addingTimeInterval(11))
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(try Data(contentsOf: f.currentURL), saved)
        XCTAssertEqual(reopened.engine?.state.word, f.legacyState.word)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(f.currentBytes)).json")), f.currentBytes)
        try assertMarkers(f)
    }

    @MainActor func testInconsistentV1V2EnvelopesFailClosedWithoutRepairingOrOverwriting() async throws {
        for mode in ["v1-with-dual", "v2-without-dual"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let migrated = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                             now: time.addingTimeInterval(10))
            XCTAssertFalse(migrated.blocked, migrated.error ?? "")
            var disk = try object(Data(contentsOf: f.currentURL))
            var state = try XCTUnwrap(disk["state"] as? [String: Any])
            XCTAssertNotNil(state["dualFSRS"])
            if mode == "v1-with-dual" { disk["format"] = "xkl-handbook-word-store-v1" }
            else { state.removeValue(forKey: "dualFSRS"); disk["state"] = state }
            let inconsistent = try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys])
            try inconsistent.write(to: f.currentURL, options: .atomic)
            let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                             now: time.addingTimeInterval(11))
            XCTAssertTrue(reopened.blocked, "An inconsistent scheduler envelope must not silently lose either history.")
            XCTAssertNil(reopened.engine)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), inconsistent)
            XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(f.currentBytes)).json")), f.currentBytes)
            try assertMarkers(f)
        }
    }

    @MainActor func testFreshSubjectImportCreatesV2WithoutLegacyOrOtherSubjectRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-dual-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let computer = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: time)
        XCTAssertFalse(computer.blocked, computer.error ?? "")
        XCTAssertNil(computer.engine)
        let raw = try encode(package(.computer))
        computer.importData(raw)
        XCTAssertFalse(computer.blocked, computer.error ?? "")
        XCTAssertNotNil(computer.engine?.state.dualFSRS)
        XCTAssertTrue(try XCTUnwrap(computer.engine?.state.word.attempts).isEmpty)
        let url = root.appendingPathComponent("HandbookWordRecall/computer/current.json")
        let current = try Data(contentsOf: url)
        XCTAssertEqual(try object(current)["format"] as? String, "xkl-handbook-word-store-v2-dual-fsrs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("HandbookWordRecall/power/current.json").path))
        computer.importData(raw)
        XCTAssertNil(computer.error)
        XCTAssertEqual(try Data(contentsOf: url), current)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: time)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.state, computer.engine?.state)
    }

    @MainActor func testSafeRollbackThenLegacyRatingAndExplicitReenableUsesLatestV1() async throws {
        for subject in [ConceptSubject.computer, .power] {
            let f = try fixture(subject)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let store = HandbookWordStore(subject: subject, baseDirectory: f.root, documentsDirectory: f.root,
                                          now: time.addingTimeInterval(10))
            XCTAssertFalse(store.blocked, store.error ?? "")
            XCTAssertTrue(store.canRollbackToLegacy)
            let v2 = try Data(contentsOf: f.currentURL), v2Hash = StudySHA256.hex(v2)
            store.rollbackToLegacy()
            XCTAssertFalse(store.blocked, store.error ?? "")
            XCTAssertNil(store.error)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
            XCTAssertEqual(store.engine?.state, f.legacyState)
            XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(v2Hash).json")), v2)
            let markerURL = f.directory.appendingPathComponent("legacy-mode.json")
            let marker = try Data(contentsOf: markerURL)
            XCTAssertFalse(String(decoding: marker, as: UTF8.self).contains("synthetic-card-"))
            XCTAssertTrue(store.canEnableDualFSRS)
            XCTAssertFalse(store.canRollbackToLegacy)
            let legacy = HandbookWordStore(subject: subject, baseDirectory: f.root, documentsDirectory: f.root,
                                           now: time.addingTimeInterval(11))
            XCTAssertFalse(legacy.blocked, legacy.error ?? "")
            XCTAssertTrue(legacy.canEnableDualFSRS)
            XCTAssertEqual(legacy.engine?.state, f.legacyState)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)

            // Make an actual new old-engine self-rating after rollback; this B
            // head must be the source of the next migration, never the old A.
            let token = try XCTUnwrap(legacy.engine?.presentation?.id)
            let ratedCardID = try XCTUnwrap(legacy.engine?.presentation?.cardID)
            XCTAssertEqual(legacy.engine?.presentation?.revealed, true)
            legacy.rate(remembered: true, token: token, now: time.addingTimeInterval(12))
            XCTAssertNil(legacy.error)
            let latest = try XCTUnwrap(legacy.engine?.state)
            XCTAssertEqual(latest.word.attempts.count, f.legacyState.word.attempts.count + 1)
            let latestV1 = try Data(contentsOf: f.currentURL)
            XCTAssertNotEqual(latestV1, f.currentBytes)
            XCTAssertEqual(try Data(contentsOf: markerURL), marker)
            let legacyRestart = HandbookWordStore(subject: subject, baseDirectory: f.root, documentsDirectory: f.root,
                                                  now: time.addingTimeInterval(13))
            XCTAssertFalse(legacyRestart.blocked, legacyRestart.error ?? "")
            XCTAssertEqual(legacyRestart.engine?.state, latest)
            XCTAssertTrue(legacyRestart.canEnableDualFSRS)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), latestV1)
            legacyRestart.reenableDualFSRS(now: time.addingTimeInterval(14))
            XCTAssertFalse(legacyRestart.blocked, legacyRestart.error ?? "")
            XCTAssertNil(legacyRestart.error)
            let dual = try XCTUnwrap(legacyRestart.engine?.state.dualFSRS)
            XCTAssertEqual(legacyRestart.engine?.state.word, latest.word)
            XCTAssertEqual(dual.legacyRatings.count, latest.word.attempts.count)
            XCTAssertEqual(dual.legacyRatings.last?.cardID, ratedCardID)
            XCTAssertEqual(dual.legacyRatings.last?.remembered, true)
            XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(latestV1)).json")), latestV1)
            XCTAssertEqual(try Data(contentsOf: markerURL), marker)
            XCTAssertFalse(legacyRestart.canEnableDualFSRS)
            XCTAssertFalse(legacyRestart.canRollbackToLegacy, "The first version deliberately supports one safe rollback only.")
            let latestV2 = try Data(contentsOf: f.currentURL)
            let final = HandbookWordStore(subject: subject, baseDirectory: f.root, documentsDirectory: f.root,
                                          now: time.addingTimeInterval(15))
            XCTAssertFalse(final.blocked, final.error ?? "")
            XCTAssertEqual(try Data(contentsOf: f.currentURL), latestV2)
            XCTAssertEqual(final.engine?.state.word, latest.word)
            XCTAssertNotNil(final.engine?.state.dualFSRS)
            XCTAssertFalse(final.canRollbackToLegacy)
            try assertMarkers(f)
        }
    }

    @MainActor func testAnyNewFSRSActivityOrContentChangeRefusesRollbackWithoutChangingCurrent() async throws {
        for mode in ["start", "reveal", "grade", "familiar", "postpone", "content"] {
            let f = try fixture(revealFinal: mode != "reveal")
            defer { try? FileManager.default.removeItem(at: f.root) }
            if mode == "start" || mode == "postpone" {
                // Use the valid no-presentation v1 initial state to create a
                // fresh dual round with enough cards for the postpone action.
                var disk = try object(f.currentBytes)
                let initial = try Data(contentsOf: f.directory.appendingPathComponent("initial.json"))
                disk["state"] = try JSONSerialization.jsonObject(with: initial)
                try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys]).write(to: f.currentURL, options: .atomic)
            }
            let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                          now: time.addingTimeInterval(10))
            XCTAssertFalse(store.blocked, store.error ?? "")
            XCTAssertTrue(store.canRollbackToLegacy, mode)
            switch mode {
            case "start": store.start(now: time.addingTimeInterval(11))
            case "reveal": store.reveal(token: try XCTUnwrap(store.engine?.presentation?.id), now: time.addingTimeInterval(11))
            case "grade": store.rate(remembered: true, token: try XCTUnwrap(store.engine?.presentation?.id), now: time.addingTimeInterval(11))
            case "familiar": store.markFamiliar(token: try XCTUnwrap(store.engine?.presentation?.id), now: time.addingTimeInterval(11))
            case "postpone":
                store.start(now: time.addingTimeInterval(11))
                store.postpone(token: try XCTUnwrap(store.engine?.presentation?.id), now: time.addingTimeInterval(12))
                XCTAssertEqual(store.engine?.state.dualFSRS?.events.last?.kind, "postpone")
            default: store.importData(try encode(package(count: 7, revision: "1.1")))
            }
            XCTAssertNil(store.error, "\(mode): \(store.error ?? "")")
            if mode != "content" { XCTAssertFalse(try XCTUnwrap(store.engine?.state.dualFSRS?.events).isEmpty) }
            XCTAssertFalse(store.canRollbackToLegacy, mode)
            let before = try Data(contentsOf: f.currentURL)
            store.rollbackToLegacy()
            XCTAssertNotNil(store.error, mode)
            XCTAssertFalse(store.blocked, mode)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), before, mode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("legacy-mode.json").path))
            try assertMarkers(f)
        }
    }

    @MainActor func testDamagedMarkerFailsClosedAndLeavesLegacyCurrentUntouched() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(10))
        store.rollbackToLegacy()
        XCTAssertFalse(store.blocked, store.error ?? "")
        let marker = f.directory.appendingPathComponent("legacy-mode.json")
        try Data("damaged synthetic marker".utf8).write(to: marker, options: .atomic)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                         now: time.addingTimeInterval(11))
        XCTAssertTrue(reopened.blocked)
        XCTAssertNil(reopened.engine)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
        try assertMarkers(f)
    }

    @MainActor func testRollbackWriteFailuresRecoverOrFailClosedWithoutLosingEitherHead() async throws {
        for mode in ["archive-before", "marker-before", "marker-after", "witness-before", "witness-after", "current-before", "current-after", "concurrent"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var armed = false
            var divergent = Data()
            let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                now: time.addingTimeInterval(10), writer: { data, url in
                    if armed {
                        let isArchive = url.deletingLastPathComponent().lastPathComponent == "revisions"
                        let isMarker = url.lastPathComponent == "legacy-mode.json"
                        let isWitness = url.lastPathComponent == "legacy-mode-witness.json"
                        let isCurrent = url.lastPathComponent == "current.json"
                        if (mode == "archive-before" && isArchive) || (mode == "marker-before" && isMarker) ||
                           (mode == "witness-before" && isWitness) ||
                           (mode == "current-before" && isCurrent) { throw CocoaError(.fileWriteUnknown) }
                        try data.write(to: url, options: .atomic)
                        if mode == "concurrent" && isMarker { try divergent.write(to: f.currentURL, options: .atomic) }
                        if (mode == "marker-after" && isMarker) || (mode == "witness-after" && isWitness) || (mode == "current-after" && isCurrent) {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    } else { try data.write(to: url, options: .atomic) }
                })
            XCTAssertFalse(store.blocked, store.error ?? "")
            XCTAssertTrue(store.canRollbackToLegacy, mode)
            let v2 = try Data(contentsOf: f.currentURL)
            divergent = v2 + Data(" \n".utf8)
            armed = true
            store.rollbackToLegacy()
            XCTAssertTrue(store.blocked, mode)
            if mode == "concurrent" { XCTAssertEqual(try Data(contentsOf: f.currentURL), divergent) }
            else if mode == "current-after" { XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes) }
            else { XCTAssertEqual(try Data(contentsOf: f.currentURL), v2) }
            let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                             now: time.addingTimeInterval(11))
            if mode == "concurrent" {
                XCTAssertTrue(reopened.blocked)
                XCTAssertNil(reopened.engine)
                XCTAssertEqual(try Data(contentsOf: f.currentURL), divergent)
            } else if mode == "archive-before" || mode == "marker-before" {
                XCTAssertFalse(reopened.blocked, reopened.error ?? "")
                XCTAssertNotNil(reopened.engine?.state.dualFSRS)
                XCTAssertEqual(try Data(contentsOf: f.currentURL), v2)
                XCTAssertTrue(reopened.canRollbackToLegacy)
            } else {
                XCTAssertFalse(reopened.blocked, reopened.error ?? "")
                XCTAssertNil(reopened.engine?.state.dualFSRS)
                XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
                XCTAssertTrue(reopened.canEnableDualFSRS)
            }
            XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(StudySHA256.hex(f.currentBytes)).json")), f.currentBytes)
            try assertMarkers(f)
        }
    }

    @MainActor func testMissingMarkerOrDamagedWitnessCannotSilentlyRemigrateLegacyState() async throws {
        for mode in ["marker-missing", "witness-damaged"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                          now: time.addingTimeInterval(10))
            store.rollbackToLegacy()
            XCTAssertFalse(store.blocked, store.error ?? "")
            let marker = f.directory.appendingPathComponent("legacy-mode.json")
            let witness = f.directory.appendingPathComponent("legacy-mode-witness.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: witness.path))
            if mode == "marker-missing" { try FileManager.default.removeItem(at: marker) }
            else { try Data("damaged synthetic witness".utf8).write(to: witness, options: .atomic) }
            let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                             now: time.addingTimeInterval(11))
            XCTAssertTrue(reopened.blocked, mode)
            XCTAssertNil(reopened.engine)
            XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
            try assertMarkers(f)
        }
    }

    @MainActor func testStaleLegacyInstanceCannotReenableOverNewerRating() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let initial = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                        now: time.addingTimeInterval(10))
        initial.rollbackToLegacy()
        XCTAssertFalse(initial.blocked, initial.error ?? "")
        let stale = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(11))
        let active = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                       now: time.addingTimeInterval(11))
        XCTAssertTrue(stale.canEnableDualFSRS)
        let token = try XCTUnwrap(active.engine?.presentation?.id)
        active.rate(remembered: true, token: token, now: time.addingTimeInterval(12))
        XCTAssertNil(active.error)
        let latest = try Data(contentsOf: f.currentURL)
        let latestState = try XCTUnwrap(active.engine?.state)
        XCTAssertNotEqual(latest, f.currentBytes)
        stale.reenableDualFSRS(now: time.addingTimeInterval(13))
        XCTAssertTrue(stale.blocked)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), latest)
        let retry = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(14))
        XCTAssertFalse(retry.blocked, retry.error ?? "")
        XCTAssertEqual(retry.engine?.state, latestState)
        retry.reenableDualFSRS(now: time.addingTimeInterval(15))
        XCTAssertFalse(retry.blocked, retry.error ?? "")
        XCTAssertEqual(retry.engine?.state.word, latestState.word)
        XCTAssertEqual(retry.engine?.state.dualFSRS?.legacyRatings.count, latestState.word.attempts.count)
        try assertMarkers(f)
    }

    @MainActor func testDeferredLegacyQueueCanResumeAndMigratesLatestHeadOnlyAfterDrain() async throws {
        let f = try fixtureWithRealDeferredCQueue()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                      now: time.addingTimeInterval(10))
        XCTAssertFalse(store.blocked, store.error ?? "")
        XCTAssertTrue(store.isDualMigrationPending)
        XCTAssertFalse(try XCTUnwrap(store.engine?.usesDualFSRS))
        XCTAssertEqual(try Data(contentsOf: f.currentURL), f.currentBytes)
        XCTAssertEqual(store.engine?.state, f.legacyState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("revisions").path))
        let token = try XCTUnwrap(store.engine?.presentation?.id)
        XCTAssertEqual(store.engine?.presentation?.revealed, true)
        store.start(now: time.addingTimeInterval(11))
        XCTAssertNil(store.error)
        XCTAssertTrue(store.isDualMigrationPending)
        XCTAssertEqual(store.engine?.presentation?.id, token)
        XCTAssertEqual(store.engine?.presentation?.revealed, true)
        XCTAssertFalse(try XCTUnwrap(store.engine?.state.word.deferredCards).isEmpty)
        var step = 0
        while !(store.engine?.state.word.deferredCards ?? [:]).isEmpty {
            step += 1
            XCTAssertLessThan(step, 20)
            if step >= 20 { break }
            let now = time.addingTimeInterval(Double(11 + step))
            if let presentation = store.engine?.presentation {
                if !presentation.revealed { store.reveal(token: presentation.id, now: now) }
                store.rate(remembered: true, token: presentation.id, now: now)
            } else { store.start(now: now) }
            XCTAssertFalse(store.blocked, store.error ?? "")
            XCTAssertNil(store.error)
            XCTAssertNil(store.engine?.state.dualFSRS)
        }
        let latestOld = try Data(contentsOf: f.currentURL)
        let latestState = try XCTUnwrap(store.engine?.state)
        XCTAssertTrue((latestState.word.deferredCards ?? [:]).isEmpty)
        XCTAssertNotEqual(latestOld, f.currentBytes)
        XCTAssertGreaterThan(latestState.word.attempts.count, f.legacyState.word.attempts.count)
        XCTAssertTrue(store.isDualMigrationPending)
        let migrateAt = time.addingTimeInterval(Double(12 + step))
        store.start(now: migrateAt)
        XCTAssertFalse(store.blocked, store.error ?? "")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isDualMigrationPending)
        XCTAssertTrue(try XCTUnwrap(store.engine?.usesDualFSRS))
        XCTAssertEqual(store.engine?.state.word, latestState.word)
        XCTAssertEqual(store.engine?.state.originalCardIDs, f.legacyState.originalCardIDs)
        XCTAssertEqual(store.engine?.state.dualFSRS?.legacyRatings.count, latestState.word.attempts.count)
        let hash = StudySHA256.hex(latestOld)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("revisions/\(hash).json")), latestOld)
        let v2 = try Data(contentsOf: f.currentURL)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: f.root, documentsDirectory: f.root,
                                         now: migrateAt.addingTimeInterval(1))
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertFalse(reopened.isDualMigrationPending)
        XCTAssertEqual(try Data(contentsOf: f.currentURL), v2)
        try assertMarkers(f)
    }
}
#endif
