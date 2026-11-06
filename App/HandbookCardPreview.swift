#if DEBUG
import Foundation
import SwiftUI
import StudyCore
import UIKit

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
    let highlightSpanCount: Int
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
    var openHighlightEditor = false
    var didRenderHighlightEditor: () -> Void = {}
    var openRelatedQuestion = false
    var didRenderRelatedQuestion: () -> Void = {}
    var openLinkedTable = false
    var didRenderLinkedTableEntry: (String) -> Void = { _ in }
    var didRenderLinkedTablePage: (String) -> Void = { _ in }
    var openTableIndex = false
    var didRenderTableIndex: (Int, Int) -> Void = { _, _ in }
    var didRenderSourceNote: (String, CGFloat) -> Void = { _, _ in }
    var didRenderTableImage: (String, CGFloat) -> Void = { _, _ in }
    var didRenderSubjectPicker: (CGRect, Bool) -> Void = { _, _ in }
    var didRenderStudyEnabled: (Bool) -> Void = { _ in }
    var openImportPicker = false
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
    let handbookCircuit: HandbookWordStore
    let handbookMechanics: HandbookWordStore
    let legacyComputer: ConceptStore
    let legacyPower: ConceptStore
    let expectedCardID: String?
    let expectedToken: UUID?
    let expectedRatings: Int
    let expectedState: HandbookWordState
    static let cases: Set<String> = ["front", "back", "table", "table-front", "long", "resume", "postponed", "completed", "missing-source", "normal-front", "normal-back", "paused-front", "focus-toggle", "multi-source", "lecture-only", "multi-source-pages", "lecture-only-pages", "diagram-branch", "diagram-flow", "diagram-switch", "highlight-front", "highlight-back", "highlight-editor", "related-question", "related-review", "linked-table-entry", "linked-table-page", "table-index", "effective-import"]

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
        precondition(!selected.hasPrefix("linked-table-") || selectedSubject == .power || selectedSubject == .mechanics,
                     "Linked table preview requires a table-enabled subject")
        precondition(selected != "effective-import" || selectedSubject == .power, "Import picker fixture is power-only")
        precondition(selected != "table-index" || selectedSubject == .mechanics, "Optional directory fixture is mechanics-only")
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
            if ["related-question", "related-review"].contains(selected) {
                var question: [String: Any] = ["id": "synthetic-question", "cardID": "synthetic-handbook-first",
                    "type": "single", "prompt": "合成原题：哪个选项是示例？",
                    "options": [["id": "A", "text": "合成选项甲"], ["id": "B", "text": "合成选项乙"]],
                    "answer": ["A"], "explanation": "纯合成解析", "sourcePage": sourcePage, "sourceLabel": "合成来源"]
                if selected == "related-review" { question["sourceIssueNote"] = "合成来源存在歧义，仅验证暂不判分。" }
                package["relatedQuestions"] = [question]
            }
            if selectedSubject != .mechanics && ["front", "back", "normal-front", "highlight-front", "highlight-back", "highlight-editor", "linked-table-entry", "linked-table-page"].contains(selected) {
                package["topicFrequencies"] = [["topicNumber": 1, "stars": 4, "sourcePage": sourcePage,
                    "cardIDs": selected == "normal-front" ? [] : ["synthetic-handbook-first"]]]
            }
            if ["front", "back", "highlight-front", "highlight-back", "highlight-editor", "linked-table-entry", "linked-table-page"].contains(selected) {
                let rows: [[String: String]] = selected.hasPrefix("linked-table-") ? [
                    ["cue": "合成提示甲", "answer": "合成值甲，仅用于界面排版。"],
                    ["cue": "合成提示乙", "answer": "合成值乙，仅用于界面排版。"],
                    ["cue": "合成提示丙", "answer": "合成值丙，仅用于界面排版。"],
                    ["cue": "合成提示丁", "answer": "合成值丁，仅用于界面排版。"],
                    ["cue": "合成提示戊", "answer": "合成值戊，仅用于界面排版。"]
                ] : [["cue": "合成提示甲", "answer": "合成答案甲"],
                     ["cue": "合成提示乙", "answer": "合成答案乙"]]
                package["memoryGuides"] = [["cardID": "synthetic-handbook-first",
                    "explanation": "仅用于验证简短骨架，不含真实课程。",
                    "rows": rows,
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
            if selected.hasPrefix("linked-table-") || selected == "table-index" {
                package["additionalSources"] = [["id": "synthetic-table-source", "source": [
                    "title": "纯合成表格来源", "fileName": "synthetic-table.pdf", "sha256": String(repeating: "e", count: 64),
                    "pdfPageCount": 3, "includedPages": [2]]]]
                package["sharedTables"] = [["id": "synthetic-shared-table", "title": "合成五列对照表",
                    "cardIDs": ["synthetic-handbook-first"], "columns": ["项目", "条件", "指标甲", "指标乙", "补充"],
                    "rows": [["项目甲", "较长的纯合成条件文字用于测试换行", "17", "", "示例甲"],
                             ["项目乙", "纯合成条件乙", "23", "示例值", "仅供排版测试"]],
                    "sourceID": "synthetic-table-source", "sourcePages": [2],
                    "sourceNote": "空白是纯合成测试，不代表真实资料。"]]
                if selectedSubject == .mechanics {
                    // Draw an entirely synthetic image and write it into the isolated preview root.
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300), format: format).image { context in
                        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
                        UIColor.systemBlue.setStroke(); let path = UIBezierPath(rect: CGRect(x: 12, y: 12, width: 576, height: 276)); path.lineWidth = 3; path.stroke()
                        for y in [90, 160, 230] { let line = UIBezierPath(); line.move(to: CGPoint(x: 12, y: CGFloat(y))); line.addLine(to: CGPoint(x: 588, y: CGFloat(y))); line.stroke() }
                        let font = UIFont.systemFont(ofSize: 26)
                        for (index, text) in ["纯合成表格 · 界面预览", "项目甲        合成内容甲", "项目乙        合成内容乙", "项目丙        合成内容丙"].enumerated() {
                            (text as NSString).draw(at: CGPoint(x: 32, y: CGFloat(30 + index * 70)), withAttributes: [.font: font, .foregroundColor: UIColor.label])
                        }
                    }
                    let png = image.pngData()!
                    let hash = StudySHA256.hex(png)
                    let sourceRoot = root.appendingPathComponent("HandbookSources", isDirectory: true)
                    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
                    try png.write(to: sourceRoot.appendingPathComponent(hash + ".png"))
                    let asset: [String: Any] = ["sha256": hash, "mimeType": "image/png", "byteCount": png.count,
                        "pixelWidth": 600, "pixelHeight": 300, "crop": ["x": 0, "y": 0, "width": 1, "height": 1],
                        "altText": "纯合成表格图片，不含真实讲义。"]
                    package["additionalSources"] = [["id": "synthetic-table-source", "source": [
                        "title": "纯合成表格来源", "fileName": "synthetic-table.pdf", "sha256": String(repeating: "e", count: 64),
                        "pdfPageCount": 3, "includedPages": [2]], "sourcePages": [["number": 2, "asset": asset]]]]
                    package["sharedTables"] = [
                        ["id": "synthetic-shared-table", "title": "合成关联原图表", "cardIDs": ["synthetic-handbook-first"],
                         "columns": [], "rows": [], "sourceID": "synthetic-table-source", "sourcePages": [2],
                         "sourceImages": [asset], "sourceNote": "纯合成校注：本示例数值只用于检查显示顺序。"],
                        ["id": "synthetic-optional-page", "title": "合成选看原页", "cardIDs": [],
                         "columns": [], "rows": [], "sourceID": "synthetic-table-source", "sourcePages": [2],
                         "sourceImages": [asset], "sourceNote": "纯合成选看内容，不进入学习队列。"]]
                }
            }
            var prepared = HandbookWordStore(subject: selectedSubject, baseDirectory: root, documentsDirectory: root)
            prepared.importData(try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys]))
            handbookPreviewTrace("fixture-imported", ["blocked": prepared.blocked, "error": prepared.error ?? "", "engine": prepared.engine != nil])
            precondition(!prepared.blocked && prepared.error == nil && prepared.engine != nil, "Synthetic card package must import")
            let now = Date()
            prepared.start(now: now)
            handbookPreviewTrace("fixture-started", ["blocked": prepared.blocked, "error": prepared.error ?? "", "card": prepared.engine?.currentCard?.id ?? "nil"])
            precondition(prepared.engine?.presentation != nil, "Synthetic card must start")
            if supplemented || selected.hasPrefix("diagram-") || ["back", "table", "long", "resume", "postponed", "missing-source", "normal-back", "focus-toggle", "highlight-back", "highlight-editor"].contains(selected) {
                prepared.reveal(token: prepared.engine!.presentation!.id, now: now)
            }
            if selected.hasPrefix("highlight-") {
                let before = prepared.engine!.state
                let current = prepared.engine!.currentCard!, guide = prepared.engine!.currentMemoryGuide!
                let document = HandbookHighlightDocument(card: current, guide: guide)
                let marks = HandbookHighlightStore(subject: selectedSubject, baseDirectory: root)
                for (fieldID, value) in [("guide.rows.0.cue", "提示甲"), ("guide.rows.0.answer", "答案甲")] {
                    let field = document.fields.first { $0.id == fieldID }!
                    let local = (field.text as NSString).range(of: value)
                    precondition(local.location != NSNotFound)
                    marks.apply(document: document, selection: NSRange(location: field.range.location + local.location, length: local.length), remove: false)
                }
                precondition(!marks.blocked && marks.error == nil && marks.state.spans.count == 2)
                let reopened = HandbookHighlightStore(subject: selectedSubject, baseDirectory: root)
                precondition(!reopened.blocked && reopened.state == marks.state && prepared.engine!.state == before,
                             "Synthetic marks must survive restart without changing the scheduler")
            }
            if selected == "resume" {
                let token = prepared.engine!.presentation!.id
                prepared = HandbookWordStore(subject: selectedSubject, baseDirectory: root, documentsDirectory: root)
                precondition(prepared.engine?.presentation?.id == token && prepared.engine?.presentation?.revealed == true,
                             "Back face and presentation token must restore without rating")
            }
            if selected == "postponed" {
                prepared.postpone(token: prepared.engine!.presentation!.id, now: now)
                precondition(prepared.engine?.currentCard?.id == "synthetic-handbook-second" && prepared.engine?.stats(on: now).remembered == 0,
                             "Postponement must move behind another card without rating")
            }
            if selected == "completed" {
                for _ in 0..<2 {
                    let token = prepared.engine!.presentation!.id
                    prepared.reveal(token: token, now: now)
                    prepared.rate(remembered: true, token: token, now: now)
                }
                precondition(prepared.engine?.presentation == nil && prepared.engine?.stats(on: now).remembered == 2,
                             "Self-rated cards must leave this round")
                precondition(prepared.engine?.nextDueAt != nil,
                             "FSRS must schedule a later review of newly remembered cards")
            }
            precondition(!prepared.blocked && prepared.error == nil, "Synthetic card changes must persist")
            store = prepared
            handbookComputer = selectedSubject == .computer ? prepared : HandbookWordStore(subject: .computer, baseDirectory: root, documentsDirectory: root)
            handbookPower = selectedSubject == .power ? prepared : HandbookWordStore(subject: .power, baseDirectory: root, documentsDirectory: root)
            handbookCircuit = selectedSubject == .circuit ? prepared : HandbookWordStore(subject: .circuit, baseDirectory: root, documentsDirectory: root)
            handbookMechanics = selectedSubject == .mechanics ? prepared : HandbookWordStore(subject: .mechanics, baseDirectory: root, documentsDirectory: root)
            for other in [handbookComputer, handbookPower, handbookCircuit, handbookMechanics] where other.subject != selectedSubject {
                precondition(other.engine == nil && !other.blocked && other.error == nil, "Other subject must have its own empty synthetic store")
            }
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
            expectedRatings = prepared.engine.map { $0.stats(on: now).remembered + $0.stats(on: now).forgotten } ?? 0
            expectedState = prepared.engine!.state
            handbookPreviewTrace("fixture-ready", ["card": expectedCardID ?? "nil", "ratings": expectedRatings])
        } catch { fatalError("Synthetic handbook fixture failed: \(error)") }
    }
}

private struct SyntheticPreviewSegmentBar: View {
    let paused: Bool
    let frameChanged: (CGRect) -> Void
    let enabledChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(paused: Bool, frameChanged: @escaping (CGRect) -> Void, enabledChanged: @escaping (Bool) -> Void) {
        self.paused = paused; self.frameChanged = frameChanged; self.enabledChanged = enabledChanged
    }
    var body: some View {
        HStack(spacing: 12) {
            if paused {
                Button("继续这一段", systemImage: "play.fill") {}
            } else {
                Text("随时可以暂停").font(.subheadline)
            }
            Spacer()
            Text("0:00").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            Button("暂停") {}.font(.subheadline.weight(.medium))
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in frameChanged(frame) }
            })
            .onChange(of: isEnabled, initial: true) { _, enabled in enabledChanged(enabled) }
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
    @State private var toggleRecord: HandbookWordState?
    @State private var sourceSheet: String?
    @State private var sourceSelectionID: String?
    @State private var sourceObservation: HandbookSourcePreviewObservation?
    @State private var sourcePhase = 0
    @State private var sourceRecord: HandbookWordState?
    @State private var diagramRequested: Bool?
    @State private var diagramObserved = false
    @State private var diagramObservedCardID: String?
    @State private var diagramSwitchToken: UUID?
    @State private var diagramScrollTarget: String?
    @State private var diagramPhase = 0
    @State private var diagramRecord: HandbookWordState?
    @State private var guideRequested: Bool?
    @State private var guideObservedCardID: String?
    @State private var guideObservedRevealed = false
    @State private var guideHelpObservedCardID: String?
    @State private var guideHelpObserved = false
    @State private var guidePhase = 0
    @State private var guideRecord: HandbookWordState?
    @State private var highlightEditorObserved = false
    @State private var relatedQuestionObserved = false
    @State private var linkedTableEntryCardID: String?
    @State private var linkedTablePageID: String?
    @State private var tableIndexCounts: [Int] = []
    @State private var noteBottom: CGFloat?
    @State private var imageTop: CGFloat?
    @State private var segmentBarFrame: CGRect?
    @State private var subjectPickerFrame: CGRect?
    @State private var segmentBarEnabled: Bool?
    @State private var subjectPickerEnabled: Bool?
    @State private var studyContentEnabled: Bool?
    @State private var effectiveContentOverlay = false
    @State private var effectiveBlockedOverlay = false
    @State private var systemPickerObserved = false
    @MainActor init() {
        let prepared = HandbookCardPreviewFixture()
        _fixture = StateObject(wrappedValue: prepared)
        _selectedSubject = State(initialValue: prepared.subject)
        _fullScreenEnabled = State(initialValue: !["normal-front", "normal-back", "paused-front", "focus-toggle"].contains(prepared.selectedCase))
    }
    var body: some View { finalPreviewTasks }

    private var previewTabs: some View {
        TabView(selection: $selectedTab) {
            Text("合成首页，不含学习资料").tabItem { Label("今天", systemImage: "house") }.tag(5)
            ProfessionalCoursesView(computer: fixture.legacyComputer, power: fixture.legacyPower,
                                subject: $selectedSubject, practicing: $practicing, recalling: $recalling,
                                onEffectiveOverlayChanged: { content, blocked in
                                    effectiveContentOverlay = content; effectiveBlockedOverlay = blocked
                                },
                                handbookComputer: fixture.handbookComputer, handbookPower: fixture.handbookPower, handbookCircuit: fixture.handbookCircuit,
                                handbookMechanics: fixture.handbookMechanics, handbookBaseDirectory: fixture.root,
                                contentDisabled: fixture.selectedCase == "paused-front",
                                segmentBar: AnyView(syntheticSegmentBar),
                                fullScreenEnabled: $fullScreenEnabled)
                .toolbar(fullScreenEnabled && recalling ? .hidden : .visible, for: .tabBar)
                .tabItem { Label("专业课", systemImage: "books.vertical") }.tag(4)
        }
    }

    private var previewBars: some View {
        previewTabs
            .safeAreaInset(edge: .top, spacing: 0) {
                if selectedTab != 4 && !(fullScreenEnabled && recalling) { syntheticSegmentBar }
            }
            .statusBarHidden(fullScreenEnabled && recalling)
    }

    private var syntheticSegmentBar: some View {
        SyntheticPreviewSegmentBar(paused: fixture.selectedCase == "paused-front", frameChanged: { frame in
            if segmentBarFrame != frame { segmentBarFrame = frame }
        }, enabledChanged: { enabled in
            if segmentBarEnabled != enabled { segmentBarEnabled = enabled }
        })
    }

    private var cardPreviewEnvironment: HandbookCardPreviewState {
        var state = HandbookCardPreviewState()
        state.didRender = {
            observation = $0
            handbookPreviewTrace("observed", ["mode": $0.mode, "fullScreen": $0.fullScreen, "card": $0.cardID ?? "nil", "ratings": $0.ratingCount])
            reportIfReady()
        }
        state.scrollTarget = diagramScrollTarget
        state.sourceSheet = sourceSheet
        state.sourceSelectionID = sourceSelectionID
        state.didRenderSources = { sourceObservation = $0 }
        state.diagramExpanded = diagramRequested
        state.didRenderDiagram = { cardID, expanded in diagramObservedCardID = cardID; diagramObserved = expanded }
        state.guideHelpExpanded = guideRequested
        state.didRenderGuide = { cardID, revealed in guideObservedCardID = cardID; guideObservedRevealed = revealed }
        state.didRenderGuideHelp = { cardID, expanded in guideHelpObservedCardID = cardID; guideHelpObserved = expanded }
        state.openHighlightEditor = fixture.selectedCase == "highlight-editor"
        state.didRenderHighlightEditor = { highlightEditorObserved = true }
        state.openRelatedQuestion = ["related-question", "related-review"].contains(fixture.selectedCase)
        state.didRenderRelatedQuestion = { relatedQuestionObserved = true }
        state.openLinkedTable = fixture.selectedCase == "linked-table-page"
        state.didRenderLinkedTableEntry = { cardID in linkedTableEntryCardID = cardID }
        state.didRenderLinkedTablePage = { tableID in linkedTablePageID = tableID }
        state.openTableIndex = fixture.selectedCase == "table-index"
        state.didRenderTableIndex = { linked, optional in tableIndexCounts = [linked, optional] }
        state.didRenderSourceNote = { tableID, bottom in if tableID == "synthetic-shared-table" { noteBottom = bottom } }
        state.didRenderTableImage = { _, top in imageTop = top }
        state.didRenderSubjectPicker = { frame, enabled in
            if subjectPickerFrame != frame { subjectPickerFrame = frame }
            if subjectPickerEnabled != enabled { subjectPickerEnabled = enabled }
        }
        state.didRenderStudyEnabled = { enabled in if studyContentEnabled != enabled { studyContentEnabled = enabled } }
        state.openImportPicker = fixture.selectedCase == "effective-import"
        return state
    }

    private var previewEnvironment: some View {
        previewBars.environment(\.handbookCardPreview, cardPreviewEnvironment)
    }

    private var previewCoreObserved: some View {
        previewEnvironment
            .onAppear { handbookPreviewTrace("root-appeared") }
            .onChange(of: observation) { _, _ in reportIfReady() }
            .onChange(of: sourceObservation) { _, _ in reportIfReady() }
            .onChange(of: guideObservedCardID) { _, _ in reportIfReady() }
            .onChange(of: guideObservedRevealed) { _, _ in reportIfReady() }
    }

    private var previewTableObserved: some View {
        previewCoreObserved
            .onChange(of: highlightEditorObserved) { _, _ in reportIfReady() }
            .onChange(of: relatedQuestionObserved) { _, _ in reportIfReady() }
            .onChange(of: linkedTableEntryCardID) { _, _ in reportIfReady() }
            .onChange(of: linkedTablePageID) { _, _ in reportIfReady() }
            .onChange(of: tableIndexCounts) { _, _ in reportIfReady() }
    }

    private var previewGeometryObserved: some View {
        previewTableObserved
            .onChange(of: noteBottom) { _, _ in reportIfReady() }
            .onChange(of: imageTop) { _, _ in reportIfReady() }
            .onChange(of: segmentBarFrame) { _, _ in reportIfReady() }
            .onChange(of: subjectPickerFrame) { _, _ in reportIfReady() }
    }

    private var previewEnabledObserved: some View {
        previewGeometryObserved
            .onChange(of: segmentBarEnabled) { _, _ in reportIfReady() }
            .onChange(of: subjectPickerEnabled) { _, _ in reportIfReady() }
            .onChange(of: studyContentEnabled) { _, _ in reportIfReady() }
    }

    private var previewOverlayObserved: some View {
        previewEnabledObserved
            .onChange(of: effectiveContentOverlay) { _, _ in reportIfReady() }
            .onChange(of: effectiveBlockedOverlay) { _, _ in reportIfReady() }
            .onChange(of: systemPickerObserved) { _, _ in reportIfReady() }
    }

    private var firstPreviewTasks: some View {
        previewOverlayObserved
            .task { await runFocusToggle() }
            .task { await runSourceNavigation() }
            .task { await runDiagramToggle() }
    }

    private var finalPreviewTasks: some View {
        firstPreviewTasks
            .task { await runDiagramSwitch() }
            .task { await runGuideHelpToggle() }
            .task { await observeSystemPicker() }
            .task { await monitorLinkedTableReadiness() }
    }

    @MainActor private func monitorLinkedTableReadiness() async {
        guard fixture.subject == .mechanics && fixture.selectedCase == "linked-table-page" else { return }
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled || reported { return }
            traceLinkedTableReadiness()
        }
    }
    @MainActor private func traceLinkedTableReadiness() {
        guard !reported, fixture.subject == .mechanics, fixture.selectedCase == "linked-table-page" else { return }
        let engine = fixture.store.engine
        var fields: [String: Any] = [
            "ready": criticalReady(), "selectedTab": selectedTab, "subjectMatches": selectedSubject == fixture.subject,
            "recalling": recalling, "practicing": practicing, "storeBlocked": fixture.store.blocked,
            "storeError": fixture.store.error ?? "", "enginePresent": engine != nil, "observationPresent": observation != nil
        ]
        let engineFields: [String: Any] = [
            "cardMatches": observation?.cardID == fixture.expectedCardID,
            "ratingsMatch": observation?.ratingCount == fixture.expectedRatings,
            "actualRatingsMatch": engine.map { $0.stats(on: Date()).remembered + $0.stats(on: Date()).forgotten == fixture.expectedRatings } ?? false,
            "packageSubjectMatches": engine?.package.subject == fixture.subject,
            "recordSubjectMatches": engine?.record.subject == fixture.subject,
            "presentationMatches": engine?.presentation?.id == fixture.expectedToken,
            "allCardsSynthetic": engine?.package.cards.allSatisfy { $0.id.hasPrefix("synthetic-handbook-") } ?? false,
            "stateMatches": engine?.state == fixture.expectedState
        ]
        let visualFields: [String: Any] = [
            "observedMode": observation?.mode ?? "missing", "observedFullScreen": observation?.fullScreen ?? false,
            "observedRevealed": observation?.revealed ?? false, "observedRatingEnabled": observation?.ratingEnabled ?? false,
            "effectiveContentOverlay": effectiveContentOverlay, "effectiveBlockedOverlay": effectiveBlockedOverlay,
            "guideObservedCardID": guideObservedCardID ?? "missing", "guideObservedRevealed": guideObservedRevealed,
            "linkedTablePageID": linkedTablePageID ?? "missing",
            "noteBottom": diagnosticNumber(noteBottom), "imageTop": diagnosticNumber(imageTop),
            "noteBeforeImage": noteBottom != nil && imageTop != nil && noteBottom! <= imageTop!
        ]
        fields.merge(engineFields) { _, new in new }
        fields.merge(visualFields) { _, new in new }
        handbookPreviewTrace("critical-readiness", fields)
    }
    private func diagnosticNumber(_ number: CGFloat?) -> Any {
        guard let number else { return NSNull() }
        return number.isFinite ? Double(number) as Any : "non-finite"
    }
    @MainActor private func observeSystemPicker() async {
        guard fixture.selectedCase == "effective-import" else { return }
        func containsPicker(_ controller: UIViewController?) -> Bool {
            guard let controller else { return false }
            if controller is UIDocumentPickerViewController || String(reflecting: type(of: controller)).contains("DocumentPicker") { return true }
            if containsPicker(controller.presentedViewController) { return true }
            return controller.children.contains { containsPicker($0) }
        }
        for _ in 0..<800 {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            if windows.contains(where: { containsPicker($0.rootViewController) }) {
                systemPickerObserved = true; reportIfReady(); return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        handbookPreviewTrace("system-picker-not-observed")
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
        toggleRecord = fixture.store.engine?.state
        print("FOCUS_TOGGLE initial record captured")
        fullScreenEnabled = true; await waitForFocus(true)
        precondition(fixture.store.engine?.state == toggleRecord, "Entering fullscreen must not mutate a study record")
        print("FOCUS_TOGGLE entered; record unchanged")
        fullScreenEnabled = false; await waitForFocus(false)
        precondition(fixture.store.engine?.state == toggleRecord, "Exiting fullscreen must keep the exact card/face/queue/grades")
        print("FOCUS_TOGGLE exited; record unchanged")
        fullScreenEnabled = true; await waitForFocus(true)
        precondition(fixture.store.engine?.state == toggleRecord, "Re-entering fullscreen must keep the exact study record")
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
        sourceRecord = fixture.store.engine?.state
        sourceSheet = "card"
        let lectureOnly = fixture.selectedCase.hasPrefix("lecture-only")
        await waitForSource(lectureOnly ? "additional:synthetic-lecture" : "primary",
                            pages: lectureOnly ? [7] : [fixture.subject == .power ? 102 : 2])
        sourceSelectionID = "additional:synthetic-lecture"
        await waitForSource("additional:synthetic-lecture", pages: [7])
        precondition(fixture.store.engine?.state == sourceRecord, "Switching source must preserve the exact study record")
        sourceSheet = nil
        await waitForSource(nil)
        precondition(fixture.store.engine?.state == sourceRecord, "Closing sources must preserve card, face, queue and grades")
        // Allow the sheet dismissal transition to finish before opening the complete source catalog.
        try? await Task.sleep(for: .milliseconds(600))
        sourceObservation = nil
        sourceSheet = "all"
        await waitForSource("additional:synthetic-lecture", pages: [7, 9])
        precondition(fixture.store.engine?.state == sourceRecord, "Opening all sources must preserve the exact study record")
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
        diagramRecord = fixture.store.engine?.state
        diagramRequested = true; await waitForDiagram(true)
        precondition(fixture.store.engine?.state == diagramRecord, "Opening diagram must preserve the study record")
        diagramRequested = false; await waitForDiagram(false)
        precondition(fixture.store.engine?.state == diagramRecord, "Closing diagram must preserve the study record")
        diagramRequested = true; await waitForDiagram(true)
        precondition(fixture.store.engine?.state == diagramRecord, "Reopening diagram must preserve the study record")
        diagramScrollTarget = "handbook-relationship-diagram"
        try? await Task.sleep(for: .milliseconds(350))
        precondition(fixture.store.engine?.state == diagramRecord, "Scrolling diagram must preserve the study record")
        diagramPhase = 3
        reportIfReady()
    }
    @MainActor private func runDiagramSwitch() async {
        guard fixture.selectedCase == "diagram-switch" else { return }
        await waitForFocus(true)
        let firstRecord = fixture.store.engine?.state
        await waitForDiagram(false)
        diagramRequested = true; await waitForDiagram(true)
        precondition(fixture.store.engine?.state == firstRecord, "Opening first diagram must preserve the study record")
        // Stop controlling expansion before the legal card change; the next block must begin closed.
        diagramRequested = nil
        guard let oldToken = fixture.store.engine?.presentation?.id else { preconditionFailure("Missing first card") }
        fixture.store.postpone(token: oldToken)
        precondition(fixture.store.engine?.currentCard?.id == "synthetic-handbook-second", "Postponement must select the second synthetic card")
        guard let newToken = fixture.store.engine?.presentation?.id else { preconditionFailure("Missing second card") }
        fixture.store.reveal(token: newToken)
        await waitForDiagram(false, cardID: "synthetic-handbook-second")
        diagramSwitchToken = newToken
        diagramRecord = fixture.store.engine?.state
        diagramRequested = true; await waitForDiagram(true, cardID: "synthetic-handbook-second")
        precondition(fixture.store.engine?.state == diagramRecord, "Opening second diagram must preserve the study record")
        diagramRequested = false; await waitForDiagram(false, cardID: "synthetic-handbook-second")
        precondition(fixture.store.engine?.state == diagramRecord, "Closing second diagram must preserve the study record")
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
        guideRecord = fixture.store.engine?.state
        await waitForGuideHelp(false)
        guideRequested = true; await waitForGuideHelp(true)
        precondition(fixture.store.engine?.state == guideRecord, "Opening guide help must not grade or change study state")
        guideRequested = false; await waitForGuideHelp(false)
        precondition(fixture.store.engine?.state == guideRecord, "Closing guide help must not grade or change study state")
        guidePhase = 3
        reportIfReady()
    }
    @MainActor private func criticalReady() -> Bool {
        guard selectedTab == 4, selectedSubject == fixture.subject, recalling, !practicing,
              !fixture.store.blocked, fixture.store.error == nil, let engine = fixture.store.engine, let observed = observation,
              observed.cardID == (fixture.selectedCase == "diagram-switch" ? "synthetic-handbook-second" : fixture.expectedCardID),
              observed.ratingCount == fixture.expectedRatings,
              engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == fixture.expectedRatings, engine.package.subject == fixture.subject,
              engine.record.subject == fixture.subject,
              engine.presentation?.id == (fixture.selectedCase == "diagram-switch" ? diagramSwitchToken : fixture.expectedToken),
              engine.package.cards.allSatisfy({ $0.id.hasPrefix("synthetic-handbook-") }),
              observed.fullScreen == !["normal-front", "normal-back", "paused-front"].contains(fixture.selectedCase) else { return false }
        let expectsContent = ["related-question", "related-review", "linked-table-page", "table-index", "highlight-editor", "multi-source-pages", "lecture-only-pages"].contains(fixture.selectedCase)
        guard effectiveContentOverlay == expectsContent,
              effectiveBlockedOverlay == (fixture.selectedCase == "effective-import") else { return false }
        switch fixture.selectedCase {
        case "related-question", "related-review": return relatedQuestionObserved && observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && observed.ratingCount == 0
        case "linked-table-entry", "linked-table-page":
            return (fixture.subject == .power || fixture.subject == .mechanics) && engine.state == fixture.expectedState &&
                observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && observed.ratingCount == 0 &&
                guideObservedCardID == "synthetic-handbook-first" && !guideObservedRevealed &&
                (fixture.selectedCase == "linked-table-entry" ? linkedTableEntryCardID == "synthetic-handbook-first" :
                    (linkedTablePageID == "synthetic-shared-table" &&
                     (fixture.subject == .power || (noteBottom != nil && imageTop != nil && noteBottom! <= imageTop!))))
        case "table-index": return fixture.subject == .mechanics && tableIndexCounts == [1, 1] &&
            engine.state == fixture.expectedState && observed.mode == "front" && !observed.revealed && observed.ratingCount == 0 &&
            engine.package.sharedTables?.last?.cardIDs.isEmpty == true
        case "effective-import": return fixture.subject == .power && systemPickerObserved &&
            engine.state == fixture.expectedState && observed.mode == "front" && !observed.revealed &&
            !observed.ratingEnabled && observed.ratingCount == 0
        case "front": return guidePhase == 3 && guideObservedCardID == "synthetic-handbook-first" && !guideObservedRevealed && engine.state == guideRecord && observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0 && observed.recallCueMode
        case "table-front", "postponed", "normal-front", "paused-front":
            let checksLayout = ["normal-front", "paused-front"].contains(fixture.selectedCase)
            let layoutReady = !checksLayout ||
                (validFrame(segmentBarFrame) && validFrame(subjectPickerFrame) && !segmentBarFrame!.intersects(subjectPickerFrame!))
            let expectedEnabled = fixture.selectedCase != "paused-front"
            let controlsReady = !checksLayout || (segmentBarEnabled == true && subjectPickerEnabled == expectedEnabled && studyContentEnabled == expectedEnabled)
            return layoutReady && controlsReady && observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0 && observed.recallCueMode == (fixture.subject == .power)
        case "back": return guideObservedCardID == "synthetic-handbook-first" && guideObservedRevealed && observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "highlight-front": return guideObservedCardID == "synthetic-handbook-first" && !guideObservedRevealed && observed.mode == "front" && !observed.revealed && observed.highlightSpanCount == 2 && observed.ratingCount == 0
        case "highlight-back", "highlight-editor": return guideObservedCardID == "synthetic-handbook-first" && guideObservedRevealed && observed.mode == "back" && observed.revealed && observed.ratingEnabled && observed.highlightSpanCount == 2 && observed.ratingCount == 0 && (fixture.selectedCase != "highlight-editor" || highlightEditorObserved)
        case "table", "long", "resume", "normal-back", "multi-source", "lecture-only": return observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "multi-source-pages", "lecture-only-pages": return sourcePhase == 3 && engine.state == sourceRecord &&
            observed.mode == "back" && observed.revealed && observed.ratingEnabled && observed.sourceSheetPresented &&
            sourceObservation?.sourceID == "additional:synthetic-lecture" && sourceObservation?.missingPageNumbers == [7, 9] && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "diagram-switch": return diagramPhase == 3 && diagramObservedCardID == "synthetic-handbook-second" && !diagramObserved &&
            engine.state == diagramRecord && observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "diagram-branch", "diagram-flow": return diagramPhase == 3 && diagramObserved && engine.state == diagramRecord &&
            observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "focus-toggle": return togglePhase == 3 && engine.state == toggleRecord && observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "missing-source": return observed.mode == "back" && observed.ratingEnabled && !observed.sourceFilesPresent && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 0
        case "completed": return observed.mode == "completed" && engine.presentation == nil && engine.stats(on: Date()).remembered + engine.stats(on: Date()).forgotten == 2
        default: return false
        }
    }
    private func validFrame(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }
    private func framePayload(_ frame: CGRect?) -> Any {
        guard let frame, validFrame(frame) else { return NSNull() }
        return ["x": Double(frame.origin.x), "y": Double(frame.origin.y), "width": Double(frame.width), "height": Double(frame.height)]
    }
    @MainActor private func reportIfReady() {
        traceLinkedTableReadiness()
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
                "sourceNavigationPreservedRecord": fixture.selectedCase.hasSuffix("-pages") && sourcePhase == 3 && fixture.store.engine?.state == sourceRecord,
                "selectedSourceID": sourceObservation.map { $0.sourceID as Any } ?? NSNull(),
                "selectedSourceTitle": sourceObservation.map { $0.title as Any } ?? NSNull(),
                "selectedSourcePageNumbers": sourceObservation?.pageNumbers ?? [],
                "selectedSourceMissingPageNumbers": sourceObservation?.missingPageNumbers ?? [],
                "recallCueMode": observation!.recallCueMode,
                "fullScreen": observation!.fullScreen,
                "topicFrequencyLabel": observation!.frequencyLabel.map { $0 as Any } ?? NSNull(),
                "memoryGuideRendered": ["front", "back", "highlight-front", "highlight-back", "highlight-editor", "linked-table-entry", "linked-table-page"].contains(fixture.selectedCase) && guideObservedCardID == "synthetic-handbook-first",
                "highlightSpanCount": observation!.highlightSpanCount,
                "highlightEditorRendered": fixture.selectedCase == "highlight-editor" && highlightEditorObserved,
                "relatedQuestionRendered": ["related-question", "related-review"].contains(fixture.selectedCase) && relatedQuestionObserved,
                "linkedTableEntryRendered": fixture.selectedCase == "linked-table-entry" && linkedTableEntryCardID == "synthetic-handbook-first",
                "linkedTablePageRendered": fixture.selectedCase == "linked-table-page" && linkedTablePageID == "synthetic-shared-table",
                "linkedTablePreservedRecord": fixture.selectedCase.hasPrefix("linked-table-") && fixture.store.engine?.state == fixture.expectedState,
                "linkedTableColumnCount": fixture.selectedCase.hasPrefix("linked-table-") ? (fixture.store.package?.sharedTables?.first?.columns.count ?? 0) : 0,
                "linkedTableBlankCell": fixture.selectedCase.hasPrefix("linked-table-") && fixture.store.package?.sharedTables?.first?.rows.contains(where: { $0.contains("") }) == true,
                "tableIndexRendered": fixture.selectedCase == "table-index" && tableIndexCounts == [1, 1],
                "noteBeforeImage": fixture.subject == .mechanics && fixture.selectedCase == "linked-table-page" && noteBottom != nil && imageTop != nil && noteBottom! <= imageTop!,
                "optionalDirectoryExcludedFromCards": fixture.selectedCase == "table-index" && fixture.store.package?.sharedTables?.last?.cardIDs.isEmpty == true,
                "segmentBarFrame": framePayload(segmentBarFrame),
                "subjectPickerFrame": framePayload(subjectPickerFrame),
                "segmentBarOverlapsPicker": (segmentBarFrame != nil && subjectPickerFrame != nil) ? (segmentBarFrame!.intersects(subjectPickerFrame!) as Any) : NSNull(),
                "segmentBarEnabled": segmentBarEnabled.map { $0 as Any } ?? NSNull(),
                "subjectPickerEnabled": subjectPickerEnabled.map { $0 as Any } ?? NSNull(),
                "studyContentEnabled": studyContentEnabled.map { $0 as Any } ?? NSNull(),
                "effectiveContentOverlay": effectiveContentOverlay,
                "effectiveBlockedOverlay": effectiveBlockedOverlay,
                "systemPickerObserved": systemPickerObserved,
                "memoryGuideHelpPreservedRecord": fixture.selectedCase == "front" && guidePhase == 3 && fixture.store.engine?.state == guideRecord,
                "rootTabShellFixture": true,
                "diagramExpanded": ["diagram-branch", "diagram-flow"].contains(fixture.selectedCase) && diagramPhase == 3 && diagramObserved,
                "diagramSwitchStartedCollapsed": fixture.selectedCase == "diagram-switch" && diagramPhase == 3 &&
                    diagramObservedCardID == "synthetic-handbook-second" && !diagramObserved,
                "diagramTogglePreservedRecord": fixture.selectedCase.hasPrefix("diagram-") && diagramPhase == 3 && fixture.store.engine?.state == diagramRecord,
                "diagramMode": diagramMode.map { $0 as Any } ?? NSNull(),
                "focusTogglePreservedRecord": fixture.selectedCase == "focus-toggle" && togglePhase == 3 && fixture.store.engine?.state == toggleRecord,
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
