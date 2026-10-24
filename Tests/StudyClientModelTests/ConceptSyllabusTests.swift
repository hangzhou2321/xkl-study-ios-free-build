import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// All titles, questions and source identities below are fictional.
enum SyllabusFixture {
    static func sample(papers: Int = 3) -> ConceptSyllabusTree {
        let sources = [ConceptSyllabusTree.Source(id: "book", title: "虚构资料", kind: "book", edition: "年份未标注",
            sha256: String(repeating: "a", count: 64), fileName: "synthetic-book.pdf")] +
            (1...6).map { (paper: Int) in ConceptSyllabusTree.Source(id: "mock-\(paper)", title: "虚构第\(paper)套", kind: "mock", edition: "2026虚构",
                sha256: String(repeating: "b", count: 64), fileName: "synthetic-mocks.pdf", paperNumber: paper) }
        var leaves = (1...2).map { ConceptSyllabusTree.Leaf(id: "book-\($0)", sourceID: "book", topicID: "topic",
            number: "\($0)", page: $0, prompt: "虚构重复题", options: ["虚构甲", "虚构乙"],
            duplicateGroup: "book-copy", verification: "sourcePending", linkedQuestionIDs: []) }
        if papers > 0 {
            leaves += (1...papers).map { ConceptSyllabusTree.Leaf(id: "paper-\($0)", sourceID: "mock-\($0)", topicID: "topic",
                number: "1", page: $0, prompt: "虚构模拟卷题", options: [], points: 0.5,
                duplicateGroup: $0 <= 2 ? "mock-copy" : nil, verification: "sourcePending", linkedQuestionIDs: []) }
        }
        return ConceptSyllabusTree(version: 1, title: "虚构考纲树", outlineSource: "2027虚构测试，非正式考纲", frequencyNote: "只统计样本",
            sources: sources, branches: [.init(id: "main", title: "测试分支", syllabusText: "测试范围", scope: "mainline"),
                .init(id: "empty", title: "缺样本分支", syllabusText: "仍然保留", scope: "mainline")],
            topics: [.init(id: "topic", branchID: "main", title: "虚构考点", conceptIDs: ["c0"], coverageNote: "仅测试关联")], leaves: leaves)
    }
    static func course(_ fixture: GuidanceFixture, tree: ConceptSyllabusTree = sample()) throws -> ConceptCourse {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: GuidanceFixture.encode(DiagramFixture.course(fixture))) as? [String: Any])
        object["format"] = "xkl-course-v4"
        var teaching = object["teaching"] as! [String: Any]
        teaching["syllabus"] = try JSONSerialization.jsonObject(with: GuidanceFixture.encode(tree))
        object["teaching"] = teaching
        return try JSONDecoder().decode(ConceptCourse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

final class ConceptSyllabusTests: XCTestCase {
    func testOldTeachingRoundTripRemainsByteIdenticalAndTreeV4PreservesBank() throws {
        let old = try GuidanceFixture()
        let decoded = try JSONDecoder().decode(ConceptTeaching.self, from: old.teachingContent)
        XCTAssertNil(decoded.syllabus)
        XCTAssertEqual(try GuidanceFixture.encode(decoded), old.teachingContent)
        let course = try SyllabusFixture.course(old), encoded = try GuidanceFixture.encode(course)
        let (loaded, _) = try ConceptCourse.load(encoded, subject: .computer)
        XCTAssertEqual(loaded.bankContent, old.bankContent)
        XCTAssertEqual(loaded.teaching.syllabus, SyllabusFixture.sample())
        XCTAssertEqual(loaded.teaching.lessons[0].guide?.steps[0].diagram, DiagramFixture.sample)
        XCTAssertEqual(try GuidanceFixture.encode(loaded), encoded)
    }

    func testFrequencyCountsPapersAndDeduplicatesOnlyExplicitGroups() throws {
        let tree = SyllabusFixture.sample(), stats = tree.statistics(for: tree.leaves)
        XCTAssertEqual(stats.bookCount, 2); XCTAssertEqual(stats.uniqueBookCount, 1)
        XCTAssertEqual(stats.mockCount, 3); XCTAssertEqual(stats.uniqueMockCount, 2)
        XCTAssertEqual(stats.papers, [1, 2, 3]); XCTAssertEqual(stats.frequencyBand, "中频")
        XCTAssertEqual(stats.pendingCount, 5)
        XCTAssertTrue(tree.branchLeaves("empty").isEmpty)
        XCTAssertEqual(tree.statistics(for: []).frequencyBand, "未见")
        for count in 0...6 {
            let value = SyllabusFixture.sample(papers: count)
            XCTAssertEqual(value.statistics(for: value.leaves).frequencyBand,
                           count == 0 ? "未见" : count == 1 ? "低频" : count < 4 ? "中频" : "高频")
        }
    }

    func testRejectsBrokenReferencesFalseReviewClaimsAndUnsafePDFNames() throws {
        let fixture = try GuidanceFixture(), tree = SyllabusFixture.sample()
        try tree.validate(bank: fixture.bank)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: GuidanceFixture.encode(tree)) as? [String: Any])
        let edits: [(inout [String: Any]) -> Void] = [
            { x in var s = x["sources"] as! [[String: Any]]; s[0]["fileName"] = "../outside.pdf"; x["sources"] = s },
            { x in var s = x["sources"] as! [[String: Any]]; s[0]["paperNumber"] = 1; x["sources"] = s },
            { x in var s = x["sources"] as! [[String: Any]]; s[1]["paperNumber"] = 7; x["sources"] = s },
            { x in var s = x["sources"] as! [[String: Any]]; s[1]["sha256"] = String(repeating: "c", count: 64); x["sources"] = s },
            { x in var t = x["topics"] as! [[String: Any]]; t[0]["branchID"] = "missing"; x["topics"] = t },
            { x in var t = x["topics"] as! [[String: Any]]; t[0]["conceptIDs"] = ["unavailable"]; x["topics"] = t },
            { x in var l = x["leaves"] as! [[String: Any]]; l[1]["id"] = l[0]["id"]; x["leaves"] = l },
            { x in var l = x["leaves"] as! [[String: Any]]; l[0]["sourceID"] = "missing"; x["leaves"] = l },
            { x in var l = x["leaves"] as! [[String: Any]]; l[0]["page"] = 0; x["leaves"] = l },
            { x in var l = x["leaves"] as! [[String: Any]]; l[0]["verification"] = "linkedReviewed"; x["leaves"] = l },
            { x in var l = x["leaves"] as! [[String: Any]]; l[0]["linkedQuestionIDs"] = ["c0-q0"]; x["leaves"] = l }
        ]
        for edit in edits {
            var changed = original; edit(&changed)
            let invalid = try JSONDecoder().decode(ConceptSyllabusTree.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try invalid.validate(bank: fixture.bank))
            XCTAssertThrowsError(try ConceptCourse.load(GuidanceFixture.encode(SyllabusFixture.course(fixture, tree: invalid)), subject: .computer))
        }
        for name in ["../a.pdf", "C:\\a.pdf", "a/b.pdf", "a.pdf\n", ".pdf", "a.exe"] {
            XCTAssertFalse(ConceptSyllabusTree.validPDFFileName(name))
        }
        XCTAssertTrue(ConceptSyllabusTree.validPDFFileName("原资料(2).pdf"))
    }
}

#if os(macOS)
final class ConceptSyllabusIntegrationTests: XCTestCase {
    @MainActor func testTreeImportAndReadOnlyStatisticsPreserveFormalStateAndOldPosition() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try GuidanceFixture(), new = try SyllabusFixture.course(old)
        let input = root.appendingPathComponent("synthetic.xklcourse"), store = ConceptStore(baseDirectory: root)
        try GuidanceFixture.write(GuidanceFixture.encode(old.course), input); store.importContent(input); store.start()
        store.openGuidance(conceptID: "c0"); store.guidanceAction("step", stepID: "define")
        let position = try XCTUnwrap(store.guidance?.active)
        let dir = root.appendingPathComponent("ComputerFoundation")
        let paths = ["\(old.teaching.bankSHA256)/current.json", "guidance-current.json", "guidance-content/\(old.hash).json"]
        let before = try paths.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        try GuidanceFixture.write(GuidanceFixture.encode(new), input); store.importContent(input)
        XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        let tree = try XCTUnwrap(store.teaching?.syllabus)
        _ = tree.statistics(for: tree.leaves); _ = tree.branchLeaves("main"); _ = tree.topicLeaves("topic")
        XCTAssertEqual(try paths.map { try Data(contentsOf: dir.appendingPathComponent($0)) }, before)
        store.openGuidance(conceptID: "c0"); store.resumeGuidance(position)
        XCTAssertEqual(store.guidance?.active, position)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(paths[0])), before[0])
        let restored = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restored.blocked); XCTAssertEqual(restored.guidance, store.guidance)
        XCTAssertEqual(restored.teaching?.syllabus, tree)
    }

    @MainActor func testInvalidTreeIsRejectedBeforeAnyActivePointerOrProgressWrite() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try GuidanceFixture(), input = root.appendingPathComponent("synthetic.xklcourse")
        let store = ConceptStore(baseDirectory: root)
        try GuidanceFixture.write(GuidanceFixture.encode(old.course), input); store.importContent(input); store.start()
        let dir = root.appendingPathComponent("ComputerFoundation")
        let paths = ["active.json", "\(old.teaching.bankSHA256)/current.json", "\(old.teaching.bankSHA256)/teaching-active.json"]
        let before = try paths.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: GuidanceFixture.encode(SyllabusFixture.sample())) as? [String: Any])
        var topics = object["topics"] as! [[String: Any]]; topics[0]["conceptIDs"] = ["not-in-bank"]; object["topics"] = topics
        let invalid = try JSONDecoder().decode(ConceptSyllabusTree.self, from: JSONSerialization.data(withJSONObject: object))
        try GuidanceFixture.write(GuidanceFixture.encode(SyllabusFixture.course(old, tree: invalid)), input)
        store.importContent(input)
        XCTAssertNotNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(try paths.map { try Data(contentsOf: dir.appendingPathComponent($0)) }, before)
    }
}
#endif
