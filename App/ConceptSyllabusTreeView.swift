import SwiftUI
import PDFKit
import CryptoKit
import Foundation

/// Navigation over source material only; opening a leaf does not grade or schedule it.
struct ConceptSyllabusTreeView: View {
    let tree: ConceptSyllabusTree
    @ObservedObject var store: ConceptStore
    let openGuide: (String) -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 0) {
                    Label("2027 考纲", systemImage: "tree.fill")
                        .font(.title2.bold()).padding(.horizontal, 24).padding(.vertical, 14)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 18)
                    Text("选一个枝 → 找考点 → 看来源题")
                        .font(.subheadline.bold())
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
                Text("原题挂到树上，只表示资料已整理，不表示你已学会。")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("全部资料覆盖与统计口径") {
                    SyllabusStatisticsView(stats: tree.statistics(for: tree.leaves))
                    Text(tree.frequencyNote).font(.footnote)
                    Text(tree.outlineSource).font(.footnote).textSelection(.enabled)
                    Text("归并只使用已明确标记的重复关系；题库与模拟卷分别计数，项目变式不计入原资料频次。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            branchSection("27考纲主线", scope: "mainline")
            branchSection("相关基础与衔接", scope: "related")
            branchSection("旧范围资料 · 单独保留", scope: "archived")
            Section("资料版本") {
                ForEach(tree.sources) { source in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.title).font(.subheadline)
                        Text(source.edition).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(tree.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func branchSection(_ title: String, scope: String) -> some View {
        let selected = tree.branches.filter { $0.scope == scope }
        if !selected.isEmpty {
            Section(title) {
                ForEach(selected) { branch in
                    NavigationLink {
                        SyllabusBranchView(tree: tree, branch: branch, store: store, openGuide: openGuide)
                    } label: {
                        HStack(spacing: 0) {
                            SyllabusBranchConnector().stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                                .frame(width: 27).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(branch.title).font(.headline)
                                let stats = tree.statistics(for: tree.branchLeaves(branch.id))
                                if stats.total == 0 {
                                    Text("暂无源题样本 · 不等于不考")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("\(tree.topics.filter { $0.branchID == branch.id }.count) 个考点 · 六套中 \(stats.papers.count) 套出现")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.vertical, 5)
                        }.frame(minHeight: 78)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }
        }
    }
}

private struct SyllabusBranchConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7, y: rect.minY))
        path.addLine(to: CGPoint(x: 7, y: rect.maxY))
        path.move(to: CGPoint(x: 7, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct SyllabusBranchView: View {
    let tree: ConceptSyllabusTree
    let branch: ConceptSyllabusTree.Branch
    @ObservedObject var store: ConceptStore
    let openGuide: (String) -> Void
    private var topics: [ConceptSyllabusTree.Topic] { tree.topics.filter { $0.branchID == branch.id } }

    var body: some View {
        List {
            Section("考纲依据") {
                Text(branch.syllabusText).textSelection(.enabled)
                if branch.scope != "mainline" {
                    Text(branch.scope == "archived" ? "本枝保留旧范围资料，不计作27考纲主线。" : "本枝用于联系相关基础，范围以所列考纲依据为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                SyllabusStatisticsView(stats: tree.statistics(for: tree.branchLeaves(branch.id)))
            }
            if topics.isEmpty {
                Section {
                    Text("暂无源题样本")
                    Text("这表示提供的资料暂时没有挂入本枝的题，不代表考试不考。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("选择一个考点") {
                    ForEach(topics) { topic in
                        NavigationLink {
                            SyllabusTopicView(tree: tree, topic: topic, store: store, openGuide: openGuide)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(topic.title).font(.headline)
                                let stats = tree.statistics(for: tree.topicLeaves(topic.id))
                                Text(stats.total == 0 ? "暂无源题样本" : "六套出现 \(stats.papers.count) 套 · \(stats.frequencyBand) · 题库 \(stats.bookCount) 次")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle(branch.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SyllabusTopicView: View {
    let tree: ConceptSyllabusTree
    let topic: ConceptSyllabusTree.Topic
    @ObservedObject var store: ConceptStore
    let openGuide: (String) -> Void
    private var leaves: [ConceptSyllabusTree.Leaf] { tree.topicLeaves(topic.id) }

    var body: some View {
        List {
            Section {
                SyllabusStatisticsView(stats: tree.statistics(for: leaves))
                Text("高低频只描述这六套资料的覆盖，不是27真卷的出题概率。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("先看懂，再核对原题") {
                if let note = topic.coverageNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                if topic.conceptIDs.isEmpty {
                    Text("本考点暂未配专门图解，可先查看下方原资料。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(topic.conceptIDs, id: \.self) { id in
                    if let lesson = store.teaching?.lessons.first(where: { $0.conceptID == id }), lesson.guide != nil {
                        Button {
                            openGuide(id)
                        } label: {
                            Label("相关图解 · " + lesson.title, systemImage: "photo.on.rectangle.angled")
                        }.disabled(store.blocked)
                    }
                }
            }
            if leaves.isEmpty {
                Section {
                    Text("暂无源题样本 · 不等于不考")
                    Text("已有讲解仍可阅读；缺口会保留在树上。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(tree.sources) { source in
                let sourceLeaves = leaves.filter { $0.sourceID == source.id }
                if !sourceLeaves.isEmpty {
                    Section {
                        NavigationLink {
                            SyllabusSourceLeavesView(store: store, leaves: sourceLeaves, source: source)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.title).font(.headline)
                                Text("本考点 \(sourceLeaves.count) 条来源题 · 点开逐题看")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SyllabusSourceLeavesView: View {
    @ObservedObject var store: ConceptStore
    let leaves: [ConceptSyllabusTree.Leaf]
    let source: ConceptSyllabusTree.Source
    @State private var pageIndex = 0
    private let pageSize = 20
    private var pageCount: Int { max(1, (leaves.count + pageSize - 1) / pageSize) }
    private var visible: [ConceptSyllabusTree.Leaf] { Array(leaves.dropFirst(pageIndex * pageSize).prefix(pageSize)) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text(source.edition).font(.footnote).foregroundStyle(.secondary).id("source-top")
                    Text("共 \(leaves.count) 条来源题；当前第 \(pageIndex + 1)/\(pageCount) 页")
                        .font(.subheadline)
                }
                ForEach(visible) { leaf in
                    NavigationLink {
                        SyllabusLeafView(store: store, leaf: leaf, source: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("第 \(leaf.number) 题 · PDF第 \(leaf.page) 页").font(.subheadline.bold())
                            Text(leaf.prompt).font(.subheadline).lineLimit(2)
                            Text(leaf.verification == "sourcePending" ? "来源题待逐题核验" : "已关联核验题")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .onChange(of: pageIndex) { _, _ in proxy.scrollTo("source-top", anchor: .top) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("上一页") { pageIndex -= 1 }.disabled(pageIndex == 0)
                Spacer()
                Text("\(pageIndex + 1) / \(pageCount)").font(.footnote)
                Spacer()
                Button("下一页") { pageIndex += 1 }.disabled(pageIndex + 1 >= pageCount)
            }.padding().background(.bar)
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SyllabusStatisticsView: View {
    let stats: ConceptSyllabusTree.Statistics
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("六套出现套数：\(stats.papers.count)/6 · \(stats.frequencyBand)").font(.headline)
            Text("原题出现次数：\(stats.total) · 归并后条目：\(stats.uniqueBookCount + stats.uniqueMockCount)")
                .font(.subheadline)
            Text("题库 \(stats.bookCount) 次（归并后 \(stats.uniqueBookCount)）\n模拟卷 \(stats.mockCount) 次（归并后 \(stats.uniqueMockCount)）")
                .font(.footnote).foregroundStyle(.secondary)
            if !stats.papers.isEmpty {
                Text("出现于第 " + stats.papers.map(String.init).joined(separator: "、") + " 套")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if stats.pendingCount > 0 {
                Text("其中 \(stats.pendingCount) 条来源题待逐题核验")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

private struct SyllabusLeafView: View {
    @ObservedObject var store: ConceptStore
    let leaf: ConceptSyllabusTree.Leaf
    let source: ConceptSyllabusTree.Source
    @State private var pdfPresented = false

    var body: some View {
        List {
            Section("来源") {
                Text(source.title).font(.headline)
                Text(source.edition).font(.subheadline)
                Text("PDF物理页码：第 \(leaf.page) 页").font(.footnote).foregroundStyle(.secondary)
                if let points = leaf.points { Text("原卷分值：\(points.formatted()) 分").font(.footnote) }
                Text(leaf.verification == "sourcePending" ? "来源题待逐题核验；题干、选项和图以原PDF为准。" : "已关联到核验题；此页仅浏览原资料。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("打开原PDF · 第 \(leaf.page) 页", systemImage: "doc.richtext") { pdfPresented = true }
            }
            Section("资料摘要 · 非完整作答题") {
                Text(leaf.prompt).textSelection(.enabled)
                ForEach(leaf.options.indices, id: \.self) { index in
                    Text(leaf.options[index]).textSelection(.enabled)
                }
            }
            if let bank=store.engine?.bank, let teaching=store.teaching {
                Section("相关知识与完整核验题") {
                    ForEach(leaf.linkedQuestionIDs, id: \.self) { id in
                        if let question=bank.concepts.flatMap(\.questions).first(where: { $0.id == id }) {
                            if teaching.questionPresentations?.contains(where: { $0.questionID == id }) == true {
                                NavigationLink("查看完整核验题") { ProfessionalSourceStartView(store:store,question:question) }
                            }
                            if let links=teaching.questionLinks?.first(where: { $0.questionID == id }) {
                                ProfessionalQuestionCardsView(primaryIDs:links.primaryCardIDs,supplementIDs:links.supplementCardIDs,guideIDs:links.guideConceptIDs,teaching:teaching,bank:bank,subject:store.subject,baseDirectory:store.professionalLearningBaseDirectory)
                            }
                        }
                    }
                }
            }
            Section {
                Text("只浏览资料，不提交答案，也不改变成绩、复习日期或掌握状态。")
                    .font(.footnote).foregroundStyle(.secondary)
                if leaf.duplicateGroup != nil {
                    Text("本题已标记明确重复关系；原出处仍保留，统计同时列出出现次数和归并后条目。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("资料原题")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pdfPresented) {
            SyllabusPDFView(source: source, page: leaf.page)
        }
    }
}

private struct SyllabusPDFView: View {
    let source: ConceptSyllabusTree.Source
    let page: Int
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    SyllabusPDFCanvas(document: document, firstPage: page - 1)
                } else if let loadError {
                    ContentUnavailableView("暂时无法打开原PDF", systemImage: "doc.questionmark", description: Text(loadError))
                } else {
                    ProgressView("核对原PDF后打开…")
                }
            }
            .navigationTitle("原PDF · 第 \(page) 页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .task(id: source.sha256 + ":" + String(page)) {
                do {
                    let bytes = try await Task.detached(priority: .userInitiated) {
                        try SyllabusPDFBytes.read(source: source)
                    }.value
                    guard !Task.isCancelled else { return }
                    guard let loaded = PDFDocument(data: bytes) else { throw ExamError.invalid("资料不是可读取的PDF。") }
                    if loaded.isLocked {
                        guard let password = source.password, loaded.unlock(withPassword: password) else {
                            throw ExamError.invalid("PDF尚未解锁，请核对课程包中的本机资料密码。")
                        }
                    }
                    guard page > 0, page <= loaded.pageCount else { throw ExamError.invalid("这条来源页码超出原PDF范围，原题仍保留以便核对。") }
                    document = loaded
                } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
            }
        }
    }
}

private enum SyllabusPDFBytes {
    static func read(source: ConceptSyllabusTree.Source) throws -> Data {
        guard ConceptSyllabusTree.validPDFFileName(source.fileName), ExamContent.isHash(source.sha256),
              let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ExamError.invalid("原PDF的本机文件名或身份无效。")
        }
        let directory = root.resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appendingPathComponent(source.fileName).resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.path else { throw ExamError.invalid("原PDF必须位于App自己的文件目录。") }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ExamError.invalid("请先把“\(source.fileName)”放入“我的 iPhone → 背词”文件目录，再打开本页。")
        }
        let limit = 120 * 1_024 * 1_024
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= limit else {
            throw ExamError.invalid("原PDF不是普通文件，或超过120MiB读取上限。")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data(), hasher = SHA256()
        data.reserveCapacity(size)
        while let part = try handle.read(upToCount: 1_024 * 1_024), !part.isEmpty {
            guard data.count + part.count <= limit else { throw ExamError.invalid("原PDF读取过程中超出大小上限。") }
            data.append(part); hasher.update(data: part)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == source.sha256 else {
            throw ExamError.invalid("PDF与课程记录的版本不一致，请放入课程对应的原文件；没有改动学习记录。")
        }
        return data
    }
}

private struct SyllabusPDFCanvas: UIViewRepresentable {
    let document: PDFDocument
    let firstPage: Int
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        if let page = document.page(at: firstPage) { view.go(to: page) }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            if let page = document.page(at: firstPage) { view.go(to: page) }
        }
    }
}

