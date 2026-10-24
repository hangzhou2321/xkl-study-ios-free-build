import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Synthetic vector content only; no user curriculum or progress in cloud tests.
enum DiagramFixture {
    static let sample = ConceptDiagram(version: 1, title: "虚构数据流", width: 320, height: 200,
        description: "输入经过连线到输出，仅供图解格式测试。",
        shapes: [.init(kind: "roundedRect", x: 20, y: 30, width: 80, height: 48, stroke: "ink", fill: "paleBlue")],
        paths: [.init(points: [.init(x: 100, y: 54), .init(x: 160, y: 54)], color: "blue", dashed: false, arrow: true)],
        labels: [.init(text: "输入", x: 24, y: 36, width: 72, height: 34, size: 16, color: "ink", align: "center", bold: true)])

    static func course(_ fixture: GuidanceFixture, diagram: ConceptDiagram = sample) throws -> ConceptCourse {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: GuidanceFixture.encode(fixture.course)) as? [String: Any])
        object["format"] = "xkl-course-v3"
        var teaching = object["teaching"] as! [String: Any]
        var lessons = teaching["lessons"] as! [[String: Any]]
        var guide = lessons[0]["guide"] as! [String: Any]
        var steps = guide["steps"] as! [[String: Any]]
        steps[0]["diagram"] = try JSONSerialization.jsonObject(with: GuidanceFixture.encode(diagram))
        guide["steps"] = steps; lessons[0]["guide"] = guide; teaching["lessons"] = lessons; object["teaching"] = teaching
        return try JSONDecoder().decode(ConceptCourse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

final class ConceptDiagramTests: XCTestCase {
    func testLegacyTeachingEncodingHasNoDiagramFieldAndRemainsRoundTripIdentical() throws {
        let legacy = try GuidanceFixture()
        let decoded = try JSONDecoder().decode(ConceptTeaching.self, from: legacy.teachingContent)
        XCTAssertTrue(decoded.lessons.allSatisfy { $0.guide?.steps.allSatisfy { $0.diagram == nil } ?? false })
        XCTAssertEqual(try GuidanceFixture.encode(decoded), legacy.teachingContent)
        XCTAssertFalse(String(decoding: legacy.teachingContent, as: UTF8.self).contains("\"diagram\""))
    }

    func testNativeDiagramRoundTripPreservesEveryPrimitiveAndBankBytes() throws {
        let old = try GuidanceFixture(), course = try DiagramFixture.course(old)
        let encoded = try GuidanceFixture.encode(course)
        let (decoded, _) = try ConceptCourse.load(encoded, subject: .computer)
        XCTAssertEqual(decoded.bankContent, old.bankContent)
        XCTAssertEqual(decoded.teaching.lessons[0].guide?.steps[0].diagram, DiagramFixture.sample)
        XCTAssertEqual(try GuidanceFixture.encode(decoded), encoded)
        XCTAssertNotEqual(StudySHA256.hex(try GuidanceFixture.encode(decoded.teaching)), old.hash)
        // Old App's accepted envelope list excludes v3, preventing unknown-field loss.
        XCTAssertFalse(["xkl-course-v1", "xkl-course-v2"].contains(course.format))
    }

    func testInvalidGeometryStylesAndExcessiveContentAreRejected() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: GuidanceFixture.encode(DiagramFixture.sample)) as? [String: Any])
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 99 }, { $0["width"] = 640 }, { $0["height"] = 1000 },
            { $0["description"] = "" },
            { x in var s = x["shapes"] as! [[String: Any]]; s[0]["x"] = -1; x["shapes"] = s },
            { x in var s = x["shapes"] as! [[String: Any]]; s[0]["width"] = 400; x["shapes"] = s },
            { x in var s = x["shapes"] as! [[String: Any]]; s[0]["kind"] = "remote-svg"; x["shapes"] = s },
            { x in var s = x["paths"] as! [[String: Any]]; s[0]["points"] = [["x": 1, "y": 1], ["x": 1, "y": 1]]; x["paths"] = s },
            { x in var s = x["paths"] as! [[String: Any]]; s[0]["points"] = [["x": 1, "y": 1], ["x": 321, "y": 1]]; x["paths"] = s },
            { x in var s = x["labels"] as! [[String: Any]]; s[0]["size"] = 9; x["labels"] = s },
            { x in var s = x["labels"] as! [[String: Any]]; s[0]["text"] = String(repeating: "字", count: 91); x["labels"] = s },
            { x in var s = x["labels"] as! [[String: Any]]; s[0]["color"] = "unknown"; x["labels"] = s },
            { x in let s = x["labels"] as! [[String: Any]]; x["labels"] = Array(repeating: s[0], count: 41) }
        ]
        for edit in edits {
            var object = original; edit(&object)
            let invalid = try JSONDecoder().decode(ConceptDiagram.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try invalid.validate())
            let course = try DiagramFixture.course(GuidanceFixture(), diagram: invalid)
            XCTAssertThrowsError(try ConceptCourse.load(GuidanceFixture.encode(course), subject: .computer))
        }
    }

    func testNonfiniteCoordinatesAndDimensionsFailClosed() throws {
        let s = DiagramFixture.sample
        for value in [Double.nan, .infinity, -.infinity] {
            let invalid = ConceptDiagram(version: 1, title: s.title, width: 320, height: s.height,
                description: s.description, shapes: [.init(kind: "rect", x: value, y: 0, width: 20, height: 20, stroke: "ink", fill: "none")],
                paths: s.paths, labels: s.labels)
            XCTAssertThrowsError(try invalid.validate())
        }
    }
}

#if os(macOS)
final class ConceptDiagramIntegrationTests: XCTestCase {
    @MainActor func testImageCourseImportPreservesFormalStateAndBothVersionPositions() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try GuidanceFixture(), new = try DiagramFixture.course(old)
        let input = root.appendingPathComponent("synthetic.xklcourse"), store = ConceptStore(baseDirectory: root)
        try GuidanceFixture.write(GuidanceFixture.encode(old.course), input); store.importContent(input); store.start(newLimit: 2)
        let presentation = try XCTUnwrap(store.engine?.shown)
        store.openGuidance(conceptID: "c0", presentationID: presentation.id)
        store.guidanceAction("step", stepID: "define"); store.guidanceAction("step", stepID: "check")
        store.guidanceAction("answer", choiceID: "b"); store.guidanceAction("step", stepID: "transfer")
        store.guidanceAction("step", stepID: ConceptGuide.recallStepID); store.guidanceAction("remember", recallIndex: 0)
        let position = try XCTUnwrap(store.guidance?.active)
        let directory = root.appendingPathComponent("ComputerFoundation")
        let state = directory.appendingPathComponent("\(old.teaching.bankSHA256)/current.json")
        let history = directory.appendingPathComponent("guidance-current.json")
        let archived = directory.appendingPathComponent("guidance-content/\(old.hash).json")
        let stateBefore = try Data(contentsOf: state), historyBefore = try Data(contentsOf: history), archiveBefore = try Data(contentsOf: archived)
        let eventsBefore = try XCTUnwrap(store.guidance?.events)
        try GuidanceFixture.write(GuidanceFixture.encode(new), input); store.importContent(input)
        XCTAssertNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(try Data(contentsOf: state), stateBefore)
        XCTAssertEqual(try Data(contentsOf: history), historyBefore)
        XCTAssertEqual(try Data(contentsOf: archived), archiveBefore)
        store.openGuidance(conceptID: "c0")
        XCTAssertNotNil(store.guidanceLesson?.guide?.steps[0].diagram)
        XCTAssertEqual(store.guidance?.positions.count, 2)
        store.resumeGuidance(position)
        XCTAssertEqual(store.guidance?.active, position)
        XCTAssertNil(store.guidanceLesson?.guide?.steps[0].diagram)
        XCTAssertEqual(Array(try XCTUnwrap(store.guidance?.events).prefix(eventsBefore.count)), eventsBefore)
        let restarted = ConceptStore(baseDirectory: root)
        XCTAssertFalse(restarted.blocked); XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.guidance, store.guidance)
        XCTAssertEqual(try Data(contentsOf: state), stateBefore)
        XCTAssertEqual(try Data(contentsOf: archived), archiveBefore)
    }

    @MainActor func testInvalidDiagramFailsBeforeAnyExistingStateOrActiveTeachingWrite() async throws {
        let root = try GuidanceFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try GuidanceFixture(), input = root.appendingPathComponent("synthetic.xklcourse")
        let store = ConceptStore(baseDirectory: root)
        try GuidanceFixture.write(GuidanceFixture.encode(old.course), input); store.importContent(input); store.start()
        store.openGuidance(conceptID: "c0")
        let directory = root.appendingPathComponent("ComputerFoundation")
        let paths = ["active.json", "guidance-current.json", "\(old.teaching.bankSHA256)/current.json", "\(old.teaching.bankSHA256)/teaching-active.json"]
        let before = try paths.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        let s = DiagramFixture.sample
        let invalid = ConceptDiagram(version: 1, title: s.title, width: 320, height: 1000,
            description: s.description, shapes: s.shapes, paths: s.paths, labels: s.labels)
        try GuidanceFixture.write(GuidanceFixture.encode(DiagramFixture.course(old, diagram: invalid)), input)
        store.importContent(input)
        XCTAssertNotNil(store.error); XCTAssertFalse(store.blocked)
        XCTAssertEqual(try paths.map { try Data(contentsOf: directory.appendingPathComponent($0)) }, before)
        XCTAssertFalse(ConceptStore(baseDirectory: root).blocked)
    }
}
#endif
