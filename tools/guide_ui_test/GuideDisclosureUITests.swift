import XCTest

/// Only synthetic simulator data is used; this exercises the ordinary root.
final class GuideDisclosureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openCard(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["专业课"]
        XCTAssertTrue(tab.waitForExistence(timeout: 90)); tab.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "按章节查看卡片")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 45), "章节入口不存在"); entry.tap()
        let card = app.staticTexts["合成卡：设备的诞生"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45), "合成卡不存在"); card.tap()
        let side = app.buttons["handbook-outline-related-questions"]
        XCTAssertTrue(side.waitForExistence(timeout: 45), "目录卡侧原题入口不存在")
        XCTAssertTrue(side.isHittable, "目录卡侧原题入口不可触摸")
        let title = app.staticTexts["合成卡：设备的诞生"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(side.frame.intersects(title.frame), "原题入口遮挡卡片标题")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "合成提示甲")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "四行合成提示未显示")
        XCTAssertFalse(side.frame.intersects(row.frame), "原题入口遮挡提示")
        capture("outline-four-rows-side-button")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "local.xkl.study")
        let fallback = "__GUIDE_TEST_FALLBACK_PLACEHOLDER__"
        XCTAssertFalse(fallback.hasPrefix("__GUIDE_TEST_"))
        if !fallback.isEmpty { app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = fallback }
        app.launch(); return app
    }

    func testOpenAndCloseDoesNotScore() {
        let app = launch(); openCard(app)
        app.buttons["handbook-outline-related-questions"].tap()
        XCTAssertTrue(app.staticTexts["合成原题：哪个选项是示例？"].waitForExistence(timeout: 30))
        capture("outline-related-question")
        let close = app.buttons["返回卡片"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(app.buttons["handbook-outline-related-questions"].waitForExistence(timeout: 20))
        app.terminate()
    }

    func testSubmitCreatesOneRealAttempt() {
        let app = launch(); openCard(app)
        app.buttons["handbook-outline-related-questions"].tap()
        let option = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "合成选项甲")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 30)); option.tap()
        let submit = app.buttons["提交答案"]
        XCTAssertTrue(submit.waitForExistence(timeout: 20)); XCTAssertTrue(submit.isEnabled); submit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "原书答案")).firstMatch.waitForExistence(timeout: 30))
        capture("outline-related-submitted")
        app.terminate()
    }

    func testCardWithoutQuestionHasNoSideButton() {
        let app = launch()
        let tab = app.tabBars.buttons["专业课"]
        XCTAssertTrue(tab.waitForExistence(timeout: 90)); tab.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "按章节查看卡片")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 45)); entry.tap()
        let card = app.staticTexts["合成卡：另一知识点"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45)); card.tap()
        XCTAssertFalse(app.buttons["handbook-outline-related-questions"].exists,
                       "无题卡片不应出现原题入口")
        capture("outline-card-without-question")
        app.terminate()
    }
}
