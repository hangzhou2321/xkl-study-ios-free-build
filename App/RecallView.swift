import SwiftUI
import UniformTypeIdentifiers

struct RecallStudyView: View {
    @StateObject private var store: RecallStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var newLimit = 10
    @State private var exporting = false
    @State private var document: RecallExportDocument?
    private let subject: ConceptSubject
    private let teaching: ConceptTeaching
    private let planSelection: ProfessionalRecallSelection?

    init(subject: ConceptSubject, bank: ConceptBank, teaching: ConceptTeaching, supplementGroup: SupplementRecallGroup? = nil, planSelection: ProfessionalRecallSelection? = nil, baseDirectory: URL? = nil) {
        self.subject = subject
        self.teaching = teaching
        self.planSelection = planSelection
        _store = StateObject(wrappedValue: RecallStore(subject: subject, bank: bank, teaching: teaching, baseDirectory: baseDirectory, supplementGroup: supplementGroup))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let engine = store.engine {
                    let selectionDay=(try? ConceptCalendar.studyDay(Date())) ?? engine.record.state.day
                    Text("当前选择 \(engine.selectedTotal) 张 / 完整档案 \(engine.deck.cards.count) 张").font(.subheadline)
                    Text("当前选择：待复习 \(engine.selectedDueCount(day:selectionDay)) 张 · 待学 \(engine.selectedNewCount) 张").font(.footnote).foregroundStyle(.secondary)
                    if let planSelection {
                        Text(planSelection.title).font(.title2.bold())
                        Text("此入口范围 \(planSelection.cardIDs.count) 张 / 完整档案 \(engine.deck.cards.count) 张").font(.subheadline)
                        Text(engine.item == nil ? "按本范围学习；原成绩保留，其他卡仍可从拓展入口学习。" : "先继续上次这一张，后续按本范围；原成绩保留，其他卡仍可从拓展入口学习。").font(.footnote).foregroundStyle(.secondary)
                        Button(engine.item == nil ? "按这部分开始" : "按这部分继续") {
                            beginSelectedScope()
                        }.buttonStyle(.borderedProminent).disabled(store.blocked)
                    }
                    if !selectionIsApplied(engine) { Text("点上方按钮即可按这部分学习；已有当前卡和成绩会保留。").font(.footnote).foregroundStyle(.secondary) }
                    Group {
                    if let item = engine.item {
                        Text(item.conceptTitle).font(.subheadline).foregroundStyle(.secondary)
                        if let priority=teaching.cardPriorities?.first(where: { $0.cardID == item.card.id && $0.sourceCardDigest == item.card.professionalDigest }) { ProfessionalCardPriorityLabel(value:priority) }
                        Text(item.card.prompt).font(.title2.weight(.semibold)).textSelection(.enabled)
                        if let result = engine.record.state.result {
                            answer(item.card)
                            Text(result.remembered ? "已记录：记住了" : "已记录：没记住")
                                .font(.headline).foregroundStyle(result.remembered ? .green : .orange)
                            Text("下次跨天复习：\(dayText(result.dueDay))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if !result.remembered && engine.record.state.queue.contains(item.id) {
                                Text("本轮会隔开至少 3 张其他卡，再补背一次；今天补背不升级。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("下一张") { store.act("next", token: result.presentation.id) }
                                .buttonStyle(.borderedProminent).disabled(store.blocked)
                        } else if let shown = engine.record.state.shown {
                            if shown.revealed {
                                answer(item.card)
                                Text("按刚才翻答案前的回忆自评。要点和必要条件说对即可，不要求逐字一致。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                HStack {
                                    Button("没记住") { store.act("grade", token: shown.id, remembered: false) }
                                        .buttonStyle(.bordered).tint(.orange)
                                    Button("记住了") { store.act("grade", token: shown.id, remembered: true) }
                                        .buttonStyle(.borderedProminent).tint(.green)
                                }.disabled(store.blocked)
                            } else {
                                Text("先在心里或口头回答，再翻开核对。")
                                    .foregroundStyle(.secondary)
                                Button("翻答案") { store.act("reveal", token: shown.id) }
                                    .buttonStyle(.borderedProminent).disabled(store.blocked)
                            }
                        }
                        Text("本轮待完成 \(engine.record.state.queue.count) 张")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("\(subject.title) · 问答背诵").font(.title2.bold())
                        Text("完整档案 \(engine.deck.cards.count) 张卡 · \(Set(engine.deck.cards.map(\.conceptID)).count) 个考点").font(.subheadline).foregroundStyle(.secondary)
                        let day = (try? ConceptCalendar.studyDay(Date())) ?? engine.record.state.day
                        if engine.record.state.selection != nil {
                            DisclosureGroup("完整档案统计") { Text("全部卡到期 \(engine.dueCount(day:day)) 张 · 未学 \(engine.newCount) 张；不表示本范围需要学习这些卡。").font(.footnote).foregroundStyle(.secondary) }
                        }
                        Stepper("本次新卡：\(newLimit)", value: $newLimit, in: 1...25)
                            .disabled(!engine.record.state.queue.isEmpty || store.blocked)
                        if planSelection == nil {
                            Button(engine.record.state.queue.isEmpty ? "开始背诵" : "继续背诵") {
                                store.act("start", newLimit: newLimit)
                            }.buttonStyle(.borderedProminent)
                                .disabled(store.blocked || (engine.record.state.queue.isEmpty && engine.selectedNewCount == 0 && engine.selectedDueCount(day: day) == 0))
                        }
                        Text("到期卡优先。记住后沿用专业课的跨天间隔；没记住则次日复习。本轮有足够其他卡时，再安排一次间隔补背。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("背诵自评单独保存，不计入原题的答对次数。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("背完后，用专业课中未作答的变式题核对能否独立运用。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("返回专业课做题") { dismiss() }.buttonStyle(.bordered)
                    }
                    }.disabled(!selectionIsApplied(engine))
                } else {
                    ContentUnavailableView("背诵卡暂不可用", systemImage: "rectangle.on.rectangle",
                        description: Text(store.error ?? "请先导入问答背诵卡课程包。"))
                }
                if let error = store.error { Text(error).foregroundStyle(.red) }
            }.padding(22).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("问答背诵")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导出") {
                    do { document = RecallExportDocument(data: try store.export()); exporting = true }
                    catch { store.error = error.localizedDescription }
                }.disabled(store.engine == nil)
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "\(subject.title)-问答背诵记录") {
            if case .failure(let error) = $0 { store.error = error.localizedDescription }
        }
        .task { store.act("refresh") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.act("refresh") } }
    }
    private func selectionIsApplied(_ engine:RecallEngine)->Bool {
        guard let planSelection else { return true }
        return engine.record.state.selection?.id == planSelection.id && engine.record.state.selection?.cardIDs == planSelection.cardIDs && (try? engine.deck.hash) == planSelection.deckSHA256
    }
    private func beginSelectedScope() {
        guard !store.blocked, let planSelection, let engine=store.engine else { return }
        guard (try? engine.deck.hash) == planSelection.deckSHA256 else {
            store.error="这部分范围与当前课程不一致，请返回课程重新打开。"
            return
        }
        if !selectionIsApplied(engine) {
            store.applySelection(planID:planSelection.id,cardIDs:planSelection.cardIDs,expectedDeckSHA256:planSelection.deckSHA256)
            guard !store.blocked, store.error == nil, let saved=store.engine, selectionIsApplied(saved) else { return }
        }
        guard let saved=store.engine, selectionIsApplied(saved) else { return }
        if saved.item == nil { store.act("start",newLimit:newLimit) }
    }
    @ViewBuilder private func answer(_ card: RecallCard) -> some View {
        Text(card.answer).font(.system(size: 25)).textSelection(.enabled)
        if let priority=teaching.cardPriorities?.first(where: { $0.cardID == card.id && $0.sourceCardDigest == card.professionalDigest }) { ProfessionalCardPriorityEvidence(value:priority) }
        ForEach((teaching.cardCorrections ?? []).filter { $0.cardID == card.id && $0.sourceCardDigest == card.professionalDigest }, id: \.cardID) { correction in
            VStack(alignment: .leading, spacing: 8) { Text("校勘说明").font(.headline); Text(correction.note); Text(correction.sourceRef).font(.caption).foregroundStyle(.secondary) }.padding().background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        if let detail = card.detail, !detail.isEmpty {
            DisclosureGroup("补充解释") { Text(detail).font(.body).textSelection(.enabled).padding(.top, 8) }
        }
    }
    private func dayText(_ day: Int) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日"
        return formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86_400))
    }
}

struct SupplementRecallGroupsView: View {
    let subject: ConceptSubject
    let bank: ConceptBank
    let teaching: ConceptTeaching

    var body: some View {
        List {
            if let syllabus = teaching.syllabus {
                ForEach(syllabus.branches.filter { branch in
                    teaching.recallGroups?.contains(where: { $0.branchID == branch.id }) == true
                }) { branch in
                    Section(branch.title) {
                        ForEach((teaching.recallGroups ?? []).filter { $0.branchID == branch.id }) { group in
                            NavigationLink {
                                RecallStudyView(subject: subject, bank: bank, teaching: teaching, supplementGroup: group)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(group.title)
                                    Text("\(group.recallCards.count) 张知识卡").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("补充知识卡")
    }
}

private struct RecallExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
