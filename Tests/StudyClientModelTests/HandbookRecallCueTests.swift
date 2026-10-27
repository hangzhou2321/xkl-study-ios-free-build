import XCTest
@testable import StudyClientModel

final class HandbookRecallCueTests: XCTestCase {
    func testBothColonsPreserveOnlySourceLabelsAcrossClauses() {
        let cues = HandbookRecallCue.lines("甲：SECRET_A；乙: SECRET_B\n丙：SECRET_C。")
        XCTAssertEqual(cues.map(\.prefix), ["甲：", "乙:", "丙："])
        XCTAssertTrue(cues.allSatisfy(\.hidesAnswer))
        XCTAssertFalse(cues.description.contains("SECRET"))
    }
    func testNestedAnswerColonDoesNotExposeAnUnlabelledParagraph() {
        let cues = HandbookRecallCue.lines("SECRET_A（备注：SECRET_B；SECRET_C），SECRET_D。")
        XCTAssertEqual(cues, [.init(prefix: "", hidesAnswer: true)])
        let labelled = HandbookRecallCue.lines("提示（条件：甲；乙）：SECRET_A（说明：SECRET_B）")
        XCTAssertEqual(labelled, [.init(prefix: "提示（条件：甲；乙）：", hidesAnswer: true)])
    }
    func testUnlabelledTextTimeRatioURLAndLiteralSymbolsStayHidden() {
        for source in ["SECRET", "12:30", "比例3:2", "https://synthetic.invalid", "U_* **甲** _乙_"] {
            XCTAssertEqual(HandbookRecallCue.lines(source), [.init(prefix: "", hidesAnswer: true)], source)
        }
        XCTAssertEqual(HandbookRecallCue.lines("U_*：A_1 * B_2"), [.init(prefix: "U_*：", hidesAnswer: true)])
        XCTAssertEqual(HandbookRecallCue.lines("标题："), [.init(prefix: "标题：", hidesAnswer: false)])
        XCTAssertTrue(HandbookRecallCue.lines(" \n ").isEmpty)
    }
    func testTableKeepsLabelsAndOriginalBlanksWithoutLeakingAnswerCells() {
        XCTAssertEqual(HandbookRecallCue.cell("项目甲", column: 0), .visible("项目甲"))
        XCTAssertEqual(HandbookRecallCue.cell("SECRET_A", column: 1), .hidden)
        XCTAssertEqual(HandbookRecallCue.cell("SECRET_B", column: 2), .hidden)
        for column in 0...2 { XCTAssertEqual(HandbookRecallCue.cell("", column: column), .visible("")) }
    }
}
