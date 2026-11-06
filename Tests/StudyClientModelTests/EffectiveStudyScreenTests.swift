import XCTest
@testable import StudyClientModel

final class EffectiveStudyScreenTests: XCTestCase {
    func testAllSevenSubjectsUseOnlyTheirVisibleContent() {
        var screen = EffectiveStudyScreen(); screen.foreground = true
        screen.tab = .vocabulary; screen.vocabularyVisible = true
        XCTAssertEqual(screen.area, .vocabulary)
        screen.tab = .publicQuestions; screen.publicVisible = true
        XCTAssertEqual(screen.area, .publicQuestions)
        screen.tab = .math; screen.mathVisible = true
        XCTAssertEqual(screen.area, .math)
        screen.tab = .professional; screen.professionalVisible = true
        for area in [EffectiveStudyArea.computer, .power, .circuit, .mechanics] {
            screen.professionalArea = area
            XCTAssertEqual(screen.area, area)
        }
        screen.professionalArea = .math
        XCTAssertNil(screen.area)
    }

    func testMathQuestionOrKnowledgeCardReportedAsMath() {
        var screen = EffectiveStudyScreen(); screen.foreground = true; screen.tab = .math
        XCTAssertNil(screen.area)
        screen.mathVisible = true
        XCTAssertEqual(screen.area, .math)
        screen.mathBlocked = true
        XCTAssertNil(screen.area)
        XCTAssertFalse(screen.acceptsInteraction)
    }

    func testMathVisibilityDistinguishesQuestionsCardsAndOverview() {
        XCTAssertTrue(EffectiveStudyScreen.mathContentIsVisible(tabVisible: true, courseOverview: false,
            questionAvailable: true, guideAvailable: true, knowledgeCardVisible: false, blocked: false))
        XCTAssertTrue(EffectiveStudyScreen.mathContentIsVisible(tabVisible: true, courseOverview: true,
            questionAvailable: false, guideAvailable: true, knowledgeCardVisible: true, blocked: false))
        XCTAssertFalse(EffectiveStudyScreen.mathContentIsVisible(tabVisible: true, courseOverview: true,
            questionAvailable: true, guideAvailable: true, knowledgeCardVisible: false, blocked: false))
        XCTAssertFalse(EffectiveStudyScreen.mathContentIsVisible(tabVisible: false, courseOverview: false,
            questionAvailable: true, guideAvailable: true, knowledgeCardVisible: false, blocked: false))
        XCTAssertFalse(EffectiveStudyScreen.mathContentIsVisible(tabVisible: true, courseOverview: false,
            questionAvailable: true, guideAvailable: false, knowledgeCardVisible: false, blocked: false))
        XCTAssertFalse(EffectiveStudyScreen.mathContentIsVisible(tabVisible: true, courseOverview: false,
            questionAvailable: true, guideAvailable: true, knowledgeCardVisible: true, blocked: true))
    }

    func testProfessionalLearningOverlayCountsButPickerAndAlertDoNot() {
        var screen = EffectiveStudyScreen(); screen.foreground = true; screen.tab = .professional
        screen.professionalArea = .circuit
        screen.professionalLearningOverlay = true
        XCTAssertEqual(screen.area, .circuit, "Original question or source sheet is learning content")
        screen.professionalArea = .power
        XCTAssertEqual(screen.area, .power, "Table or source sheet belongs to the visible subject")
        screen.professionalArea = .mechanics
        XCTAssertEqual(screen.area, .mechanics, "Engineering mechanics has its own activity total")
        screen.professionalBlocked = true
        XCTAssertNil(screen.area, "An importer, exporter or error alert blocks counting")
        XCTAssertFalse(screen.acceptsInteraction)
    }

    func testPauseBreakBackgroundAndNavigationHaveDistinctEffects() {
        var screen = EffectiveStudyScreen(); screen.foreground = true; screen.tab = .vocabulary
        screen.vocabularyVisible = true; screen.vocabularyPaused = true
        XCTAssertNil(screen.area)
        screen.vocabularyPaused = false
        XCTAssertEqual(screen.area, .vocabulary)
        screen.globalBlocked = true
        XCTAssertNil(screen.area); XCTAssertFalse(screen.acceptsInteraction)
        screen.globalBlocked = false; screen.foreground = false
        XCTAssertNil(screen.area); XCTAssertFalse(screen.acceptsInteraction)
        screen.foreground = true; screen.tab = .home
        XCTAssertNil(screen.area); XCTAssertTrue(screen.acceptsInteraction)
        screen.tab = .records
        XCTAssertNil(screen.area); XCTAssertTrue(screen.acceptsInteraction)
    }

    func testExplicitProfessionalReferenceSheetMayFollowPausedSegment() {
        var screen = EffectiveStudyScreen(); screen.foreground = true; screen.tab = .professional
        screen.professionalArea = .power; screen.professionalVisible = true; screen.professionalPaused = true
        XCTAssertNil(screen.area)
        screen.professionalLearningOverlay = true
        XCTAssertEqual(screen.area, .power, "Opening a table is new active study independent of an old paused segment")
    }
}
