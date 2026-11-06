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
    @Binding private var fullScreenEnabled: Bool
    @StateObject private var store: HandbookWordStore
    @StateObject private var highlightStore: HandbookHighlightStore
    @StateObject private var relatedQuestionStore: HandbookRelatedQuestionStore
    @State private var studying = false
    @State private var importing = false
    @State private var recommendedStagedFile: URL?
    @State private var exporting = false
    @State private var showingOutline = false
    @State private var showingSources = false
    @State private var showingAllSources = false
    @State private var showingOldQuestions = false
    @State private var highlightTarget: HandbookHighlightTarget?
    @State private var outlineHighlightTarget: HandbookHighlightTarget?
    @State private var relatedQuestionTarget: HandbookCard?
    @State private var document = HandbookCardRecordDocument(data: Data())
    @State private var displayDate = Date()
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    @State private var layoutReady = false
    @State private var scrollReady = false
    @State private var previewStudyStarted = false
    #endif

    init(subject: ConceptSubject = .computer, baseDirectory: URL? = nil,
         injectedStore: HandbookWordStore? = nil,
         originalQuestionStore: ProfessionalQuestionStore? = nil, legacyStore: ConceptStore? = nil,
         studying: Binding<Bool> = .constant(false), startInStudy: Bool = false,
         fullScreenEnabled: Binding<Bool> = .constant(false),
         onStart: @escaping () -> Void = {}, onOverlayChanged: @escaping (Bool) -> Void = { _ in }) {
        self.subject = subject; self.baseDirectory = baseDirectory
        self.originalQuestionStore = originalQuestionStore; self.legacyStore = legacyStore
        self.onStart = onStart; self.onOverlayChanged = onOverlayChanged
        self.startInStudy = startInStudy
        _externalStudying = studying
        _fullScreenEnabled = fullScreenEnabled
        _studying = State(initialValue: startInStudy || studying.wrappedValue)
        _store = StateObject(wrappedValue: injectedStore ?? HandbookWordStore(subject: subject, baseDirectory: baseDirectory))
        _highlightStore = StateObject(wrappedValue: HandbookHighlightStore(subject: subject,
            baseDirectory: injectedStore?.annotationBaseDirectory ?? baseDirectory))
        _relatedQuestionStore = StateObject(wrappedValue: HandbookRelatedQuestionStore(subject: subject,
            baseDirectory: injectedStore?.annotationBaseDirectory ?? baseDirectory))
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
                    .padding(.horizontal, fullScreenActive ? 12 : 20)
                    .padding(.top, fullScreenActive ? 0 : 10).padding(.bottom, 24)
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
            .toolbar(fullScreenActive ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if studying { Button("卡片", systemImage: "chevron.left") { studying = false } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if studying {
                        Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right") { fullScreenEnabled = true }
                            .accessibilityIdentifier("handbook-enter-fullscreen")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if studying, let engine = store.engine, let presentation = engine.presentation,
                       presentation.revealed, let card = engine.currentCard {
                        Button("标红", systemImage: "highlighter") {
                            highlightTarget = .init(card: card, guide: engine.currentMemoryGuide)
                        }.accessibilityIdentifier("handbook-highlight-open")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if store.package != nil { Button("章节目录", systemImage: "list.bullet") { showingOutline = true } }
                        if store.package != nil { Button("核对讲义原页", systemImage: "doc.text.magnifyingglass") { showingAllSources = true } }
                        if let staged = recommendedStagedFile {
                            Button("导入已准备的宝典卡", systemImage: "tray.and.arrow.down") { importStaged(staged) }
                                .disabled(store.blocked)
                        }
                        Button("选择卡片文件", systemImage: "square.and.arrow.down") { importing = true }.disabled(store.blocked)
                        Button("导出背卡记录", systemImage: "square.and.arrow.up") { exportRecords() }.disabled(store.engine == nil)
                        if !studying && store.canRollbackToLegacy {
                            Button("撤回本次算法切换", systemImage: "arrow.uturn.backward") { store.rollbackToLegacy() }
                                .accessibilityIdentifier("handbook-rollback-scheduler")
                        }
                        if !studying && store.canEnableDualFSRS {
                            Button("重新启用双 FSRS", systemImage: "arrow.triangle.2.circlepath") { store.reenableDualFSRS() }
                                .accessibilityIdentifier("handbook-reenable-fsrs")
                        }
                        if originalQuestionStore != nil {
                            Button("原题与旧资料", systemImage: "books.vertical") { showingOldQuestions = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if fullScreenActive { fullScreenBar }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url): store.importContent(url); recommendedStagedFile = store.recommendedStagedFile()
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
                HandbookSourcePagesView(groups: handbookSourceGroups(package, card: card), assetRoot: sourceRoot, title: "原文出处")
            }
        }
        .sheet(isPresented: $showingAllSources) {
            if let package = store.package {
                HandbookSourcePagesView(groups: handbookSourceGroups(package), assetRoot: sourceRoot, title: "核对讲义原页")
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
        .sheet(item: $highlightTarget) { target in
            HandbookHighlightEditor(target: target, store: highlightStore)
        }
        .fullScreenCover(item: $relatedQuestionTarget) { card in
            if let package = store.package {
                HandbookRelatedQuestionPage(card: card, questions: package.questions(for: card),
                    assetRoot: sourceRoot, store: relatedQuestionStore,
                    cardAnswerWasVisible: store.engine?.presentation?.revealed ?? false)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            recommendedStagedFile = store.recommendedStagedFile()
            if startInStudy || studying { store.start() }
            #if DEBUG
            previewStudyStarted = true
            if preview.openHighlightEditor, let engine = store.engine, let presentation = engine.presentation,
               presentation.revealed, let card = engine.currentCard {
                highlightTarget = .init(card: card, guide: engine.currentMemoryGuide)
            }
            if preview.openRelatedQuestion, let engine = store.engine, let card = engine.currentCard,
               !engine.package.questions(for: card).isEmpty { relatedQuestionTarget = card }
            reportPreview()
            #endif
        }
        .onChange(of: externalStudying) { _, value in studying = value }
        .onChange(of: studying) { _, value in externalStudying = value; reportPreviewIfEnabled() }
        .onChange(of: fullScreenEnabled) { _, _ in reportPreviewIfEnabled() }
        .onChange(of: importing || exporting || showingOutline || showingSources || showingAllSources || showingOldQuestions || highlightTarget != nil || relatedQuestionTarget != nil || store.error != nil) { _, value in
            onOverlayChanged(value)
        }
        .onChange(of: scenePhase) { _, phase in
            displayDate = Date()
            if phase == .active { recommendedStagedFile = store.recommendedStagedFile() }
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
        .onChange(of: store.engine.map { $0.stats(on: displayDate).remembered + $0.stats(on: displayDate).forgotten }) { _, _ in reportPreview() }
        .onChange(of: store.blocked) { _, _ in reportPreview() }
        .onChange(of: preview.sourceSheet) { _, route in
            showingSources = route == "card"
            showingAllSources = route == "all"
        }
        .onChange(of: showingSources || showingAllSources) { _, _ in reportPreview() }
        #endif
    }

    private var sourceRoot: URL {
        (baseDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("HandbookSources", isDirectory: true)
    }
    private var fullScreenActive: Bool { studying && fullScreenEnabled }
    private var fullScreenBar: some View {
        HStack {
            Button { fullScreenEnabled = false } label: {
                Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.footnote).frame(minHeight: 44)
            }.accessibilityIdentifier("handbook-exit-fullscreen")
            Spacer()
            if let engine = store.engine, let presentation = engine.presentation,
               presentation.revealed, let card = engine.currentCard {
                Button { highlightTarget = .init(card: card, guide: engine.currentMemoryGuide) } label: {
                    Label("标红", systemImage: "highlighter").font(.footnote).frame(minHeight: 44)
                }.accessibilityIdentifier("handbook-highlight-open")
            }
            Menu {
                Button("返回卡片首页", systemImage: "rectangle.on.rectangle") { studying = false }
                Button("章节目录", systemImage: "list.bullet") { showingOutline = true }
                Button("核对本卡原页", systemImage: "doc.text.magnifyingglass") { showingSources = true }
                Button("导出背卡记录", systemImage: "square.and.arrow.up") { exportRecords() }
            } label: {
                Image(systemName: "ellipsis").font(.body).frame(width: 44, height: 44)
            }.accessibilityLabel("卡片选项")
        }.padding(.horizontal, 16)
            .background(Color(uiColor: .systemGroupedBackground))
    }
    private func importStaged(_ url: URL) {
        let recommendation = store.recommendedStagedFile()
        recommendedStagedFile = recommendation
        guard recommendation == url else { return }
        store.importContent(url)
        recommendedStagedFile = store.recommendedStagedFile()
    }
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
            if let staged = recommendedStagedFile {
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

    private func home(_ engine: HandbookWordEngine) -> some View {
        let stats = engine.stats(on: displayDate)
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("按知识点，把这一册背清楚").font(.system(.title, design: .rounded).weight(.bold))
                Text(verbatim: handbookDisplayText(engine.package.title)).font(.subheadline).foregroundStyle(.secondary)
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
                if engine.presentation == nil && engine.retryCount(on: displayDate) > 0 {
                    Button { store.startRetry(); if store.error == nil, store.engine?.presentation != nil { studying = true; onStart() } } label: {
                        Label("可选补练没记住的卡（\(engine.retryCount(on: displayDate))）", systemImage: "arrow.clockwise")
                    }.accessibilityIdentifier("handbook-retry-optional").disabled(store.blocked)
                }
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

    private func studyCard(_ engine: HandbookWordEngine, _ card: HandbookCard, _ p: HandbookCardPresentation) -> some View {
        let stats = engine.stats(on: displayDate)
        let index = engine.activePosition(of: card.id)
        return VStack(alignment: .leading, spacing: 18) {
            if !fullScreenActive { HStack {
                Text(verbatim: handbookDisplayText(engine.package.chapter(for: card)?.title ?? "宝典知识点")).font(.subheadline.weight(.medium))
                Spacer()
                Text(index.map { "\($0) / \(stats.total)" } ?? "复习中")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }.foregroundStyle(.secondary)
            if engine.usesDualFSRS {
                HStack {
                    Text("本轮还剩 \(stats.remainingToday) 张")
                    Spacer()
                    Text("今日自评 \(stats.ratedToday) 次")
                }.font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(stats.ratedToday), total: Double(max(1, stats.ratedToday + stats.remainingToday)))
                    .tint(.blue).accessibilityLabel("今日已自评\(stats.ratedToday)次")
            }
            }
            HStack(alignment: .center, spacing: 4) {
                HandbookCardFace(card: card, revealed: p.revealed, showRecallCues: subject == .power,
                                 focused: fullScreenActive, primarySourceTitle: engine.package.source.title,
                                 frequencyLabel: engine.package.frequencyLabel(for: card),
                                 memoryGuide: engine.currentMemoryGuide)
                    .environment(\.handbookHighlightContext, .init(cardID: card.id, state: highlightStore.state))
                    .id(p.id)
                if !engine.package.questions(for: card).isEmpty {
                    Button { relatedQuestionTarget = card } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "doc.text")
                            Text("原题").font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }.frame(width: 44, height: 76).foregroundStyle(.blue)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel("查看本考点对应原题")
                        .accessibilityIdentifier("handbook-related-questions")
                }
            }
            if p.revealed {
                Button { showingSources = true } label: {
                    Label { Text(verbatim: sourceLabel(card)).multilineTextAlignment(.leading) }
                        icon: { Image(systemName: "doc.text.magnifyingglass") }
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("handbook-source")
                if !fullScreenActive {
                    Text("这次只是背卡自评，不计入原题正确率。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !fullScreenActive {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                    Text(subject == .power ? "看提示回忆遮住的内容，再翻开核对。" : "先在心里回答，再翻开核对。")
                }.font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }.padding(.top, 10)
    }

    private func completion(_ engine: HandbookWordEngine) -> some View {
        let stats = engine.stats(on: displayDate)
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.blue)
            Text("这一轮先到这里").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(engine.usesDualFSRS ? "本轮已完成，记录已经保存。回到首页可以继续下一轮，到期卡会按双 FSRS 安排。" :
                 "当前可背的卡片已完成或暂缓。记录已经保存，本轮未完成的强化会按单词引擎继续安排。")
                .font(.title3).lineSpacing(6)
            if engine.presentation == nil && engine.retryCount(on: displayDate) > 0 {
                Button { store.startRetry() } label: {
                    Label("可选补练没记住的卡（\(engine.retryCount(on: displayDate))）", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered).disabled(store.blocked).accessibilityIdentifier("handbook-retry-optional")
            }
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
            Text(store.isDualMigrationPending ? "先接续旧的暂存卡" :
                 (store.engine?.usesDualFSRS == true ? "按双 FSRS 继续学习" : "按英语单词引擎继续学习"))
                .font(.subheadline.weight(.semibold))
            Text(store.isDualMigrationPending ? "旧档还有未完成的暂存卡，先按原断点继续；待它们进入队列后，再开始时会保留记录并切换双 FSRS。" :
                 (store.engine?.usesDualFSRS == true ?
                  "每天首次正常背卡自评安排下次复习；可选补练单独记录，不推迟计划。没记住不要求当轮固定重复七次；当天错卡满10分钟可选补练。每轮最多20张，可随时退出续学。翻答案本身不计分。" :
                  "新卡首次直接记住会按英语规则标为已会；没记住会进入当轮强化和后续复习。翻答案本身不计分。"))
                .font(.footnote).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(.horizontal, 3)
    }

    @ViewBuilder private var actions: some View {
        if studying, let engine = store.engine, let p = engine.presentation, engine.currentCard != nil {
            if fullScreenActive {
                focusedActions(p)
            } else { VStack(spacing: 10) {
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
                    Text(engine.currentMemoryGuide != nil ? "按本卡核心自评；完整内容和做题表现另行核对。" :
                         (subject == .power ? "按整张卡遮住的内容自评，下一张会自动出现。" : "按现在能否回忆来选，下一张会自动出现。"))
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
                Button { store.markFamiliar(token: p.id) } label: {
                    Text("已熟记 · 不再复习").font(.footnote).frame(minHeight: 44)
                }.accessibilityIdentifier("handbook-familiar")
            }.controlSize(.regular).disabled(store.blocked)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: .infinity).background(.bar)
            }
        }
    }

    private func focusedActions(_ p: HandbookCardPresentation) -> some View {
        HStack(spacing: 8) {
            if p.revealed {
                Button { store.rate(remembered: false, token: p.id) } label: {
                    Text("没记住").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).tint(.orange).accessibilityIdentifier("handbook-forgotten")
                Button { store.rate(remembered: true, token: p.id) } label: {
                    Text("记住了").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("handbook-remembered")
            } else {
                Button { store.reveal(token: p.id) } label: {
                    Text("翻答案").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("handbook-reveal")
            }
            Button { store.postpone(token: p.id) } label: {
                Text("稍后").font(.footnote).frame(minWidth: 40, minHeight: 44)
            }.buttonStyle(.bordered).accessibilityLabel("暂时不背，本轮稍后")
                .accessibilityIdentifier("handbook-postpone")
            Button { store.markFamiliar(token: p.id) } label: {
                Text("熟记").font(.footnote).frame(minWidth: 40, minHeight: 44)
            }.buttonStyle(.bordered).accessibilityLabel("已熟记，不再复习")
                .accessibilityIdentifier("handbook-familiar")
        }.disabled(store.blocked).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }

    private func outline(_ package: HandbookCardPackage) -> some View {
        NavigationStack {
            List {
                ForEach(package.chapters, id: \.id) { chapter in
                    Section {
                        ForEach(package.cards.filter { package.chapter(for: $0)?.id == chapter.id }, id: \.id) { card in
                            NavigationLink {
                                ScrollView {
                                    HandbookCardFace(card: card, revealed: true, primarySourceTitle: package.source.title,
                                                     frequencyLabel: package.frequencyLabel(for: card),
                                                     memoryGuide: package.memoryGuide(for: card))
                                        .environment(\.handbookHighlightContext, .init(cardID: card.id, state: highlightStore.state))
                                        .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
                                    Text("目录预览不产生自评，也不改变复习日期。")
                                        .font(.footnote).foregroundStyle(.secondary).padding()
                                }.background(Color(uiColor: .systemGroupedBackground))
                                    .navigationTitle("知识点预览").navigationBarTitleDisplayMode(.inline)
                                    .toolbar {
                                        Button("标红", systemImage: "highlighter") {
                                            outlineHighlightTarget = .init(card: card, guide: package.memoryGuide(for: card))
                                        }.accessibilityIdentifier("handbook-outline-highlight-open")
                                    }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: handbookDisplayText(card.title))
                                    if let label = package.frequencyLabel(for: card) {
                                        Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    } header: {
                        Text(verbatim: handbookDisplayText(chapter.title))
                    }
                }
            }.navigationTitle("章节目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { showingOutline = false } }
        }
        .sheet(item: $outlineHighlightTarget) { target in
            HandbookHighlightEditor(target: target, store: highlightStore)
        }
    }
    private func sourceLabel(_ card: HandbookCard) -> String {
        guard let package = store.package else { return "查看原文出处" }
        return handbookSourceGroups(package, card: card).map { group in
            group.title + " · " + (group.isPhoto ? "照片" : "PDF第") + group.pageNumbers.map(String.init).joined(separator: "、") + (group.isPhoto ? "" : "页")
        }.joined(separator: "\n")
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
            guard layoutReady, previewStudyStarted, preview.scrollTarget == nil || scrollReady else { return }
            let engine = store.engine
            let card = engine?.currentCard
            let p = engine?.presentation
            let mode = !studying ? (engine == nil ? "empty" : "home") : (card == nil || p == nil ? "completed" : (p!.revealed ? "back" : "front"))
            let filesPresent = card.map { current in
                guard let package = engine?.package else { return false }
                let groups = handbookSourceGroups(package, card: current)
                return !groups.isEmpty && groups.allSatisfy { group in
                    group.pageNumbers.allSatisfy { group.imageExists(page: $0, root: sourceRoot) }
                }
            } ?? false
            preview.didRender(.init(mode: mode, cardID: card?.id, revealed: p?.revealed ?? false,
                ratingCount: engine.map { $0.stats(on: displayDate).remembered + $0.stats(on: displayDate).forgotten } ?? 0, ratingEnabled: studying && p?.revealed == true && !store.blocked,
                sourceFilesPresent: filesPresent,
                recallCueMode: (subject == .power || engine?.currentMemoryGuide != nil) && mode == "front", fullScreen: fullScreenActive,
                sourceSheetPresented: showingSources || showingAllSources,
                frequencyLabel: card.flatMap { engine?.package.frequencyLabel(for: $0) },
                highlightSpanCount: card.map { current in highlightStore.state.spans.filter { $0.cardID == current.id }.count } ?? 0))
        }
    }
    #endif
}

private struct HandbookCardFace: View {
    let card: HandbookCard
    let revealed: Bool
    var showRecallCues = false
    var focused = false
    var primarySourceTitle: String? = nil
    var frequencyLabel: String? = nil
    var memoryGuide: HandbookCardPackage.MemoryGuide? = nil
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 24.0
    @ScaledMetric(relativeTo: .title2) private var promptSize: CGFloat = 21.0
    @ScaledMetric(relativeTo: .title2) private var summarySize: CGFloat = 20.0
    @ScaledMetric(relativeTo: .body) private var exampleSize: CGFloat = 18.0
    @ScaledMetric(relativeTo: .body) private var stepSize: CGFloat = 18.0
    @ScaledMetric(relativeTo: .body) private var noteSize: CGFloat = 16.0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !focused { HStack {
                Text(revealed ? "核对答案" : "主动回忆").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
                Image(systemName: revealed ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                    .foregroundStyle(.blue.opacity(0.7))
            } }
            HandbookMarkedText(source: card.title, fieldID: "title").font(.system(size: titleSize, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("handbook-card-title")
            if let label = frequencyLabel {
                Text(verbatim: label).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("handbook-topic-frequency")
            }
            if let guide = memoryGuide {
                HandbookMemoryGuideView(guide: guide, revealed: revealed)
                if revealed {
                    Text("按本卡核心自评；完整内容与做题表现另行核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("查看完整讲义内容") {
                        fullAnswer.padding(.top, 12)
                    }.font(.headline).accessibilityIdentifier("handbook-guide-full-answer")
                }
            } else if !revealed && showRecallCues {
                if !focused {
                    Text("冒号前作提示，后面遮住；翻一次核对整张。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if card.answerSummary != "讲义原文" {
                    HandbookCueTextView(source: card.answerSummary, fontSize: summarySize, fieldID: "summary")
                }
                ForEach(Array(card.blocks.enumerated()), id: \.offset) { index, block in
                    if !block.collapsed { HandbookCardBlockView(block: block, blockID: "blocks.\(index)", masked: true, focused: focused) }
                }
            } else if !revealed {
                HandbookMarkedText(source: card.prompt, fieldID: "prompt").font(.system(size: promptSize)).lineSpacing(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("handbook-card-prompt")
                    .padding(.top, 5).padding(.bottom, 34)
            } else {
                fullAnswer
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.045), lineWidth: 1) }
    }

    private var fullAnswer: some View {
        VStack(alignment: .leading, spacing: 18) {
                if !focused || card.answerSummary != "讲义原文" {
                HandbookMarkedText(source: card.answerSummary, fieldID: "summary").font(.system(size: summarySize, weight: .medium)).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("handbook-card-summary")
                }
                ForEach(Array(card.blocks.enumerated()), id: \.offset) { index, block in
                    if block.collapsed {
                        HandbookCollapsibleBlock(cardID: card.id, block: block, blockID: "blocks.\(index)", focused: focused)
                            .id(HandbookBlockIdentity(cardID: card.id, index: index))
                    } else { HandbookCardBlockView(block: block, blockID: "blocks.\(index)", focused: focused) }
                }
                if !card.examples.isEmpty {
                    DisclosureGroup("用原例再理解一次") {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(card.examples.enumerated()), id: \.offset) { exampleIndex, example in
                                VStack(alignment: .leading, spacing: 11) {
                                    if !example.title.isEmpty { HandbookMarkedText(source: example.title, fieldID: "examples.\(exampleIndex).title").font(.headline) }
                                    HandbookMarkedText(source: example.prompt, fieldID: "examples.\(exampleIndex).prompt").font(.system(size: exampleSize)).lineSpacing(5)
                                    ForEach(Array(example.steps.enumerated()), id: \.offset) { index, step in
                                        HStack(alignment: .top, spacing: 9) {
                                            Text(String(index + 1)).font(.caption.bold()).foregroundStyle(.blue)
                                                .frame(width: 22, height: 22).background(.blue.opacity(0.09), in: Circle())
                                            HandbookMarkedText(source: step, fieldID: "examples.\(exampleIndex).steps.\(index)").font(.system(size: stepSize)).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    HandbookMarkedText(source: example.answer, fieldID: "examples.\(exampleIndex).answer").font(.system(size: exampleSize, weight: .medium))
                                    Text(verbatim: (primarySourceTitle.map { $0 + " · " } ?? "") + "PDF物理第\(example.sourcePage)页")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let note = example.sourceIssueNote, !note.isEmpty {
                                        HandbookMarkedText(source: note, fieldID: "examples.\(exampleIndex).note").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.padding(.top, 14)
                    }.font(.headline)
                }
                if !card.sourceNotes.isEmpty {
                    DisclosureGroup("原书校注") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(card.sourceNotes.enumerated()), id: \.offset) { index, note in
                                HandbookMarkedText(source: note, fieldID: "sourceNotes.\(index)").font(.system(size: noteSize)).foregroundStyle(.secondary).lineSpacing(5)
                            }
                        }.padding(.top, 10)
                    }.font(.headline)
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A guide is only a compact aid; opening it never grades or advances the card.
private struct HandbookMemoryGuideView: View {
    let guide: HandbookCardPackage.MemoryGuide
    let revealed: Bool
    @ScaledMetric(relativeTo: .body) private var rowSize: CGFloat = 19
    @State private var helpExpanded = false
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    #endif

    private func rows(showAnswers: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(guide.rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 4) {
                    HandbookMarkedText(source: row.cue, fieldID: "guide.rows.\(index).cue", suffix: "：")
                        .font(.system(size: rowSize, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if showAnswers {
                        HandbookMarkedText(source: row.answer, fieldID: "guide.rows.\(index).answer")
                            .font(.system(size: rowSize)).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("已遮住").font(.subheadline).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    @ViewBuilder private var explanation: some View {
        if let text = guide.explanation, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HandbookMarkedText(source: text, fieldID: "guide.explanation").font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var mnemonic: some View {
        if let text = guide.mnemonic, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HandbookMarkedText(source: text, fieldID: "guide.mnemonic", prefix: "记忆提示：")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if revealed {
                explanation
                rows(showAnswers: true).accessibilityIdentifier("handbook-guide-answers")
                mnemonic
            } else {
                rows(showAnswers: false).accessibilityIdentifier("handbook-guide-cues")
                DisclosureGroup(isExpanded: $helpExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        explanation
                        rows(showAnswers: true)
                        mnemonic
                    }.padding(.top, 10)
                } label: {
                    Text("先看懂，不计成绩")
                }.font(.headline).accessibilityIdentifier("handbook-guide-study-first")
                #if DEBUG
                .onAppear { preview.didRenderGuideHelp(guide.cardID, helpExpanded) }
                .task(id: preview.guideHelpExpanded) {
                    if let requested = preview.guideHelpExpanded { helpExpanded = requested }
                }
                .onChange(of: helpExpanded) { _, value in preview.didRenderGuideHelp(guide.cardID, value) }
                #endif
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        #if DEBUG
        .onAppear { preview.didRenderGuide(guide.cardID, revealed) }
        .onChange(of: revealed) { _, value in preview.didRenderGuide(guide.cardID, value) }
        #endif
    }
}

private struct HandbookBlockIdentity: Hashable {
    let cardID: String
    let index: Int
}

private struct HandbookCollapsibleBlock: View {
    let cardID: String
    let block: HandbookCard.Block
    let blockID: String
    let focused: Bool
    @State private var expanded = false
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    #endif
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            HandbookCardBlockView(block: block, blockID: blockID, focused: focused).padding(.top, 12)
                #if DEBUG
                .onAppear { if block.kind == "diagram" { preview.didRenderDiagram(cardID, true) } }
                #endif
        } label: {
            if block.title.isEmpty { Text("展开补充").font(.headline) }
            else { HandbookMarkedText(source: block.title, fieldID: blockID + ".title").font(.headline) }
        }
        #if DEBUG
        .onAppear {
            if block.kind == "diagram" && !expanded { preview.didRenderDiagram(cardID, false) }
        }
        .task(id: preview.diagramExpanded) {
            if block.kind == "diagram", let requested = preview.diagramExpanded { expanded = requested }
        }
        .onChange(of: expanded) { _, value in
            if block.kind == "diagram" && !value { preview.didRenderDiagram(cardID, false) }
        }
        #endif
    }
}

/// Uses only the validated block nodes; it never reads or writes learning state.
private struct HandbookRelationshipDiagram: View {
    let mode: String
    let items: [String]
    let blockID: String
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 17
    private func node(_ text: String, index: Int, color: Color) -> some View {
        HandbookMarkedText(source: text, fieldID: blockID + ".items.\(index)")
            .font(.system(size: textSize, weight: .medium)).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity).padding(12)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.45), lineWidth: 1) }
    }
    private func arrow(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol).font(.body.weight(.bold)).foregroundStyle(.blue)
            .accessibilityLabel(label)
    }
    var body: some View {
        VStack(spacing: 8) {
            if mode == "branch", items.count == 3 {
                node(items[0], index: 0, color: .blue)
                if dynamicType.isAccessibilitySize {
                    Label("由根节点分支一", systemImage: "arrow.turn.down.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                    node(items[1], index: 1, color: .teal)
                    Label("由根节点分支二", systemImage: "arrow.turn.down.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                    node(items[2], index: 2, color: .orange)
                } else {
                    HStack(spacing: 12) {
                        arrow("arrow.down.left", label: "分支一").frame(maxWidth: .infinity)
                        arrow("arrow.down.right", label: "分支二").frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        node(items[1], index: 1, color: .teal).frame(maxWidth: .infinity)
                        node(items[2], index: 2, color: .orange).frame(maxWidth: .infinity)
                    }
                }
            } else if mode == "flow" {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { arrow("arrow.down", label: "接下来") }
                    node(item, index: index, color: index == 0 ? .blue : .teal)
                }
            }
        }.frame(maxWidth: .infinity).id("handbook-relationship-diagram")
            .accessibilityIdentifier("handbook-relationship-diagram")
    }
}

private struct HandbookCardBlockView: View {
    let block: HandbookCard.Block
    let blockID: String
    var masked = false
    var focused = false
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 19.0
    @ScaledMetric(relativeTo: .body) private var keySize: CGFloat = 17.0
    @ScaledMetric(relativeTo: .body) private var keyWidth: CGFloat = 72.0
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !block.title.isEmpty && !block.collapsed && !(focused && ["原文", "原表", "原图"].contains(block.title)) {
                HandbookMarkedText(source: block.title, fieldID: blockID + ".title").font(.headline).foregroundStyle(.secondary)
            }
            if block.kind == "diagram", !masked, let mode = block.text, let items = block.items {
                HandbookRelationshipDiagram(mode: mode, items: items, blockID: blockID)
            } else if block.kind == "keyValues" || block.kind == "table" { table }
            else if block.kind == "bullets" || block.kind == "steps" {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 11) {
                        Text(block.kind == "steps" ? String(index + 1) + "." : "•")
                            .font(.system(size: keySize, weight: .semibold)).foregroundStyle(.blue).frame(minWidth: 15, alignment: .leading)
                        if masked { HandbookCueTextView(source: item, fontSize: bodySize, fieldID: blockID + ".items.\(index)") }
                        else { HandbookMarkedText(source: item, fieldID: blockID + ".items.\(index)").font(.system(size: bodySize)).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } else if let text = block.text {
                if masked { HandbookCueTextView(source: text, fontSize: bodySize, fieldID: blockID + ".text") }
                else { HandbookMarkedText(source: text, fieldID: blockID + ".text").font(.system(size: bodySize)).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var table: some View {
        VStack(spacing: 0) {
            if block.kind == "table", let columns = block.columns, columns.contains(where: { !$0.isEmpty }), !dynamicType.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                        HandbookMarkedText(source: title, fieldID: blockID + ".columns.\(index)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: columns.count == 2 && index == 0 ? keyWidth : nil, alignment: .leading)
                            .frame(maxWidth: columns.count == 2 && index == 0 ? nil : .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10).background(Color.blue.opacity(0.07))
            }
            ForEach(Array((block.rows ?? []).enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.horizontal, 14) }
                rowView(row, rowIndex: index).padding(.horizontal, 14).padding(.vertical, 14)
            }
        }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder private func rowView(_ row: [String], rowIndex: Int) -> some View {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                    VStack(alignment: .leading, spacing: 4) {
                        if block.kind == "table", let columns = block.columns, column < columns.count {
                            HandbookMarkedText(source: columns[column], fieldID: blockID + ".columns.\(column)").font(.caption).foregroundStyle(.secondary)
                        }
                        cellText(cell, rowIndex: rowIndex, column: column)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 13) {
                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                    cellText(cell, rowIndex: rowIndex, column: column)
                        .frame(width: row.count == 2 && column == 0 ? keyWidth : nil, alignment: .leading)
                        .frame(maxWidth: row.count == 2 && column == 0 ? nil : .infinity, alignment: .leading)
                }
            }
        }
    }
    @ViewBuilder private func cellText(_ cell: String, rowIndex: Int, column: Int) -> some View {
        if masked, HandbookRecallCue.cell(cell, column: column) == .hidden {
            HandbookAnswerMask()
        } else {
            HandbookMarkedText(source: cell, fieldID: blockID + ".rows.\(rowIndex).\(column)").font(.system(size: column == 0 ? keySize : bodySize, weight: column == 0 ? .semibold : .regular))
                .foregroundStyle(column == 0 ? Color.blue : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HandbookCueTextView: View {
    let source: String
    let fontSize: CGFloat
    let fieldID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(HandbookRecallCue.lines(source).enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 6) {
                    if !line.prefix.isEmpty {
                        HandbookMarkedExcerpt(source: source, fieldID: fieldID, prefix: line.prefix).font(.system(size: fontSize)).lineSpacing(6)
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

/// Keep each PDF's physical page numbers in its own namespace.
struct HandbookSourceGroup: Identifiable {
    let id: String
    let title: String
    let pageNumbers: [Int]
    let pages: [HandbookCardPackage.Page]
    var isPhoto = false

    func imageExists(page number: Int, root: URL) -> Bool {
        guard let asset = pages.first(where: { $0.number == number })?.asset else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(
            asset.sha256 + (asset.mimeType == "image/jpeg" ? ".jpg" : ".png")).path)
    }
}

func handbookSourceGroups(_ package: HandbookCardPackage, card: HandbookCard? = nil) -> [HandbookSourceGroup] {
    var groups: [HandbookSourceGroup] = []
    let primaryPages = card?.sourcePages ?? package.source.includedPages
    if !primaryPages.isEmpty {
        groups.append(.init(id: "primary", title: package.source.title, pageNumbers: primaryPages.sorted(), pages: package.sourcePages ?? []))
    }
    for extra in package.additionalSources ?? [] {
        let numbers = card.map { current in
            (current.sourceReferences ?? []).filter { $0.sourceID == extra.id }.map(\.page)
        } ?? extra.source.includedPages
        if !numbers.isEmpty {
            groups.append(.init(id: "additional:" + extra.id, title: extra.source.title,
                                pageNumbers: numbers.sorted(), pages: extra.sourcePages ?? [],
                                isPhoto: ["jpg", "jpeg", "png"].contains((extra.source.fileName as NSString).pathExtension.lowercased())))
        }
    }
    return groups
}

private struct HandbookSourcePagesView: View {
    let groups: [HandbookSourceGroup]
    let assetRoot: URL
    let title: String
    @State private var selectedID = ""
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    #endif
    private var selected: HandbookSourceGroup? { groups.first(where: { $0.id == selectedID }) ?? groups.first }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text("按来源页号核对原文。查阅原页不产生自评，也不改变复习日期。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if groups.count > 1 {
                        Menu {
                            ForEach(groups) { group in
                                Button { selectedID = group.id } label: {
                                    if selected?.id == group.id { Label(group.title, systemImage: "checkmark") }
                                    else { Text(verbatim: group.title) }
                                }
                            }
                        } label: {
                            HStack(alignment: .top) {
                                Text(verbatim: selected?.title ?? "选择来源").multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.up.chevron.down")
                            }.font(.headline).padding(14).frame(maxWidth: .infinity)
                                .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }.accessibilityIdentifier("handbook-source-picker")
                    }
                    if groups.isEmpty {
                        Text("这个卡包暂未附上原页图片；仍可继续背文字卡。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let selected {
                    Text(verbatim: selected.title).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("handbook-source-title")
                    ForEach(selected.pageNumbers, id: \.self) { number in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(selected.isPhoto ? "照片 \(number)" : "PDF物理第\(number)页").font(.headline)
                            if let page = selected.pages.first(where: { $0.number == number }) {
                                HandbookOriginalPageImage(asset: page.asset, root: assetRoot)
                            } else {
                                Label("这页原图尚未附上；可继续阅读卡片正文。", systemImage: "photo.badge.exclamationmark")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("handbook-source-image-missing")
                            }
                        }
                    }
                    }
                }.padding(20)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { dismiss() } }
        }
        #if DEBUG
        .onAppear { reportSourcePreview() }
        .onChange(of: selectedID) { _, _ in reportSourcePreview() }
        .onChange(of: preview.sourceSelectionID, initial: true) { _, id in
            if let id, groups.contains(where: { $0.id == id }) { selectedID = id }
        }
        #endif
    }
    #if DEBUG
    private func reportSourcePreview() {
        Task { @MainActor in
            await Task.yield()
            guard let selected else { return }
            preview.didRenderSources(.init(sourceID: selected.id, title: selected.title,
                pageNumbers: selected.pageNumbers,
                missingPageNumbers: selected.pageNumbers.filter { !selected.imageExists(page: $0, root: assetRoot) }))
        }
    }
    #endif
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
                Label(error, systemImage: "photo.badge.exclamationmark").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("handbook-source-image-missing")
            } else { ProgressView("打开原页…") }
        }.task(id: asset.sha256) {
            image = nil; error = nil
            do { image = try asset.decodedCGImage(assetRoot: root) }
            catch { self.error = "这页原图尚未附上或无法打开；可继续阅读卡片正文。" }
        }
    }
}

/// A related exercise never changes or advances the visible recall card.
private struct HandbookRelatedQuestionPage: View {
    let card: HandbookCard
    let questions: [HandbookRelatedQuestion]
    let assetRoot: URL
    @ObservedObject var store: HandbookRelatedQuestionStore
    let cardAnswerWasVisible: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var selected: Set<String> = []
    @State private var result: HandbookRelatedAttempt?
    @State private var showingSourceAnswer = false
    @State private var attemptID = UUID()
    @State private var loadedImages: Set<Int> = []
    @State private var failedImages: Set<Int> = []
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if questions.indices.contains(index) {
                    let question = questions[index]
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(card.title).font(.subheadline).foregroundStyle(.secondary)
                            HStack {
                                Text(question.type.title).font(.headline)
                                Spacer()
                                Text("\(index + 1) / \(questions.count)").foregroundStyle(.secondary)
                            }
                            Text(question.sourceLabel).font(.footnote).foregroundStyle(.secondary)
                            Text(question.prompt).font(.system(size: 21)).textSelection(.enabled)
                            ForEach(Array((question.sourceAssets ?? []).enumerated()), id: \.offset) { number, asset in
                                HandbookRelatedQuestionImage(asset: asset, root: assetRoot) { available in
                                    if available { loadedImages.insert(number); failedImages.remove(number) }
                                    else { loadedImages.remove(number); failedImages.insert(number) }
                                }.id(question.definitionID + ":" + String(number))
                            }
                            if !failedImages.isEmpty {
                                Label("题图未能打开，请补齐原图后作答。", systemImage: "photo.badge.exclamationmark")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                            if question.type == .multiple {
                                Text("多选题：选齐后提交。 ").font(.footnote).foregroundStyle(.secondary)
                            }
                            if let note = question.sourceIssueNote {
                                Label("原题待校：仅查看，不自动判分。", systemImage: "exclamationmark.triangle")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                                Text(note).font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(question.options) { option in
                                Button { choose(option.id, type: question.type) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: selected.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                        Text(option.id).bold()
                                        if question.optionsShownInImage != true { Text(option.text).frame(maxWidth: .infinity, alignment: .leading) }
                                        else { Spacer() }
                                    }.font(.body).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).disabled(result != nil || showingSourceAnswer || !imagesReady(question) || store.blocked)
                            }
                            if let result {
                                Label(result.correct ? "本次答对" : "本次答错", systemImage: result.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.title3.bold()).foregroundStyle(result.correct ? Color.green : Color.orange)
                                Text("原书答案：" + question.answer.joined(separator: "、")).font(.headline)
                                Text(question.explanation).font(.body).textSelection(.enabled)
                                Text("这是对应原题的练习记录，不会改变背卡自评或复习日期。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if showingSourceAnswer && question.requiresReview {
                                Text("原书标记：" + (question.originalAnswerLabel ?? question.answer.joined(separator: "、"))).font(.headline)
                                Text(question.explanation).font(.body).textSelection(.enabled)
                                Text("这道题的选项或条件待核，本次不生成答对／答错记录。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                        }.padding(20).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 10) {
                            if question.requiresReview && !showingSourceAnswer {
                                Button("查看原书标记与解析") { showingSourceAnswer = true }
                                    .buttonStyle(.borderedProminent).disabled(!imagesReady(question))
                            } else if question.requiresReview && showingSourceAnswer {
                                if index + 1 < questions.count { Button("下一道原题") { advance() }.buttonStyle(.borderedProminent) }
                                else { Button("返回卡片") { dismiss() }.buttonStyle(.borderedProminent) }
                            } else if result == nil {
                                Button("提交答案") {
                                    guard result == nil else { return }
                                    result = store.submit(question: question, selected: selected,
                                        cardAnswerWasVisible: cardAnswerWasVisible, id: attemptID, at: Date())
                                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || !imagesReady(question) || store.blocked)
                            } else if index + 1 < questions.count {
                                Button("下一道原题") { advance() }.buttonStyle(.borderedProminent)
                            } else {
                                Button("返回卡片") { dismiss() }.buttonStyle(.borderedProminent)
                            }
                        }.frame(maxWidth: .infinity).padding(12).background(.bar)
                    }
                } else {
                    ContentUnavailableView("暂未附原题", systemImage: "doc.text")
                }
            }
            .navigationTitle("对应原题").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回卡片") { dismiss() } } }
            #if DEBUG
            .onAppear { preview.didRenderRelatedQuestion() }
            #endif
        }
    }
    private func imagesReady(_ question: HandbookRelatedQuestion) -> Bool {
        failedImages.isEmpty && loadedImages.count == (question.sourceAssets ?? []).count
    }
    private func choose(_ id: String, type: ExamQuestionType) {
        guard result == nil else { return }
        if type == .multiple {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else { selected = [id] }
    }
    private func advance() {
        index += 1; selected = []; result = nil; showingSourceAnswer = false; attemptID = UUID(); loadedImages = []; failedImages = []
    }
}

private struct HandbookRelatedQuestionImage: View {
    let asset: ProfessionalSourceFileAsset
    let root: URL
    let onAvailability: (Bool) -> Void
    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoomed = false
    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 8) {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel(asset.altText)
                    Button("放大题图") { zoomed = true }.font(.footnote).buttonStyle(.bordered)
                }
            } else if failed {
                Text("本机尚未找到题图。").font(.footnote).foregroundStyle(.orange)
            } else { ProgressView("正在打开题图…") }
        }.task(id: asset.sha256) {
            image = nil; failed = false
            do { image = try asset.croppedCGImage(assetRoot: root); onAvailability(true) }
            catch { failed = true; onAvailability(false) }
        }
        .sheet(isPresented: $zoomed) {
            NavigationStack {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1).accessibilityLabel(asset.altText)
                    }.navigationTitle("题图 · 可横竖滑动").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("关闭") { zoomed = false } }
                }
            }
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
