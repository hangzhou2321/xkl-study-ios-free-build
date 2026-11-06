import XCTest

/// Exercises the ordinary production RootView, not the synthetic preview shell.
/// Its disposable simulator receives synthetic card state before this test runs.
final class GuideDisclosureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func select(_ index: Int, in app: XCUIApplication) {
        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 60), "Production subject picker missing")
        XCTAssertTrue(picker.isHittable, "Production subject picker is not hittable")
        let point = picker.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(index) + 0.5) / 4, dy: 0.5))
        point.tap()
    }

    private func exercise(sourceIndex: Int, targetIndex: Int, targetTitle: String, drag: Bool) {
        let app = XCUIApplication(bundleIdentifier: "local.xkl.study")
        let fallback = "__GUIDE_TEST_FALLBACK_PLACEHOLDER__"
        XCTAssertFalse(fallback.hasPrefix("__GUIDE_TEST_"), "Simulator fallback was not bound")
        if !fallback.isEmpty { app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = fallback }
        app.launch() // No --handbook-card-preview: this is the production root and its window observer.
        let professional = app.tabBars.buttons["专业课"]
        XCTAssertTrue(professional.waitForExistence(timeout: 90), "Professional tab missing")
        professional.tap()
        select(sourceIndex, in: app)
        let continueCard = app.buttons["handbook-continue"]
        XCTAssertTrue(continueCard.waitForExistence(timeout: 45), "Synthetic source was not loaded into real root")
        continueCard.tap()
        let exitFullScreen = app.buttons["handbook-exit-fullscreen"]
        if exitFullScreen.waitForExistence(timeout: 10) { exitFullScreen.tap() }
        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 45), "Real segment pause button missing")
        pause.tap()
        XCTAssertTrue(professional.waitForExistence(timeout: 30), "Home navigation after pause failed")
        professional.tap()
        XCTAssertTrue(app.buttons["继续这一段"].waitForExistence(timeout: 45), "Segment is not visibly paused")
        let answeredCard = app.buttons["handbook-remembered"]
        XCTAssertTrue(answeredCard.waitForExistence(timeout: 30), "Frozen revealed source card not restored")
        XCTAssertFalse(answeredCard.isEnabled, "Paused card must not accept a self-rating")
        capture("before-paused-coordinate-tap")
        // XCTest injects actual screen events against the visible segmented control.
        // No selectedSegmentIndex assignment, sendActions, or in-process switch helper is used.
        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.isHittable, "Paused subject picker is not hittable")
        let destination = picker.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(targetIndex) + 0.5) / 4, dy: 0.5))
        if drag {
            let start = picker.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(sourceIndex) + 0.5) / 4, dy: 0.5))
            start.press(forDuration: 0.2, thenDragTo: destination)
        } else {
            destination.tap()
        }
        capture("immediately-after-physical-gesture")
        let target = app.staticTexts[targetTitle].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 45), "Real coordinate tap did not change subject")
        XCTAssertTrue(app.buttons["handbook-continue"].waitForExistence(timeout: 30), "Destination is not its card home")
        XCTAssertFalse(app.buttons["handbook-remembered"].exists, "Destination must not start or self-rate automatically")
        capture("after-paused-coordinate-tap")
        app.terminate()
    }

    func testPowerToMechanicsTap() { exercise(sourceIndex: 1, targetIndex: 3, targetTitle: "工程力学", drag: false) }
    func testPowerToMechanicsDrag() { exercise(sourceIndex: 1, targetIndex: 3, targetTitle: "工程力学", drag: true) }
    func testMechanicsToPowerTap() { exercise(sourceIndex: 3, targetIndex: 1, targetTitle: "宝典一 · 电力系统", drag: false) }
    func testMechanicsToPowerDrag() { exercise(sourceIndex: 3, targetIndex: 1, targetTitle: "宝典一 · 电力系统", drag: true) }
}
