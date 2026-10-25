#if os(macOS)
import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Real temporary-directory transactions. Every bank/card/record is synthetic.
final class ProfessionalRecallStoreTests: XCTestCase {
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func fixture() throws -> (ConceptBank, ConceptTeaching) {
        let questions = (0..<2).map { ConceptQuestion(id: "synthetic-q\($0)", type: .single,
            prompt: "Synthetic question \($0)?", options: [.init(id: "A", text: "First"), .init(id: "B", text: "Second")],
            answer: ["A"], explanation: "Synthetic explanation", sourceIDs: ["synthetic-source"],
            sourceLocation: "Synthetic only", verification: "Synthetic verified") }
        let cards = (0..<3).map { RecallCard(id: "synthetic-concept:\($0)", prompt: "Synthetic card \($0)?", answer: "Synthetic answer \($0)") }
        let group = SupplementRecallGroup(id: "synthetic-group", title: "Synthetic supplement", branchID: "main",
            recallCards: (0..<2).map { RecallCard(id: "synthetic-group:\($0)", prompt: "Synthetic supplement \($0)?", answer: "Synthetic answer") })
        let bank = ConceptBank(id: ConceptSubject.computer.bankID, title: "Synthetic", scope: "Synthetic", notice: "Synthetic only",
            sources: [.init(id: "synthetic-source", title: "Synthetic source", reference: "fixture")],
            concepts: [.init(id: "synthetic-concept", title: "Synthetic concept", section: "Synthetic", method: "Synthetic method", questions: questions)])
        var teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: StudySHA256.hex(try encode(bank)),
            lessons: [.init(conceptID: "synthetic-concept", title: "Synthetic", story: "Story", keyIdea: "Idea", workedExample: "Example", commonTrap: "Trap", recallCards: cards)])
        let tree = SyllabusFixture.sample()
        teaching.syllabus = ConceptSyllabusTree(version: tree.version, title: tree.title, outlineSource: tree.outlineSource,
            frequencyNote: tree.frequencyNote, sources: tree.sources, branches: tree.branches,
            topics: tree.topics.map { .init(id: $0.id, branchID: $0.branchID, title: $0.title, conceptIDs: ["synthetic-concept"], coverageNote: $0.coverageNote) }, leaves: tree.leaves)
        teaching.recallGroups = [group]
        let primary = try RecallDeck.make(subject: .computer, bank: bank, teaching: teaching)
        teaching.primaryRecallDeck = primary
        teaching.studyPlan = ProfessionalStudyPlan(format: "xkl-professional-plan-v1", id: "synthetic-store-plan", subject: .computer,
            basePrimaryDeckSHA256: try primary.hash, mainlineCardIDs: Array(cards.prefix(2)).map(\.id), relatedCardIDs: [cards[2].id],
            mainlineSupplementGroupIDs: [group.id], relatedSupplementGroupIDs: [group.id],
            supplementSelections: [.init(groupID: group.id, mainlineCardIDs: [group.recallCards[0].id], relatedCardIDs: [group.recallCards[1].id])],
            priorityConceptIDs: ["synthetic-concept"], sourceQuestionIDs: questions.map(\.id))
        teaching.questionPresentations = questions.map { .init(questionID: $0.id, sourceQuestionDigest: $0.professionalDigest, requiredDiagram: false, beforeAnswer: [], afterAnswer: []) }
        teaching.questionLinks = [.init(questionID: questions[0].id, sourceQuestionDigest: questions[0].professionalDigest,
            primaryCardIDs: Array(cards.prefix(2)).map(\.id), supplementCardIDs: [group.recallCards[0].id], guideConceptIDs: [])]
        let diagram = ConceptDiagram(version: 1, title: "Synthetic", width: 320, height: 160, description: "Synthetic only",
            shapes: [.init(kind: "rect", x: 20, y: 20, width: 200, height: 80, stroke: "ink", fill: "white")], paths: [],
            labels: [.init(text: "Synthetic", x: 30, y: 30, width: 180, height: 30, size: 18, color: "ink", align: "leading", bold: false)])
        teaching.sourceLeaves = [.init(sourceQuestionID: "synthetic-source-q", sourceID: "synthetic-source", page: 1,
            label: "Synthetic original", status: "verified", bankQuestionID: questions[0].id,
            visual: .init(id: "synthetic-visual", kind: "vector", diagram: diagram), primaryCardIDs: [cards[0].id], supplementCardIDs: [],
            sourceStatus: .verified, courseReadiness: .ready, scope: .mainline, reason: "Synthetic verified original")]
        teaching.cardCorrections = []
        teaching.cardPriorities = (cards + group.recallCards).enumerated().map { index, card in
            ProfessionalCardPriority(cardID: card.id, sourceCardDigest: card.professionalDigest,
                level: index == 0 ? "priority" : ([1, 3].contains(index) ? "regular" : "extension"),
                classificationBasis: index == 0 ? "foundation" : ([1, 3].contains(index) ? "local_detail" : "extension"),
                reason: "Synthetic learning order", sourceQuestionIDs: [0, 3].contains(index) ? [questions[0].id] : [])
        }
        try teaching.validate(bank: bank, hash: teaching.bankSHA256)
        return (bank, teaching)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("professional-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func current(_ root: URL, _ scope: ProfessionalRecallScope = .mainline) -> URL {
        root.appendingPathComponent("ProfessionalRecall/computer/current.json")
    }
    private func baseline(_ root: URL) -> URL { root.appendingPathComponent("ProfessionalRecall/computer/legacy-baseline.json") }
    private struct SubjectDisk: Decodable { let records: [String: ProfessionalRecallRecord] }
    private func records(_ root: URL) throws -> [String: ProfessionalRecallRecord] {
        try JSONDecoder().decode(SubjectDisk.self, from: Data(contentsOf: current(root))).records
    }
    private func revision(_ root: URL, bytes: Data) -> URL {
        root.appendingPathComponent("ProfessionalRecall/computer/revisions/\(StudySHA256.hex(bytes)).json")
    }
    private func revisionCount(_ root: URL) throws -> Int {
        let directory = root.appendingPathComponent("ProfessionalRecall/computer/revisions")
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
    }

    /// Update only synthetic scope metadata / a supplementary card; frozen
    /// primary content and every existing ID remain unchanged.
    private func updated(_ base: ConceptTeaching, bank: ConceptBank,
                         promotePrimary: Bool = false, allMainline: Bool = false,
                         appendSupplement: Bool = false) throws -> ConceptTeaching {
        var teaching = base
        let old = try XCTUnwrap(base.studyPlan)
        if appendSupplement {
            let group = try XCTUnwrap(base.recallGroups?.first)
            let appended = RecallCard(id: "synthetic-group:2", prompt: "Synthetic appended question?", answer: "Synthetic appended answer")
            teaching.recallGroups = [SupplementRecallGroup(id: group.id, title: group.title, branchID: group.branchID,
                topicID: group.topicID, recallCards: group.recallCards + [appended])]
        }
        let primaryMain = allMainline || promotePrimary ? old.mainlineCardIDs + old.relatedCardIDs : old.mainlineCardIDs
        let primaryRelated = allMainline || promotePrimary ? [] : old.relatedCardIDs
        let selections = old.supplementSelections.map { selection in
            ProfessionalSupplementSelection(groupID: selection.groupID,
                mainlineCardIDs: selection.mainlineCardIDs + (allMainline ? selection.relatedCardIDs : [])
                    + (appendSupplement ? ["synthetic-group:2"] : []),
                relatedCardIDs: allMainline ? [] : selection.relatedCardIDs)
        }
        teaching.studyPlan = ProfessionalStudyPlan(format: old.format, id: old.id, subject: old.subject,
            basePrimaryDeckSHA256: old.basePrimaryDeckSHA256, mainlineCardIDs: primaryMain, relatedCardIDs: primaryRelated,
            mainlineSupplementGroupIDs: selections.filter { !$0.mainlineCardIDs.isEmpty }.map(\.groupID),
            relatedSupplementGroupIDs: selections.filter { !$0.relatedCardIDs.isEmpty }.map(\.groupID),
            supplementSelections: selections, priorityConceptIDs: old.priorityConceptIDs, sourceQuestionIDs: old.sourceQuestionIDs)
        let main = Set(primaryMain + selections.flatMap(\.mainlineCardIDs))
        let oldPriorities = Dictionary(uniqueKeysWithValues: (base.cardPriorities ?? []).map { ($0.cardID, $0) })
        let cards = (teaching.primaryRecallDeck?.cards.map(\.card) ?? []) + (teaching.recallGroups ?? []).flatMap(\.recallCards)
        teaching.cardPriorities = cards.map { card in
            let prior = oldPriorities[card.id]
            let priority = main.contains(card.id) && prior?.level == "priority"
            return ProfessionalCardPriority(cardID: card.id, sourceCardDigest: card.professionalDigest,
                level: main.contains(card.id) ? (priority ? "priority" : "regular") : "extension",
                classificationBasis: main.contains(card.id) ? (priority ? "foundation" : "local_detail") : "extension",
                reason: "Synthetic scope update", sourceQuestionIDs: prior?.sourceQuestionIDs ?? [])
        }
        try teaching.validate(bank: bank, hash: teaching.bankSHA256)
        return teaching
    }
    private func files(_ root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
    @MainActor private func startReveal(_ store: ProfessionalRecallStore) throws -> UUID {
        store.start(); XCTAssertFalse(store.blocked, store.error ?? "")
        let token = try XCTUnwrap(store.engine?.record.presentation?.id)
        store.reveal(token: token); XCTAssertFalse(store.blocked, store.error ?? "")
        XCTAssertTrue(store.engine?.record.presentation?.revealed == true)
        return token
    }

    @MainActor func testBothScopesHaveSeparateStateAndPreserveAllLegacyAndOtherRecords() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let old = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        old.act("start", newLimit: 3)
        let token = try XCTUnwrap(old.engine?.record.state.shown?.id)
        old.act("reveal", token: token); old.act("grade", token: token, remembered: false)
        let supplement = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root, supplementGroup: teaching.recallGroups![0])
        supplement.act("start", newLimit: 2)
        XCTAssertFalse(old.blocked); XCTAssertFalse(supplement.blocked)
        for name in ["English/snapshot.bin", "English/event-log.bin", "English/personal-state.bin", "PublicQuestions/current.json", "MathExperience/current.json", "ComputerFoundation/current.json", "PhoneArchive/archive.bin"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("Synthetic protected " + name).utf8).write(to: url)
        }
        let protected = try files(root)
        let main = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let related = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, scope: .related, baseDirectory: root)
        XCTAssertFalse(main.blocked, main.error ?? ""); XCTAssertFalse(related.blocked, related.error ?? "")
        let mainIDs = try XCTUnwrap(main.engine?.record.cardIDs), relatedIDs = try XCTUnwrap(related.engine?.record.cardIDs)
        XCTAssertEqual(Set(mainIDs), Set(["synthetic-concept:0", "synthetic-concept:1", "synthetic-group:0"]))
        XCTAssertEqual(Set(relatedIDs), Set(["synthetic-concept:2", "synthetic-group:1"]))
        XCTAssertTrue(Set(mainIDs).isDisjoint(with: relatedIDs))
        XCTAssertTrue(main.engine?.record.attempts.isEmpty == true)
        let relatedRecord = try XCTUnwrap(records(root)[ProfessionalRecallScope.related.rawValue])
        let baselineBytes = try Data(contentsOf: baseline(root))
        let mainToken = try startReveal(main); main.grade(remembered: true, token: mainToken)
        XCTAssertEqual(main.engine?.record.attempts.count, 1)
        XCTAssertEqual(try records(root)[ProfessionalRecallScope.related.rawValue], relatedRecord)
        XCTAssertEqual(try Data(contentsOf: baseline(root)), baselineBytes)
        for (path, bytes) in protected { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes, path) }
        let savedBaseline = try JSONDecoder().decode(ProfessionalRecallBaseline.self, from: baselineBytes)
        XCTAssertFalse(savedBaseline.files.isEmpty)
        for file in savedBaseline.files { XCTAssertEqual(StudySHA256.hex(file.bytes), file.sha256) }
    }

    @MainActor func testRepeatedStartRevealAndGradeTokenDoNotAppendAgainAndColdResumeRetainsAnswer() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let store = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let token = try startReveal(store), revealed = try Data(contentsOf: current(root))
        store.start(); store.reveal(token: token)
        XCTAssertEqual(try Data(contentsOf: current(root)), revealed)
        let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertEqual(reopened.engine?.record.presentation?.id, token)
        XCTAssertTrue(reopened.engine?.record.presentation?.revealed == true)
        reopened.grade(remembered: true, token: token)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
        let graded = try Data(contentsOf: current(root))
        reopened.grade(remembered: true, token: token); reopened.reveal(token: token)
        XCTAssertEqual(try Data(contentsOf: current(root)), graded)
        XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
    }

    @MainActor func testLegacyCreationMarkerWithoutArchiveBlocksBeforeMigration() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let hash = try XCTUnwrap(teaching.primaryRecallDeck).hash
        let marker = root.appendingPathComponent("RecallCards/computer/\(hash)/created.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try encode(hash); try bytes.write(to: marker)
        let store = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertTrue(store.blocked); XCTAssertNil(store.engine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current(root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseline(root).path))
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
    }

    @MainActor func testMissingBaselineInitialOrCurrentNeverCreatesFreshState() throws {
        for missing in ["legacy-baseline.json", "initial.json", "current.json"] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let (bank, teaching) = try fixture()
            let store = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
            let token = try startReveal(store); store.grade(remembered: false, token: token)
            XCTAssertFalse(store.blocked)
            let target = root.appendingPathComponent("ProfessionalRecall/computer/" + missing)
            try FileManager.default.removeItem(at: target)
            let remaining = try files(root)
            let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
            XCTAssertTrue(reopened.blocked, missing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), missing)
            XCTAssertEqual(try files(root), remaining, missing)
        }
    }

    @MainActor func testMetadataAndCatalogReorderingRetainPermanentIDsAndSnapshot() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let store = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let token = try startReveal(store); store.grade(remembered: false, token: token)
        let record = try XCTUnwrap(store.engine?.record), bytes = try Data(contentsOf: current(root))
        var changed = teaching
        changed.cardPriorities = teaching.cardPriorities!.reversed().map {
            ProfessionalCardPriority(cardID: $0.cardID, sourceCardDigest: $0.sourceCardDigest, level: $0.level,
                classificationBasis: $0.classificationBasis, reason: "Edited synthetic presentation reason", sourceQuestionIDs: $0.sourceQuestionIDs)
        }
        let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.record, record)
        XCTAssertEqual(try Data(contentsOf: current(root)), bytes)
        let catalog = try ProfessionalRecallCatalog.make(subject: .computer, bank: bank, teaching: changed, scope: .mainline)
        let reordered = RecallDeck(subject: catalog.subject, bankID: catalog.bankID, cards: Array(catalog.cards.reversed()))
        let restoredOrder = try ProfessionalRecallCatalog.usingStoredOrder(reordered, cardIDs: record.cardIDs)
        XCTAssertEqual(restoredOrder.cards.map(\.id), record.cardIDs)
        XCTAssertEqual(try ProfessionalRecallEngine(deck: restoredOrder, record: record).record.snapshot, record.snapshot)
    }

    private final class FaultWriter {
        enum Failure: Equatable { case none, beforeWrite, afterWrite }
        var failure: Failure = .none
        var targetFile: String? = nil
        func write(_ data: Data, _ url: URL) throws {
            let selected = targetFile == nil || targetFile == url.lastPathComponent
            if selected && failure == .beforeWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
            if selected && failure == .afterWrite { throw CocoaError(.fileWriteUnknown) }
        }
    }
    @MainActor func testWriterFailuresBeforeAndAfterRenameRecoverWithoutDoubleGrade() throws {
        for afterWrite in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let (bank, teaching) = try fixture(), writer = FaultWriter()
            let store = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root, writer: writer.write)
            let token = try startReveal(store), before = try XCTUnwrap(store.engine?.record)
            writer.failure = afterWrite ? .afterWrite : .beforeWrite
            store.grade(remembered: true, token: token)
            XCTAssertTrue(store.blocked)
            XCTAssertEqual(store.engine?.record, before, "The failed transaction cannot publish speculative UI progress")
            let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
            XCTAssertFalse(reopened.blocked, reopened.error ?? "")
            XCTAssertEqual(reopened.engine?.record.attempts.count, afterWrite ? 1 : 0)
            reopened.grade(remembered: true, token: token)
            XCTAssertFalse(reopened.blocked, reopened.error ?? "")
            XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
            let durable = try Data(contentsOf: current(root))
            reopened.grade(remembered: true, token: token)
            XCTAssertEqual(try Data(contentsOf: current(root)), durable)
        }
    }

    @MainActor func testNewerLegacyRecordAndConcurrentStoreCannotBeOverwritten() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let legacy = RecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        legacy.act("start", newLimit: 1)
        let first = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let stale = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let token = try startReveal(first); first.grade(remembered: true, token: token)
        let saved = try Data(contentsOf: current(root))
        stale.start(); XCTAssertTrue(stale.blocked)
        XCTAssertEqual(try Data(contentsOf: current(root)), saved)
        let legacyToken = try XCTUnwrap(legacy.engine?.record.state.shown?.id)
        legacy.act("reveal", token: legacyToken); legacy.act("grade", token: legacyToken, remembered: false)
        XCTAssertFalse(legacy.blocked)
        let protected = try files(root)
        let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertTrue(reopened.blocked)
        XCTAssertEqual(try files(root), protected)
    }

    @MainActor func testRepeatedCourseImportPreservesQuestionRecordAndProfessionalSnapshot() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture(), bankBytes = try encode(bank)
        let content = ConceptContent(format: "xkl-concepts-v1", bankBytes: bankBytes, bankSHA256: StudySHA256.hex(bankBytes))
        let course = ConceptCourse(format: "xkl-course-v5", subject: .computer, bankContent: try encode(content), teaching: teaching)
        let file = root.appendingPathComponent("synthetic-course.xklcourse")
        try encode(course).write(to: file)
        let questions = ConceptStore(subject: .computer, baseDirectory: root)
        questions.importContent(file); XCTAssertNil(questions.error)
        questions.startQuestion("synthetic-q0", expectedCurrentToken: nil)
        let questionToken = try XCTUnwrap(questions.engine?.shown?.id)
        questions.choose("A", token: questionToken); XCTAssertNil(questions.error)
        let questionRecord = try encode(XCTUnwrap(questions.engine?.record))
        let recall = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let token = try startReveal(recall); recall.grade(remembered: false, token: token)
        XCTAssertFalse(recall.blocked)
        let bytes = try Data(contentsOf: current(root)), oldBaseline = try Data(contentsOf: baseline(root))
        for _ in 0..<2 {
            questions.importContent(file); XCTAssertNil(questions.error); XCTAssertFalse(questions.blocked)
            XCTAssertEqual(try encode(XCTUnwrap(questions.engine?.record)), questionRecord)
            XCTAssertEqual(try Data(contentsOf: current(root)), bytes)
            XCTAssertEqual(try Data(contentsOf: baseline(root)), oldBaseline)
        }
        let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.record, recall.engine?.record)
    }

    @MainActor func testPromotionMovesRealStateAtomicallyWithoutCreatingTargetGradesOrReplacingMainlineHead() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let related = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, scope: .related, baseDirectory: root)
        let movedID = "synthetic-concept:2"
        let sourceToken = try startReveal(related)
        XCTAssertEqual(related.engine?.currentItem?.id, movedID)
        related.grade(remembered: false, token: sourceToken)
        XCTAssertFalse(related.blocked, related.error ?? "")
        let source = try XCTUnwrap(related.engine), packed = try XCTUnwrap(source.packedCard(id: movedID))
        let sourceAttempts = source.record.attempts
        let main = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let mainToken = try startReveal(main), oldMainIDs = try XCTUnwrap(main.engine?.record.cardIDs)
        let before = try Data(contentsOf: current(root))
        let changed = try updated(teaching, bank: bank, promotePrimary: true)
        let promoted = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(promoted.blocked, promoted.error ?? "")
        let target = try XCTUnwrap(promoted.engine)
        XCTAssertEqual(Array(target.record.cardIDs.prefix(oldMainIDs.count)), oldMainIDs)
        XCTAssertEqual(target.record.cardIDs.last, movedID)
        XCTAssertEqual(try target.packedCard(id: movedID), packed)
        XCTAssertEqual(target.record.presentation?.id, mainToken)
        XCTAssertEqual(target.record.presentation?.revealed, true)
        XCTAssertTrue(target.record.attempts.isEmpty, "Importing remembered/forgotten state is not a target answer")
        let disk = try records(root), parked = try XCTUnwrap(disk[ProfessionalRecallScope.related.rawValue])
        XCTAssertEqual(parked.attempts, sourceAttempts)
        XCTAssertTrue(parked.cardIDs.contains(movedID), "Stable source IDs and original events remain present")
        let sourceCatalog = try ProfessionalRecallCatalog.make(subject: .computer, bank: bank, teaching: changed, scope: .related)
        let sourceAfter = try ProfessionalRecallEngine.restore(record: parked, fallback: sourceCatalog)
        XCTAssertFalse(sourceAfter.activeCardIDs.contains(movedID))
        XCTAssertEqual(try Data(contentsOf: revision(root, bytes: before)), before)
        let saved = try Data(contentsOf: current(root)), count = try revisionCount(root)
        let repeated = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(repeated.blocked, repeated.error ?? "")
        XCTAssertEqual(try Data(contentsOf: current(root)), saved)
        XCTAssertEqual(try revisionCount(root), count)

        // The imported card still owes its actual reinforcement stage, rather
        // than becoming a brand-new first-known card after promotion.
        var foundMovedStage = false
        for _ in 0..<30 {
            let e = try XCTUnwrap(repeated.engine)
            guard let p = e.record.presentation else {
                repeated.start()
                XCTAssertFalse(repeated.blocked, repeated.error ?? "")
                continue
            }
            if p.cardID == movedID {
                XCTAssertGreaterThan(try e.info.stage, 0)
                foundMovedStage = true
                break
            }
            if !p.revealed { repeated.reveal(token: p.id) }
            repeated.grade(remembered: true, token: p.id)
            XCTAssertFalse(repeated.blocked, repeated.error ?? "")
        }
        XCTAssertTrue(foundMovedStage)
    }

    @MainActor func testSupplementAppendPreservesMappingVisibleStepAndAllPriorEvents() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let store = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        let token = try startReveal(store), old = try XCTUnwrap(store.engine)
        let ids = old.record.cardIDs, events = try old.allEvents(), before = try Data(contentsOf: current(root))
        let changed = try updated(teaching, bank: bank, appendSupplement: true)
        let upgraded = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(upgraded.blocked, upgraded.error ?? "")
        let engine = try XCTUnwrap(upgraded.engine)
        XCTAssertEqual(Array(engine.record.cardIDs.prefix(ids.count)), ids)
        XCTAssertEqual(engine.record.cardIDs.last, "synthetic-group:2")
        XCTAssertEqual(engine.record.presentation?.id, token)
        XCTAssertEqual(engine.record.presentation?.revealed, true)
        XCTAssertEqual(Array(try engine.allEvents().prefix(events.count)), events)
        XCTAssertTrue(engine.record.attempts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: revision(root, bytes: before)), before)
        let durable = try Data(contentsOf: current(root))
        let repeated = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(repeated.blocked, repeated.error ?? "")
        XCTAssertEqual(try Data(contentsOf: current(root)), durable)
        repeated.grade(remembered: true, token: token)
        XCTAssertFalse(repeated.blocked, repeated.error ?? "")
        XCTAssertEqual(repeated.engine?.record.attempts.count, 1)
    }

    @MainActor func testOpeningOldCourseBeforeImportingPromotionsAndNewCardsDoesNotBlockOrReset() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (bank, teaching) = try fixture()
        let old = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
        XCTAssertFalse(old.blocked, old.error ?? "")
        let original = try XCTUnwrap(old.engine?.record), before = try Data(contentsOf: current(root))
        XCTAssertTrue(original.attempts.isEmpty)
        let changed = try updated(teaching, bank: bank, promotePrimary: true, appendSupplement: true)
        let upgraded = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(upgraded.blocked, upgraded.error ?? "")
        let engine = try XCTUnwrap(upgraded.engine)
        XCTAssertEqual(Array(engine.record.cardIDs.prefix(original.cardIDs.count)), original.cardIDs)
        XCTAssertEqual(engine.activeCardIDs.count, 5)
        XCTAssertTrue(engine.record.attempts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: revision(root, bytes: before)), before)
        let token = try startReveal(upgraded)
        upgraded.grade(remembered: true, token: token)
        XCTAssertFalse(upgraded.blocked, upgraded.error ?? "")
        XCTAssertEqual(upgraded.engine?.record.attempts.count, 1)
        let saved = try Data(contentsOf: current(root))
        let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(try Data(contentsOf: current(root)), saved)
    }

    @MainActor func testEmptyRelatedScopeDoesNotBlockFreshOrUpgradedMainline() throws {
        let (bank, teaching) = try fixture(), allMainline = try updated(teaching, bank: bank, allMainline: true)
        for hadRelatedArchive in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            var oldRelated: ProfessionalRecallRecord?
            if hadRelatedArchive {
                let old = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, scope: .related, baseDirectory: root)
                let token = try startReveal(old); old.grade(remembered: false, token: token)
                XCTAssertFalse(old.blocked)
                oldRelated = old.engine?.record
            }
            let main = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: allMainline, baseDirectory: root)
            XCTAssertFalse(main.blocked, main.error ?? "")
            XCTAssertEqual(main.engine?.activeCardIDs.count, 5)
            _ = try startReveal(main)
            let empty = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: allMainline, scope: .related, baseDirectory: root)
            XCTAssertFalse(empty.blocked, empty.error ?? "")
            if let oldRelated {
                let retained = try XCTUnwrap(records(root)[ProfessionalRecallScope.related.rawValue])
                XCTAssertEqual(retained.cardIDs, oldRelated.cardIDs)
                XCTAssertEqual(retained.attempts, oldRelated.attempts)
                XCTAssertTrue(empty.engine?.activeCardIDs.isEmpty ?? true)
            } else {
                XCTAssertNil(try records(root)[ProfessionalRecallScope.related.rawValue])
            }
        }
    }

    @MainActor func testScopeUpgradeWriteFailuresCannotCommitOnlyOneSide() throws {
        for afterWrite in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let (bank, teaching) = try fixture()
            let source = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, scope: .related, baseDirectory: root)
            let token = try startReveal(source); source.grade(remembered: false, token: token)
            let before = try Data(contentsOf: current(root))
            let changed = try updated(teaching, bank: bank, promotePrimary: true), writer = FaultWriter()
            writer.targetFile = "current.json"
            writer.failure = afterWrite ? .afterWrite : .beforeWrite
            let failed = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root, writer: writer.write)
            XCTAssertTrue(failed.blocked)
            if !afterWrite { XCTAssertEqual(try Data(contentsOf: current(root)), before) }
            let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
            XCTAssertFalse(reopened.blocked, reopened.error ?? "")
            XCTAssertTrue(reopened.engine?.activeCardIDs.contains("synthetic-concept:2") == true)
            XCTAssertTrue(reopened.engine?.record.attempts.isEmpty == true)
            let related = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, scope: .related, baseDirectory: root)
            XCTAssertFalse(related.blocked, related.error ?? "")
            XCTAssertFalse(related.engine?.activeCardIDs.contains("synthetic-concept:2") ?? true)
            XCTAssertEqual(related.engine?.record.attempts.count, 1)
            XCTAssertEqual(try Data(contentsOf: revision(root, bytes: before)), before)
        }
    }

    @MainActor func testMissingScopeOrReferencedRevisionFailsWithoutReinitializingEitherScope() throws {
        for removeScope in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let (bank, teaching) = try fixture()
            let original = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: teaching, baseDirectory: root)
            let token = try startReveal(original); original.grade(remembered: false, token: token)
            let before = try Data(contentsOf: current(root)), changed = try updated(teaching, bank: bank, appendSupplement: true)
            let upgraded = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
            XCTAssertFalse(upgraded.blocked, upgraded.error ?? "")
            if removeScope {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: current(root))) as? [String: Any])
                var values = try XCTUnwrap(json["records"] as? [String: Any])
                values.removeValue(forKey: ProfessionalRecallScope.related.rawValue)
                json["records"] = values
                try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: current(root))
            } else { try FileManager.default.removeItem(at: revision(root, bytes: before)) }
            let damaged = try files(root)
            let reopened = ProfessionalRecallStore(subject: .computer, bank: bank, teaching: changed, baseDirectory: root)
            XCTAssertTrue(reopened.blocked)
            XCTAssertEqual(try files(root), damaged)
        }
    }
}
#endif
