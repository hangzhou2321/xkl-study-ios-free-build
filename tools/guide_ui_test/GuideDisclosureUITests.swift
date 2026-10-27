import XCTest

final class GuideDisclosureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func capture(_ label: String) {
        let result = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        result.name = label
        result.lifetime = .keepAlways
        add(result)
    }

    private func verifySubject(_ subject: String) throws {
        let app = XCUIApplication(bundleIdentifier: "local.xkl.study")
        app.launchArguments = ["--handbook-card-preview", "--subject=\(subject)", "--case=front",
                               "--capture-id=\(UUID().uuidString.lowercased())"]
        if let fallback = ProcessInfo.processInfo.environment["GUIDE_TEST_DYLD_FALLBACK"], !fallback.isEmpty {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = fallback
        }
        app.launch()
        let reveal = app.buttons["handbook-reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 45), "Synthetic front should start")
        let firstCue = app.staticTexts["合成提示甲："]
        XCTAssertTrue(firstCue.waitForExistence(timeout: 10), "Guide front should render")
        XCTAssertTrue(app.staticTexts["合成提示己："].exists, "All six cues belong to one card")
        XCTAssertFalse(app.staticTexts["合成答案甲"].exists, "Guide answers must be hidden before revealing")
        capture("\(subject)-six-rows-front-top")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        scroll.swipeUp()
        XCTAssertTrue(app.staticTexts["合成提示己："].isHittable, "Last cue should be reachable by scrolling")
        capture("\(subject)-six-rows-front-bottom")
        XCTAssertTrue(reveal.isHittable, "Single reveal button must remain available")
        reveal.tap()
        XCTAssertTrue(app.buttons["handbook-remembered"].waitForExistence(timeout: 10))
        let fullAnswer = app.descendants(matching: .any).matching(identifier: "handbook-guide-full-answer").firstMatch
        for _ in 0..<3 where !fullAnswer.isHittable { scroll.swipeUp() }
        XCTAssertTrue(fullAnswer.isHittable, "The full lesson disclosure should be reachable")
        XCTAssertTrue(app.staticTexts["合成答案己"].exists, "The same single reveal exposes the last core answer")
        capture("\(subject)-six-rows-back")

        let summary = app.descendants(matching: .any).matching(identifier: "handbook-card-summary").firstMatch
        XCTAssertFalse(summary.exists, "Full lesson should start collapsed")
        // Allow the host record monitor to capture a stable post-reveal baseline.
        Thread.sleep(forTimeInterval: 8)
        fullAnswer.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Tap must expand the real full lesson")
        capture("\(subject)-full-answer-expanded")
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<3 where !fullAnswer.isHittable { scroll.swipeDown() }
        XCTAssertTrue(fullAnswer.isHittable, "The same disclosure can be closed")
        fullAnswer.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: summary)
        wait(for: [gone], timeout: 10)
        capture("\(subject)-full-answer-collapsed")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["handbook-remembered"].exists, "No self-rating was submitted")
        app.terminate()
    }

    func testComputerGuideDisclosure() throws { try verifySubject("computer") }
    func testPowerGuideDisclosure() throws { try verifySubject("power") }
}
