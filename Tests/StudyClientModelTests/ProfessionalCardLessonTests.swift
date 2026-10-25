import XCTest
import StudyCore
@testable import StudyClientModel

enum CardLessonFixture {
    static func sample(_ cards:[RecallCard],id:String="synthetic-application")->ProfessionalCardLesson {
        .init(id:id,title:"合成：从容量到任务",bindings:cards.map { .init(cardID:$0.id,sourceCardDigest:$0.professionalDigest) },
              intuition:"功率表示速度，容量表示总量；先统一单位，再问任务能持续多久。",
              conditions:["只用明确给定的可用能量与恒定功率。","没有给效率或可用比例时，不自行猜一个比例。"],
              workedExample:.init(prompt:"合成设备可用能量12单位，以3单位每小时输出，能持续多久？",steps:["总量为12。","每小时消耗3，所以用12除以3。"],answer:"4小时。"),
              transferCheck:.init(prompt:"同一设备只允许使用一半能量，输出仍为3单位每小时，能持续多久？",steps:["可用量变为12×1/2=6。","6÷3=2。"],answer:"2小时。"),
              transferHint:"先改可用总量，再除以原输出速度。",sourceRefs:["纯合成测试；不含用户资料。"])
    }
}

final class ProfessionalCardLessonTests:XCTestCase {
    private func fixture()->(RecallDeck,RecallCard) {
        let card=RecallCard(id:"synthetic:one",prompt:"原问题",answer:"原答案",detail:"原详情")
        return (RecallDeck(subject:.power,bankID:ConceptSubject.power.bankID,cards:[.init(conceptID:"synthetic",conceptTitle:"合成",card:card)]),card)
    }
    func testDigestBindingRejectsRevisedCardDuplicateBindingAndUnknownID() throws {
        let (deck,card)=fixture();let lesson=CardLessonFixture.sample([card])
        XCTAssertNoThrow(try ProfessionalCardLesson.validateAll([lesson],deck:deck,groups:[]))
        XCTAssertThrowsError(try ProfessionalCardLesson.validateAll([lesson,CardLessonFixture.sample([card],id:"other")],deck:deck,groups:[]))
        let changed=RecallDeck(subject:.power,bankID:deck.bankID,cards:[.init(conceptID:"synthetic",conceptTitle:"合成",card:.init(id:card.id,prompt:card.prompt,answer:"changed"))])
        XCTAssertThrowsError(try ProfessionalCardLesson.validateAll([lesson],deck:changed,groups:[]))
        XCTAssertThrowsError(try ProfessionalCardLesson.validateAll([CardLessonFixture.sample([.init(id:"unknown",prompt:"?",answer:"!")])],deck:deck,groups:[]))
    }
    func testLessonRequiresCompleteExampleAndActualChangedPrompt() throws {
        let (deck,card)=fixture();let source=CardLessonFixture.sample([card])
        var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any])
        raw["conditions"]=[]
        let noConditions=try JSONDecoder().decode(ProfessionalCardLesson.self,from:JSONSerialization.data(withJSONObject:raw))
        XCTAssertThrowsError(try ProfessionalCardLesson.validateAll([noConditions],deck:deck,groups:[]))
        raw=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any]);raw["transferCheck"]=raw["workedExample"]
        let repeated=try JSONDecoder().decode(ProfessionalCardLesson.self,from:JSONSerialization.data(withJSONObject:raw))
        XCTAssertThrowsError(try ProfessionalCardLesson.validateAll([repeated],deck:deck,groups:[]))
        raw.removeValue(forKey:"transferCheck")
        XCTAssertThrowsError(try JSONDecoder().decode(ProfessionalCardLesson.self,from:JSONSerialization.data(withJSONObject:raw)))
    }
    func testOldTeachingHasNoLessonAndLookupNeedsExactCardDigest() throws {
        let (_,card)=fixture();var teaching=ConceptTeaching(format:"xkl-teaching-v1",bankSHA256:String(repeating:"a",count:64),lessons:[])
        let loaded=try JSONDecoder().decode(ConceptTeaching.self,from:JSONEncoder().encode(teaching))
        XCTAssertNil(loaded.cardLessons);XCTAssertNil(loaded.applicationLesson(for:card))
        teaching.cardLessons=[CardLessonFixture.sample([card])]
        XCTAssertNotNil(teaching.applicationLesson(for:card))
        XCTAssertNil(teaching.applicationLesson(for:.init(id:card.id,prompt:card.prompt,answer:"stale")))
    }
}
