import SwiftUI

struct ConceptKnowledgeMapView: View {
    @ObservedObject var store: ConceptStore
    var open: (String) -> Void
    var resume: (ConceptGuidancePosition) -> Void
    private var concepts: [StudyConcept] { store.engine?.activeConcepts ?? [] }
    private var sections: [String] {
        concepts.reduce(into: [String]()) { result, concept in
            if !result.contains(concept.section) { result.append(concept.section) }
        }
    }
    private var unfinished: [ConceptGuidancePosition] {
        (store.guidance?.positions.values.map { $0 } ?? [])
            .filter { position in !position.completed && concepts.contains { $0.id == position.conceptID } }
            .sorted { $0.key < $1.key }
    }
    private func currentLesson(_ conceptID: String) -> ConceptLesson? {
        store.teaching?.lessons.first { $0.conceptID == conceptID }
    }
    private func hasDiagram(_ lesson: ConceptLesson?) -> Bool {
        lesson?.guide?.steps.contains { $0.diagram != nil } == true
    }
    private func isPreviousVersion(_ position: ConceptGuidancePosition) -> Bool {
        store.guidanceLesson(for: position) != currentLesson(position.conceptID)
    }
    private var suggestedStart: [StudyConcept] {
        let ids = store.subject == .computer
            ? ["h-components", "h-memory", "h-binary"]
            : ["p-grid-structure", "p-equipment-role", "p-power"]
        return ids.compactMap { id in concepts.first { $0.id == id && currentLesson(id)?.guide != nil } }
    }
    var body: some View {
        List {
            if let tree = store.teaching?.syllabus {
                Section {
                    NavigationLink {
                        ConceptSyllabusTreeView(tree: tree, store: store, openGuide: open)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("按27考纲找知识和原题", systemImage: "list.bullet.indent")
                                .font(.headline)
                            Text("看考点关系、六套出现套数和资料空缺")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }
            Section("每次只学清一个考点") {
                Text("看图 → 逐步看懂 → 合上回忆 → 换题检验")
                    .font(.headline)
                Text(store.subject == .computer
                     ? "先看硬件和数据怎么走，再学软件、网络、安全与前沿知识。每次读完一篇，自己说出规则，再回正式练习用不同问法检验。"
                     : "先看电从哪里来、经过哪些设备，再学功率、交流与三相，最后看系统怎么运行。先说清图中的关系，再用正式题目检验。")
                    .font(.subheadline)
                Text("按章节看知识之间的关系。讲解中的小检查和回忆核对只留下学习记录；正式练习仍用原题库、原难度和原复习安排。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !suggestedStart.isEmpty {
                Section("不知道从哪开始，就按这个顺序") {
                    ForEach(Array(suggestedStart.enumerated()), id: \.element.id) { index, concept in
                        Button { open(concept.id) } label: {
                            Label("\(index + 1). " + concept.title, systemImage: "play.circle")
                        }.disabled(store.blocked)
                    }
                    Text("一次学清一篇即可；已经会的可以直接到下面选下一篇。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !unfinished.isEmpty {
                Section("继续未读完的讲解") {
                    ForEach(unfinished, id: \.key) { position in
                        VStack(alignment: .leading, spacing: 10) {
                            Button { resume(position) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.guidanceLesson(for: position)?.title ?? "讲解断点")
                                    Text((isPreviousVersion(position) ? "继续原版讲解 · " : "继续上次 · ") +
                                         (store.guidanceLesson(for: position)?.guide?.steps.first { $0.id == position.stepID }?.title ?? "回忆核对"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(store.blocked)
                            if isPreviousVersion(position), hasDiagram(currentLesson(position.conceptID)) {
                                Button("查看新版图解", systemImage: "rectangle.and.pencil.and.ellipsis") {
                                    open(position.conceptID)
                                }.font(.subheadline).disabled(store.blocked)
                                Text("原版阅读位置仍保留，新版从自己的阅读位置开始。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(concepts.filter { $0.section == section }) { concept in
                        let lesson = store.teaching?.lessons.first { $0.conceptID == concept.id }
                        if let guide = lesson?.guide {
                            VStack(alignment: .leading, spacing: 8) {
                                Button { open(concept.id) } label: {
                                    Label(concept.title, systemImage: hasDiagram(lesson) ? "photo.on.rectangle.angled" : "point.topleft.down.to.point.bottomright.curvepath")
                                }.disabled(store.blocked)
                                if hasDiagram(lesson) {
                                    Text("图解讲解 · 点开按步骤学")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(guide.goal).font(.footnote).foregroundStyle(.secondary)
                                if !guide.relatedConceptIDs.isEmpty {
                                    Text("联系到").font(.caption).foregroundStyle(.secondary)
                                    ForEach(guide.relatedConceptIDs, id: \.self) { id in
                                        if let related = concepts.first(where: { $0.id == id }) {
                                            Button("↳ " + related.title) { open(id) }
                                                .font(.footnote).disabled(store.blocked)
                                        }
                                    }
                                }
                            }.padding(.vertical, 5)
                        } else if let lesson {
                            DisclosureGroup(concept.title) {
                                Text(lesson.story); Text(lesson.keyIdea)
                                Text(lesson.workedExample); Text(lesson.commonTrap)
                                Text("该课程目前提供整篇讲解；导入新版课程后可用分步讲解。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Text(concept.title).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .navigationTitle("知识地图与讲解目录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConceptGuidanceView: View {
    @ObservedObject var store: ConceptStore
    var close: () -> Void
    var returnToPractice: Bool
    @State private var actionLocked = false
    var body: some View {
        NavigationStack {
            if let position = store.guidance?.active, let lesson = store.guidanceLesson, let guide = lesson.guide {
                let index = guide.steps.firstIndex { $0.id == position.stepID } ?? guide.steps.count
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Color.clear.frame(height: 1).id("guidance-top")
                            Text(guide.goal).font(.subheadline).foregroundStyle(.secondary)
                            Text(index < guide.steps.count ? "第 \(index + 1) / \(guide.steps.count) 步" : "回忆核对")
                                .font(.caption).foregroundStyle(.secondary)
                            if index < guide.steps.count {
                                step(guide.steps[index], position: position)
                            } else {
                                Text("先自己说，再点开核对").font(.title2.bold())
                                Text("不用一次背完整篇。能否应用还需要回到正式题目检验。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                ForEach(guide.remember.indices, id: \.self) { item in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(guide.remember[item].prompt).font(.headline)
                                        if position.revealedRecall.contains(item) {
                                            Text(guide.remember[item].answer).textSelection(.enabled)
                                        } else {
                                            Button("我先回忆，再展开核对") {
                                                perform { store.guidanceAction("remember", recallIndex: item) }
                                            }.buttonStyle(.bordered)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                }
                                Text("读完只记录“读过”，不会标记已掌握。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if !guide.relatedConceptIDs.isEmpty {
                                Divider()
                                DisclosureGroup("相关考点（需要时再看）") {
                                    ForEach(guide.relatedConceptIDs, id: \.self) { id in
                                        if let related = store.engine?.activeConcepts.first(where: { $0.id == id }),
                                           store.teaching?.lessons.first(where: { $0.conceptID == id })?.guide != nil {
                                            Button(related.title, systemImage: "arrow.turn.down.right") {
                                                perform { store.openGuidance(conceptID: id) }
                                            }.padding(.vertical, 8)
                                        }
                                    }
                                    Text("跳转会保留本篇阅读位置，可在目录继续。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                    }
                    .onChange(of: position.key + position.stepID) { _, _ in proxy.scrollTo("guidance-top", anchor: .top) }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 16) {
                        Button("上一步") {
                            perform { store.guidanceAction("step", stepID: guide.steps[index - 1].id) }
                        }.disabled(index == 0)
                        Spacer()
                        if index < guide.steps.count {
                            Button(index == guide.steps.count - 1 ? "去回忆核对" : "下一步") {
                                let next = index + 1 < guide.steps.count ? guide.steps[index + 1].id : ConceptGuide.recallStepID
                                perform { store.guidanceAction("step", stepID: next) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(guide.steps[index].check != nil && position.choices[position.stepID] == nil)
                        } else {
                            Button(returnToPractice ? "读完，回到原题" : "读完，返回目录") {
                                perform {
                                    store.guidanceAction("finish")
                                    if !store.blocked && store.error == nil { close() }
                                }
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding().background(.bar).disabled(store.blocked || actionLocked)
                }
                .navigationTitle(lesson.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(returnToPractice ? "先回原题" : "暂时离开") { close() }
                    }
                }
                .disabled(actionLocked)
            } else {
                ContentUnavailableView("讲解位置已保存", systemImage: "bookmark", description: Text("返回目录后可继续。"))
                    .toolbar { Button("关闭") { close() } }
            }
        }
        .alert("讲解记录已暂停", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func step(_ step: ConceptGuide.Step, position: ConceptGuidancePosition) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(step.title).font(.title2.bold())
            if let diagram = step.diagram {
                ConceptDiagramView(diagram: diagram).id(position.key + ":" + step.id)
            }
            Text(step.body).font(.body).textSelection(.enabled)
            if let visual = step.visual {
                if step.diagram != nil {
                    DisclosureGroup("文字对照") { relation(visual).padding(.top, 8) }
                } else { relation(visual) }
            }
            if let check = step.check {
                Divider()
                Text("想一想").font(.headline)
                Text(check.prompt)
                ForEach(check.options) { option in
                    Button {
                        perform { store.guidanceAction("answer", choiceID: option.id) }
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: position.choices[step.id] == option.id ? "checkmark.circle.fill" : "circle")
                            Text(option.text).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(store.blocked || position.choices[step.id] == option.id)
                }
                if let choice = position.choices[step.id], let selected = check.options.first(where: { $0.id == choice }) {
                    Label(choice == check.answerID ? "这一步判断正确" : "这里有个需要分清的地方",
                          systemImage: choice == check.answerID ? "checkmark.circle" : "arrow.uturn.backward.circle")
                        .font(.headline)
                    Text(selected.feedback).textSelection(.enabled)
                    if choice != check.answerID {
                        Button("回看关键一步", systemImage: "arrow.uturn.backward") {
                            perform { store.guidanceAction("step", stepID: check.repairStepID) }
                        }.buttonStyle(.bordered).disabled(store.blocked)
                    }
                } else {
                    Text("选一个判断，看看为什么。小检查不会记为正式成绩。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func relation(_ visual: ConceptGuide.Visual) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(visual.kind == "flow" ? "顺着关系看" : "放在一起比较",
                  systemImage: visual.kind == "flow" ? "arrow.down" : "rectangle.split.2x1")
                .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(visual.items.indices, id: \.self) { index in
                if index > 0 && visual.kind == "flow" {
                    Image(systemName: "arrow.down").frame(maxWidth: .infinity).foregroundStyle(.tint)
                }
                HStack(alignment: .top, spacing: 12) {
                    if visual.kind == "compare" { Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(visual.items[index].label).font(.headline)
                        Text(visual.items[index].detail).font(.subheadline)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }.accessibilityElement(children: .contain)
    }
    private func perform(_ action: () -> Void) {
        guard !actionLocked, !store.blocked else { return }
        actionLocked = true; action()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            actionLocked = false
        }
    }
}
