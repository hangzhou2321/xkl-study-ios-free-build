import XCTest
import StudyCore
@testable import StudyClientModel

final class ProfessionalQuestionHoldTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func bank() -> ConceptBank {
        ConceptBank(id: ConceptSubject.computer.bankID, title: "Synthetic hold bank", scope: "Synthetic", notice: "Synthetic only",
            sources: [.init(id: "s", title: "Synthetic source", reference: "fixture")], concepts: (0..<2).map { c in
                StudyConcept(id: "c\(c)", title: "Synthetic concept \(c)", section: "Synthetic", method: "Synthetic method",
                    questions: (0..<2).map { q in ConceptQuestion(id: "c\(c)q\(q)", type: .multiple,
                        prompt: "Synthetic question \(c) \(q)", options: [.init(id: "A", text: "First"), .init(id: "B", text: "Second")],
                        answer: ["A"], explanation: "Synthetic explanation", sourceIDs: ["s"], sourceLocation: "Synthetic",
                        verification: "Synthetic verified") })
            })
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func assertGradesUnchanged(_ before: ConceptRecord, _ after: ConceptRecord,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before.progress, after.progress, file: file, line: line)
        XCTAssertEqual(before.attempts, after.attempts, file: file, line: line)
        XCTAssertEqual(before.nextSequence, after.nextSequence, file: file, line: line)
        XCTAssertEqual(before.volumes, after.volumes, file: file, line: line)
        XCTAssertEqual(before.retriesToday, after.retriesToday, file: file, line: line)
    }

    func testHeldPendingQuestionParksExactSelectionAndContinuesReplacementWithoutGrade() throws {
        let bank = bank()
        var engine = try ConceptEngine(bank: bank, hash: fixtureHash)
        try engine.start(day: 21000, now: now, newLimit: 2)
        let token = try XCTUnwrap(engine.shown?.id)
        engine.toggle("A", token: token)
        let before = engine.record
        try engine.applyQuestionHolds(["c0q0"], revision: "synthetic-note", now: now)
        assertGradesUnchanged(before, engine.record)
        XCTAssertNil(engine.shown)
        XCTAssertEqual(engine.record.scopeSuspensions?.first?.presentation, before.presentation)
        XCTAssertEqual(engine.record.scopeSuspensions?.first?.parkedQueue, before.queue)
        try engine.applyQuestionHolds(["c0q0"], revision: "synthetic-note", now: now)
        XCTAssertEqual(engine.record.scopeSuspensions?.count, 1)
        try engine.startQuestion(questionID: "c0q1", day: 21000, now: now)
        XCTAssertEqual(engine.question?.id, "c0q1")
        XCTAssertTrue(engine.shown?.selected.isEmpty == true)
        assertGradesUnchanged(before, engine.record)
        try engine.record.validate(bank: bank, hash: fixtureHash)
    }

    func testNewTaskAndNextFilterHoldsWithoutConsumingQuestionsOrBlockingOtherConcepts() throws {
        let bank = bank()
        var engine = try ConceptEngine(bank: bank, hash: fixtureHash)
        try engine.applyQuestionHolds(["c0q0", "c1q0"], revision: "synthetic-note", now: now)
        try engine.start(day: 21000, now: now, newLimit: 2)
        XCTAssertEqual(engine.question?.id, "c0q1")
        let token = try XCTUnwrap(engine.shown?.id)
        engine.toggle("A", token: token)
        try engine.answer(token: token, day: 21000, now: now)
        try engine.nextOnDay(token: token, day: 21000, now: now)
        XCTAssertEqual(engine.question?.id, "c1q1")
        XCTAssertEqual(engine.record.attempts.map(\.presentation.questionID), ["c0q1"])
        XCTAssertEqual(engine.record.progress["c0"]?.usedQuestionIDs, ["c0q1"])
        XCTAssertNil(engine.record.progress["c1"])
        try engine.record.validate(bank: bank, hash: fixtureHash)
    }

    func testHeldReviewAndEntireQueuedConceptParkWithoutFamiliarOrCorrectnessChanges() throws {
        let bank = bank()
        var engine = try ConceptEngine(bank: bank, hash: fixtureHash)
        try engine.start(day: 21000, now: now, newLimit: 2)
        let token = try XCTUnwrap(engine.shown?.id)
        engine.toggle("A", token: token)
        try engine.answer(token: token, day: 21000, now: now)
        let before = engine.record
        try engine.applyQuestionHolds(["c0q0", "c1q0", "c1q1"], revision: "synthetic-note", now: now)
        XCTAssertNil(engine.shown); XCTAssertTrue(engine.record.queue.isEmpty)
        XCTAssertEqual(engine.record.scopeSuspensions?.last?.review, before.review)
        XCTAssertEqual(engine.record.scopeSuspensions?.last?.parkedQueue, before.queue)
        assertGradesUnchanged(before, engine.record)
        try engine.startQuestion(questionID: "c0q1", day: 21000, now: now)
        XCTAssertEqual(engine.question?.id, "c0q1")
        XCTAssertThrowsError(try engine.applyQuestionHolds(["missing"], revision: "synthetic-note", now: now))
        try engine.record.validate(bank: bank, hash: fixtureHash)
    }

    #if os(macOS)
    private func course(holds: Bool = false) throws -> ConceptCourse {
        let bank = bank(), bytes = try encode(bank), hash = StudySHA256.hex(bytes)
        var teaching = ConceptTeaching(format: "xkl-teaching-v1", bankSHA256: hash,
            lessons: bank.concepts.map { concept in ConceptLesson(conceptID: concept.id, title: "Synthetic lesson",
                story: "Synthetic story", keyIdea: "Synthetic idea", workedExample: "Synthetic example", commonTrap: "Synthetic trap",
                recallCards: [.init(id: concept.id + ":card", prompt: "Synthetic recall?", answer: "Synthetic answer")]) })
        let deck = try RecallDeck.make(subject: .computer, bank: bank, teaching: teaching)
        teaching.primaryRecallDeck = deck
        teaching.studyPlan = ProfessionalStudyPlan(format: "xkl-professional-plan-v1", id: "synthetic-plan", subject: .computer,
            basePrimaryDeckSHA256: try deck.hash, mainlineCardIDs: deck.cards.map(\.id), relatedCardIDs: [],
            mainlineSupplementGroupIDs: [], relatedSupplementGroupIDs: [], priorityConceptIDs: bank.concepts.map(\.id),
            sourceQuestionIDs: bank.concepts.flatMap(\.questions).map(\.id))
        teaching.questionPresentations = bank.concepts.flatMap(\.questions).map {
            .init(questionID: $0.id, sourceQuestionDigest: $0.professionalDigest, requiredDiagram: false, beforeAnswer: [], afterAnswer: [])
        }
        teaching.questionLinks = bank.concepts.flatMap { concept in concept.questions.map {
            .init(questionID: $0.id, sourceQuestionDigest: $0.professionalDigest, primaryCardIDs: [concept.id + ":card"], supplementCardIDs: [], guideConceptIDs: []) as ProfessionalQuestionLinks
        } }
        let diagram = ConceptDiagram(version: 1, title: "Synthetic source", width: 320, height: 160, description: "Synthetic source only",
            shapes: [.init(kind: "rect", x: 20, y: 20, width: 200, height: 80, stroke: "ink", fill: "white")], paths: [],
            labels: [.init(text: "Synthetic source solution", x: 30, y: 30, width: 180, height: 30, size: 18, color: "ink", align: "leading", bold: false)])
        teaching.sourceLeaves = [.init(sourceQuestionID: "synthetic-source-q", sourceID: "s", page: 1,
            label: "Synthetic original", status: "verified", bankQuestionID: "c0q0",
            visual: .init(id: "synthetic-visual", kind: "vector", diagram: diagram), primaryCardIDs: ["c0:card"], supplementCardIDs: [],
            sourceStatus: .verified, courseReadiness: .ready, scope: .mainline, reason: "Synthetic verified original")]
        teaching.cardCorrections = []
        if holds {
            let question = bank.concepts[0].questions[0]
            teaching.questionPracticeNotes = [.init(questionID: question.id, sourceQuestionDigest: question.professionalDigest,
                status: "hold", reason: "Synthetic ambiguous statement", sourceRef: "Synthetic source evidence", replacementQuestionIDs: ["c0q1"])]
        }
        try teaching.validate(bank: bank, hash: hash)
        return ConceptCourse(format: "xkl-course-v5", subject: .computer,
            bankContent: try encode(ConceptContent(format: "xkl-concepts-v1", bankBytes: bytes, bankSHA256: hash)), teaching: teaching)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("professional-hold-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor private func importCourse(_ course: ConceptCourse, to store: ConceptStore, root: URL) throws {
        let path = root.appendingPathComponent("synthetic-course.xklcourse")
        try encode(course).write(to: path, options: .atomic)
        store.importContent(path)
        XCTAssertFalse(store.blocked, store.error ?? ""); XCTAssertNil(store.error)
    }

    @MainActor func testImportHoldParksExistingQuestionAndAllowsReplacementAcrossRestart() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConceptStore(subject: .computer, baseDirectory: root)
        try importCourse(course(), to: store, root: root)
        store.startQuestion("c0q0", expectedCurrentToken: nil)
        let token = try XCTUnwrap(store.engine?.shown?.id)
        store.choose("A", token: token)
        let before = try XCTUnwrap(store.engine?.record)
        try importCourse(course(holds: true), to: store, root: root)
        let parked = try XCTUnwrap(store.engine?.record)
        assertGradesUnchanged(before, parked)
        XCTAssertEqual(parked.scopeSuspensions?.last?.presentation, before.presentation)
        XCTAssertNil(store.engine?.shown)
        XCTAssertNotNil(store.sourceQuestionAvailability("c0q0"))
        XCTAssertNil(store.sourceQuestionAvailability("c0q1"))
        store.choose("A", token: token)
        XCTAssertTrue(store.engine?.record.attempts.isEmpty == true)
        let restarted = ConceptStore(subject: .computer, baseDirectory: root)
        XCTAssertFalse(restarted.blocked, restarted.error ?? "")
        XCTAssertEqual(restarted.engine?.record.scopeSuspensions?.count, 1)
        restarted.startQuestion("c0q1", expectedCurrentToken: nil)
        XCTAssertEqual(restarted.engine?.question?.id, "c0q1")
        let replacement = try XCTUnwrap(restarted.engine?.shown?.id)
        restarted.choose("A", token: replacement); restarted.submit(token: replacement)
        XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.engine?.record.attempts.map(\.presentation.questionID), ["c0q1"])
        XCTAssertEqual(restarted.engine?.record.progress["c0"]?.usedQuestionIDs, ["c0q1"])
    }

    @MainActor func testSavedQuestionRecallExposureIsLinkedIdempotentAndDoesNotGrade() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConceptStore(subject: .computer, baseDirectory: root)
        try importCourse(course(), to: store, root: root)
        store.startQuestion("c0q0", expectedCurrentToken: nil)
        let token = try XCTUnwrap(store.engine?.shown?.id)
        let before = try encode(XCTUnwrap(store.engine?.record))
        XCTAssertTrue(store.recordRecallCardExposure(cardID: "c1:card", token: token))
        XCTAssertFalse(store.currentQuestionUsedCardHelp)
        XCTAssertTrue(store.recordRecallCardExposure(cardID: "c0:card", token: token))
        XCTAssertTrue(store.currentQuestionUsedCardHelp)
        let count = store.coachingEvents.count
        XCTAssertTrue(store.recordRecallCardExposure(cardID: "c0:card", token: token))
        XCTAssertEqual(store.coachingEvents.count, count)
        XCTAssertEqual(try encode(XCTUnwrap(store.engine?.record)), before)
        let reopened = ConceptStore(subject: .computer, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertEqual(reopened.engine?.shown?.id, token)
        XCTAssertTrue(reopened.currentQuestionUsedCardHelp)
        XCTAssertEqual(reopened.coachingEvents.count, count)
    }

    @MainActor func testSourceReadSurvivesNavigationAndRestartButDoesNotContaminateDifferentVariant() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConceptStore(subject: .computer, baseDirectory: root)
        try importCourse(course(), to: store, root: root)
        let before = try encode(XCTUnwrap(store.engine?.record))
        XCTAssertTrue(store.recordSourceExposure(questionID: "c0q0"))
        XCTAssertTrue(store.recordSourceExposure(questionID: "c0q0"))
        XCTAssertEqual(store.coachingEvents.filter { $0.kind == "source-read" }.count, 1)
        XCTAssertEqual(try encode(XCTUnwrap(store.engine?.record)), before)
        let observed = try XCTUnwrap(store.coachingEvents.first)
        XCTAssertNil(observed.attemptID); XCTAssertTrue(observed.beforeAnswer)
        let reopened = ConceptStore(subject: .computer, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        reopened.startQuestion("c0q0", expectedCurrentToken: nil)
        XCTAssertTrue(reopened.currentQuestionUsedCardHelp)
        let token = try XCTUnwrap(reopened.engine?.shown?.id)
        XCTAssertNotEqual(token, observed.presentationID, "Reader identity is not a fabricated question presentation")
        reopened.choose("A", token: token); reopened.submit(token: token)
        XCTAssertTrue(reopened.currentQuestionUsedCardHelp)
        reopened.next(token: token)
        reopened.startQuestion("c0q1", expectedCurrentToken: nil)
        XCTAssertEqual(reopened.engine?.question?.id, "c0q1")
        XCTAssertFalse(reopened.currentQuestionUsedCardHelp)
        XCTAssertEqual(reopened.engine?.record.attempts.count, 1)
    }

    @MainActor func testReadingSourceAfterScoringDoesNotRewriteIndependentResult() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConceptStore(subject: .computer, baseDirectory: root)
        try importCourse(course(), to: store, root: root)
        store.startQuestion("c0q0", expectedCurrentToken: nil)
        let token = try XCTUnwrap(store.engine?.shown?.id)
        store.choose("A", token: token); store.submit(token: token)
        let before = try encode(XCTUnwrap(store.engine?.record))
        XCTAssertFalse(store.currentQuestionUsedCardHelp)
        XCTAssertTrue(store.recordSourceExposure(questionID: "c0q0"))
        XCTAssertFalse(store.coachingEvents.last?.beforeAnswer ?? true)
        XCTAssertFalse(store.currentQuestionUsedCardHelp)
        XCTAssertEqual(try encode(XCTUnwrap(store.engine?.record)), before)
        let reopened = ConceptStore(subject: .computer, baseDirectory: root)
        XCTAssertFalse(reopened.blocked, reopened.error ?? "")
        XCTAssertFalse(reopened.currentQuestionUsedCardHelp)
        XCTAssertEqual(try encode(XCTUnwrap(reopened.engine?.record)), before)
    }

    @MainActor func testSourceReadWriteFailureReturnsFalseForTheImageGateAndNeverGrades() throws {
        final class Writer {
            var fail = false
            func write(_ bytes: Data, _ path: URL) throws {
                if fail && path.lastPathComponent == "coaching-current.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try bytes.write(to: path, options: .atomic)
            }
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer(), store = ConceptStore(subject: .computer, baseDirectory: root, writer: writer.write)
        try importCourse(course(), to: store, root: root)
        let before = try encode(XCTUnwrap(store.engine?.record))
        writer.fail = true
        XCTAssertFalse(store.recordSourceExposure(questionID: "c0q0"), "The source view must keep its image gate closed")
        XCTAssertTrue(store.blocked); XCTAssertTrue(store.coachingEvents.isEmpty)
        XCTAssertEqual(try encode(XCTUnwrap(store.engine?.record)), before)
        XCTAssertFalse(store.recordSourceExposure(questionID: "c0q0"))
    }

    private func sharedSourceCourse() throws -> ConceptCourse {
        let original = try course()
        var teaching = original.teaching
        let asset = ProfessionalSourceFileAsset(sha256: String(repeating: "a", count: 64), mimeType: "image/jpeg",
            byteCount: 1000, pixelWidth: 320, pixelHeight: 160, crop: .init(x: 0, y: 0, width: 1, height: 1),
            altText: "Synthetic shared raw page containing two question answers")
        teaching.sourceLeaves = (0..<3).map { index in
            ProfessionalSourceLeaf(sourceQuestionID: "shared-leaf-\(index)", sourceID: "s", page: index + 1,
                label: "Synthetic shared page", status: index == 2 ? "pending" : "verified",
                bankQuestionID: index == 2 ? nil : "c\(index)q0",
                visual: .init(id: "shared-visual-\(index)", kind: "sourceFile", sourceFile: asset),
                primaryCardIDs: index == 2 ? [] : ["c\(index):card"], supplementCardIDs: [],
                sourceStatus: .verified, courseReadiness: index == 2 ? .awaitingCanonicalBinding : .ready,
                scope: .mainline, reason: "Synthetic source-page exposure fixture")
        }
        try teaching.validate(bank: bank(), hash: teaching.bankSHA256)
        return ConceptCourse(format: original.format, subject: original.subject, bankContent: original.bankContent, teaching: teaching)
    }

    @MainActor func testSharedRawPageMarksAllBoundQuestionsIncludingFromUnboundIndex() throws {
        for opened in ["shared-leaf-0", "shared-leaf-2"] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ConceptStore(subject: .computer, baseDirectory: root)
            try importCourse(sharedSourceCourse(), to: store, root: root)
            let before = try encode(XCTUnwrap(store.engine?.record))
            XCTAssertTrue(store.recordSourceExposure(sourceQuestionID: opened))
            XCTAssertEqual(Set(store.coachingEvents.filter { $0.kind == "source-read" }.map(\.questionID)), ["c0q0", "c1q0"])
            XCTAssertTrue(store.recordSourceExposure(sourceQuestionID: opened))
            XCTAssertEqual(store.coachingEvents.count, 2)
            XCTAssertEqual(try encode(XCTUnwrap(store.engine?.record)), before)
            let reopened = ConceptStore(subject: .computer, baseDirectory: root)
            XCTAssertFalse(reopened.blocked, reopened.error ?? "")
            reopened.startQuestion("c1q0", expectedCurrentToken: nil)
            XCTAssertTrue(reopened.currentQuestionUsedCardHelp, "Another question on the exposed raw image cannot become a blind test")
            XCTAssertTrue(reopened.engine?.record.attempts.isEmpty == true)
        }
    }

    @MainActor func testSharedPageImageGateStaysClosedIfAnyQuestionExposureWriteFails() throws {
        final class Writer {
            var writes = 0
            var fail = false
            func write(_ bytes: Data, _ path: URL) throws {
                if fail && path.lastPathComponent == "coaching-current.json" {
                    writes += 1
                    if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                }
                try bytes.write(to: path, options: .atomic)
            }
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = Writer(), store = ConceptStore(subject: .computer, baseDirectory: root, writer: writer.write)
        try importCourse(sharedSourceCourse(), to: store, root: root)
        let before = try encode(XCTUnwrap(store.engine?.record))
        writer.fail = true
        XCTAssertFalse(store.recordSourceExposure(sourceQuestionID: "shared-leaf-2"))
        XCTAssertTrue(store.blocked)
        XCTAssertEqual(store.coachingEvents.count, 1, "Partial observations are retained, but the raw image must remain hidden")
        XCTAssertEqual(try encode(XCTUnwrap(store.engine?.record)), before)
    }
    #endif
}
