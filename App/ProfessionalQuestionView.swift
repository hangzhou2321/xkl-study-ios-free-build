import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Original supplied questions use their own objective record and longer review
/// schedule. The legacy teaching/card stores are reachable only as an archive.
struct ProfessionalQuestionView: View {
    let subject: ConceptSubject
    private let baseDirectory: URL?
    private let legacyStore: ConceptStore?
    private let startInPractice: Bool
    private let onStart: () -> Void
    private let onOverlayChanged: (Bool) -> Void
    @Binding private var practicing: Bool
    @Binding private var recalling: Bool
    @StateObject private var store: ProfessionalQuestionStore
    @State private var studying = false
    @State private var importing = false
    @State private var exporting = false
    @State private var showingAnswer = false
    @State private var showingLegacy = false
    @State private var showingArchive = false
    @State private var assetOverlay = false
    @State private var availableAssets = Set<String>()
    @State private var failedAssets = Set<String>()
    @State private var document = ProfessionalQuestionRecordDocument(data: Data())
    @State private var displayDate = Date()
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    #if DEBUG
    @Environment(\.professionalQuestionPreview) private var previewState
    @State private var previewLayoutReady = false
    @State private var previewScrollReady = false
    #endif

    init(subject: ConceptSubject, baseDirectory: URL? = nil, injectedStore: ProfessionalQuestionStore? = nil,
         legacyStore: ConceptStore? = nil,
         practicing: Binding<Bool> = .constant(false), recalling: Binding<Bool> = .constant(false),
         startInPractice: Bool = false, onStart: @escaping () -> Void = {},
         onOverlayChanged: @escaping (Bool) -> Void = { _ in }) {
        self.subject = subject; self.baseDirectory = baseDirectory
        self.legacyStore = legacyStore; self.startInPractice = startInPractice
        self.onStart = onStart; self.onOverlayChanged = onOverlayChanged
        _practicing = practicing; _recalling = recalling
        _studying = State(initialValue: startInPractice || practicing.wrappedValue)
        _store = StateObject(wrappedValue: injectedStore ?? ProfessionalQuestionStore(subject: subject, baseDirectory: baseDirectory))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Color.clear.frame(height: 0).id("question-top")
                        if let engine = store.engine {
                            if studying, let question = engine.currentQuestion,
                               let presentation = engine.presentation {
                                questionContent(engine, question, presentation)
                            } else if studying {
                                completion(engine)
                            } else {
                                home(engine)
                            }
                        } else {
                            emptyState
                        }
                        if let error = store.error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if store.blocked {
                            Text("记录保护已启用，当前作答与导入已暂停，原文件保留。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding(22).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: store.engine?.presentation?.id) { _, _ in
                    availableAssets.removeAll(); failedAssets.removeAll()
                    scroll.scrollTo("question-top", anchor: .top)
                }
                #if DEBUG
                .task(id: previewState.scrollTarget) {
                    if let target = previewState.scrollTarget {
                        previewScrollReady = false
                        await Task.yield()
                        scroll.scrollTo(target, anchor: .top)
                        await Task.yield()
                        previewScrollReady = true
                        reportPreviewAfterLayout()
                    }
                }
                #endif
            }
            .navigationTitle(subject.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if studying { Button("题库") { studying = false } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let staged = singleStagedFile {
                            Button("导入手机中已准备的原题", systemImage: "tray.and.arrow.down") { importStaged(staged) }
                                .disabled(store.blocked)
                        }
                        Button("导入原题题库", systemImage: "square.and.arrow.down") { importing = true }
                            .disabled(store.blocked)
                        Button("导出作答与调度记录", systemImage: "square.and.arrow.up") { exportRecords() }
                            .disabled(store.engine == nil)
                        if let package = store.package, package.questions.contains(where: { $0.isActive == false }) {
                            Button("范围外原题档案") { showingArchive = true }
                        }
                        if legacyStore != nil {
                            Button("旧课程资料与记录") { showingLegacy = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url):
                store.importContent(url)
                if store.error == nil { studying = false }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { store.error = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: subject.shortTitle + "-原题作答完整记录") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .sheet(isPresented: $showingAnswer) {
            NavigationStack {
                if let question = store.engine?.currentQuestion,
                   let presentation = store.engine?.presentation {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Label("已标记参考答案", systemImage: "eye")
                                .font(.headline).foregroundStyle(.orange)
                            Text("这次之后答对会保留“参考后答对”标记，不计作独立答对。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            answerContent(question, order: presentation.optionOrder)
                        }.padding(22).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
                    }.navigationTitle("所给参考答案").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("回到题目") { showingAnswer = false } }
                }
            }
        }
        .sheet(isPresented: $showingLegacy) {
            if let legacyStore {
                VStack(spacing: 0) {
                    HStack {
                        Text("旧课程资料与记录").font(.headline)
                        Spacer()
                        Button("关闭") { showingLegacy = false }
                    }.padding()
                    ConceptView(store: legacyStore, practicing: $practicing, recalling: $recalling,
                                onStart: onStart, onOverlayChanged: { _ in })
                }
            }
        }
        .sheet(isPresented: $showingArchive) {
            if let package = store.package {
                NavigationStack {
                    List(package.questions.filter { $0.isActive == false }) { question in
                        NavigationLink {
                            ProfessionalArchivedQuestionView(question: question, assetRoot: assetRoot)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(question.prompt).lineLimit(3)
                                Text(question.sourceLocation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.navigationTitle("范围外原题档案")
                        .toolbar { Button("关闭") { showingArchive = false } }
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            if startInPractice { store.start() }
        }
        .onChange(of: studying) { _, value in
            practicing = value; recalling = false
            #if DEBUG
            reportPreviewAfterLayout()
            #endif
        }
        .onChange(of: practicing) { _, value in
            if !showingLegacy { studying = value }
        }
        .onChange(of: showingLegacy) { _, value in
            if !value { practicing = studying; recalling = false }
        }
        .onChange(of: importing || exporting || showingAnswer || showingLegacy || showingArchive || assetOverlay || store.error != nil) { _, value in
            onOverlayChanged(value)
        }
        .onChange(of: scenePhase) { _, phase in
            displayDate = Date()
            if phase == .active, studying, store.engine?.presentation != nil { store.start() }
        }
        .onReceive(clock) { value in displayDate = value }
        .onDisappear { onOverlayChanged(false) }
        #if DEBUG
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        previewLayoutReady = geometry.size.width > 0 && geometry.size.height > 0
                        reportPreviewAfterLayout()
                    }
                    .onChange(of: geometry.size) { _, size in
                        previewLayoutReady = size.width > 0 && size.height > 0
                        reportPreviewAfterLayout()
                    }
            }.allowsHitTesting(false)
        }
        .onChange(of: store.engine?.presentation) { _, _ in reportPreviewAfterLayout() }
        .onChange(of: store.engine?.result) { _, _ in reportPreviewAfterLayout() }
        .onChange(of: availableAssets) { _, _ in reportPreviewAfterLayout() }
        .onChange(of: failedAssets) { _, _ in reportPreviewAfterLayout() }
        .onChange(of: store.blocked) { _, _ in reportPreviewAfterLayout() }
        #endif
    }

    private var assetRoot: URL {
        (baseDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("KnowledgeSources", isDirectory: true)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("基础与强化原题", systemImage: subject.symbol).font(.title2.bold())
            Text("直接做你提供的原题，提交后按所给答案判对错。答错隔天再测，答对至少隔3天；同题不会立即回锅。")
                .font(.subheadline).foregroundStyle(.secondary)
            if let staged = singleStagedFile {
                Button("导入手机中已准备的原题") { importStaged(staged) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.blocked)
                    .accessibilityIdentifier("professional-questions-import-staged")
                Text(staged.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                Button("选择其他题库文件") { importing = true }.buttonStyle(.bordered).disabled(store.blocked)
                    .accessibilityIdentifier("professional-questions-import")
            } else {
                Button("导入原题题库") { importing = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.blocked)
                    .accessibilityIdentifier("professional-questions-import")
            }
            Text("在“文件”中选择 ProfessionalQuestionBanks 目录内、本科目的 .xklqbank 文件。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("原英语、公共题库、数学及旧专业记录保留。新原题记录独立保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func home(_ engine: ProfessionalQuestionEngine) -> some View {
        let stats = engine.stats(on: displayDate)
        let questions = engine.package.questions.filter { $0.isActive != false }
        return VStack(alignment: .leading, spacing: 18) {
            Text("基础与强化原题").font(.title2.bold())
            Text(engine.package.title).font(.subheadline).foregroundStyle(.secondary)
            Text("基础 \(questions.filter { $0.book == "basic" }.count) 题 · 强化 \(questions.filter { $0.book == "reinforcement" }.count) 题")
                .font(.subheadline)
            ProgressView(value: Double(stats.answered), total: Double(max(1, stats.total)))
            Text("已作答 \(stats.answered) / \(stats.total) 题 · 到期 \(stats.due) · 未做 \(stats.unseen)")
                .font(.subheadline)
            if let question = engine.currentQuestion {
                Label("接着上次的题目", systemImage: "bookmark")
                    .font(.subheadline)
                Text(question.sourceLocation).font(.footnote).foregroundStyle(.secondary)
            }
            Button("继续做题") { continueStudy() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.blocked).accessibilityIdentifier("professional-questions-continue")
            Text("先处理到期复测，再按基础、强化顺序做新题。选答案后提交；参考过答案会单独标记。")
                .font(.subheadline).foregroundStyle(.secondary)
            scheduleNote
            if stats.archived > 0 {
                Button("另有 \(stats.archived) 题保留在范围外档案") { showingArchive = true }
                    .font(.footnote)
            }
        }
    }

    private var scheduleNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("专业原题采用较长复测间隔").font(.subheadline.weight(.semibold))
            Text("答错隔天再测；独立答对后按3、7、14、30天等间隔复测。参考后答对不增加独立答对次数。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("“独立答对”仅表示本次未在App内查看答案。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func completion(_ engine: ProfessionalQuestionEngine) -> some View {
        let stats = engine.stats(on: displayDate)
        return VStack(alignment: .leading, spacing: 18) {
            Label("这轮先到这里", systemImage: "checkmark.circle").font(.title2.bold())
            Text("今天可做的题已完成或暂缓。已答题不会在本轮立即重现，作答与断点已保存。")
            if let next = stats.nextDueDay ?? engine.nextDueDay {
                Text("下次到期：" + dueText(next)).font(.headline)
            }
            Text("累计正确 \(stats.correct) 次 · 错误 \(stats.wrong) 次 · 其中独立答对 \(stats.independentCorrect) 次")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("返回题库") { studying = false }.buttonStyle(.borderedProminent)
            scheduleNote
        }
    }

    private func questionContent(_ engine: ProfessionalQuestionEngine, _ question: ProfessionalObjectiveQuestion,
                                 _ presentation: ProfessionalQuestionSessionPresentation) -> some View {
        let result = engine.result
        let sourceAssets = assets(for: question)
        let stats = engine.stats(on: displayDate)
        return VStack(alignment: .leading, spacing: 18) {
            Text("已作答 \(stats.answered) / \(stats.total) 题 · 今日到期 \(stats.due)")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(question.book == "reinforcement" ? "强化原题" : "基础原题").font(.subheadline.weight(.semibold))
                Spacer()
                Text(question.type.title).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(question.chapter).font(.headline)
            Text(question.sourceLocation).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("professional-question-source")
            Text(question.prompt).font(.system(size: 24)).textSelection(.enabled)
                .accessibilityIdentifier("professional-question-prompt")
            if !sourceAssets.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(sourceAssets.enumerated()), id: \.offset) { index, asset in
                        ProfessionalQuestionAssetView(asset: asset, assetRoot: assetRoot,
                            onAvailability: { ok in
                                let key = assetKey(asset, index: index)
                                if ok { availableAssets.insert(key); failedAssets.remove(key) }
                                else { availableAssets.remove(key); failedAssets.insert(key) }
                            }, onOverlayChanged: { assetOverlay = $0 })
                            .id(presentation.id.uuidString + ":" + String(index))
                    }
                }
            }
            if !failedAssets.isEmpty {
                Label("题图未能打开，这道题先暂缓；补齐原图后再作答。", systemImage: "photo.badge.exclamationmark")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            if question.type == .multiple {
                Text("多选题：选齐全部正确项再提交。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(presentation.optionOrder, id: \.self) { id in
                if let option = question.options.first(where: { $0.id == id }) {
                    Button { store.choose(id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: indicator(id, presentation: presentation, result: result))
                            Text(optionLabel(id, order: presentation.optionOrder)).bold()
                            Text(option.text).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).font(.system(size: 22)).foregroundStyle(optionColor(id, result: result))
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).disabled(result != nil || store.blocked || !assetsReady(question))
                    .accessibilityIdentifier("professional-question-option-" + id)
                }
            }
            if presentation.helped && result == nil {
                Label("本题已参考答案，提交后如实保留帮助标记。", systemImage: "eye")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let result {
                VStack(alignment: .leading, spacing: 14) {
                    Label(result.isCorrect ? (result.helped ? "参考后答对" : "答对了") : "本次答错",
                          systemImage: result.isCorrect ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                        .font(.title3.bold()).foregroundStyle(result.isCorrect && !result.helped ? Color.green : Color.orange)
                        .accessibilityIdentifier("professional-question-result")
                    if result.helped {
                        Text("本次使用过参考答案，不计作独立答对。").font(.footnote).foregroundStyle(.secondary)
                    }
                    answerContent(question, order: presentation.optionOrder)
                    Text("下次复测：" + dueText(result.dueDay)).font(.subheadline.weight(.semibold))
                    Text("本轮不立即重做这道题。").font(.footnote).foregroundStyle(.secondary)
                }.padding(.top, 8).id("professional-question-result-top")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if studying, let engine = store.engine, let presentation = engine.presentation,
           let question = engine.currentQuestion {
            VStack(spacing: 10) {
                if engine.result != nil {
                    Button("下一题") { store.next(token: presentation.id) }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(store.blocked).accessibilityIdentifier("professional-question-next")
                } else {
                    HStack(spacing: 20) {
                        Button("暂时不做") { store.postpone(token: presentation.id) }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        Button("先看答案") { referenceAnswer(presentation) }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(store.blocked)
                    Button("提交答案") { store.submit(token: presentation.id) }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(store.blocked || presentation.selectedOptions.isEmpty || !assetsReady(question))
                        .accessibilityIdentifier("professional-question-submit")
                }
            }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 8)
                .frame(maxWidth: 740).frame(maxWidth: .infinity).background(.bar)
        }
    }

    private func answerContent(_ question: ProfessionalObjectiveQuestion, order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正确答案").font(.headline)
            ForEach(question.answer, id: \.self) { id in
                if let option = question.options.first(where: { $0.id == id }) {
                    Text(optionLabel(id, order: order) + "．" + option.text).font(.system(size: 23)).textSelection(.enabled)
                }
            }
            if let explanation = question.explanation, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("查看所给解析") { Text(explanation).font(.system(size: 21)).textSelection(.enabled) }
            } else {
                Text("本题目前仅附所给参考答案，未附独立解析。").font(.footnote).foregroundStyle(.secondary)
            }
            if let note = question.scopeNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("题源备注") { Text(note).font(.system(size: 21)).textSelection(.enabled) }
            }
            if !question.sourceAnswer.isEmpty {
                DisclosureGroup("原题答案标记") {
                    Text(question.sourceAnswer).font(.subheadline).textSelection(.enabled)
                    Text("原书标记按原选项顺序；上方答案已按当前显示顺序对应。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func continueStudy() {
        availableAssets.removeAll(); failedAssets.removeAll()
        store.start()
        guard store.error == nil, store.engine != nil else { return }
        studying = true; practicing = true; recalling = false; onStart()
    }
    private var singleStagedFile: URL? {
        let files = store.stagedFiles()
        return files.count == 1 ? files[0] : nil
    }
    private func importStaged(_ url: URL) {
        store.importContent(url)
        if store.error == nil { studying = false }
    }
    private func referenceAnswer(_ presentation: ProfessionalQuestionSessionPresentation) {
        store.help(token: presentation.id)
        if store.engine?.presentation?.helped == true { showingAnswer = true }
    }
    private func exportRecords() {
        do { document = ProfessionalQuestionRecordDocument(data: try store.exportRecords()); exporting = true }
        catch { store.error = error.localizedDescription }
    }
    private func assets(for question: ProfessionalObjectiveQuestion) -> [ProfessionalSourceFileAsset] {
        (question.sourceAsset.map { [$0] } ?? []) + (question.sourceAssets ?? [])
    }
    private func assetKey(_ asset: ProfessionalSourceFileAsset, index: Int) -> String { String(index) + ":" + asset.sha256 }
    private func assetsReady(_ question: ProfessionalObjectiveQuestion) -> Bool {
        assets(for: question).enumerated().allSatisfy { availableAssets.contains(assetKey($0.element, index: $0.offset)) }
    }
    private func optionLabel(_ id: String, order: [String]) -> String {
        guard let index = order.firstIndex(of: id), index < 26 else { return id }
        return String(UnicodeScalar(65 + index)!)
    }
    private func indicator(_ id: String, presentation: ProfessionalQuestionSessionPresentation, result: ProfessionalQuestionAttempt?) -> String {
        if let result {
            if result.correctOptions.contains(id) { return "checkmark.circle.fill" }
            return result.selectedOptions.contains(id) ? "xmark.circle.fill" : "circle"
        }
        return presentation.selectedOptions.contains(id) ? "checkmark.circle.fill" : "circle"
    }
    private func optionColor(_ id: String, result: ProfessionalQuestionAttempt?) -> Color {
        guard let result else { return .primary }
        if result.correctOptions.contains(id) { return .green }
        if result.selectedOptions.contains(id) { return .red }
        return .secondary
    }
    private func dueText(_ day: Int) -> String {
        let today = (try? ConceptCalendar.studyDay(displayDate)) ?? day
        let delta = day - today
        if delta == 1 { return "明天" }
        if delta > 1 { return "\(delta)天后" }
        if delta == 0 { return "今天" }
        return "已到期"
    }
    #if DEBUG
    private func reportPreviewAfterLayout() {
        Task { @MainActor in
            await Task.yield()
            guard previewLayoutReady, previewState.scrollTarget == nil || previewScrollReady else { return }
            let engine = store.engine
            let question = engine?.currentQuestion
            let presentation = engine?.presentation
            let result = engine?.result
            let mode = !studying ? (engine == nil ? "empty" : "home") :
                (question == nil || presentation == nil ? "completed" : (result == nil ? "question" : "result"))
            let ready = question.map { assetsReady($0) } ?? false
            previewState.didRender(.init(mode: mode, questionID: question?.id,
                selectedOptions: presentation?.selectedOptions ?? [], optionOrder: presentation?.optionOrder ?? [],
                isCorrect: result?.isCorrect, helped: presentation?.helped ?? false,
                assetsReady: ready, failedAssets: failedAssets.count,
                submitEnabled: studying && question != nil && presentation != nil && result == nil &&
                    !(presentation?.selectedOptions.isEmpty ?? true) && ready && !store.blocked))
        }
    }
    #endif
}

/// Loads required question figures before submission. Viewing the question's
/// own figure is part of answering, not an answer-help event.
private struct ProfessionalQuestionAssetView: View {
    let asset: ProfessionalSourceFileAsset
    let assetRoot: URL
    let onAvailability: (Bool) -> Void
    let onOverlayChanged: (Bool) -> Void
    @State private var image: CGImage?
    @State private var fullImage: CGImage?
    @State private var failed = false
    @State private var fullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel(asset.altText)
                Button("放大题图") { openImage() }.buttonStyle(.bordered)
            } else if failed {
                Text("本机题图不可读：请确认 KnowledgeSources 配套文件已传入。").font(.footnote).foregroundStyle(.orange)
            } else {
                ProgressView("正在打开题图…")
            }
        }
        .task(id: asset.sha256) {
            image = nil; failed = false
            do { image = try asset.croppedCGImage(assetRoot: assetRoot); onAvailability(true) }
            catch { failed = true; onAvailability(false) }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            NavigationStack {
                if let fullImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: fullImage, scale: 1)
                            .frame(width: CGFloat(fullImage.width), height: CGFloat(fullImage.height))
                            .accessibilityLabel(asset.altText)
                    }.navigationTitle("原题图 · 可横竖滑动").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("关闭") { fullScreen = false } }
                }
            }
        }
        .onChange(of: fullScreen) { _, value in onOverlayChanged(value) }
    }
    private func openImage() {
        do { fullImage = try asset.decodedCGImage(assetRoot: assetRoot); fullScreen = true }
        catch { failed = true; onAvailability(false) }
    }
}

private struct ProfessionalArchivedQuestionView: View {
    let question: ProfessionalObjectiveQuestion
    let assetRoot: URL
    @State private var showingAnswer = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(question.scopeNote ?? "原资料保留在档案，不进入当前两科主线。").font(.subheadline).foregroundStyle(.secondary)
                Text(question.sourceLocation).font(.footnote).foregroundStyle(.secondary)
                Text(question.prompt).font(.system(size: 24)).textSelection(.enabled)
                ForEach(question.options) { option in Text(option.id + "．" + option.text).font(.system(size: 22)) }
                ForEach(Array(((question.sourceAsset.map { [$0] } ?? []) + (question.sourceAssets ?? [])).enumerated()), id: \.offset) { _, asset in
                    ProfessionalQuestionAssetView(asset: asset, assetRoot: assetRoot, onAvailability: { _ in }, onOverlayChanged: { _ in })
                }
                DisclosureGroup("查看原资料所给答案", isExpanded: $showingAnswer) {
                    Text(question.sourceAnswer.isEmpty ? "此项未附可核对答案。" : question.sourceAnswer).textSelection(.enabled)
                    if let explanation = question.explanation { Text(explanation).textSelection(.enabled) }
                }
                Text("档案浏览不生成对错成绩或调度记录。").font(.footnote).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("原题档案").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfessionalQuestionRecordDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
