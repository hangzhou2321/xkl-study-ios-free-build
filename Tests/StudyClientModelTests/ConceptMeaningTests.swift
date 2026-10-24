import Foundation
import XCTest
@testable import StudyClientModel

final class ConceptMeaningTests: XCTestCase {
    private func word(_ json: String) throws -> StudyWord {
        try JSONDecoder().decode(StudyWord.self, from: Data(json.utf8))
    }

    func testOldWordContentStillLoadsWithoutInventedMapping() throws {
        let value = try word(#"{"id":0,"word":"sample","core":[{"pos":"n.","meaning":"样本","cue":""}],"expanded":"补充"}"#)
        XCTAssertTrue(value.hasValidConceptMapping)
        XCTAssertFalse(value.usesConceptPresentation)
        XCTAssertEqual(value.originalDefinitionText, "")
        XCTAssertNil(value.core[0].explanation)
    }

    func testMergedGroupsKeepAllOriginalDefinitionsInOriginalOrder() throws {
        let value = try word(#"{"id":0,"word":"sample","meaningPresentation":"whole-word-concepts-v1","originalCoreCount":3,"core":[{"pos":"v.","meaning":"原义甲和丙属于同一概念","cue":"","oldCoreIndices":[0,2],"originalMeanings":[{"pos":"v.","meaning":"原义甲","cue":"example A"},{"pos":"v.","meaning":"原义丙","cue":""}]},{"pos":"n.","meaning":"独立意思乙","cue":"","oldCoreIndices":[1],"originalMeanings":[{"pos":"n.","meaning":"原义乙","cue":"example B"}]}],"expanded":"保留的扩展义"}"#)
        XCTAssertTrue(value.hasValidConceptMapping)
        XCTAssertEqual(value.core.count, 2)
        XCTAssertEqual(value.originalDefinitionText, "1. v. 原义甲\nexample A\n\n2. n. 原义乙\nexample B\n\n3. v. 原义丙")
        XCTAssertEqual(value.expanded, "保留的扩展义")
    }

    func testPerSenseExplanationAndUsageLabelsDoNotChangeOriginalMapping() throws {
        let value = try word(#"{"id":0,"word":"sample","meaningPresentation":"whole-word-concepts-v1","originalCoreCount":3,"core":[{"pos":"v.","meaning":"主记概念甲","cue":"短例句","explanation":"区分这个概念与相近义项的详细解释。","usageLabels":["正式","~ sth (with sth)"],"oldCoreIndices":[0,2],"originalMeanings":[{"pos":"v.","meaning":"原义甲","cue":"example A"},{"pos":"v.","meaning":"原义丙","cue":"example C"}]},{"pos":"n.","meaning":"主记概念乙","cue":"","oldCoreIndices":[1],"originalMeanings":[{"pos":"n.","meaning":"原义乙","cue":"example B"}]}],"expanded":"保留的整词扩展义"}"#)

        XCTAssertTrue(value.hasValidConceptMapping)
        XCTAssertEqual(value.core[0].meaning, "主记概念甲")
        XCTAssertEqual(value.core[0].cue, "短例句")
        XCTAssertEqual(value.core[0].explanation, "区分这个概念与相近义项的详细解释。")
        XCTAssertEqual(value.core[0].usageLabels, ["正式", "~ sth (with sth)"])
        XCTAssertNil(value.core[1].explanation)
        XCTAssertFalse(value.originalDefinitionText.contains("详细解释"))
        XCTAssertFalse(value.originalDefinitionText.contains("正式"))
        XCTAssertEqual(value.originalDefinitionText, "1. v. 原义甲\nexample A\n\n2. n. 原义乙\nexample B\n\n3. v. 原义丙\nexample C")
        XCTAssertEqual(value.expanded, "保留的整词扩展义")
    }

    func testDroppedDuplicatedAndUnboundOriginalSensesAreRejected() throws {
        for indices in ["[0]", "[0,0]", "[0,2]", "[-1,1]"] {
            let count = indices == "[0]" ? 1 : 2
            let originals = Array(repeating: #"{"pos":"v.","meaning":"原释义","cue":""}"#, count: count).joined(separator: ",")
            let json = "{\"id\":0,\"word\":\"sample\",\"meaningPresentation\":\"whole-word-concepts-v1\",\"originalCoreCount\":2,\"core\":[{\"pos\":\"v.\",\"meaning\":\"简记\",\"cue\":\"\",\"oldCoreIndices\":\(indices),\"originalMeanings\":[\(originals)]}],\"expanded\":\"\"}"
            XCTAssertFalse(try word(json).hasValidConceptMapping)
        }
        let missing = try word(#"{"id":0,"word":"sample","meaningPresentation":"whole-word-concepts-v1","originalCoreCount":1,"core":[{"pos":"v.","meaning":"简记","cue":""}],"expanded":""}"#)
        XCTAssertFalse(missing.hasValidConceptMapping)
    }

    func testNewDictionarySensesRetainOldMappingWithoutShowingWrongLegacyMeaningAsSource() throws {
        let value = try word(#"{"id":0,"word":"sample","meaningPresentation":"whole-word-concepts-v1","originalCoreCount":1,"core":[{"pos":"n.","meaning":"修正义一","cue":"","newlySourced":true,"oldCoreIndices":[0],"originalMeanings":[{"pos":"n.","meaning":"旧版错误释义","cue":""}],"sourceOriginals":[{"pos":"n.","meaning":"来源义一","cue":"","english":"source definition one","source":"词典条目1"}]},{"pos":"n.","meaning":"新增义二","cue":"","newlySourced":true,"oldCoreIndices":[],"originalMeanings":[],"sourceOriginals":[{"pos":"n.","meaning":"来源义二","cue":"","english":"source definition two","source":"词典条目2"}]}],"expanded":""}"#)
        XCTAssertTrue(value.hasValidConceptMapping)
        XCTAssertEqual(value.originalCoreCount, 1)
        XCTAssertEqual(value.core.count, 2)
        XCTAssertFalse(value.originalDefinitionText.contains("旧版错误释义"))
        XCTAssertTrue(value.originalDefinitionText.contains("来源义一"))
        XCTAssertTrue(value.originalDefinitionText.contains("source definition two"))
        let unbound = try word(#"{"id":0,"word":"sample","meaningPresentation":"whole-word-concepts-v1","originalCoreCount":1,"core":[{"pos":"n.","meaning":"义一","cue":"","oldCoreIndices":[0],"originalMeanings":[{"pos":"n.","meaning":"旧义","cue":""}]},{"pos":"n.","meaning":"未经来源绑定的新义","cue":"","oldCoreIndices":[],"originalMeanings":[]}],"expanded":""}"#)
        XCTAssertFalse(unbound.hasValidConceptMapping)
    }
}
