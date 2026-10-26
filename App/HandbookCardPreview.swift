#if DEBUG
import Foundation
import SwiftUI
import StudyCore

struct HandbookCardPreviewObservation: Equatable {
    let mode: String
    let cardID: String?
    let revealed: Bool
    let ratingCount: Int
    let ratingEnabled: Bool
    let sourceFilesPresent: Bool
}
struct HandbookCardPreviewState {
    var didRender: (HandbookCardPreviewObservation) -> Void = { _ in }
    var scrollTarget: String? = nil
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
    let selectedCase: String
    let store: HandbookCardStore
    let expectedCardID: String?
    let expectedToken: UUID?
    let expectedRatings: Int
    static let cases: Set<String> = ["front", "back", "table", "long", "resume", "postponed", "completed", "missing-source"]

    init() {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            args.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
        }
        let selected = argument("--case") ?? "front"
        precondition(Self.cases.contains(selected), "Unknown synthetic handbook fixture")
        selectedCase = selected
        root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-handbook-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let table = selected == "table"
            let long = selected == "long"
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
            func card(_ id: String, second: Bool = false) -> [String: Any] {
                ["id": id, "sourceGroupIDs": [id + "-group"], "topicNumber": 1, "chapterID": "synthetic-chapter",
                 "title": second ? "合成卡：另一知识点" : (table ? "合成卡：演进阶段" : (long ? "合成卡：长内容排版" : "合成卡：设备的诞生")),
                 "prompt": second ? "这个知识点要记住哪件事？" : (table ? "四个阶段分别采用什么部件？" : "它在什么时候、什么地方诞生？名称是什么？"),
                 "answerSummary": second ? "这是第二个合成知识点，供检查暂缓和自动续背。" : (table ? "按主要部件划分，四个阶段一起比较。" : "这是一张合成样式卡，只用于检查手机排版。"),
                 "blocks": blocks, "sourcePages": [2], "examples": [], "sourceNotes": ["纯合成测试，不是宝典原文，也不会写入个人学习记录。"]]
            }
            var cards = [card("synthetic-handbook-first")]
            if ["resume", "postponed", "completed"].contains(selected) { cards.append(card("synthetic-handbook-second", second: true)) }
            var package: [String: Any] = ["format": "xkl-handbook-cards-v1", "id": "synthetic-handbook-package", "subject": "computer",
                "title": "纯合成卡组 · 不含用户资料", "revision": "synthetic-1",
                "source": ["title": "纯合成来源", "fileName": "synthetic.pdf", "sha256": String(repeating: "b", count: 64), "pdfPageCount": 2, "includedPages": [2]],
                "chapters": [["id": "synthetic-chapter", "title": "合成章节 · 仅用于页面检查"]], "cards": cards]
            if selected == "missing-source" {
                package["sourcePages"] = [["number": 2, "asset": ["sha256": String(repeating: "a", count: 64), "mimeType": "image/png", "byteCount": 128,
                    "pixelWidth": 120, "pixelHeight": 160, "crop": ["x": 0, "y": 0, "width": 1, "height": 1], "altText": "故意缺失的合成原页，不影响文字卡自评。"]]]
            }
            var prepared = HandbookCardStore(subject: .computer, baseDirectory: root, documentsDirectory: root)
            prepared.importData(try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys]))
            precondition(!prepared.blocked && prepared.error == nil && prepared.engine != nil, "Synthetic card package must import")
            let now = Date()
            prepared.start(now: now)
            precondition(prepared.engine?.presentation != nil, "Synthetic card must start")
            if ["back", "table", "long", "resume", "postponed", "missing-source"].contains(selected) {
                prepared.reveal(token: prepared.engine!.presentation!.id, now: now)
            }
            if selected == "resume" {
                let token = prepared.engine!.presentation!.id
                prepared = HandbookCardStore(subject: .computer, baseDirectory: root, documentsDirectory: root)
                precondition(prepared.engine?.presentation?.id == token && prepared.engine?.presentation?.revealed == true,
                             "Back face and presentation token must restore without rating")
            }
            if selected == "postponed" {
                prepared.postpone(token: prepared.engine!.presentation!.id, now: now)
                precondition(prepared.engine?.currentCard?.id == "synthetic-handbook-second" && prepared.engine?.record.ratings.isEmpty == true,
                             "Postponement must move behind another card without rating")
            }
            if selected == "completed" {
                for _ in 0..<2 {
                    let token = prepared.engine!.presentation!.id
                    prepared.reveal(token: token, now: now)
                    prepared.rate(remembered: true, token: token, now: now)
                }
                precondition(prepared.engine?.presentation == nil && prepared.engine?.record.ratings.count == 2,
                             "Self-rated cards must leave this round")
                precondition((prepared.engine?.nextDueAt?.timeIntervalSince(now) ?? 0) >= 72 * 3600,
                             "First remembered review must wait at least 72 hours")
            }
            precondition(!prepared.blocked && prepared.error == nil, "Synthetic card changes must persist")
            store = prepared
            expectedCardID = prepared.engine?.currentCard?.id
            expectedToken = prepared.engine?.presentation?.id
            expectedRatings = prepared.engine?.record.ratings.count ?? 0
        } catch { fatalError("Synthetic handbook fixture failed: \(error)") }
    }
}

struct HandbookCardPreview: View {
    @StateObject private var fixture = HandbookCardPreviewFixture()
    @State private var observation: HandbookCardPreviewObservation?
    @State private var reported = false
    var body: some View {
        HandbookCardView(subject: .computer, baseDirectory: fixture.root, injectedStore: fixture.store, startInStudy: true)
            .environment(\.handbookCardPreview, .init(didRender: { observation = $0 }))
            .onChange(of: observation) { _, _ in reportIfReady() }
    }
    @MainActor private func criticalReady() -> Bool {
        guard !fixture.store.blocked, fixture.store.error == nil, let engine = fixture.store.engine, let observed = observation,
              observed.cardID == fixture.expectedCardID, observed.ratingCount == fixture.expectedRatings,
              engine.record.ratings.count == fixture.expectedRatings,
              engine.presentation?.id == fixture.expectedToken,
              engine.package.cards.allSatisfy({ $0.id.hasPrefix("synthetic-handbook-") }) else { return false }
        switch fixture.selectedCase {
        case "front", "postponed": return observed.mode == "front" && !observed.revealed && !observed.ratingEnabled && engine.record.ratings.isEmpty
        case "back", "table", "long", "resume": return observed.mode == "back" && observed.revealed && observed.ratingEnabled && engine.record.ratings.isEmpty
        case "missing-source": return observed.mode == "back" && observed.ratingEnabled && !observed.sourceFilesPresent && engine.record.ratings.isEmpty
        case "completed": return observed.mode == "completed" && engine.presentation == nil && engine.record.ratings.count == 2
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
            let payload: [String: Any] = ["suite": "handbook-cards", "captureID": id, "subject": "computer", "case": fixture.selectedCase,
                "ready": true, "syntheticOnly": true, "mode": observation!.mode, "revealed": observation!.revealed,
                "ratingEnabled": observation!.ratingEnabled, "selfRatings": observation!.ratingCount,
                "sourceFilesPresent": observation!.sourceFilesPresent, "source": "production card layout and validated persisted synthetic fixture"]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("handbook-card-preview-ready-" + id + ".json")
                try data.write(to: file, options: .atomic)
                reported = true
                print("HANDBOOK_CARD_PREVIEW_RENDERED case=\(fixture.selectedCase)")
            } catch { print("HANDBOOK_CARD_PREVIEW_RECEIPT_FAILED \(error)") }
        }
    }
}
#endif
