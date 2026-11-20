import XCTest

final class OriginalPracticeSmokeUITests: XCTestCase {
    private let app = XCUIApplication()

    private func element(_ e: XCUIElement, _ context: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        guard e.waitForExistence(timeout: 20) else {
            XCTFail("Missing \(context): \(app.debugDescription)", file: file, line: line)
            throw NSError(domain: "OriginalPracticeUISmoke", code: 1)
        }
        return e
    }

    private func open(_ subject: String) throws {
        let tab = app.tabBars.buttons["专业课"].firstMatch
        try element(tab, "professional tab").tap()
        let label = subject == "circuit" ? "电路" : "力学"
        try element(app.segmentedControls.buttons[label].firstMatch, label).tap()
        try element(app.buttons["original-practice-course"].firstMatch, "native course entry").tap()
        let web = try element(app.webViews.firstMatch, "production WKWebView")
        try element(web.links["Open synthetic problem " + subject].firstMatch, "subject-routed course.html").tap()
        _ = try element(web.buttons["Reveal synthetic hint"].firstMatch, "main.html hint")
    }
    private func queryText(_ label: String) -> XCUIElement {
        app.webViews.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    func testSubjectNavigationAssistedResponsesAndColdReopen() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "First-launch simulator permission") { dialog in
            guard dialog.label.localizedCaseInsensitiveContains("Bluetooth") || dialog.label.contains("蓝牙") ||
                  dialog.staticTexts.allElementsBoundByIndex.contains(where: { $0.label.localizedCaseInsensitiveContains("Bluetooth") || $0.label.contains("蓝牙") }) else { return false }
            for name in ["不允许","Don’t Allow","Don't Allow","拒绝"] where dialog.buttons[name].exists {
                dialog.buttons[name].tap(); return true
            }
            return false
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--synthetic-original-practice-ui"]
        app.launch()
        for subject in ["circuit", "mechanics"] {
            try open(subject)
            _ = try element(queryText("Hint concealed"), "unused hint")
            _ = try element(queryText("Not selected"), "unanswered problem")
            let web = app.webViews.firstMatch
            try element(web.buttons["Reveal synthetic hint"].firstMatch, "hint").tap()
            _ = try element(queryText("Hint used"), "hint action")
            try element(web.buttons["Choose four"].firstMatch, "answer choice").tap()
            _ = try element(queryText("Selected four"), "answer action")
            // Web app changes the exercise fragment, then opens a document. Native Back must restore
            // the actual recent exercise, not the initial URL of main.html.
            try element(web.buttons["Switch to second synthetic question"].firstMatch, "advance within main.html").tap()
            _ = try element(queryText("Second synthetic question"), "updated bookmark")
            try element(web.links["Open synthetic detail"].firstMatch, "open document").tap()
            _ = try element(queryText("Synthetic detail " + subject), "detail page")
            try element(app.buttons["返回"].firstMatch, "native back").tap()
            _ = try element(queryText("Second synthetic question"), "returned to actual recent question")
            _ = try element(queryText("Selected four"), "response after native back")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "synthetic-assisted-" + subject; shot.lifetime = .keepAlways; add(shot)
            // Native dismissal drains pending WK messages before leaving the lesson.
            try element(app.buttons["退出练习"].firstMatch, "leave and drain bridge").tap()
            _ = try element(app.buttons["original-practice-course"].firstMatch, "returned to native course entry")
            app.terminate(); app.launch()
            try open(subject)
            _ = try element(queryText("Hint used"), "restored hint after cold launch")
            _ = try element(queryText("Selected four"), "restored option after cold launch")
            try element(app.buttons["退出练习"].firstMatch, "leave restored lesson").tap()
            _ = try element(app.buttons["original-practice-course"].firstMatch, "restored native entry")
        }
    }
}
