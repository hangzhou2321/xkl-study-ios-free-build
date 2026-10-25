import XCTest
@testable import StudyClientModel

final class ProfessionalSourceSectionsTests: XCTestCase {
    func testPlanSectionsAreDisjointCompleteAndPreservePracticeOrder() {
        let groups=ProfessionalSourceSections.make(practiceQuestionIDs:["extension","original","variant","other-original"],sourceBankQuestionIDs:["original","other-original"],selectedPlanQuestionIDs:["variant","original"])
        XCTAssertEqual(groups.lectureQuestionIDs,["original"])
        XCTAssertEqual(groups.variantQuestionIDs,["variant"])
        XCTAssertEqual(groups.extensionQuestionIDs,["extension","other-original"])
        let all=groups.lectureQuestionIDs+groups.variantQuestionIDs+groups.extensionQuestionIDs
        XCTAssertEqual(all.count,Set(all).count)
        XCTAssertEqual(Set(all),Set(["extension","original","variant","other-original"]))
        XCTAssertFalse(groups.usesLegacyFallback)
    }
    func testSourceAliasesAndRepeatedPracticeReferencesDoNotDuplicateQuestions() {
        let groups=ProfessionalSourceSections.make(practiceQuestionIDs:["original","original","variant"],sourceBankQuestionIDs:["original","original","unbound-alias"],selectedPlanQuestionIDs:["original","variant","original"])
        XCTAssertEqual(groups.lectureQuestionIDs,["original"])
        XCTAssertEqual(groups.variantQuestionIDs,["variant"])
        XCTAssertEqual(groups.extensionQuestionIDs,[])
    }
    func testNoPlanShowsEntireLegacyPracticeWithoutInventingVariants() {
        let groups=ProfessionalSourceSections.make(practiceQuestionIDs:["old-b","old-a","old-b"],sourceBankQuestionIDs:["old-a"],selectedPlanQuestionIDs:nil)
        XCTAssertTrue(groups.usesLegacyFallback)
        XCTAssertEqual(groups.extensionQuestionIDs,["old-b","old-a"])
        XCTAssertEqual(groups.lectureQuestionIDs,[])
        XCTAssertEqual(groups.variantQuestionIDs,[])
    }
    func testCompletedUnavailableAndUnselectedQuestionsRemainBrowsable() {
        let alreadyAnswered=Set(["original-done","variant-done","extension-done"])
        let practice=["original-done","original-new","variant-done","extension-done"]
        let groups=ProfessionalSourceSections.make(practiceQuestionIDs:practice,sourceBankQuestionIDs:["original-done","original-new"],selectedPlanQuestionIDs:["original-done","original-new","variant-done"])
        XCTAssertEqual(groups.lectureQuestionIDs,["original-done","original-new"])
        XCTAssertEqual(groups.variantQuestionIDs,["variant-done"])
        XCTAssertEqual(groups.extensionQuestionIDs,["extension-done"])
        XCTAssertTrue(alreadyAnswered.isSubset(of:Set(groups.lectureQuestionIDs+groups.variantQuestionIDs+groups.extensionQuestionIDs)))
    }
    func testEmptyPlanDoesNotFallBackToMakingAllQuestionsMainline() {
        let groups=ProfessionalSourceSections.make(practiceQuestionIDs:["old","original"],sourceBankQuestionIDs:["original"],selectedPlanQuestionIDs:[])
        XCTAssertFalse(groups.usesLegacyFallback)
        XCTAssertEqual(groups.lectureQuestionIDs,[])
        XCTAssertEqual(groups.variantQuestionIDs,[])
        XCTAssertEqual(groups.extensionQuestionIDs,["old","original"])
    }
}
