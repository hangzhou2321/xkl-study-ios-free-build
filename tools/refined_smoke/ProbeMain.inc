#if DEBUG
private struct SyntheticCourseRoot: View {
 @StateObject private var computer = ConceptStore()
 @StateObject private var power = ConceptStore(subject:.power)
 @StateObject private var oldComputer = HandbookWordStore(subject:.computer)
 @StateObject private var oldPower = HandbookWordStore(subject:.power)
 @StateObject private var newComputer = RefinedMemoryStore(subject:.computer)
 @StateObject private var newPower = RefinedMemoryStore(subject:.power)
 @State private var subject:ConceptSubject = .computer
 @State private var practicing=false
 @State private var recalling=false
 var body:some View {TabView {
    Text("Synthetic Home").tabItem{Label("首页",systemImage:"house")}
    ProfessionalCoursesView(computer:computer,power:power,subject:$subject,practicing:$practicing,recalling:$recalling,
      handbookComputer:oldComputer,handbookPower:oldPower,refinedComputer:newComputer,refinedPower:newPower)
        .tabItem{Label("专业课",systemImage:"books.vertical")}
 }}
}
#endif
