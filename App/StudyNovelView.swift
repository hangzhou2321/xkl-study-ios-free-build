import SwiftUI
import UniformTypeIdentifiers

@MainActor struct StudyNovelEntry: View {
    @ObservedObject var store: StudyNovelStore
    let compact: Bool
    let open: (Bool) -> Void

    var body: some View {
        if let book = store.active {
            Button { open(compact && book.nextUnread != nil) } label: {
                if compact {
                    Label(book.nextUnread != nil ? "读下一章" :
                          (book.progress.unlocked == book.chapterCount ? "全书已解锁" : progress(book)), systemImage: "book")
                        .font(.footnote.monospacedDigit()).padding(.horizontal, 4).frame(minHeight: 44)
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "book.closed").font(.title3).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: book.title).font(.headline).lineLimit(1)
                            Text(verbatim: status(book)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(compact ? "追更小说，" + status(book) : "追更小说，" + book.title + "，" + status(book))
        } else if !compact {
            Button { open(false) } label: { Label("导入小说 · 背完一组读一章", systemImage: "book.closed") }
                .buttonStyle(.bordered)
        }
    }

    private func progress(_ book: StudyNovelStore.Book) -> String {
        "\(book.progress.cardsInChapter.count)/\(StudyNovelProgress.cardsPerChapter)"
    }

    private func status(_ book: StudyNovelStore.Book) -> String {
        if let next = book.nextUnread { return "第 \(next + 1) 章可读" }
        if book.progress.unlocked == book.chapterCount { return "全书已解锁" }
        return progress(book) + " 张 · 解锁下一章"
    }
}

@MainActor struct StudyNovelShelfView: View {
    @ObservedObject var store: StudyNovelStore
    let records: () -> [String: [ProfessionalRecallAttempt]]
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var path: [Int]

    init(store: StudyNovelStore, records: @escaping () -> [String: [ProfessionalRecallAttempt]], firstChapter: Int?) {
        self.store = store
        self.records = records
        _path = State(initialValue: firstChapter.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let book = store.active, let novel = store.novel, novel.id == book.id {
                    Section {
                        if let next = book.nextUnread {
                            chapterLink(index: next, title: "读下一章")
                                .font(.headline)
                        } else if let last = book.progress.lastOpened {
                            chapterLink(index: last, title: "接着读")
                        }
                        LabeledContent("已解锁", value: "\(book.progress.unlocked) / \(book.chapterCount) 章")
                        if book.progress.unlocked < book.chapterCount {
                            ProgressView(value: Double(book.progress.cardsInChapter.count),
                                         total: Double(StudyNovelProgress.cardsPerChapter)) {
                                Text("下一章还差 \(StudyNovelProgress.cardsPerChapter - book.progress.cardsInChapter.count) 张")
                            }
                        }
                    } header: {
                        Text(verbatim: book.title)
                    }
                    Section("章节") {
                        ForEach(0..<book.chapterCount, id: \.self) { index in
                            if index < book.progress.unlocked {
                                chapterLink(index: index, title: novel.chapters[index].title)
                            } else {
                                Label("第 \(index + 1) 章", systemImage: "lock")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("选择一本想追的小说").font(.headline)
                        Text("每完成 25 张卡的自评，解锁一整章。新卡和复习卡都算，同一张卡当天只计一次。")
                            .foregroundStyle(.secondary)
                        Button { importing = true } label: { Label("导入 TXT 小说", systemImage: "square.and.arrow.down") }
                    } footer: {
                        Text("章节标题应单独占一行，例如「第一章 初入青云宗」。导入后从下一张卡开始累计。")
                    }
                }
                if store.books.count > 1 {
                    Section("书架") {
                        ForEach(store.books) { book in
                            Button { store.select(book.id, records: records()) } label: {
                                HStack {
                                    Text(verbatim: book.title)
                                    Spacer()
                                    if book.id == store.active?.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("背卡追更")
            .navigationDestination(for: Int.self) { index in
                if let book = store.active, let novel = store.novel, novel.id == book.id,
                   novel.chapters.indices.contains(index), index < book.progress.unlocked {
                    StudyNovelChapterView(store: store, chapter: novel.chapters[index], index: index)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if store.active != nil {
                        Button { importing = true } label: { Label("导入 TXT 小说", systemImage: "plus") }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
                switch result {
                case .success(let url): store.importText(url, records: records())
                case .failure(let error): store.error = error.localizedDescription
                }
            }
            .alert("小说书架", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }

    private func chapterLink(index: Int, title: String) -> some View {
        NavigationLink(value: index) {
            Text(verbatim: title)
        }
    }
}

@MainActor private struct StudyNovelChapterView: View {
    @ObservedObject var store: StudyNovelStore
    let chapter: StudyNovel.Chapter
    let index: Int
    let paragraphs: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var visibleParagraph: Int?

    init(store: StudyNovelStore, chapter: StudyNovel.Chapter, index: Int) {
        self.store = store
        self.chapter = chapter
        self.index = index
        let lines = chapter.text.split(separator: "\n").map(String.init)
        paragraphs = lines
        let saved = store.active?.progress.readingPositions[index]
        _visibleParagraph = State(initialValue: saved.flatMap { lines.indices.contains($0) ? $0 : nil })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(verbatim: chapter.title).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(paragraphs.indices, id: \.self) { paragraph in
                    Text(verbatim: paragraphs[paragraph])
                        .font(.system(.body, design: .serif))
                        .lineSpacing(7)
                        .textSelection(.enabled)
                        .id(paragraph)
                }
                Button("读完这一章") { store.finish(index); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .scrollTargetLayout()
            .frame(maxWidth: 620, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $visibleParagraph, anchor: .top)
        .navigationTitle("第 \(index + 1) 章")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.open(index) }
        .onDisappear(perform: savePosition)
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition() } }
    }

    private func savePosition() {
        if let visibleParagraph { store.bookmark(index, paragraph: visibleParagraph) }
    }
}
