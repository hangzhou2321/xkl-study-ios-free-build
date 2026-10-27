import Foundation
import XCTest
import CPocket
import StudyCore
@testable import StudyClientModel

final class HandbookWordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private func package(_ n: Int = 3) -> HandbookCardPackage {
        .init(id: "synthetic-handbook-word", subject: .computer, title: "Synthetic", revision: "1.0",
              source: .init(title: "Synthetic", fileName: "synthetic.pdf", sha256: String(repeating: "a", count: 64), pdfPageCount: 2, includedPages: [1]),
              chapters: [.init(id: "chapter", title: "Synthetic")], cards: (0..<n).map {
                  .init(id: "original-id-\($0)", sourceGroupIDs: ["group-\($0)"], topicNumber: 1, title: "Synthetic \($0)", prompt: "Recall",
                        answerSummary: "Source;value", blocks: [], sourcePages: [1], examples: [], sourceNotes: [], chapterID: "chapter")
              })
    }
    @MainActor private func english(_ n: Int) throws -> PocketEngine {
        var stream = UUID().uuid
        let values = [UInt32](repeating: 0, count: n)
        let pointer = withUnsafeBytes(of: &stream) { bytes in values.withUnsafeBufferPointer {
            xkl_engine_import_cards(UInt32(n), $0.baseAddress, UInt32(try! ConceptCalendar.studyDay(now)), UInt32.max,
                                    bytes.bindMemory(to: UInt8.self).baseAddress)
        } }!
        defer { xkl_engine_free(pointer) }
        var data = Data(count: xkl_engine_snapshot_size(pointer))
        _ = data.withUnsafeMutableBytes { xkl_engine_snapshot(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        return try PocketEngine(snapshot: data)
    }
    private func cards(_ data: Data, _ count: Int) -> [UInt32] {
        let p = data.withUnsafeBytes { xkl_engine_restore($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }!
        defer { xkl_engine_free(p) };return (0..<count).map { xkl_engine_card(p, UInt32($0)) }
    }
    @MainActor private func events(_ record: ProfessionalRecallRecord) throws -> [StudyEvent] {
        try (record.volumes.map(\.snapshot) + [record.snapshot]).flatMap { snapshot in
            let engine = try PocketEngine(snapshot: snapshot)
            return try engine.events(from: engine.logBase + 1)
        }
    }
    private func updatedPackage(_ original: HandbookCardPackage, appendingCard: Bool = false) throws -> HandbookCardPackage {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object["revision"] = appendingCard ? "1.2" : "1.1"
        var source = object["source"] as! [String: Any]
        source["title"] = "Revised source metadata"; source["sha256"] = String(repeating: "b", count: 64)
        object["source"] = source
        object["additionalSources"] = [["id": "supplement", "source": source]]
        var rows = object["cards"] as! [[String: Any]]
        for index in rows.indices {
            rows[index]["answerSummary"] = "Updated answer for " + (rows[index]["id"] as! String)
            rows[index]["sourceReferences"] = [["sourceID": "supplement", "page": 1]]
        }
        if appendingCard {
            let extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(package(original.cards.count + 1).cards.last!)) as! [String: Any]
            rows.insert(extra, at: 0)
        }
        // Reordering the content must not reorder the permanent English C slots.
        object["cards"] = Array(rows.reversed())
        return try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    @MainActor func testExactEnglishAnswerPathRepeatsLevelsAndDueDays() async throws {
        let book = try HandbookWordEngine(package: package(), now: now), direct = try english(3)
        let day = UInt32(try ConceptCalendar.studyDay(now))
        try book.start(now: now);try direct.start(day: day)
        var policy = StudyAnalysisSettings(streamID: try direct.streamID, nextSequence: 1, now: now)
        var count = 0, stages: [UInt32] = []
        while let shown = book.presentation {
            let expected = try direct.info
            XCTAssertEqual(book.currentCard?.id, "original-id-\(expected.word)")
            stages.append(expected.stage)
            try book.reveal(token: shown.id, now: now);try direct.reveal()
            let remembered = count != 0
            try book.rate(remembered: remembered, token: shown.id, now: now)
            if let decision = try direct.answer(remembered ? 0 : 1, policy: policy) { policy.reductions.append(decision) }
            XCTAssertEqual(cards(book.record.snapshot, 3), cards(try direct.snapshot(), 3))
            XCTAssertEqual(try direct.info.has_task != 0, book.presentation != nil)
            count += 1;XCTAssertLessThan(count, 40)
            if count >= 40 { break }
        }
        XCTAssertTrue(Set(1...7).isSubset(of: Set(stages)))
        XCTAssertEqual(book.record.attempts.count, count)
        XCTAssertTrue(book.record.migration.sourceRecords.isEmpty)
        XCTAssertNotNil(book.nextDueAt)
        let next = now.addingTimeInterval(86_400)
        try book.start(now: next);try direct.start(day: UInt32(ConceptCalendar.studyDay(next)))
        XCTAssertEqual(book.currentCard?.id, "original-id-\(try direct.info.word)")
        XCTAssertEqual(cards(book.record.snapshot, 3), cards(try direct.snapshot(), 3))
    }
    @MainActor func testOriginalFirstKnownGraduationAndNoRevealGrade() async throws {
        let book = try HandbookWordEngine(package: package(1), now: now)
        try book.start(now: now);let token = try XCTUnwrap(book.presentation?.id)
        try book.reveal(token: token, now: now);XCTAssertTrue(book.record.attempts.isEmpty)
        try book.rate(remembered: true, token: token, now: now)
        XCTAssertNil(book.presentation);XCTAssertNil(book.nextDueAt)
        let before = book.state;try book.rate(remembered: false, token: token, now: now)
        XCTAssertEqual(book.state, before)
    }
    @MainActor func testResumeAcrossDaysAndContentUpdateKeepOriginalIDsAndFrozenFace() async throws {
        let original = package(),book = try HandbookWordEngine(package: original, now: now)
        try book.start(now: now);let token = try XCTUnwrap(book.presentation?.id);try book.reveal(token: token, now: now)
        let restored = try HandbookWordEngine(state: JSONDecoder().decode(HandbookWordState.self, from: JSONEncoder().encode(book.state)))
        try restored.start(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(restored.presentation?.id, token);XCTAssertEqual(restored.presentation?.revealed, true)
        let frozen = restored.currentCard, before = restored.record
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object["revision"] = "1.1";var rows = object["cards"] as! [[String: Any]];rows[0]["answerSummary"] = "Updated source";object["cards"] = rows
        let updated = try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
        try restored.updatePackage(updated, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(restored.record, before);XCTAssertEqual(restored.currentCard, frozen)
        XCTAssertEqual(restored.state.originalCardIDs, original.cards.map(\.id))
        XCTAssertEqual(restored.package.cards[0].answerSummary, "Updated source")
    }
    @MainActor func testContentSourceUpdateAndAddedCardPreserveAnsweredStreamAndFrozenFace() async throws {
        let original = package(), book = try HandbookWordEngine(package: original, now: now)
        try book.start(now: now)
        let first = try XCTUnwrap(book.presentation?.id)
        try book.reveal(token: first, now: now); try book.rate(remembered: false, token: first, now: now)
        let token = try XCTUnwrap(book.presentation?.id)
        try book.reveal(token: token, now: now)
        let before = book.record, frozen = book.currentCard, ids = book.state.originalCardIDs
        let oldEvents = try events(before), stream = try PocketEngine(snapshot: before.snapshot).streamID
        XCTAssertEqual(before.attempts.count, 1); XCTAssertFalse(oldEvents.isEmpty)

        let edited = try updatedPackage(original)
        try book.updatePackage(edited, now: now)
        XCTAssertEqual(book.record, before)
        XCTAssertEqual(book.state.originalCardIDs, ids)
        XCTAssertEqual(book.currentCard, frozen)
        XCTAssertEqual(book.presentation?.id, token); XCTAssertEqual(book.presentation?.revealed, true)
        XCTAssertEqual(book.package.source.title, "Revised source metadata")
        XCTAssertEqual(book.package.additionalSources?.count, 1)
        try book.updatePackage(edited, now: now)
        XCTAssertEqual(book.record, before)

        let appended = try updatedPackage(original, appendingCard: true)
        try book.updatePackage(appended, now: now)
        XCTAssertEqual(book.state.originalCardIDs, ids + ["original-id-3"])
        XCTAssertEqual(book.record.cardIDs, before.cardIDs + ["handbook:3"])
        XCTAssertEqual(cards(book.record.snapshot, 3), cards(before.snapshot, 3))
        XCTAssertEqual(cards(book.record.snapshot, 4).last, 0)
        XCTAssertEqual(book.record.attempts, before.attempts)
        XCTAssertEqual(book.record.migration, before.migration)
        XCTAssertEqual(book.record.analysis, before.analysis)
        XCTAssertEqual(book.record.volumes, before.volumes)
        XCTAssertEqual(Array(try events(book.record).prefix(oldEvents.count)), oldEvents)
        XCTAssertEqual(try PocketEngine(snapshot: book.record.snapshot).streamID, stream)
        XCTAssertEqual(book.record.contentChanges?.last?.beforeSnapshot, before.snapshot)
        XCTAssertEqual(book.currentCard, frozen)
        XCTAssertEqual(book.presentation?.id, token); XCTAssertEqual(book.presentation?.revealed, true)
        let afterAppend = book.state
        try book.updatePackage(appended, now: now); XCTAssertEqual(book.state, afterAppend)

        let reopened = try HandbookWordEngine(state: JSONDecoder().decode(HandbookWordState.self, from: JSONEncoder().encode(book.state)))
        XCTAssertEqual(reopened.state, afterAppend)
        try reopened.rate(remembered: true, token: token, now: now)
        XCTAssertNotEqual(reopened.presentation?.id, token)
        let next = try XCTUnwrap(reopened.currentCard)
        XCTAssertEqual(next, appended.cards.first { $0.id == next.id })
        XCTAssertEqual(reopened.record.attempts.count, before.attempts.count + 1)
        XCTAssertEqual(Array(reopened.record.attempts.prefix(before.attempts.count)), before.attempts)
    }
    #if canImport(Combine)
    private func stagedPackage(_ base: HandbookCardPackage, id: String? = nil, subject: String? = nil,
                               revision: String, answer: String? = nil) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        if let id { object["id"] = id }
        if let subject { object["subject"] = subject }
        object["revision"] = revision
        if let answer {
            var cards = object["cards"] as! [[String: Any]]
            cards[0]["answerSummary"] = answer; object["cards"] = cards
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    @MainActor func testStagedRecommendationUpdatesWithoutChangingLearningOrOriginalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-staged-update-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("HandbookCards")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let old = try stagedPackage(package(), revision: "1.23.1")
        let fresh = try stagedPackage(package(), revision: "1.26", answer: "Updated source")
        let oldURL = staging.appendingPathComponent("computer-old.xklflashcards")
        let newURL = staging.appendingPathComponent("computer-new.xklflashcards")
        try old.write(to: oldURL); try fresh.write(to: newURL)
        try Data("invalid".utf8).write(to: staging.appendingPathComponent("computer-bad.json"))
        let oversizedURL = staging.appendingPathComponent("computer-oversized.json")
        try stagedPackage(package(), revision: "99.0").write(to: oversizedURL)
        let largeFile = try FileHandle(forWritingTo: oversizedURL)
        try largeFile.seekToEnd()
        let padding = Data(repeating: 0x20, count: 1_024 * 1_024)
        for _ in 0..<40 { try largeFile.write(contentsOf: padding) }
        try largeFile.close()
        XCTAssertGreaterThan(try XCTUnwrap(oversizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize), 40 * 1_024 * 1_024)
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        store.importData(old); store.start(now: now)
        let first = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: first, now: now); store.rate(remembered: false, token: first, now: now)
        let active = try XCTUnwrap(store.engine?.presentation?.id); store.reveal(token: active, now: now)
        let before = try XCTUnwrap(store.engine?.state), eventsBefore = try events(before.word)
        let currentURL = root.appendingPathComponent("HandbookWordRecall/computer/current.json")
        let currentBefore = try Data(contentsOf: currentURL)
        let archiveBefore = try JSONDecoder().decode(Archive.self, from: store.exportRecords())
        XCTAssertEqual(store.recommendedStagedFile(), newURL)
        XCTAssertEqual(store.engine?.state, before)
        XCTAssertEqual(try Data(contentsOf: currentURL), currentBefore)
        store.importContent(try XCTUnwrap(store.recommendedStagedFile()))
        XCTAssertNil(store.error)
        let after = try XCTUnwrap(store.engine?.state)
        XCTAssertEqual(after.originalCardIDs, before.originalCardIDs)
        XCTAssertEqual(after.word, before.word)
        XCTAssertEqual(cards(after.word.snapshot, 3), cards(before.word.snapshot, 3))
        XCTAssertEqual(try events(after.word), eventsBefore)
        XCTAssertEqual(after.frozenToken, before.frozenToken)
        XCTAssertEqual(after.frozenCard, before.frozenCard)
        let currentAfter = try Data(contentsOf: currentURL)
        store.importContent(newURL)
        XCTAssertEqual(try Data(contentsOf: currentURL), currentAfter)
        let archiveAfter = try JSONDecoder().decode(Archive.self, from: store.exportRecords())
        for key in ["initial.json", "legacy-baseline.json", "imports/\(StudySHA256.hex(old)).xklflashcards"] {
            XCTAssertEqual(archiveAfter.files[key], archiveBefore.files[key])
        }
        XCTAssertEqual(archiveAfter.files["revisions/\(StudySHA256.hex(currentBefore)).json"], currentBefore)
        XCTAssertEqual(try Data(contentsOf: oldURL), old)
        XCTAssertEqual(try Data(contentsOf: newURL), fresh)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertEqual(reopened.engine?.state, after)
    }
    @MainActor func testStagedRecommendationRejectsAmbiguousIDsAndConflictingTopVersionsSeparatelyPerSubject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-staged-ambiguous-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("HandbookCards")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        func stage(_ name: String, _ data: Data) throws -> URL {
            let url = staging.appendingPathComponent(name); try data.write(to: url); return url
        }
        let computerOld = try stagedPackage(package(), revision: "1.23.1")
        let computerNew = try stagedPackage(package(), revision: "1.26")
        let computerOldURL = try stage("a.xklflashcards", computerOld)
        let computerNewURL = try stage("b.xklflashcards", computerNew)
        _ = try stage("numeric-1.9.xklflashcards", stagedPackage(package(), revision: "1.9"))
        let otherURL = try stage("c.xklflashcards", stagedPackage(package(), id: "different", revision: "9.0"))
        let powerOld = try stagedPackage(package(), id: "power-package", subject: "power", revision: "1.24.0")
        let powerNew = try stagedPackage(package(), id: "power-package", subject: "power", revision: "1.26")
        _ = try stage("d.xklflashcards", powerOld)
        let powerNewURL = try stage("e.xklflashcards", powerNew)
        let computer = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        let power = HandbookWordStore(subject: .power, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertNil(computer.recommendedStagedFile(), "Different package IDs require manual selection before first import.")
        XCTAssertEqual(power.recommendedStagedFile(), powerNewURL)
        computer.importData(computerOld); power.importData(powerOld)
        XCTAssertEqual(computer.recommendedStagedFile(), computerNewURL)
        XCTAssertEqual(power.recommendedStagedFile(), powerNewURL)
        let duplicateURL = try stage("z.xklflashcards", computerNew)
        XCTAssertEqual(computer.recommendedStagedFile(), computerNewURL, "Equivalent duplicates are unambiguous.")
        try FileManager.default.removeItem(at: duplicateURL)
        var removedCard = try JSONSerialization.jsonObject(with: computerNew) as! [String: Any]
        removedCard["revision"] = "1.27"
        var rows = removedCard["cards"] as! [[String: Any]]; rows.removeFirst(); removedCard["cards"] = rows
        let removedURL = try stage("removed.xklflashcards", JSONSerialization.data(withJSONObject: removedCard, options: [.sortedKeys]))
        XCTAssertNil(computer.recommendedStagedFile(), "A top package that drops an existing ID is not offered.")
        try FileManager.default.removeItem(at: removedURL)
        let computerBefore = try XCTUnwrap(computer.engine?.state), powerBefore = try XCTUnwrap(power.engine?.state)
        let conflictURL = try stage("f.xklflashcards", stagedPackage(package(), revision: "1.26", answer: "Conflicting source"))
        XCTAssertNil(computer.recommendedStagedFile())
        XCTAssertEqual(power.recommendedStagedFile(), powerNewURL)
        XCTAssertEqual(computer.engine?.state, computerBefore); XCTAssertEqual(power.engine?.state, powerBefore)
        try FileManager.default.removeItem(at: conflictURL)
        try FileManager.default.removeItem(at: computerNewURL)
        XCTAssertEqual(computer.recommendedStagedFile(), computerOldURL)
        computer.importData(computerNew)
        XCTAssertNil(computer.recommendedStagedFile(), "The only matching staged package is older than the installed one.")
        XCTAssertEqual(power.engine?.state, powerBefore)
        XCTAssertEqual(try Data(contentsOf: otherURL), try stagedPackage(package(), id: "different", revision: "9.0"))
    }
    private struct Archive: Decodable {
        struct Entry: Decodable {
            let storedKey: String
            let sha256: String
            let originalRelativePath: String?
            let candidateRelativePaths: [String]
            let resolution: String
        }
        let files: [String: Data]
        let currentLegacyFiles: [String: Data]
        let legacyBaselineMappingPolicy: String
        let legacyBaselineIndex: [Entry]
    }
    func testArchiveRelativeKeysResolveRootAliasesAndRejectEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-path-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical"), alias = root.appendingPathComponent("alias")
        let book = physical.appendingPathComponent("HandbookCards/computer")
        try FileManager.default.createDirectory(at: book.appendingPathComponent("imports"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let aliasedBook = alias.appendingPathComponent("HandbookCards/computer")
        let file = book.appendingPathComponent("imports/source.xklflashcards")
        try Data("synthetic".utf8).write(to: file)
        XCTAssertEqual(try HandbookWordArchivePath.relativeKey(for: file, within: aliasedBook), "imports/source.xklflashcards")
        XCTAssertEqual(try HandbookWordArchivePath.relativeKey(for: aliasedBook.appendingPathComponent("imports/source.xklflashcards"), within: book), "imports/source.xklflashcards")
        XCTAssertEqual(try HandbookWordArchivePath.relativeKey(for: file, within: book.appendingPathComponent(".")), "imports/source.xklflashcards")
        XCTAssertThrowsError(try HandbookWordArchivePath.relativeKey(for: book, within: book))
        XCTAssertThrowsError(try HandbookWordArchivePath.relativeKey(for: physical.appendingPathComponent("HandbookCards/computer-other/current.json"), within: book))
        XCTAssertThrowsError(try HandbookWordArchivePath.relativeKey(for: book.appendingPathComponent("../outside.json"), within: book))
        XCTAssertThrowsError(try HandbookWordArchivePath.relativeKey(for: URL(string: "https://example.invalid/current.json")!, within: book))
        let outside = root.appendingPathComponent("outside.json"), escape = book.appendingPathComponent("escape.json")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        XCTAssertThrowsError(try HandbookWordArchivePath.relativeKey(for: escape, within: book))
        for key in ["", "/current.json", "../current.json", "a/../current.json", "a//current.json", "a\\current.json", "C:current.json"] {
            XCTAssertFalse(HandbookWordArchivePath.isSafeRelativeKey(key), key)
        }
    }
    @MainActor func testStoreThroughRootAliasExportsActualRelativeKeysAndRejectsNestedSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let old = HandbookCardStore(subject: .computer, baseDirectory: physical, documentsDirectory: physical)
        let raw = try JSONEncoder().encode(package()); old.importData(raw)
        let store = HandbookWordStore(subject: .computer, baseDirectory: alias, documentsDirectory: alias, now: now)
        XCTAssertFalse(store.blocked, store.error ?? "")
        let archive = try JSONDecoder().decode(Archive.self, from: store.exportRecords())
        let hash = StudySHA256.hex(raw)
        XCTAssertEqual(Set(archive.currentLegacyFiles.keys), ["current.json", "initial.json", "imports/\(hash).xklflashcards"])
        XCTAssertEqual(Set(archive.files.keys), ["current.json", "initial.json", "legacy-baseline.json", "imports/\(hash).xklflashcards"])
        XCTAssertTrue(archive.legacyBaselineIndex.allSatisfy { $0.storedKey == $0.originalRelativePath && $0.resolution == "exact-path-and-bytes" })
        for (key, bytes) in archive.files {
            XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent("HandbookWordRecall/computer/" + key)), bytes)
        }
        let escape = physical.appendingPathComponent("HandbookWordRecall/computer/escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: physical.appendingPathComponent("HandbookCards"))
        XCTAssertThrowsError(try store.exportRecords())
        XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent("HandbookWordRecall/computer/current.json")), archive.files["current.json"])
        try FileManager.default.removeItem(at: escape)
        let legacy = physical.appendingPathComponent("HandbookCards"), externalLegacy = root.appendingPathComponent("external-legacy")
        try FileManager.default.moveItem(at: legacy, to: externalLegacy)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: externalLegacy)
        XCTAssertThrowsError(try store.exportRecords(), "An ancestor link must not move the scanned root outside the store base.")
        XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent("HandbookWordRecall/computer/current.json")), archive.files["current.json"])
    }
    @MainActor func testStoreArchivesOldSelfRatingsWithoutReplayingAndReimportDoesNotReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-book-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try JSONEncoder().encode(package())
        let old = HandbookCardStore(subject: .computer, baseDirectory: root, documentsDirectory: root)
        old.importData(raw);old.start(now: now);let oldToken = try XCTUnwrap(old.engine?.presentation?.id)
        old.reveal(token: oldToken, now: now);old.rate(remembered: true, token: oldToken, now: now)
        let oldURL = root.appendingPathComponent("HandbookCards/computer/current.json"), oldBytes = try Data(contentsOf: oldURL)
        let migrated = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(migrated.blocked, migrated.error ?? "");XCTAssertTrue(try XCTUnwrap(migrated.engine).record.attempts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        let currentURL = root.appendingPathComponent("HandbookWordRecall/computer/current.json"), initialBytes = try Data(contentsOf: currentURL)
        migrated.importData(raw);XCTAssertEqual(try Data(contentsOf: currentURL), initialBytes)
        migrated.start(now: now);let p = try XCTUnwrap(migrated.engine?.presentation)
        migrated.reveal(token: p.id, now: now)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertEqual(reopened.engine?.presentation?.id, p.id);XCTAssertEqual(reopened.engine?.presentation?.revealed, true)
        reopened.rate(remembered: false, token: p.id, now: now)
        let once = try Data(contentsOf: currentURL)
        reopened.rate(remembered: true, token: p.id, now: now);reopened.importData(raw)
        XCTAssertEqual(try Data(contentsOf: currentURL), once);XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertFalse(try reopened.exportRecords().isEmpty)
    }
    @MainActor func testExistingPrefixedBaselineRemainsByteIdenticalAndExportsEvidenceOnlyMapping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-old-keys-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try JSONEncoder().encode(package())
        let old = HandbookCardStore(subject: .computer, baseDirectory: root, documentsDirectory: root)
        old.importData(raw)
        let legacyRoot = root.appendingPathComponent("HandbookCards/computer")
        try FileManager.default.createDirectory(at: legacyRoot.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let collision = Data("duplicate synthetic bytes".utf8)
        try collision.write(to: legacyRoot.appendingPathComponent("collision.json"))
        try collision.write(to: legacyRoot.appendingPathComponent("nested/collision.json"))
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        store.start(now: now)
        let first = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: first, now: now); store.rate(remembered: false, token: first, now: now)
        let shown = try XCTUnwrap(store.engine?.presentation?.id); store.reveal(token: shown, now: now)
        let expected = try XCTUnwrap(store.engine?.state)
        let directory = root.appendingPathComponent("HandbookWordRecall/computer")
        let baselineURL = directory.appendingPathComponent("legacy-baseline.json"), currentURL = directory.appendingPathComponent("current.json")
        let initial = try Data(contentsOf: directory.appendingPathComponent("initial.json"))

        // Construct a synthetic already-written build-45 archive, including keys
        // with no unique evidence. Production code must never rewrite this fixture.
        var baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as! [String: Any]
        let originalFiles = baseline["legacyFiles"] as! [String: String]
        var malformed = Dictionary(uniqueKeysWithValues: originalFiles.map { ("omputer/" + $0.key, $0.value) })
        malformed["omputer/missing.json"] = Data("archived-only-history".utf8).base64EncodedString()
        malformed["../current.json"] = originalFiles["current.json"]
        baseline["legacyFiles"] = malformed
        let oldBaseline = try JSONSerialization.data(withJSONObject: baseline, options: [.prettyPrinted, .sortedKeys])
        try oldBaseline.write(to: baselineURL)
        var disk = try JSONSerialization.jsonObject(with: Data(contentsOf: currentURL)) as! [String: Any]
        disk["baselineSHA256"] = StudySHA256.hex(oldBaseline)
        let oldCurrent = try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys])
        try oldCurrent.write(to: currentURL)

        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.state, expected)
        reopened.importData(raw)
        XCTAssertEqual(try Data(contentsOf: currentURL), oldCurrent)
        let archive = try JSONDecoder().decode(Archive.self, from: reopened.exportRecords())
        XCTAssertEqual(archive.files["legacy-baseline.json"], oldBaseline)
        XCTAssertEqual(try Data(contentsOf: baselineURL), oldBaseline)
        XCTAssertEqual(try Data(contentsOf: currentURL), oldCurrent)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("initial.json")), initial)
        XCTAssertEqual(archive.legacyBaselineIndex.count, malformed.count)
        XCTAssertTrue(archive.legacyBaselineMappingPolicy.contains("original-baseline-bytes-and-stored-keys-retained"))
        for key in ["current.json", "initial.json", "imports/\(StudySHA256.hex(raw)).xklflashcards"] {
            let entry = try XCTUnwrap(archive.legacyBaselineIndex.first { $0.storedKey == "omputer/" + key })
            XCTAssertEqual(entry.originalRelativePath, key)
            XCTAssertEqual(entry.resolution, "unique-suffix-and-bytes")
            XCTAssertEqual(entry.sha256, StudySHA256.hex(try XCTUnwrap(archive.currentLegacyFiles[key])))
        }
        let ambiguous = try XCTUnwrap(archive.legacyBaselineIndex.first { $0.storedKey == "omputer/nested/collision.json" })
        XCTAssertNil(ambiguous.originalRelativePath)
        XCTAssertEqual(ambiguous.candidateRelativePaths, ["collision.json", "nested/collision.json"])
        XCTAssertEqual(ambiguous.resolution, "ambiguous-retained")
        let missing = try XCTUnwrap(archive.legacyBaselineIndex.first { $0.storedKey == "omputer/missing.json" })
        XCTAssertNil(missing.originalRelativePath); XCTAssertEqual(missing.resolution, "unresolved-retained")
        let unsafe = try XCTUnwrap(archive.legacyBaselineIndex.first { $0.storedKey == "../current.json" })
        XCTAssertNil(unsafe.originalRelativePath); XCTAssertEqual(unsafe.resolution, "unsafe-stored-key-retained")
        XCTAssertEqual(reopened.engine?.state, expected)
    }
    @MainActor func testStoreContentUpdatesKeepActiveLearningAndImmutableArchivesAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-content-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        let original = package(), raw = try JSONEncoder().encode(original)
        store.importData(raw); store.start(now: now)
        let first = try XCTUnwrap(store.engine?.presentation?.id)
        store.reveal(token: first, now: now); store.rate(remembered: false, token: first, now: now)
        let shown = try XCTUnwrap(store.engine?.presentation?.id); store.reveal(token: shown, now: now)
        let before = try XCTUnwrap(store.engine?.state), originalEvents = try events(before.word)
        let beforeExport = try JSONDecoder().decode(Archive.self, from: store.exportRecords())
        let currentURL = root.appendingPathComponent("HandbookWordRecall/computer/current.json")
        let currentBefore = try Data(contentsOf: currentURL)
        store.importData(raw); XCTAssertEqual(try Data(contentsOf: currentURL), currentBefore)

        let edited = try updatedPackage(original), editedRaw = try JSONEncoder().encode(edited)
        store.importData(editedRaw)
        XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(store.engine?.record, before.word)
        XCTAssertEqual(store.engine?.state.originalCardIDs, before.originalCardIDs)
        XCTAssertEqual(store.engine?.currentCard, before.frozenCard)
        let editedCurrent = try Data(contentsOf: currentURL)
        store.importData(editedRaw); XCTAssertEqual(try Data(contentsOf: currentURL), editedCurrent)

        let appended = try updatedPackage(original, appendingCard: true), appendedRaw = try JSONEncoder().encode(appended)
        store.importData(appendedRaw)
        XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        let after = try XCTUnwrap(store.engine?.state)
        XCTAssertEqual(after.originalCardIDs, before.originalCardIDs + ["original-id-3"])
        XCTAssertEqual(after.word.cardIDs, before.word.cardIDs + ["handbook:3"])
        XCTAssertEqual(after.word.attempts, before.word.attempts)
        XCTAssertEqual(cards(after.word.snapshot, 3), cards(before.word.snapshot, 3))
        XCTAssertEqual(Array(try events(after.word).prefix(originalEvents.count)), originalEvents)
        XCTAssertEqual(after.word.contentChanges?.last?.beforeSnapshot, before.word.snapshot)
        XCTAssertEqual(after.frozenCard, before.frozenCard); XCTAssertEqual(after.frozenToken, before.frozenToken)
        let appendedCurrent = try Data(contentsOf: currentURL)
        store.importData(appendedRaw); XCTAssertEqual(try Data(contentsOf: currentURL), appendedCurrent)

        let archive = try JSONDecoder().decode(Archive.self, from: store.exportRecords())
        for key in ["initial.json", "legacy-baseline.json", "imports/\(StudySHA256.hex(raw)).xklflashcards"] {
            XCTAssertEqual(archive.files[key], beforeExport.files[key])
        }
        XCTAssertEqual(archive.files["revisions/\(StudySHA256.hex(currentBefore)).json"], currentBefore)
        XCTAssertEqual(archive.files["revisions/\(StudySHA256.hex(editedCurrent)).json"], editedCurrent)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(reopened.blocked, reopened.error ?? ""); XCTAssertEqual(reopened.engine?.state, after)
        reopened.importData(appendedRaw); XCTAssertEqual(try Data(contentsOf: currentURL), appendedCurrent)
        reopened.rate(remembered: true, token: shown, now: now)
        XCTAssertNil(reopened.error)
        let next = try XCTUnwrap(reopened.engine?.currentCard)
        XCTAssertNotEqual(reopened.engine?.presentation?.id, shown)
        XCTAssertEqual(next, appended.cards.first { $0.id == next.id })
        XCTAssertEqual(reopened.engine?.record.attempts.count, before.word.attempts.count + 1)
    }
    @MainActor func testCommittedWriteFailureKeepsNewAnswerAndNeverReplaysIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-word-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var failAfterCommit = false
        let store = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now, writer: { data,url in
            try data.write(to: url, options: .atomic)
            if failAfterCommit { throw NSError(domain: "SyntheticPostCommit", code: 1) }
        })
        store.importData(try JSONEncoder().encode(package()));store.start(now: now)
        let token = try XCTUnwrap(store.engine?.presentation?.id);store.reveal(token: token, now: now)
        failAfterCommit = true;store.rate(remembered: false, token: token, now: now)
        XCTAssertTrue(store.blocked)
        let reopened = HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root, now: now)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "");XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        let path = root.appendingPathComponent("HandbookWordRecall/computer/current.json"),before = try Data(contentsOf: path)
        reopened.rate(remembered: true, token: token, now: now)
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
    #endif
}
