import SwiftUI
import Foundation
import UIKit
import UniformTypeIdentifiers

/// One visible assessment is one existing stable reference. Scheduling, writes and
/// duplicate-token handling all belong to RefinedMemoryStore.
@MainActor
struct RefinedMemoryView: View {
    let subject: ConceptSubject
    @ObservedObject var store: RefinedMemoryStore
    private let studyControl: Binding<Bool>?
    var onLearningChanged: (Bool) -> Void = { _ in }
    var onReturnToOriginal: (() -> Void)? = nil
    var onReadChapter: (() -> Void)? = nil
    var onStart: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var enabled
    @State private var directory: RefinedDirectoryMode?
    @State private var confirming: UUID?
    @State private var visible = false
    @State private var notifiedStart = false
    @State private var active = false
    @State private var localStudy = false
    private var isStudying: Bool { studyControl?.wrappedValue ?? localStudy }

    init(subject: ConceptSubject, store: RefinedMemoryStore,
         studying: Binding<Bool>? = nil,
         onStart: @escaping () -> Void = {},
         onLearningChanged: @escaping (Bool) -> Void = { _ in },
         onReturnToOriginal: (() -> Void)? = nil,
         onReadChapter: (() -> Void)? = nil) {
        self.subject = subject; self.store = store; self.onLearningChanged = onLearningChanged
        self.onReturnToOriginal = onReturnToOriginal; self.onReadChapter = onReadChapter
        self.onStart = onStart; studyControl = studying
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(subject.shortTitle) · 逐问背卡").font(.subheadline.weight(.medium))
                Spacer()
                if isStudying, let p = store.presentation, !store.blocked {
                    Button("熟记") { confirming = p.id }
                        .accessibilityLabel("将当前小问标为熟记")
                        .accessibilityIdentifier("refined-familiar")
                }
                Menu {
                    if let onReadChapter {
                        Button("读下一章", systemImage: "book") { onReadChapter() }
                    }
                    if isStudying {
                        Button("回卡片首页", systemImage: "house") { setStudying(false) }
                    }
                    Button("全部小问", systemImage: "list.bullet") { directory = .all }
                    Button("已熟记", systemImage: "checkmark.circle") { directory = .familiar }
                    if let onReturnToOriginal {
                        Button("返回原卡", systemImage: "arrow.uturn.backward") { report(false); onReturnToOriginal() }
                    }
                } label: {
                    Label("目录", systemImage: "list.bullet").font(.subheadline)
                }.accessibilityIdentifier("refined-directory")
            }.padding(.horizontal).frame(minHeight: 44)
            Divider()
            if store.blocked || store.course == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.title2)
                    Text(store.error ?? "新版课程或练习记录未能读取。").multilineTextAlignment(.center)
                    if let onReturnToOriginal { Button("返回原卡", action: onReturnToOriginal) }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isStudying, let item = store.current, let p = store.presentation {
                question(item, p)
            } else {
                idle
            }
            if !store.blocked, store.course != nil, let error = store.error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("refined-feedback").padding(8)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { visible = true; notifiedStart = isStudying; updateActivity() }
        .onDisappear { visible = false; notifiedStart = false; report(false) }
        .onChange(of: scenePhase) { _,_ in updateActivity() }
        .onChange(of: directory) { _,_ in updateActivity() }
        .onChange(of: confirming) { _,_ in updateActivity() }
        .onChange(of: enabled) { _,_ in updateActivity() }
        .onChange(of: isStudying) { _,newValue in if !newValue { notifiedStart = false }; updateActivity() }
        .onChange(of: store.presentation?.id) { _,newToken in
            if newToken == nil && !store.blocked { setStudying(false) }
            updateActivity()
        }
        .onChange(of: store.blocked) { _,_ in updateActivity() }
        .sheet(item: $directory) { selection in
            NavigationStack { RefinedDirectory(store: store, initial: selection) }
        }
        .confirmationDialog("将这一个小问标为熟记？", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), titleVisibility: .visible, presenting: confirming) { token in
            Button("标为熟记") { confirming = nil; store.markFamiliar(token: token) }
            Button("取消", role: .cancel) { confirming = nil }
        } message: { _ in Text("之后可在「目录 → 已熟记」重新加入队列。") }
    }

    private func report(_ value: Bool) {
        guard active != value else { return }
        active = value; onLearningChanged(value)
    }

    private func updateActivity() {
        report(visible && enabled && isStudying && scenePhase == .active && directory == nil &&
               confirming == nil && !store.blocked &&
               store.current != nil && store.presentation != nil)
    }

    private func setStudying(_ value: Bool) {
        if let studyControl { studyControl.wrappedValue = value } else { localStudy = value }
        if !value { notifiedStart = false; report(false) }
    }

    private func startFeedback() {
        if !notifiedStart { notifiedStart = true; onStart() }
    }

    private var idle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let stats = store.stats()
                Text("继续背卡").font(.title2.weight(.semibold))
                if let stats {
                    Text("已接触 \(stats.introduced) / \(stats.total) 问　·　到期 \(stats.due) 问")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: Double(stats.introduced), total: Double(max(1, stats.total)))
                }
                Button {
                    store.start()
                    if store.current != nil { setStudying(true); startFeedback() }
                } label: {
                    Label("继续背卡", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("refined-start")
                Button("已熟记 \(store.familiarRefs.count) 问") { directory = .familiar }
                    .accessibilityIdentifier("refined-known")
            }.frame(maxWidth: 600, alignment: .leading).padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func question(_ item: RefinedMemoryStore.Entry, _ p: ProfessionalRecallPresentation) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                RefinedFace(subject: subject, item: item, revealed: p.revealed)
                    .frame(maxWidth: 650, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }.id(p.id)
            Divider()
            VStack(spacing: 8) {
                if p.revealed {
                    let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                    actions {
                        Button { startFeedback(); store.grade(remembered: false, token: p.id) } label: {
                            Text("没记住").frame(maxWidth: .infinity, minHeight: 34)
                        }.buttonStyle(.bordered).accessibilityIdentifier("refined-again")
                        Button { startFeedback(); store.grade(remembered: true, token: p.id) } label: {
                            Text("答对了").frame(maxWidth: .infinity, minHeight: 34)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("refined-remembered")
                    }
                } else {
                    Button { startFeedback(); store.reveal(token: p.id) } label: {
                        Text("翻答案").frame(maxWidth: .infinity, minHeight: 34)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("refined-reveal")
                }
                HStack {
                    Text("只评当前小问").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("稍后") { startFeedback(); store.postpone(token: p.id) }
                        .font(.subheadline).disabled(!store.canPostpone)
                        .accessibilityIdentifier("refined-postpone")
                }
            }.padding(.horizontal).padding(.vertical, 8)
                .background(Color(uiColor: .systemBackground))
        }
    }
}

private enum RefinedDirectoryMode: String, Identifiable { case all, supplement, familiar; var id: String { rawValue } }

@MainActor
private struct RefinedDirectory: View {
    @ObservedObject var store: RefinedMemoryStore
    @State private var mode: RefinedDirectoryMode
    @State private var search = ""
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    init(store: RefinedMemoryStore, initial: RefinedDirectoryMode) {
        self.store = store; _mode = State(initialValue: initial)
    }

    private var filtered: [RefinedMemoryStore.Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope: Set<String>?
        switch mode {
        case .all: scope = nil
        case .supplement: scope = store.supplementRefs
        case .familiar: scope = store.familiarRefs
        }
        return store.entries.filter { e in
            (scope?.contains(e.id) ?? true) && (query.isEmpty ||
                [e.group.title, RefinedFace.chapter(e.group.chapter), e.row.q, e.id].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $mode) {
                    Text("全部小问").tag(RefinedDirectoryMode.all)
                    if !store.supplementRefs.isEmpty { Text("本次调整").tag(RefinedDirectoryMode.supplement) }
                    Text("已熟记").tag(RefinedDirectoryMode.familiar)
                }.pickerStyle(.segmented)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            let entries = filtered
            if entries.isEmpty {
                Text(search.isEmpty && mode == .familiar ? "还没有标为熟记的小问。" : "没有匹配的小问。").foregroundStyle(.secondary)
            } else {
                let groups = Dictionary(grouping:entries,by: { $0.group.key })
                let familiar = store.familiarRefs
                ForEach(store.course?.cards ?? []) { group in
                    if let items = groups[group.key] {
                        Section(RefinedFace.chapter(group.chapter) + " · " + group.title) {
                            ForEach(items) { item in
                                NavigationLink {
                                    RefinedReference(store: store, item: item, didRequeue: { message = $0 })
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.row.q).font(.body)
                                        if familiar.contains(item.id) {
                                            Label("已熟记", systemImage: "checkmark.circle").font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("小问目录").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜章节、知识点或问法")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
    }
}

@MainActor
private struct RefinedReference: View {
    @ObservedObject var store: RefinedMemoryStore
    let item: RefinedMemoryStore.Entry
    let didRequeue: (String) -> Void
    @State private var shown = false
    @State private var requeued = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RefinedFace(subject: store.subject, item: item, revealed: shown)
                Button(shown ? "遮住答案" : "查看答案（不计成绩）") { shown.toggle() }.buttonStyle(.bordered)
                Button {
                    store.requeue(ref: item.id)
                    if !store.blocked && store.error == nil {
                        requeued = true
                        didRequeue("「\(item.group.title)」的这一个小问已重新加入队列。")
                    }
                } label: { Label(requeued ? "已重新加入队列" : "重新加入队列", systemImage: "arrow.uturn.backward.circle") }
                    .buttonStyle(.borderedProminent).disabled(requeued || store.blocked)
                    .accessibilityIdentifier("refined-requeue")
                if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }.frame(maxWidth: 650, alignment: .leading).padding()
        }.navigationTitle("查看一个小问").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct RefinedFace: View {
    let subject: ConceptSubject
    let item: RefinedMemoryStore.Entry
    let revealed: Bool
    @State private var sources = false
    @State private var practicingFirstMove = false
    @State private var copiedPrompt: String?
    private var firstMoveLesson: PowerFirstMoveLesson? {
        PowerFirstMoveLesson.lesson(for: item.row)
    }
    static func chapter(_ code: String) -> String {
        ["hardware":"计算机硬件基础", "software":"计算机软件基础", "network":"网络技术基础",
         "security":"信息安全技术", "frontier":"信息新技术"][code] ?? code
    }
    private var how: String {
        switch item.row.how { case "A": return "A 认对就过"; case "B": return "B 想一步"; case "C": return "C 换条件再判"; default: return item.row.how }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.chapter(item.group.chapter)).font(.caption).foregroundStyle(.secondary)
            Text(item.group.title).font(.headline)
            HStack(spacing: 8) {
                Text(how).font(.caption.weight(.medium)).padding(.vertical, 3).padding(.horizontal, 8)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                Text(item.group.evidence.label == "新增考点" ? "本次 · 新增考点" :
                        (item.group.evidence.label == "本次修订" ? "本次修订" : "上版 · \(item.group.evidence.label)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(RefinedText.render(item.row, answer: false))
                .font(.title3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("refined-current-question")
            if firstMoveLesson != nil, !revealed {
                Text("看到这个条件，第一时间想到什么？")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            if revealed {
                Divider()
                Text(RefinedText.render(item.row, answer: true))
                    .font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityIdentifier("refined-current-answer")
                computerIllustration
                if let recognize = item.row.recognize, !recognize.isEmpty {
                    Text("只认读，不要求默写").font(.caption).foregroundStyle(.secondary)
                    Text(recognize).font(.body)
                }
                if !item.row.note.isEmpty {
                    Text(item.row.note).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let firstMoveLesson {
                    DisclosureGroup("看讲解") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(firstMoveLesson.explanation)
                            Text(firstMoveLesson.example)
                        }.font(.subheadline).padding(.vertical, 5)
                    }.accessibilityIdentifier("refined-first-move-explain")
                    Button("换条件练起手") { practicingFirstMove = true }
                        .accessibilityIdentifier("refined-first-move-practice")
                }
                DisclosureGroup(isExpanded: $sources) {
                    Text(item.group.evidence.detail).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } label: {
                    Text(["新增考点","本次修订"].contains(item.group.evidence.label) ? "本问依据" : "上版卡组依据 · \(item.group.evidence.label)")
                        .font(.footnote)
                }
                Menu {
                    Button("复制讲解指令") { copyPrompt(.explain) }
                    Button("复制改卡指令") { copyPrompt(.rewrite) }
                } label: {
                    Label("AI 辅助", systemImage: "text.bubble").font(.footnote)
                }
                if let copiedPrompt { Text(copiedPrompt).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $practicingFirstMove) {
            if let firstMoveLesson, revealed {
                PowerFirstMovePractice(lesson: firstMoveLesson)
            }
        }
    }

    private func copyPrompt(_ purpose: CardLookupSession.PromptPurpose) {
        let prompt = CardLookupSession.prompt(subject: subject.shortTitle, title: item.group.title,
                                              question: item.row.q, answer: item.row.a, purpose: purpose)
        UIPasteboard.general.setItems([[UTType.plainText.identifier: prompt]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        switch purpose {
        case .explain: copiedPrompt = "已复制讲解指令"
        case .rewrite: copiedPrompt = "已复制改卡指令"
        }
    }

    @ViewBuilder private var computerIllustration: some View {
        switch item.row.ref {
        case "hw-ieee-layout#1":
            ieeeRow("单精度 32 位", [1,8,23])
            ieeeRow("双精度 64 位", [1,11,52])
            DisclosureGroup("讲义字段原图") { cardImage("ieee-fields",label:"基础讲义的单精度与双精度三字段原图") }
        case "hw-ieee-layout#2":
            Text("符号位 S：0 为正号，1 为负号。")
                .font(.body).foregroundStyle(Color.accentColor)
        case "hw-von-neumann#2":
            cardImage("classic-five-parts", label:"宝典原图。实线为数据线，虚线为控制线与反馈线。")
            Text("实线：外部 → 输入设备 → 运算器 → 输出设备 → 外部；运算器 ↔ 存储器；存储器 → 控制器。")
                .font(.subheadline)
            Text("虚线：控制器与输入设备、输出设备、运算器、存储器分别双向相连。")
                .font(.subheadline)
        default: EmptyView()
        }
    }

    private func ieeeRow(_ title: String, _ bits: [Int]) -> some View {
        let labels = ["符号", "阶码", "尾数"]
        let colors: [Color] = [.orange,.blue,.green]
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            HStack(spacing: 4) {
                ForEach(bits.indices, id: \.self) { i in
                    VStack(spacing: 2) {
                        Text("\(bits[i]) 位").font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text(labels[i]).font(.caption)
                    }.frame(maxWidth: .infinity).padding(6)
                        .background(colors[i].opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func cardImage(_ name: String, label: String) -> some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "RefinedMemory/Diagrams"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel(label)
        }
    }
}

/// Optional teaching content is tied to the exact current card text and sits outside the recall deck.
@MainActor
private struct PowerFirstMoveLesson: Decodable {
    let expectedQ, expectedA, explanation, example, question, firstFeedback, feedback: String
    let starts, options: [String]
    let firstKey, key: Int

    private static let library: [String: PowerFirstMoveLesson] = {
        guard let url = Bundle.main.url(forResource: "power-first-move", withExtension: "json",
                                        subdirectory: "RefinedMemory"),
              let bytes = try? Data(contentsOf: url), bytes.count <= 262_144,
              let catalog = try? JSONDecoder().decode([String: PowerFirstMoveLesson].self, from: bytes)
        else { return [:] }
        return catalog
    }()

    static func lesson(for row: RefinedMemoryCourse.Row) -> Self? {
        guard let lesson = library[row.ref], lesson.expectedQ == row.q, lesson.expectedA == row.a,
              lesson.starts.count >= 2, lesson.options.count >= 2,
              lesson.starts.indices.contains(lesson.firstKey), lesson.options.indices.contains(lesson.key)
        else { return nil }
        return lesson
    }
}

/// Temporary two-step practice. The card's grading buttons own all writes to the learning record.
@MainActor
private struct PowerFirstMovePractice: View {
    let lesson: PowerFirstMoveLesson
    @Environment(\.dismiss) private var dismiss
    @State private var firstChoice: Int?
    @State private var answerChoice: Int?
    @State private var firstConfirmed = false
    @State private var finished = false

    private var options: [String] { firstConfirmed ? lesson.options : lesson.starts }
    private var selected: Int? { firstConfirmed ? answerChoice : firstChoice }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(lesson.question).font(.title3)
                    Text(firstConfirmed ? "再选结论" : "第一时间先想到什么？").font(.headline)
                    ForEach(options.indices, id: \.self) { index in
                        Button {
                            if firstConfirmed { answerChoice = index } else { firstChoice = index }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: selected == index ? "checkmark.circle.fill" : "circle")
                                Text(options[index]).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.frame(minHeight: 32)
                        }.buttonStyle(.bordered).disabled(finished)
                            .accessibilityAddTraits(selected == index ? .isSelected : [])
                    }
                    if finished {
                        Text((firstChoice == lesson.firstKey ? "起手正确。" : "先改起手。") + lesson.firstFeedback)
                        Text((answerChoice == lesson.key ? "结论正确。" : "再核对结论。") + lesson.feedback)
                        Button("回到卡片") { dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(firstConfirmed ? "交卷核对" : "确认第一步") {
                            if firstConfirmed { finished = true } else { firstConfirmed = true }
                        }.buttonStyle(.borderedProminent).disabled(selected == nil)
                    }
                }.frame(maxWidth: 640, alignment: .leading).padding()
            }
            .navigationTitle("换条件练起手").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

@MainActor
private enum RefinedText {
    /// Colour offsets in the frozen documents are UTF-16; 'start', if present, counts Unicode scalars.
    /// Apply source spans before inserting display line breaks. A recognised paraphrase never inherits a book colour.
    static func render(_ row: RefinedMemoryCourse.Row, answer: Bool) -> AttributedString {
        let raw = answer ? row.a : row.q, ns = raw as NSString
        var flags = [UInt8](repeating: 0, count: ns.length)
        func paint(_ range: NSRange, _ flag: UInt8) {
            guard range.location != NSNotFound, range.length > 0, range.location >= 0,
                  range.length <= ns.length, range.location <= ns.length - range.length else { return }
            for k in range.location..<NSMaxRange(range) { flags[k] |= flag }
        }
        for mark in row.colors where mark.field == (answer ? "a" : "q") && !mark.text.isEmpty {
            let bit: UInt8
            switch mark.color {
            case "red": bit = 1; case "yellow": bit = 2; case "both": bit = 3
            case "green": bit = 8; case "blue","cyan","teal": bit = 16; default: continue
            }
            let length = (mark.text as NSString).length
            var specified = mark.location
            if specified == nil, let start = mark.start {
                guard start >= 0, start <= raw.unicodeScalars.count,
                      let idx = raw.unicodeScalars.index(raw.unicodeScalars.startIndex, offsetBy: start, limitedBy: raw.unicodeScalars.endIndex)
                else { continue }
                specified = raw[..<idx].utf16.count
            }
            if let loc = specified {
                let r = NSRange(location: loc, length: length)
                if loc >= 0 && length <= ns.length && loc <= ns.length - length && ns.substring(with: r) == mark.text { paint(r,bit) }
            } else {
                var pos = 0
                while pos < ns.length {
                    let r = ns.range(of: mark.text, options: .literal, range: NSRange(location: pos, length: ns.length - pos))
                    if r.location == NSNotFound { break }
                    paint(r,bit); pos = NSMaxRange(r)
                }
            }
        }
        if answer, let core = row.core {
            var offset = 0
            if core.isEmpty { paint(NSRange(location: 0, length: ns.length),4) }
            for word in core where !word.isEmpty {
                let r = ns.range(of: word, options: .literal, range: NSRange(location: offset, length: ns.length - offset))
                guard r.location != NSNotFound else { continue }
                paint(r,4); offset = NSMaxRange(r)
            }
        } else if answer && row.how != "A", let regex = try? NSRegularExpression(pattern: #"(?:^|[；;。\n])([^；;。\n→]+)→"#) {
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let r = match.range(at: 1), prefix = ns.substring(with: r) as NSString
                let colon = prefix.rangeOfCharacter(from: CharacterSet(charactersIn: "：:"), options: .backwards)
                let skip = colon.location == NSNotFound ? 0 : NSMaxRange(colon)
                paint(NSRange(location: r.location + skip,length: r.length - skip),4)
            }
        }
        var result = AttributedString(), chunk = "", last: UInt8?, offset = 0
        func append() {
            guard !chunk.isEmpty, let bit = last else { return }
            var part = AttributedString(chunk)
            if bit & 4 != 0 { part.inlinePresentationIntent = .stronglyEmphasized }
            if bit & 1 != 0 { part.foregroundColor = .red }
            else if bit & 8 != 0 { part.foregroundColor = .green }
            else if bit & 16 != 0 { part.foregroundColor = .blue }
            if bit & 2 != 0 { part.backgroundColor = Color.yellow.opacity(0.5) }
            result.append(part); chunk = ""
        }
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx], next = raw.index(after: idx), bits = flags[offset]
            if last != bits { append(); last = bits }
            chunk.append(ch)
            if answer && (ch == "；" || ch == ";") && next < raw.endIndex && raw[next] != "\n" { chunk.append("\n") }
            offset += String(ch).utf16.count; idx = next
        }
        append(); return result
    }
}
