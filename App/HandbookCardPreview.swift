#if DEBUG
import Foundation
import SwiftUI
import StudyCore

private func handbookPreviewTrace(_ stage: String, _ extra: [String: Any] = [:]) {
    guard let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-id=") }),
          let id = UUID(uuidString: String(raw.dropFirst("--capture-id=".count))) else { return }
    let value = extra.merging(["stage": stage], uniquingKeysWith: { _, new in new })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("handbook-card-preview-debug-" + id.uuidString.lowercased() + ".json")
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
}

struct HandbookCardPreviewObservation: Equatable {
    let mode: String
    let cardID: String?
    let revealed: Bool
    let ratingCount: Int
    let ratingEnabled: Bool
    let sourceFilesPresent: Bool
    let recallCueMode: Bool
    let fullScreen: Bool
    let sourceSheetPresented: Bool
    let frequencyLabel: String?
}
struct HandbookSourcePreviewObservation: Equatable {
    let sourceID: String
    let title: String
    let pageNumbers: [Int]
    let missingPageNumbers: [Int]
}
struct HandbookCardPreviewState {
    var didRender: (HandbookCardPreviewObservation) -> Void = { _ in }
    var scrollTarget: String? = nil
    var sourceSheet: String? = nil
    var sourceSelectionID: String? = nil
    var didRenderSources: (HandbookSourcePreviewObservation) -> Void = { _ in }
    var diagramExpanded: Bool? = nil
    var didRenderDiagram: (String, Bool) -> Void = { _, _ in }
    var guideHelpExpanded: Bool? = nil
    var didRenderGuide: (String, Bool) -> Void = { _, _ in }
    var didRenderGuideHelp: (String, Bool) -> Void = { _, _ in }
}
private struct HandbookCardPreviewKey: EnvironmentKey {
    static let defaultValue = HandbookCardPreviewState()
}
extension EnvironmentValues {
    var handbookCardPreview: HandbookCardPreviewState {
        get { self[HandbookCardPreviewKey.self] }
        set { self[HandbookCardPreviewKey.self] = newValue }
    }
}

@MainActor private final class HandbookCardPreviewFixture: ObservableObject {
    let root: URL
    let subject: ConceptSubject
    let selectedCase: String
    let store: HandbookWordStore
    let handbookComputer: HandbookWordStore
    let handbookPower: HandbookWordStore
    let legacyComputer: ConceptStore
    let legacyPower: ConceptStore
    let expectedCardID: String?
    let expectedToken: UUID?
    let expectedRatings: Int
    static let cases: Set<String> = ["front", "back", "table", "table-front", "long", "resume", "postponed", "completed", "missing-source", "normal-front", "normal-back", "focus-toggle", "multi-source", "lecture-only", "multi-source-pages", "lecture-only-pages", "diagram-branch", "diagram-flow", "diagram-switch"]

    init() {
        handbookPreviewTrace("fixture-begin")
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            args.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
        }
        let selected = argument("--case") ?? "front"
        precondition(Self.cases.contains(selected), "Unknown synthetic handbook fixture")
        let rawSubject = argument("--subject") ?? "computer"
        guard let selectedSubject = ConceptSubject(rawValue: rawSubject) else {
            preconditionFailure("Unknown synthetic handbook subject")
        }
        subject = selectedSubject
        selectedCase = selected
        root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-handbook-" + rawSubject + "-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let table = ["table", "table-front"].contains(selected)
            let long = selected == "long"
            let power = selectedSubject == .power
            let sourcePage = power ? 102 : 2
            let archivePage = power ? 117 : 3
            let supplemented = selected.hasPrefix("multi-source") || selected.hasPrefix("lecture-only")
            let lectureOnly = selected.hasPrefix("lecture-only")
            var blocks: [[String: Any]]
            if table {
                blocks = [["title": "四个阶段放在同一张卡", "kind": "table", "columns": ["阶段", "主要部件"],
                           "rows": [["第一阶段", "合成部件甲"], ["第二阶段", "合成部件乙"], ["第三阶段", "合成组合部件丙"], ["第四阶段", "合成的大规模组合部件丁"]], "collapsed": false]]
            } else if long {
                blocks = [["title": "分行阅读", "kind": "bullets", "items": [
                    "先说清这个知识点的含义，再记住它适用的条件。",
                    "有关联的内容放在同一组，比较时看清不同之处。",
                    "较长的句子应当自然换行，不挤成一整块小字。",
                    "每一行都保持足够的间距，方便在手机上扫读。",
                    "原例和补充内容可以展开，主背答案保持简洁。"], "collapsed": false],
                          ["title": "按需展开的合成补充", "kind": "text", "text": "这里只是排版样式检查，不含用户的真实学习材料。", "collapsed": true]]
            } else {
                blocks = [["title": "记住三件事", "kind": "keyValues", "rows": [["时间", "2001年"], ["地点", "合成实验室"], ["名称", "DEMO"]], "collapsed": false]]
            }
            if power {
                if table {
                    blocks = [["title": "纯合成原表留空与符号", "kind": "table", "columns": ["", "", ""],
                               "rows": [["情形甲", "U_*", ""], ["", "A_1 * B_2", "**双星号**"],
                                        ["情形乙", "_下划线_", "原样保留"]], "collapsed": false]]
                } else if long {
                    blocks = [["title": "纯合成文字 · 不是讲义", "kind": "bullets", "items": [
                        "这一段只检查电力系统页面排版，不提供真实电力知识。",
                        "字面量 **双星号** 应当完整显示，不能被自动当成粗体。",
                        "字面量 _下划线_ 和 U_* 不应丢失字符。",
                        "A_1 * B_2 是合成符号，不表示已经核实的电力公式。",
                        "长文字自然换行，原例和校注仍按需展开。"], "collapsed": false],
                              ["title": "合成补充 _甲_", "kind": "text", "text": "**原样保留**：A_1 * B_2。纯合成测试。", "collapsed": true]]
                } else {
                    blocks = [["title": "纯合成提示 · 不是讲义", "kind": "bullets", "items": [
                        "（1）项目甲：U_*；项目乙：A_1 * B_2。", "项目丙: **合成** 与 _示例_。"], "collapsed": false],
                        ["title": "纯合成符号记录", "kind": "keyValues", "rows": [["符号甲", "U_*"],
                        ["符号乙", "A_1 * B_2"], ["字面标记", "**合成** 与 _示例_"]], "collapsed": false]]
                }
            }
            if supplemented {
                blocks = [
                    ["title": lectureOnly ? "讲义补充" : "本卡补充", "kind": "text",
                     "text": "适用条件：只用于合成预览；核对方式：按来源书名和物理页号查阅。", "collapsed": false],
                    ["title": "补充原例 · 合成讲义甲", "kind": "text",
                     "text": "原例：甲、乙两项合成记录并列；说明：这是普通文字分块。", "collapsed": false]]
            }
            if selected == "diagram-branch" || selected == "diagram-switch" {
                blocks = [["title": "展开合成分支图", "kind": "diagram", "text": "branch",
                           "items": ["合成根节点", "合成分支甲", "合成分支乙"], "collapsed": true]]
            } else if selected == "diagram-flow" {
                blocks = [["title": "展开合成流程图", "kind": "diagram", "text": "flow",
                           "items": ["合成起点", "合成步骤甲", "合成步骤乙", "合成终点"], "collapsed": true]]
            }
            func card(_ id: String, second: Bool = false) -> [String: Any] {
                let title: String
                let prompt: String
                let summary: String
                if supplemented {
                    title = lectureOnly ? "合成卡：仅讲义出处" : "合成卡：多来源补充"
                    prompt = "合成记录的条件与核对方式是什么？"
                    summary = "纯合成内容，不含真实资料。"
                } else if second {
                    title = "合成卡：另一知识点"
                    prompt = "这个知识点要记住哪件事？"
                    summary = "这是第二个合成知识点，供检查暂缓和自动续背。"
                } else if power {
                    title = table ? "合成卡：符号对照" : "合成卡：量与符号"
                    prompt = "纯合成记录中的 U_* 与 A_1 * B_2 怎样原样写出？"
                    summary = "纯合成：U_*、A_1 * B_2、**双星号** 与 _下划线_ 均按字面保留。"
                } else {
                    title = table ? "合成卡：演进阶段" : (long ? "合成卡：长内容排版" : "合成卡：设备的诞生")
                    prompt = table ? "四个阶段分别采用什么部件？" : "它在什么时候、什么地方诞生？名称是什么？"
                    summary = table ? "按主要部件划分，四个阶段一起比较。" : "这是合成样式；仅用于检查手机排版;不含真实课程。"
                }
                let examples: [[String: Any]] = power && !supplemented ? [["title": "合成原例 _甲_", "prompt": "照写 **字面值** 与 U_*。",
                    "steps": ["保留 A_1 中的下划线。", "保留 A_1 * B_2 中的星号。"], "answer": "**字面值**；U_*。",
                    "sourcePage": sourcePage, "sourceIssueNote": "纯合成校注 _原样_，不是讲义结论。"]] : []
                let notes = [power ? "纯合成校注：**标记** 和 _符号_ 原样显示。不是讲义原文。" : "纯合成测试，不是宝典原文，也不会写入个人学习记录。"]
                var cardBlocks = blocks
                if selected == "diagram-switch" && second {
                    cardBlocks = [["title": "第二张合成分支图", "kind": "diagram", "text": "branch",
                                   "items": ["第二张根节点", "第二张分支甲", "第二张分支乙"], "collapsed": true]]
                }
                var result: [String: Any] = ["id": id, "sourceGroupIDs": [id + "-group"], "topicNumber": 1, "chapterID": "synthetic-chapter",
                        "title": title, "prompt": prompt, "answerSummary": summary, "blocks": cardBlocks,
                        "sourcePages": lectureOnly ? [] : [sourcePage], "examples": examples, "sourceNotes": notes]
                if supplemented { result["sourceReferences"] = [["sourceID": "synthetic-lecture", "page": 7]] }
                return result
            }
            var cards = [card("synthetic-handbook-first")]
            if ["resume", "postponed", "completed", "diagram-switch"].contains(selected) { cards.append(card("synthetic-handbook-second", second: true)) }
            var package: [String: Any] = ["format": "xkl-handbook-cards-v1", "id": "synthetic-handbook-package", "subject": rawSubject,
                "title": "纯合成卡组 · 不含用户资料", "revision": "synthetic-1",
                "source": ["title": "纯合成来源", "fileName": "synthetic.pdf", "sha256": String(repeating: "b", count: 64), "pdfPageCount": archivePage, "includedPages": [sourcePage, archivePage]],
                "chapters": [["id": "synthetic-chapter", "title": "合成章节 · 仅用于页面检查"]], "cards": cards]
            if ["front", "back", "normal-front"].contains(selected) {
                package["topicFrequencies"] = [["topicNumber": 1, "stars": 4, "sourcePage": sourcePage,
                    "cardIDs": selected == "normal-front" ? [] : ["synthetic-handbook-first"]]]
            }
            if ["front", "back"].contains(selected) {
                package["memoryGuides"] = [["cardID": "synthetic-handbook-first",
                    "explanation": "仅用于验证简短骨架，不含真实课程。",
                    "rows": [["cue": "合成提示甲", "answer": "合成答案甲"],
                             ["cue": "合成提示乙", "answer": "合成答案乙"],
                             ["cue": "合成提示丙", "answer": "合成答案丙"],
                             ["cue": "合成提示丁", "answer": "合成答案丁"],
                             ["cue": "合成提示戊", "answer": "合成答案戊"],
                             ["cue": "合成提示己", "answer": "合成答案己"]],
                    "mnemonic": "合成记忆提示"]]
            }
            var sourcePages: [[String: Any]] = [["number": archivePage, "asset": ["sha256": String(repeating: "c", count: 64), "mimeType": "image/png", "byteCount": 128,
                "pixelWidth": 120, "pixelHeight": 160, "crop": ["x": 0, "y": 0, "width": 1, "height": 1], "altText": "纯合成档案原页，仅查阅，不在任何卡片的调度中。"]]]
            if selected == "missing-source" {
                sourcePages.append(["number": sourcePage, "asset": ["sha256": String(repeating: "a", count: 64), "mimeType": "image/png", "byteCount": 128,
                    "pixelWidth": 120, "pixelHeight": 160, "crop": ["x": 0, "y": 0, "width": 1, "height": 1], "altText": "故意缺失的合成原页，不影响文字卡自评。"]])
            }
            package["sourcePages"] = sourcePages
            if supplemented {
                package["additionalSources"] = [["id": "synthetic-lecture", "source": [
                    "title": "纯合成讲义甲", "fileName": "synthetic-lecture.pdf", "sha256": String(repeating: "d", count: 64),
                    "pdfPageCount": 9, "includedPages": [7, 9]],
                    "sourcePages": [["number": 7, "asset": ["sha256": String(repeating: "e", count: 64),
                        "mimeType": "image/jpeg", "byteCount": 128, "pixelWidth": 120, "pixelHeight": 160,
                        "crop": ["x": 0, "y": 0, "width": 1, "height": 1],
                        "altText": "故意缺失的纯合成讲义页，用于验证来源隔离。"]]]]]
            }
            var prepared = HandbookWordStore(subject: selectedSubject, baseDirectory: root, documentsDirectory: root)
            prepared.importData(try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys]))
            handbookPreviewTrace("fixture-imported", ["blocked": prepared.blocked, "error": prepared.error ?? "", "engine": prepared.engine != nil])
            precondition(!prepared.blocked && prepared.error == nil && prepared.engine != nil, "Synthetic card package must import")
            let now = Date()
            prepared.start(now: now)
            handbookPreviewTrace("fixture-started", ["blocked": prepared.blocked, "error": prepared.error ?? "", "card": prepared.engine?.currentCard?.id ?? "nil"])
            precondition(prepared.engine?.presentation != nil, "Synthetic card must start")
            if supplemented || selected.hasPrefix("diagram-") || ["back", "table", "long", "resume", "postponed", "missing-source", "normal-back", "focus-toggle"].contains(selected) {
                prepared.reveal(token: prepared.engine!.presentation!.id, now: now)
            }
            if selected == "resume" {
                let token = prepared.engine!.presentation!.id
                prepared = HandbookWordStore(subject: selectedSubject, baseDirectory: root, documentsDirectory: root)
                precondition(prepared.engine?.presentation?.id == token && prepared.engine?.presentation?.revealed == true,
                             "Back face and presentation token must restore without rating")
            }
            if selected == "postponed" {
                prepared.postpone(token: prepared.engine!.presentation!.id, now: now)
                precondition(prepared.engine?.currentCard?.id == "synthetic-handbook-second" && prepared.engine?.record.attempts.isEmpty == true,
                             "Postponement must move behind another card without rating")
            }
            if selected == "completed" {
                for _ in 0..<2 {
                    let token = prepared.engine!.presentation!.id
                    prepared.reveal(token: token, now: now)
                    prepared.rate(remembered: true, token: token, now: now)
                }
                precondition(prepared.engine?.presentation == nil && prepared.engine?.record.attempts.count == 2,
                             "Self-rated cards must leave this round")
                precondition(prepared.engine?.nextDueAt == nil,
                             "Original English first-known graduation must remain unchanged")
            }
            precondition(!prepared.blocked && prepared.error == nil, "Synthetic card changes must persist")
            store = prepared
            let otherSubject: ConceptSubject = selectedSubject == .computer ? .power : .computer
            let otherStore = HandbookWordStore(subject: otherSubject, baseDirectory: root, documentsDirectory: root)
            precondition(otherStore.engine == nil && !otherStore.blocked && otherStore.error == nil,
                         "Other subject must have its own empty synthetic store")
            handbookComputer = selectedSubject == .computer ? prepared : otherStore
            handbookPower = selectedSubject == .power ? prepared : otherStore
            let computerArchive = ConceptStore(subject: .computer, baseDirectory: root)
            let powerArchive = ConceptStore(subject: .power, baseDirectory: root)
            precondition(computerArchive.engine == nil && powerArchive.engine == nil &&
                         !computerArchive.blocked && !powerArchive.blocked &&
                         computerArchive.error == nil && powerArchive.error == nil,
                         "Legacy stores must be empty and isolated from personal records")
            legacyComputer = computerArchive
            legacyPower = powerArchive
            expectedCardID = prepared.engine?.currentCard?.id
            expectedToken = prepared.engine?.presentation?.id
            expectedRatings = prepared.engine?.record.attempts.count ?? 0
            handbookPreviewTrace("fixture-ready", ["card": expectedCardID ?? "nil", "ratings": expectedRatings])
        } catch { fatalError("Synthetic handbook fixture failed: \(error)") }
    }
}

struct HandbookCardPreview: View {
    @StateObject private var fixture: HandbookCardPreviewFixture
    @State private var selectedSubject: ConceptSubject
    @State private var practicing = false
    @State private var recalling = true
    @State private var observation: HandbookCardPreviewObservation?
    @State private var reported = false
    @State private var fullScreenEnabled: Bool
    @State private var selectedTab = 4
    @State private var togglePhase = 0
    @State private var toggleRecord: ProfessionalRecallRecord?
    @State private var sourceSheet: String?
    @State private var sourceSelectionID: String?
    @State private var sourceObservation: HandbookSourcePreviewObservation?
    @State private var sourcePhase = 0
    @State private var sourceRecord: ProfessionalRecallRecord?
    @State private var diagramRequested: Bool?
    @State private var diagramObserved = false
    @State private var diagramObservedCardID: String?
    @State private var diagramSwitchToken: UUID?
    @State private var diagramScrollTarget: String?
    @State private var diagramPhase = 0
    @State private var diagramRecord: ProfessionalRecallRecord?
    @State private var guideRequested: Bool?
    @State private var guideObservedCardID: String?
    @State private var guideObservedRevealed = false
    @State private var guideHelpObservedCardID: String?
    @State private var guideHelpObserved = false
    @State private var guidePhase = 0
    @State private var guideRecord: ProfessionalRecallRecord?
    @MainActor init() {
        let prepared = HandbookCardPreviewFixture()
        _fixture = StateObject(wrappedValue: prepared)
        _selectedSubject = State(initialValue: prepared.subject)
        _fullScreenEnabled = State(initialValue: !["normal-front", "normal-back", "focus-toggle"].contains(prepared.selectedCase))
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            Text("合成首页，不含学习资料").tabItem { Label("今天", systemImage: "house") }.tag(5)
            ProfessionalCoursesView(computer: fixture.legacyComputer, power: fixture.legacyPower,
                                subject: $selectedSubject, practicing: $practicing, recalling: $recalling,
                                handbookComputer: fixture.handbookComputer, handbookPower: fixture.handbookPower,
                                fullScreenEnabled: $fullScreenEnabled)
                .toolbar(fullScreenEnabled && recalling ? .hidden : .visible, for: .tabBar)
                .tabItem { Label("专业课", systemImage: "books.vertical") }.tag(4)
        }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !(fullScreenEnabled && recalling) {
                    Text("合成学习段栏 · 非真实学习记录").font(.footnote).padding(8)
                }
            }
            .statusBarHidden(fullScreenEnabled && recalling)
            .environment(\.handbookCardPreview, .init(didRender: {
                observation = $0
                handbookPreviewTrace("observed", ["mode": $0.mode, "fullScreen": $0.fullScreen, "card": $0.cardID ?? "nil", "ratings": $0.ratingCount])
            }, scrollTarget: diagramScrollTarget, sourceSheet: sourceSheet, sourceSelectionID: sourceSelectionID, didRenderSources: {
                sourceObservation = $0
            }, diagramExpanded: diagramRequested, didRenderDiagram: { cardID, expanded in
                diagramObservedCardID = cardID; diagramObserved = expanded
            }, guideHelpExpanded: guideRequested, didRenderGuide: { cardID, revealed in
                guideObservedCardID = cardID; guideObservedRevealed = revealed
            }, didRenderGuideHelp: { cardID, expanded in
                guideHelpObservedCardID = cardID; guideHelpObserved = expanded
            }))
            .onAppear { handbookPreviewTrace("root-appeared") }
            .onChange(of: observation) { _, _ in reportIfReady() }
            .onChange(of: sourceObservation) { _, _ in reportIfReady() }
            .onChange(of: guideObservedCardID) { _, _ in reportIfReady() }
            .onChange(of: guideObservedRevealed) { _, _ in reportIfReady() }
            .task { await runFocusToggle() }
            .task { await runSourceNavigation() }
            .task { await runDiagramToggle() }
            .task { await runDiagramSwitch() }
            .task { await runGuideHelpToggle() }
    }
    @MainActor private func waitForFocus(_ value: Bool) async {
        for _ in 0..<200 {
            if observation?.fullScreen == value { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Synthetic fullscreen transition did not render: \(value)")
    }
    @MainActor private func runFocusToggle() async {
        guard fixture.selectedCase == "focus-toggle" else { return }
        await waitForFocus(false)
        toggleRecord = fixture.store.engine?.record
        print("FOCUS_TOGGLE initial record captured")
        fullScreenEnabled = true; await waitForFocus(true)
        precondition(fixture.store.engine?.record == toggleRecord, "Entering fullscreen must not mutate a study record")
        print("FOCUS_TOGGLE entered; record unchanged")
        fullScreenEnabled = false; await waitForFocus(false)
        precondition(fixture.store.engine?.record == toggleRecord, "Exiting fullscreen must keep the exact card/face/queue/grades")
        print("FOCUS_TOGGLE exited; record unchanged")
        fullScreenEnabled = true; await waitForFocus(true)
        precondition(fixture.store.engine?.record == toggleRecord, "Re-entering fullscreen must keep the exact study record")
        togglePhase = 3
        reportIfReady()
    }
    @MainActor private func waitForSource(_ id: String?, pages: [Int] = []) async {
        for _ in 0..<200 {
            if let id {
                if observation?.sourceSheetPresented == true, sourceObservation?.sourceID == id,
                   sourceObservation?.pageNumbers == pages { return }
            } else if observation?.sourceSheetPresented == false { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Synthetic source navigation did not render")
    }
    @MainActor private func runSourceNavigation() async {
        guard fixture.selectedCase.hasSuffix("-pages") else { return }
        await waitForFocus(true)
        sourceRecord = fixture.store.engine?.record
        sourceSheet = "card"
        let lectureOnly = fixture.selectedCase.hasPrefix("lecture-only")
        await waitForSource(lectureOnly ? "additional:synthetic-lecture" : "primary",
                            pages: lectureOnly ? [7] : [fixture.subject == .power ? 102 : 2])
        sourceSelectionID = "additional:synthetic-lecture"
        await waitForSource("additional:synthetic-lecture", pages: [7])
        precondition(fixture.store.engine?.record == sourceRecord, "Switching source must preserve the exact study record")
        sourceSheet = nil
        await waitForSource(nil)
        precondition(fixture.store.engine?.record == sourceRecord, "Closing sources must preserve card, face, queue and grades")
        // Allow the sheet dismissal transition to finish before opening the complete source catalog.
        try? await Task.sleep(for: .milliseconds(600))
        sourceObservation = nil
        sourceSheet = "all"
        await waitForSource("additional:synthetic-lecture", pages: [7, 9])
        precondition(fixture.store.engine?.record == sourceRecord, "Opening all sources must preserve the exact study record")
        sourcePhase = 3
        reportIfReady()
    }
    @MainActor private func waitForDiagram(_ expanded: Bool, cardID: String = "synthetic-handbook-first") async {
        for _ in 0..<200 {
            if diagramObservedCardID == cardID && diagramObserved == expanded { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Synthetic diagram transition did not render")
    }
    @MainActor private func runDiagramToggle() async {
        guard ["diagram-branch", "diagram-flow"].contains(fixture.selectedCase) else { return }
        await waitForFocus(true)
        diagramRecord = fixture.store.engine?.record
        diagramRequested = true; await waitForDiagram(true)
        precondition(fixture.store.engine?.record == diagramRecord, "Opening diagram must preserve the study record")
        diagramRequested = false; await waitForDiagram(false)
        precondition(fixture.store.engine?.record == diagramRecord, "Closing diagram must preserve the study record")
        diagramRequested = true; await waitForDiagram(true)
        precondition(fixture.store.engine?.record == diagramRecord, "Reopening diagram must preserve the study record")
        diagramScrollTarget = "handbook-relationship-diagram"
        try? await Task.sleep(for: .milliseconds(350))
        precondition(fixture.store.engine?.record == diagramRecord, "Scrolling diagram must preserve the study record")
        diagramPhase = 3
        reportIfReady()
    }
    @MainActor private func runDiagramSwitch() async {
        guard fixture.selectedCase == "diagram-switch" else { return }
        await waitForFocus(true)
        let firstRecord = fixture.store.engine?.record
        await waitForDiagram(false)
        diagramRequested = true; await waitForDiagram(true)
        precondition(fixture.store.engine?.record == firstRecord, "Opening first diagram must preserve the study record")
        // Stop controlling expansion before the legal card change; the next block must begin closed.
        diagramRequested = nil
        guard let oldToken = fixture.store.engine?.presentation?.id else { preconditionFailure("Missing first card") }
        fixture.store.postpone(token: oldToken)
        precondition(fixture.store.engine?.currentCard?.id == "synthetic-handbook-second", "Postponement must select the second synthetic card")
        guard let newToken = fixture.store.engine?.presentation?.id else { preconditionFailure("Missing second card") }
        fixture.store.reveal(token: newToken)
        await waitForDiagram(false, cardID: "synthetic-handbook-second")
        diagramSwitchToken = newToken
        diagramRecord = fixture.store.engine?.record
        diagramRequested = true; await waitForDiagram(true, cardID: "synthetic-handbook-second")
        precondition(fixture.store.engine?.record == diagramRecord, "Opening second diagram must preserve the study record")
        diagramRequested = false; await waitForDiagram(false, cardID: "synthetic-handbook-second")
        precondition(fixture.store.engine?.record == diagramRecord, "Closing second diagram must preserve the study record")
        diagramPhase = 3
        reportIfReady()
    }
    @MainActor private func waitForGuideHelp(_ expanded: Bool) async {
        for _ in 0..<200 {
            if guideHelpObservedCardID == "synthetic-handbook-first" && guideHelpObserved == expanded { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Synthetic guide help transition did not render")
    }
    @MainActor private func runGuideHelpToggle() async {
        guard fixture.selectedCase == "front" else { return }
        await waitForFocus(true)
        guideRecord = fixture.store.engine?.record
        await waitForGuideHelp(false)
        guideRequested = true; await waitForGuideHelp(true)
        precondition(fixture.store.engine?.record == guideRecord, "Opening guide help must not grade or change study state")
        guideRequested = false; await waitForGuideHelp(false)
        precondition(fixture.store.engine?.record == guideRecord, "Closing guide help must not grade or change study state")
        guidePhase = 3
        reportIfReady()
    }
    @MainActor private func criticalReady() -> Bool {
        guard selectedTab == 4, selectedSubject == fixture.subject, recalling, !practicing,
              !fixture.store.blocked, fixture.store.error == nil, let engine = fixture.store.engine, let observed = observation,
              observed.cardID == (fixture.selectedCase == "diagram-switch" ? "synthetic-handbook-second" : fixture.expectedCardID),
              observed.ratingCount == fixture.expectedRatings,
              engine.record.attempts.count == fixture.expectedRatings, engine.package.subject == fixture.subject,
              engine.record.subject == fixture.subject,
              engine.presentation?.id == (fixture.selectedCase == "diagram-switch" ? diagramSwitchToken : fixture.expectedToken),
              engine.package.cards.allSatisfy({ $0.id.hasPrefix("synthetic-handbook-") }),
              observed.fullScreen == !["normal-front", "normal-back"].contains(fixture.selectedCase) else { return false }
        switch fixture.selectedCase {
        case "front": return guidePhase == 3 && guideObservedCardID == "synthetic-handbook-first" && !guideObservedRevealed && engine.record == guideRecord && observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && engine.record.attempts.isEmpty && observed.recallCueMode
        case "table-front", "postponed", "normal-front": return observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && engine.record.attempts.isEmpty && observed.recallCueMode == (fixture.subject == .power)
        case "back": return guideObservedCardID == "synthetic-handbook-first" && guideObservedRevealed && observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.record.attempts.isEmpty
        case "table", "long", "resume", "normal-back", "multi-source", "lecture-only": return observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.record.attempts.isEmpty
        case "multi-source-pages", "lecture-only-pages": return sourcePhase == 3 && engine.record == sourceRecord &&
            observed.mode == "back" && observed.revealed && observed.ratingEnabled && observed.sourceSheetPresented &&
            sourceObservation?.sourceID == "additional:synthetic-lecture" && sourceObservation?.missingPageNumbers == [7, 9] && engine.record.attempts.isEmpty
        case "diagram-switch": return diagramPhase == 3 && diagramObservedCardID == "synthetic-handbook-second" && !diagramObserved &&
            engine.record == diagramRecord && observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.record.attempts.isEmpty
        case "diagram-branch", "diagram-flow": return diagramPhase == 3 && diagramObserved && engine.record == diagramRecord &&
            observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.record.attempts.isEmpty
        case "focus-toggle": return togglePhase == 3 && engine.record == toggleRecord && observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.record.attempts.isEmpty
        case "missing-source": return observed.mode == "back" && observed.ratingEnabled && !observed.sourceFilesPresent && engine.record.attempts.isEmpty
        case "completed": return observed.mode == "completed" && engine.presentation == nil && engine.record.attempts.count == 2
        default: return false
        }
    }
    @MainActor private func reportIfReady() {
        guard !reported, criticalReady() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !reported, criticalReady(), let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-id=") }),
                  let capture = UUID(uuidString: String(raw.dropFirst("--capture-id=".count))) else { return }
            let id = capture.uuidString.lowercased()
            let diagramMode = fixture.store.engine?.currentCard?.blocks.first(where: { $0.kind == "diagram" })?.text
            let payload: [String: Any] = ["suite": "handbook-cards", "captureID": id, "subject": fixture.subject.rawValue, "case": fixture.selectedCase,
                "ready": true, "syntheticOnly": true, "route": "ProfessionalCoursesView", "selectedSubject": selectedSubject.rawValue,
                "mode": observation!.mode, "revealed": observation!.revealed,
                "ratingEnabled": observation!.ratingEnabled, "selfRatings": observation!.ratingCount,
                "cardID": observation!.cardID.map { $0 as Any } ?? NSNull(),
                "presentationID": (fixture.selectedCase == "diagram-switch" ? diagramSwitchToken : fixture.expectedToken).map { $0.uuidString.lowercased() as Any } ?? NSNull(),
                "sourceFilesPresent": observation!.sourceFilesPresent,
                "sourceSheetPresented": observation!.sourceSheetPresented,
                "sourceNavigationPreservedRecord": fixture.selectedCase.hasSuffix("-pages") && sourcePhase == 3 && fixture.store.engine?.record == sourceRecord,
                "selectedSourceID": sourceObservation.map { $0.sourceID as Any } ?? NSNull(),
                "selectedSourceTitle": sourceObservation.map { $0.title as Any } ?? NSNull(),
                "selectedSourcePageNumbers": sourceObservation?.pageNumbers ?? [],
                "selectedSourceMissingPageNumbers": sourceObservation?.missingPageNumbers ?? [],
                "recallCueMode": observation!.recallCueMode,
                "fullScreen": observation!.fullScreen,
                "topicFrequencyLabel": observation!.frequencyLabel.map { $0 as Any } ?? NSNull(),
                "memoryGuideRendered": ["front", "back"].contains(fixture.selectedCase) && guideObservedCardID == "synthetic-handbook-first",
                "memoryGuideHelpPreservedRecord": fixture.selectedCase == "front" && guidePhase == 3 && fixture.store.engine?.record == guideRecord,
                "rootTabShellFixture": true,
                "diagramExpanded": ["diagram-branch", "diagram-flow"].contains(fixture.selectedCase) && diagramPhase == 3 && diagramObserved,
                "diagramSwitchStartedCollapsed": fixture.selectedCase == "diagram-switch" && diagramPhase == 3 &&
                    diagramObservedCardID == "synthetic-handbook-second" && !diagramObserved,
                "diagramTogglePreservedRecord": fixture.selectedCase.hasPrefix("diagram-") && diagramPhase == 3 && fixture.store.engine?.record == diagramRecord,
                "diagramMode": diagramMode.map { $0 as Any } ?? NSNull(),
                "focusTogglePreservedRecord": fixture.selectedCase == "focus-toggle" && togglePhase == 3 && fixture.store.engine?.record == toggleRecord,
                "semicolonFormatting": handbookDisplayText("甲；乙;丙") == "甲；\n乙;\n丙",
                "sourcePageNumbering": "physical-pdf", "textRenderingMode": "verbatim",
                "literalSymbolsFixture": fixture.subject == .power && !fixture.selectedCase.hasPrefix("multi-source") && !fixture.selectedCase.hasPrefix("lecture-only"),
                "sourceBlankCellsPreserved": fixture.store.package?.cards.contains { card in
                    card.blocks.contains { $0.kind == "table" && $0.columns?.allSatisfy(\.isEmpty) == true && $0.rows?.contains(where: { $0.contains("") }) == true }
                } == true,
                "cardSourcePageNumbers": fixture.store.engine?.currentCard?.sourcePages ?? [],
                "cardAdditionalSourceReferences": (fixture.store.engine?.currentCard?.sourceReferences ?? []).map {
                    ["sourceID": $0.sourceID, "page": $0.page] as [String: Any]
                },
                "cardSourceTitles": fixture.store.engine?.currentCard.map { card in
                    handbookSourceGroups(fixture.store.package!, card: card).map(\.title)
                } ?? [],
                "allSourceTitles": fixture.store.package.map { handbookSourceGroups($0).map(\.title) } ?? [],
                "supplementalExampleUsesOrdinaryBlock": fixture.store.engine?.currentCard?.blocks.contains {
                    $0.title == "补充原例 · 合成讲义甲" && $0.kind == "text"
                } == true,
                "allSourcePageNumbers": (fixture.store.package?.sourcePages ?? []).map(\.number).sorted(),
                "archivalSourcePageNumbers": (fixture.store.package?.sourcePages ?? []).map(\.number).filter { number in
                    fixture.store.package?.cards.allSatisfy { !$0.sourcePages.contains(number) } == true
                }.sorted(),
                "source": "production card layout and validated persisted synthetic fixture"]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("handbook-card-preview-ready-" + id + ".json")
                try data.write(to: file, options: .atomic)
                reported = true
                print("HANDBOOK_CARD_PREVIEW_RENDERED subject=\(fixture.subject.rawValue) case=\(fixture.selectedCase)")
            } catch { print("HANDBOOK_CARD_PREVIEW_RECEIPT_FAILED \(error)") }
        }
    }
}
#endif
