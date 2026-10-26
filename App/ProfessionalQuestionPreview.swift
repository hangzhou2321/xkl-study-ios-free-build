#if DEBUG
import Foundation
import SwiftUI
import UIKit
import StudyCore

/// DEBUG observations are emitted by the actual production question view after
/// layout and asset loading. They never modify a learner's question or result.
struct ProfessionalQuestionPreviewObservation: Equatable {
    let mode: String
    let questionID: String?
    let selectedOptions: [String]
    let optionOrder: [String]
    let isCorrect: Bool?
    let helped: Bool
    let assetsReady: Bool
    let failedAssets: Int
    let submitEnabled: Bool
}

struct ProfessionalQuestionPreviewState {
    var didRender: (ProfessionalQuestionPreviewObservation) -> Void = { _ in }
    var scrollTarget: String? = nil
}

private struct ProfessionalQuestionPreviewKey: EnvironmentKey {
    static let defaultValue = ProfessionalQuestionPreviewState()
}

extension EnvironmentValues {
    var professionalQuestionPreview: ProfessionalQuestionPreviewState {
        get { self[ProfessionalQuestionPreviewKey.self] }
        set { self[ProfessionalQuestionPreviewKey.self] = newValue }
    }
}

@MainActor
private final class ProfessionalQuestionPreviewFixture: ObservableObject {
    let subject: ConceptSubject
    let selectedCase: String
    let root: URL
    let store: ProfessionalQuestionStore
    let today: Int
    let expectedQuestionID: String?
    let expectedAttemptCount: Int
    let expectedDraftToken: UUID?
    let expectedDraftOrder: [String]?
    private static let cases: Set<String> = ["home", "question", "draft", "correct", "wrong", "helped", "completed", "missing-image"]

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            if let value = arguments.first(where: { $0.hasPrefix(name + "=") }) { return String(value.dropFirst(name.count + 1)) }
            if let index = arguments.firstIndex(of: name), index + 1 < arguments.count { return arguments[index + 1] }
            return nil
        }
        let subject: ConceptSubject = argument("--subject") == "power" ? .power : .computer
        let requested = argument("--case") ?? "home"
        precondition(Self.cases.contains(requested), "Synthetic question preview case is not allowed")
        self.subject = subject
        selectedCase = requested
        root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-professional-questions-" + UUID().uuidString, isDirectory: true)
        let now = Date()
        do {
            today = try ConceptCalendar.studyDay(now)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let png = Self.syntheticImage()
            let asset = ProfessionalSourceFileAsset(sha256: StudySHA256.hex(png), mimeType: "image/png", byteCount: png.count,
                pixelWidth: 600, pixelHeight: 140, crop: .init(x: 0, y: 0, width: 1, height: 1),
                altText: "纯合成题图：四个蓝色方块，不含任何私有原题。")
            if requested == "question" {
                let assets = root.appendingPathComponent("KnowledgeSources", isDirectory: true)
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                try DurableFile.write(png, to: assets.appendingPathComponent(asset.sha256 + ".png"))
            }
            func question(_ id: String, second: Bool = false, archived: Bool = false) -> ProfessionalObjectiveQuestion {
                let imageCase = requested == "question" || requested == "missing-image"
                return .init(id: id, type: .single, book: second ? "reinforcement" : "basic", chapter: "合成题 · 仅用于页面检查",
                    prompt: imageCase ? "合成题：图中有几个蓝色方块？" : (second ? "合成题：9减5的结果是多少？" : "合成题：12除以3的结果是多少？"),
                    options: [.init(id: "A", text: "8"), .init(id: "B", text: "4")], answer: ["B"],
                    sourceLocation: "纯合成来源 · 第" + (second ? "2" : "1") + "题", sourceDocumentID: "synthetic", pdfPage: second ? 2 : 1,
                    sourceAnswer: "B", explanation: "纯合成参考解析：这道示例的结果为4。", preserveOptionOrder: false,
                    sourceAssets: imageCase ? [asset] : nil, isActive: !archived, scopeNote: archived ? "纯合成范围外档案。" : nil)
            }
            var questions = [question("synthetic-original-first")]
            if ["home", "draft", "completed"].contains(requested) { questions.append(question("synthetic-original-second", second: true)) }
            if requested == "home" { questions.append(question("synthetic-original-archive", archived: true)) }
            let package = ProfessionalQuestionPackage(id: "synthetic-original-" + subject.rawValue, subject: subject,
                title: "合成原题样式 · 不含用户题库", revision: "synthetic-1",
                sources: [.init(id: "synthetic", title: "纯合成来源", reference: "synthetic-only")], questions: questions)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var prepared = ProfessionalQuestionStore(subject: subject, baseDirectory: root, documentsDirectory: root)
            prepared.importData(try encoder.encode(package))
            precondition(!prepared.blocked && prepared.error == nil && prepared.engine != nil, "Synthetic question package must import")
            var draftToken: UUID?
            var draftOrder: [String]?
            if requested != "home" {
                prepared.start(now: now)
                precondition(prepared.engine?.presentation != nil, "Synthetic question must start")
            }
            switch requested {
            case "draft":
                let presentation = prepared.engine!.presentation!
                prepared.saveDraft(["A"], token: presentation.id)
                draftToken = presentation.id; draftOrder = presentation.optionOrder
                prepared = ProfessionalQuestionStore(subject: subject, baseDirectory: root, documentsDirectory: root)
                precondition(prepared.engine?.presentation?.id == draftToken && prepared.engine?.presentation?.selectedOptions == ["A"] && prepared.engine?.presentation?.optionOrder == draftOrder,
                    "Synthetic persisted selection and order must restore")
            case "correct", "wrong", "helped":
                let token = prepared.engine!.presentation!.id
                if requested == "helped" { prepared.help(token: token) }
                prepared.saveDraft(requested == "wrong" ? ["A"] : ["B"], token: token)
                prepared.submit(token: token, now: now)
                let answer = prepared.engine!.result!
                precondition(answer.isCorrect == (requested != "wrong") && answer.helped == (requested == "helped"), "Synthetic objective result must match")
                precondition(answer.dueDay == today + (requested == "wrong" ? 1 : 3), "Synthetic long interval must match")
                if requested == "helped" { precondition(!answer.independent && answer.afterProgress.independentCorrectCount == 0, "Help must not become independent success") }
            case "completed":
                for _ in 0..<2 {
                    let token = prepared.engine!.presentation!.id
                    prepared.saveDraft(["B"], token: token); prepared.submit(token: token, now: now); prepared.next(token: token, now: now)
                }
                precondition(prepared.engine?.presentation == nil && prepared.engine?.record.attempts.count == 2, "Answered originals must not immediately repeat")
            case "missing-image":
                prepared.saveDraft(["B"], token: prepared.engine!.presentation!.id)
            default: break
            }
            precondition(!prepared.blocked && prepared.error == nil, "Synthetic preparation must save cleanly")
            store = prepared
            expectedQuestionID = prepared.engine?.presentation?.questionID
            expectedAttemptCount = prepared.engine?.record.attempts.count ?? 0
            expectedDraftToken = draftToken
            expectedDraftOrder = draftOrder
        } catch { fatalError("Synthetic question preview failed: \(error)") }
    }

    private static func syntheticImage() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 140), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 140))
            ("纯合成示意图" as NSString).draw(at: CGPoint(x: 18, y: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.darkGray])
            UIColor.systemBlue.setFill()
            for index in 0..<4 { context.fill(CGRect(x: 35 + index * 135, y: 52, width: 70, height: 66)) }
        }
        return image.pngData()!
    }
}

struct ProfessionalQuestionPreview: View {
    @StateObject private var fixture = ProfessionalQuestionPreviewFixture()
    @State private var observation: ProfessionalQuestionPreviewObservation?
    @State private var reported = false
    private var scrollTarget: String? { ["correct", "wrong", "helped"].contains(fixture.selectedCase) ? "professional-question-result-top" : nil }

    var body: some View {
        ProfessionalQuestionView(subject: fixture.subject, baseDirectory: fixture.root, injectedStore: fixture.store,
            startInPractice: fixture.selectedCase != "home")
            .environment(\.professionalQuestionPreview, .init(didRender: { observation = $0 }, scrollTarget: scrollTarget))
            .onChange(of: observation) { _, _ in reportIfReady() }
    }

    @MainActor private func criticalStateReady() -> Bool {
        guard !fixture.store.blocked, fixture.store.error == nil, let engine = fixture.store.engine, let observed = observation,
              engine.record.attempts.count == fixture.expectedAttemptCount,
              engine.record.definitions.values.allSatisfy({ $0.id.hasPrefix("synthetic-original-") }),
              observed.questionID == fixture.expectedQuestionID else { return false }
        switch fixture.selectedCase {
        case "home": return observed.mode == "home" && engine.presentation == nil && engine.record.attempts.isEmpty && engine.stats(on: Date()).total == 2
        case "completed": return observed.mode == "completed" && engine.presentation == nil && engine.record.attempts.count == 2 && engine.stats(on: Date()).due == 0
        case "question": return observed.mode == "question" && observed.assetsReady && observed.failedAssets == 0 && !observed.submitEnabled && engine.result == nil
        case "missing-image": return observed.mode == "question" && !observed.assetsReady && observed.failedAssets > 0 && !observed.submitEnabled && engine.record.attempts.isEmpty
        case "draft": return observed.mode == "question" && observed.submitEnabled && observed.selectedOptions == ["A"] && engine.presentation?.id == fixture.expectedDraftToken && observed.optionOrder == fixture.expectedDraftOrder
        case "correct", "wrong", "helped":
            guard observed.mode == "result", let result = engine.result,
                  observed.isCorrect == result.isCorrect, observed.helped == result.helped, !observed.submitEnabled,
                  result.dueDay == fixture.today + (fixture.selectedCase == "wrong" ? 1 : 3) else { return false }
            return fixture.selectedCase != "helped" || (!result.independent && engine.stats(on: Date()).independentCorrect == 0)
        default: return false
        }
    }

    @MainActor private func reportIfReady() {
        guard !reported, criticalStateReady() else { return }
        Task { @MainActor in
            // State is supplied after production layout and asset readiness. The
            // short settle only allows the validated result scroll to be painted.
            try? await Task.sleep(for: .milliseconds(200))
            guard !reported, criticalStateReady() else { return }
            let arguments = ProcessInfo.processInfo.arguments
            let raw = arguments.first(where: { $0.hasPrefix("--capture-id=") }).map { String($0.dropFirst("--capture-id=".count)) }
            guard let raw, let capture = UUID(uuidString: raw) else { return }
            let id = capture.uuidString.lowercased()
            do {
                let receipt: [String: Any] = ["suite": "professional-questions", "captureID": id, "subject": fixture.subject.rawValue,
                    "case": fixture.selectedCase, "ready": true, "syntheticOnly": true,
                    "mode": observation!.mode, "questionID": observation!.questionID ?? "", "assetsReady": observation!.assetsReady,
                    "failedAssets": observation!.failedAssets, "submitEnabled": observation!.submitEnabled,
                    "objectiveAttempts": fixture.expectedAttemptCount, "source": "production view layout and validated persisted fixture"]
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("professional-question-preview-ready-" + id + ".json")
                try data.write(to: path, options: .atomic)
                reported = true
                print("PROFESSIONAL_QUESTION_PREVIEW_RENDERED subject=\(fixture.subject.rawValue) case=\(fixture.selectedCase)")
            } catch { print("PROFESSIONAL_QUESTION_PREVIEW_RECEIPT_FAILED \(error)") }
        }
    }
}
#endif
