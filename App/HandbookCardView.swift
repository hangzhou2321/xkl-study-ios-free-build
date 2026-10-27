import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A book knowledge point is one self-assessed card. It never awards an
/// objective question-bank answer or changes another subject's scheduler.
struct HandbookCardView: View {
    let subject: ConceptSubject
    private let baseDirectory: URL?
    private let originalQuestionStore: ProfessionalQuestionStore?
    private let legacyStore: ConceptStore?
    private let onStart: () -> Void
    private let onOverlayChanged: (Bool) -> Void
    private let startInStudy: Bool
    @Binding private var externalStudying: Bool
    @StateObject private var store: HandbookCardStore
    @State private var studying = false
    @State private var importing = false
    @State private var exporting = false
    @State private var showingOutline = false
    @State private var showingSources = false
    @State private var showingAllSources = false
    @State private var showingOldQuestions = false
    @State private var document = HandbookCardRecordDocument(data: Data())
    @State private var displayDate = Date()
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    @State private var layoutReady = false
    @State private var scrollReady = false
    #endif

    init(subject: ConceptSubject = .computer, baseDirectory: URL? = nil,
         injectedStore: HandbookCardStore? = nil,
         originalQuestionStore: ProfessionalQuestionStore? = nil, legacyStore: ConceptStore? = nil,
         studying: Binding<Bool> = .constant(false), startInStudy: Bool = false,
         onStart: @escaping () -> Void = {}, onOverlayChanged: @escaping (Bool) -> Void = { _ in }) {
        self.subject = subject; self.baseDirectory = baseDirectory
        self.originalQuestionStore = originalQuestionStore; self.legacyStore = legacyStore
        self.onStart = onStart; self.onOverlayChanged = onOverlayChanged
        self.startInStudy = startInStudy
        _externalStudying = studying
        _studying = State(initialValue: startInStudy || studying.wrappedValue)
        _store = StateObject(wrappedValue: injectedStore ?? HandbookCardStore(subject: subject, baseDirectory: baseDirectory))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let engine = store.engine {
                            if studying, let card = engine.currentCard, let presentation = engine.presentation {
                                studyCard(engine, card, presentation)
                            } else if studying {
                                completion(engine)
                            } else {
                                home(engine)
                            }
                        } else {
                            emptyState
                        }
                        if let error = store.error {
                            Text(error).font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if store.blocked {
                            Label("记录已保护，原文件保留。请先导出记录再处理。", systemImage: "lock.shield")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .id("handbook-top")
                    .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
                    .frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: store.engine?.presentation?.id) { _, _ in
                    scroll.scrollTo("handbook-top", anchor: .top)
                }
                .onChange(of: store.engine?.presentation?.revealed) { _, _ in
                    scroll.scrollTo("handbook-top", anchor: .top)
                }
                #if DEBUG
                .task(id: preview.scrollTarget) {
                    if let target = preview.scrollTarget {
                        scrollReady = false
                        await Task.yield()
                        scroll.scrollTo(target, anchor: .top)
                        await Task.yield()
                        scrollReady = true
                        reportPreview()
                    }
                }
                #endif
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("宝典一 · \(subject.shortTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if studying { Button("卡片", systemImage: "chevron.left") { studying = false } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if store.package != nil { Button("章节目录", systemImage: "list.bullet") { showingOutline = true } }
                        if store.package != nil { Button("核对讲义原页", systemImage: "doc.text.magnifyingglass") { showingAllSources = true } }
                        if let staged = singleStagedFile {
                            Button("导入已准备的宝典卡", systemImage: "tray.and.arrow.down") { importStaged(staged) }
                                .disabled(store.blocked)
                        }
                        Button("选择卡片文件", systemImage: "square.and.arrow.down") { importing = true }.disabled(store.blocked)
                        Button("导出背卡记录", systemImage: "square.and.arrow.up") { exportRecords() }.disabled(store.engine == nil)
                        if originalQuestionStore != nil {
                            Button("原题与旧资料", systemImage: "books.vertical") { showingOldQuestions = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url): store.importContent(url); if store.error == nil { studying = false }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { store.error = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "宝典一-\(subject.shortTitle)-完整背卡记录") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .sheet(isPresented: $showingOutline) {
            if let package = store.package { outline(package) }
        }
        .sheet(isPresented: $showingSources) {
            if let package = store.package, let card = store.engine?.currentCard {
                HandbookSourcePagesView(pageNumbers: card.sourcePages, package: package, assetRoot: sourceRoot, title: "原文出处")
            }
        }
        .sheet(isPresented: $showingAllSources) {
            if let package = store.package {
                HandbookSourcePagesView(pageNumbers: (package.sourcePages ?? []).map(\.number).sorted(),
                                        package: package, assetRoot: sourceRoot, title: "核对讲义原页")
            }
        }
        .sheet(isPresented: $showingOldQuestions) {
            if let originalQuestionStore {
                VStack(spacing: 0) {
                    HStack {
                        Text("原题与旧资料").font(.headline)
                        Spacer()
                        Button("关闭") { showingOldQuestions = false }
                    }.padding()
                    ProfessionalQuestionView(subject: subject, injectedStore: originalQuestionStore,
                                             legacyStore: legacyStore, onOverlayChanged: { _ in })
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task { if startInStudy || studying { store.start() } }
        .onChange(of: externalStudying) { _, value in studying = value }
        .onChange(of: studying) { _, value in externalStudying = value; reportPreviewIfEnabled() }
        .onChange(of: importing || exporting || showingOutline || showingSources || showingAllSources || showingOldQuestions || store.error != nil) { _, value in
            onOverlayChanged(value)
        }
        .onChange(of: scenePhase) { _, phase in
            displayDate = Date()
            if phase == .active, studying, store.engine?.presentation != nil { store.start() }
        }
        .onReceive(clock) { date in displayDate = date }
        .onDisappear { onOverlayChanged(false) }
        #if DEBUG
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear {
                    layoutReady = geometry.size.width > 0 && geometry.size.height > 0
                    reportPreview()
                }.onChange(of: geometry.size) { _, size in
                    layoutReady = size.width > 0 && size.height > 0
                    reportPreview()
                }
            }.allowsHitTesting(false)
        }
        .onChange(of: store.engine?.presentation) { _, _ in reportPreview() }
        .onChange(of: store.engine?.record.ratings.count) { _, _ in reportPreview() }
        .onChange(of: store.blocked) { _, _ in reportPreview() }
        #endif
    }

    private var sourceRoot: URL {
        (baseDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("HandbookSources", isDirectory: true)
    }
    private var singleStagedFile: URL? { let files = store.stagedFiles(); return files.count == 1 ? files.first : nil }
    private func importStaged(_ url: URL) { store.importContent(url); if store.error == nil { studying = false } }
    private func exportRecords() {
        do { document = HandbookCardRecordDocument(data: try store.exportRecords()); exporting = true }
        catch { store.error = error.localizedDescription }
    }
    private func begin() {
        store.start()
        if store.engine != nil && store.error == nil && !store.blocked { studying = true; onStart() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 42)).foregroundStyle(.blue)
            Text("一张卡，一个知识点").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("先回忆，再翻答案。按原书顺序背，随时停下，下次接着来。")
                .font(.title3).foregroundStyle(.secondary).lineSpacing(6)
            if let staged = singleStagedFile {
                Button { importStaged(staged) } label: {
                    Label("导入已准备的宝典卡", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.blocked)
                    .accessibilityIdentifier("handbook-import-staged")
            } else {
                Button("选择宝典卡片文件") { importing = true }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.blocked)
                    .accessibilityIdentifier("handbook-import")
            }
            Text("背卡自评单独保存，不会变成原题做对的成绩。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 36)
    }

    private func home(_ engine: HandbookRecallEngine) -> some View {
        let stats = engine.stats(on: displayDate)
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("按知识点，把这一册背清楚").font(.system(.title, design: .rounded).weight(.bold))
                Text(verbatim: engine.package.title).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(stats.seen)").font(.system(size: 42, weight: .bold, design: .rounded)).foregroundStyle(.blue)
                    Text("/ \(stats.total) 张已开始").font(.title3).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ProgressView(value: Double(stats.seen), total: Double(max(1, stats.total))).tint(.blue)
                HStack(spacing: 24) {
                    countLabel("到期", stats.due)
                    countLabel("未背", stats.unseen)
                    countLabel("今日自评", stats.ratedToday)
                }
                Button(action: begin) {
                    Label("继续背卡", systemImage: "play.fill").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.blocked)
                    .accessibilityIdentifier("handbook-continue")
            }.padding(22).background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Button { showingOutline = true } label: {
                HStack { Label("按章节查看卡片", systemImage: "list.bullet.rectangle"); Spacer(); Image(systemName: "chevron.right") }
                    .font(.headline).padding(18).frame(maxWidth: .infinity)
            }.buttonStyle(.plain).background(.background, in: RoundedRectangle(cornerRadius: 18))
            Button { showingAllSources = true } label: {
                HStack {
                    Label("核对讲义原页", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.subheadline.weight(.medium)).padding(18).frame(maxWidth: .infinity)
            }.buttonStyle(.plain).background(.background, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("handbook-all-sources")
            scheduleNote
        }.padding(.top, 20)
    }
    private func countLabel(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(value)).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func studyCard(_ engine: HandbookRecallEngine, _ card: HandbookCard, _ p: HandbookCardPresentation) -> some View {
        let stats = engine.stats(on: displayDate)
        let index = engine.package.cards.firstIndex(where: { $0.id == card.id }).map { $0 + 1 }
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(verbatim: engine.package.chapter(for: card)?.title ?? "宝典知识点").font(.subheadline.weight(.medium))
                Spacer()
                Text(index.map { "\($0) / \(stats.total)" } ?? "复习中")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }.foregroundStyle(.secondary)
            ProgressView(value: Double(stats.ratedToday), total: Double(max(1, stats.ratedToday + stats.remainingToday)))
                .tint(.blue).accessibilityLabel("今日已自评\(stats.ratedToday)张")
            HandbookCardFace(card: card, revealed: p.revealed, showRecallCues: subject == .power)
                .id("handbook-card-face")
            if p.revealed {
                Button { showingSources = true } label: {
                    Label(sourceLabel(card), systemImage: "doc.text.magnifyingglass").font(.footnote)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("handbook-source")
                Text("这次只是背卡自评，不计入原题正确率。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                    Text(subject == .power ? "看提示回忆遮住的内容，再翻开核对。" : "先在心里回答，再翻开核对。")
                }.font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }.padding(.top, 10)
    }

    private func completion(_ engine: HandbookRecallEngine) -> some View {
        let stats = engine.stats(on: displayDate)
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.blue)
            Text("这一轮先到这里").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("当前可背的卡片已完成或暂缓。记录已经保存，刚自评过的卡不会立即回锅。")
                .font(.title3).lineSpacing(6)
            if let date = stats.nextDueAt ?? engine.nextDueAt {
                VStack(alignment: .leading, spacing: 7) {
                    Text("下次复习").font(.subheadline).foregroundStyle(.secondary)
                    Text(dueText(date)).font(.title2.weight(.semibold))
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
            }
            Button("返回卡片首页") { studying = false }.buttonStyle(.borderedProminent).controlSize(.large)
            scheduleNote
        }.padding(.top, 34)
    }

    private var scheduleNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拉开间隔，再检查能否想起来").font(.subheadline.weight(.semibold))
            Text("没记住至少隔24小时；记住后按3、7、14、30天等间隔再见。翻过答案不会自动记为掌握。")
                .font(.footnote).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(.horizontal, 3)
    }

    @ViewBuilder private var actions: some View {
        if studying, let engine = store.engine, let p = engine.presentation, engine.currentCard != nil {
            VStack(spacing: 10) {
                if p.revealed {
                    HStack(spacing: 12) {
                        Button { store.rate(remembered: false, token: p.id) } label: {
                            Label("没记住", systemImage: "arrow.uturn.backward")
                                .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                                .padding(.vertical, 6)
                        }.buttonStyle(.bordered).tint(.orange).accessibilityIdentifier("handbook-forgotten")
                        Button { store.rate(remembered: true, token: p.id) } label: {
                            Label("记住了", systemImage: "checkmark")
                                .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                                .padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("handbook-remembered")
                    }
                    Text(subject == .power ? "按整张卡遮住的内容自评，下一张会自动出现。" : "按现在能否回忆来选，下一张会自动出现。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button { store.reveal(token: p.id) } label: {
                        Label("翻答案", systemImage: "rectangle.on.rectangle")
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                            .padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("handbook-reveal")
                }
                Button { store.postpone(token: p.id) } label: {
                    Text("暂时不背 · 本轮稍后").font(.footnote).frame(minHeight: 44)
                }.accessibilityIdentifier("handbook-postpone")
            }.controlSize(.regular).disabled(store.blocked)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: .infinity).background(.bar)
        }
    }

    private func outline(_ package: HandbookCardPackage) -> some View {
        NavigationStack {
            List {
                ForEach(package.chapters, id: \.id) { chapter in
                    Section {
                        ForEach(package.cards.filter { package.chapter(for: $0)?.id == chapter.id }, id: \.id) { card in
                            NavigationLink {
                                ScrollView {
                                    HandbookCardFace(card: card, revealed: true)
                                        .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
                                    Text("目录预览不产生自评，也不改变复习日期。")
                                        .font(.footnote).foregroundStyle(.secondary).padding()
                                }.background(Color(uiColor: .systemGroupedBackground))
                                    .navigationTitle("知识点预览").navigationBarTitleDisplayMode(.inline)
                            } label: { Text(verbatim: card.title).padding(.vertical, 5) }
                        }
                    } header: {
                        Text(verbatim: chapter.title)
                    }
                }
            }.navigationTitle("章节目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { showingOutline = false } }
        }
    }
    private func sourceLabel(_ card: HandbookCard) -> String {
        let pages = card.sourcePages.map(String.init).joined(separator: "、")
        return "原文 · PDF第\(pages)页"
    }
    private func dueText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current; formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date) + "后"
    }
    private func reportPreviewIfEnabled() {
        #if DEBUG
        reportPreview()
        #endif
    }
    #if DEBUG
    private func reportPreview() {
        Task { @MainActor in
            await Task.yield()
            guard layoutReady, preview.scrollTarget == nil || scrollReady else { return }
            let engine = store.engine
            let card = engine?.currentCard
            let p = engine?.presentation
            let mode = !studying ? (engine == nil ? "empty" : "home") : (card == nil || p == nil ? "completed" : (p!.revealed ? "back" : "front"))
            let filesPresent = card.map { current in
                current.sourcePages.allSatisfy { number in
                    guard let a = engine?.package.sourcePages?.first(where: { $0.number == number })?.asset else { return false }
                    return FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent(a.sha256 + (a.mimeType == "image/jpeg" ? ".jpg" : ".png")).path)
                }
            } ?? false
            preview.didRender(.init(mode: mode, cardID: card?.id, revealed: p?.revealed ?? false,
                ratingCount: engine?.record.ratings.count ?? 0, ratingEnabled: studying && p?.revealed == true && !store.blocked,
                sourceFilesPresent: filesPresent,
                recallCueMode: subject == .power && mode == "front"))
        }
    }
    #endif
}

private struct HandbookCardFace: View {
    let card: HandbookCard
    let revealed: Bool
    var showRecallCues = false
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 24.0
    @ScaledMetric(relativeTo: .title2) private var promptSize: CGFloat = 21.0
    @ScaledMetric(relativeTo: .title2) private var summarySize: CGFloat = 20.0
    @ScaledMetric(relativeTo: .body) private var exampleSize: CGFloat = 18.0
    @ScaledMetric(relativeTo: .body) private var stepSize: CGFloat = 18.0
    @ScaledMetric(relativeTo: .body) private var noteSize: CGFloat = 16.0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(revealed ? "核对答案" : "主动回忆").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
                Image(systemName: revealed ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                    .foregroundStyle(.blue.opacity(0.7))
            }
            Text(verbatim: card.title).font(.system(size: titleSize, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("handbook-card-title")
            if !revealed && showRecallCues {
                Text("冒号前作提示，后面遮住；翻一次核对整张。")
                    .font(.footnote).foregroundStyle(.secondary)
                if card.answerSummary != "讲义原文" {
                    HandbookCueTextView(source: card.answerSummary, fontSize: summarySize)
                }
                ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, block in
                    if !block.collapsed { HandbookCardBlockView(block: block, masked: true) }
                }
            } else if !revealed {
                Text(verbatim: card.prompt).font(.system(size: promptSize)).lineSpacing(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("handbook-card-prompt")
                    .padding(.top, 5).padding(.bottom, 34)
            } else {
                Text(verbatim: card.answerSummary).font(.system(size: summarySize, weight: .medium)).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("handbook-card-summary")
                ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, block in
                    if block.collapsed {
                        DisclosureGroup {
                            HandbookCardBlockView(block: block).padding(.top, 12)
                        } label: { Text(verbatim: block.title.isEmpty ? "展开补充" : block.title).font(.headline) }
                    } else { HandbookCardBlockView(block: block) }
                }
                if !card.examples.isEmpty {
                    DisclosureGroup("用原例再理解一次") {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(card.examples.enumerated()), id: \.offset) { _, example in
                                VStack(alignment: .leading, spacing: 11) {
                                    if !example.title.isEmpty { Text(verbatim: example.title).font(.headline) }
                                    Text(verbatim: example.prompt).font(.system(size: exampleSize)).lineSpacing(5)
                                    ForEach(Array(example.steps.enumerated()), id: \.offset) { index, step in
                                        HStack(alignment: .top, spacing: 9) {
                                            Text(String(index + 1)).font(.caption.bold()).foregroundStyle(.blue)
                                                .frame(width: 22, height: 22).background(.blue.opacity(0.09), in: Circle())
                                            Text(verbatim: step).font(.system(size: stepSize)).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Text(verbatim: example.answer).font(.system(size: exampleSize, weight: .medium))
                                    Text("PDF第\(example.sourcePage)页").font(.caption).foregroundStyle(.secondary)
                                    if let note = example.sourceIssueNote, !note.isEmpty {
                                        Text(verbatim: note).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.padding(.top, 14)
                    }.font(.headline)
                }
                if !card.sourceNotes.isEmpty {
                    DisclosureGroup("原书校注") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(card.sourceNotes.enumerated()), id: \.offset) { _, note in
                                Text(verbatim: note).font(.system(size: noteSize)).foregroundStyle(.secondary).lineSpacing(5)
                            }
                        }.padding(.top, 10)
                    }.font(.headline)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.045), lineWidth: 1) }
    }
}

private struct HandbookCardBlockView: View {
    let block: HandbookCard.Block
    var masked = false
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 19.0
    @ScaledMetric(relativeTo: .body) private var keySize: CGFloat = 17.0
    @ScaledMetric(relativeTo: .body) private var keyWidth: CGFloat = 72.0
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !block.title.isEmpty && !block.collapsed { Text(verbatim: block.title).font(.headline).foregroundStyle(.secondary) }
            if block.kind == "keyValues" || block.kind == "table" { table }
            else if block.kind == "bullets" || block.kind == "steps" {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 11) {
                        Text(block.kind == "steps" ? String(index + 1) + "." : "•")
                            .font(.system(size: keySize, weight: .semibold)).foregroundStyle(.blue).frame(minWidth: 15, alignment: .leading)
                        if masked { HandbookCueTextView(source: item, fontSize: bodySize) }
                        else { Text(verbatim: item).font(.system(size: bodySize)).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } else if let text = block.text {
                if masked { HandbookCueTextView(source: text, fontSize: bodySize) }
                else { Text(verbatim: text).font(.system(size: bodySize)).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var table: some View {
        VStack(spacing: 0) {
            if block.kind == "table", let columns = block.columns, columns.contains(where: { !$0.isEmpty }), !dynamicType.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                        Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: columns.count == 2 && index == 0 ? keyWidth : nil, alignment: .leading)
                            .frame(maxWidth: columns.count == 2 && index == 0 ? nil : .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10).background(Color.blue.opacity(0.07))
            }
            ForEach(Array((block.rows ?? []).enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.horizontal, 14) }
                rowView(row).padding(.horizontal, 14).padding(.vertical, 14)
            }
        }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder private func rowView(_ row: [String]) -> some View {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                    VStack(alignment: .leading, spacing: 4) {
                        if block.kind == "table", let columns = block.columns, column < columns.count {
                            Text(verbatim: columns[column]).font(.caption).foregroundStyle(.secondary)
                        }
                        cellText(cell, column: column)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 13) {
                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                    cellText(cell, column: column)
                        .frame(width: row.count == 2 && column == 0 ? keyWidth : nil, alignment: .leading)
                        .frame(maxWidth: row.count == 2 && column == 0 ? nil : .infinity, alignment: .leading)
                }
            }
        }
    }
    @ViewBuilder private func cellText(_ cell: String, column: Int) -> some View {
        if masked, HandbookRecallCue.cell(cell, column: column) == .hidden {
            HandbookAnswerMask()
        } else {
            Text(verbatim: cell).font(.system(size: column == 0 ? keySize : bodySize, weight: column == 0 ? .semibold : .regular))
                .foregroundStyle(column == 0 ? Color.blue : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HandbookCueTextView: View {
    let source: String
    let fontSize: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(HandbookRecallCue.lines(source).enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 6) {
                    if !line.prefix.isEmpty {
                        Text(verbatim: line.prefix).font(.system(size: fontSize)).lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if line.hidesAnswer { HandbookAnswerMask() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HandbookAnswerMask: View {
    var body: some View {
        Text("已遮住").font(.caption).foregroundStyle(.secondary)
            .frame(minWidth: 48, maxWidth: 104, minHeight: 30)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel("答案已遮住，使用底部翻答案统一查看")
    }
}

private struct HandbookSourcePagesView: View {
    let pageNumbers: [Int]
    let package: HandbookCardPackage
    let assetRoot: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text("按PDF物理页号核对原文。查阅原页不产生自评，也不改变复习日期。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if pageNumbers.isEmpty {
                        Text("这个卡包暂未附上原页图片；仍可继续背文字卡。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(pageNumbers, id: \.self) { number in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("PDF第\(number)页").font(.headline)
                            if let page = package.sourcePages?.first(where: { $0.number == number }) {
                                HandbookOriginalPageImage(asset: page.asset, root: assetRoot)
                            } else {
                                Text("可对照原书此页。没有附图也不影响翻卡和自评。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(20)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

private struct HandbookOriginalPageImage: View {
    let asset: ProfessionalSourceFileAsset
    let root: URL
    @State private var image: CGImage?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: 1).accessibilityLabel(asset.altText)
                        .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                }.frame(height: 470).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("可横竖滑动查看原页。").font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else { ProgressView("打开原页…") }
        }.task(id: asset.sha256) {
            do { image = try asset.decodedCGImage(assetRoot: root) }
            catch { self.error = "这页原图尚未附上；仍可继续使用完整文字卡。" }
        }
    }
}

private struct HandbookCardRecordDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
