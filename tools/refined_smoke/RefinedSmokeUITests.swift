import XCTest
final class RefinedSmokeUITests: XCTestCase {
 let app=XCUIApplication()
 func must(_ e:XCUIElement,_ tag:String,file:StaticString=#filePath,line:UInt=#line) throws -> XCUIElement {
  guard e.waitForExistence(timeout:12) else{XCTFail("Missing \(tag): \(app.debugDescription)",file:file,line:line);throw NSError(domain:"probe",code:1)};return e
 }
 func b(_ id:String)throws->XCUIElement{try must(app.buttons[id].firstMatch,id)}
 func subject(_ s:String)throws {
  let tab=try must(app.tabBars.buttons["专业课"].firstMatch,"subject tab");tab.tap()
  try must(app.segmentedControls.buttons[s].firstMatch,s).tap()
 }
 func edition(_ name:String)throws{try must(app.segmentedControls.buttons[name].firstMatch,name).tap()}
 var thinHost=false
 func launch() {app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"]="SIMULATOR_18_5_SWIFT_ABSOLUTE";app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]+(thinHost ? ["--refined-synthetic-course"] : []);app.launch()}
 func checkQuestion(_ key:String)throws->String{
  let q=try must(app.staticTexts["refined-current-question"].firstMatch,"one question")
  XCTAssertEqual(app.staticTexts.matching(identifier:"refined-current-question").count,1)
  let names=(1...3).map{"Synthetic " + key + " question " + String($0) + "?"}
  let matched=names.filter{name in app.staticTexts.allElementsBoundByIndex.contains(where:{$0.label==name})}
  XCTAssertEqual(matched,[q.label]);XCTAssertTrue(names.contains(q.label));return q.label
 }
 func testRealRoot()throws{try exercise()}
 func testSameCourseView()throws{thinHost=true;try exercise()}
 private func exercise()throws{
  continueAfterFailure=false
  addUIInterruptionMonitor(withDescription:"Bluetooth"){a in
   for s in ["Don’t Allow","Don't Allow","不允许","拒绝"] where a.buttons[s].exists {a.buttons[s].tap();return true};return false
  }
  launch()
  let subjects=[("计算机","computer"),("电力","power")]
  // Independently import and grade genuine legacy archives, so preservation is not a check against an empty or fabricated snapshot.
  for (name,_) in subjects {
   try subject(name);try edition("原卡与进度");try b("handbook-import-staged").tap();try b("handbook-continue").tap();try b("handbook-reveal").tap();try b("handbook-forgotten").tap()
   app.terminate();launch()
  }
  var pending=[String:String]()
  for (name,k) in subjects {
   try subject(name);try edition("新版精讲");try b("refined-start").tap()
   let question=try checkQuestion(k);XCTAssertFalse(app.staticTexts["refined-current-answer"].exists)
   try b("refined-reveal").tap();let answer=try must(app.staticTexts["refined-current-answer"].firstMatch,"revealed")
   XCTAssertTrue(answer.label.contains("Synthetic "+k+" answer"));XCTAssertEqual(try checkQuestion(k),question)
   sleep(1) // host-side independent snapshot observer records revealed with zero graded attempts
   try b("refined-again").tap();XCTAssertTrue(try b("refined-reveal").exists);let current=try checkQuestion(k);pending[k]=current
   try edition("原卡与进度");XCTAssertTrue(try b("handbook-continue").exists);XCTAssertFalse(app.buttons["refined-reveal"].exists)
   try edition("新版精讲");try b("refined-start").tap();XCTAssertEqual(try checkQuestion(k),current)
   app.terminate();launch()
   try subject(name);try b("refined-start").tap();XCTAssertEqual(try checkQuestion(k),current);XCTAssertFalse(app.staticTexts["refined-current-answer"].exists)
   app.terminate();launch()
  }
 }
}
