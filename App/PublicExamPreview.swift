#if DEBUG
import Foundation
import SwiftUI
import StudyCore

/// Entirely synthetic local fixture, used only by the simulator smoke workflow.
@MainActor private final class PublicExamPreviewFixture: ObservableObject {
    let store: ExamStore
    let selectedCase: String
    let captureID: String
    let expectedPresentation: UUID
    let oldBytes: Data
    let legacyURL: URL

    init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            args.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
        }
        let requested = value("--case") ?? "home"
        precondition(["home", "question"].contains(requested), "Only synthetic preview cases are allowed")
        guard let rawID = value("--capture-id"), let uuid = UUID(uuidString: rawID) else {
            fatalError("Synthetic preview requires a fresh UUID")
        }
        let idString = uuid.uuidString.lowercased()
        selectedCase = requested; captureID = idString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-public-exam-" + idString, isDirectory: true)
        let qroot = root.appendingPathComponent("QuestionBank", isDirectory: true)
        let banks = qroot.appendingPathComponent("banks", isDirectory: true)
        do {
            let bank = ExamBank(id: "synthetic-exam-preview", title: "合成题库 · 仅用于界面检查",
                sourceName: "synthetic.pdf", sourceSHA256: String(repeating: "a", count: 64),
                totalPages: 1, questions: (1...8).map { n in
                    ExamQuestion(id: "synthetic-\(n)", number: n, type: .multiple, section: "合成章节",
                        prompt: "合成题 \(n)：哪些数字小于 3？", options: [
                            ExamOption(id: "A", text: "1"), ExamOption(id: "B", text: "2"),
                            ExamOption(id: "C", text: "5")], answer: ["A", "B"], pageStart: 1, pageEnd: 1)
                })
            let data = try JSONEncoder().encode(bank), hash = StudySHA256.hex(data)
            let package = ExamContent(format: ExamContent.formatName, bankBytes: data, bankSHA256: hash)
            let version = qroot.appendingPathComponent("versions", isDirectory: true).appendingPathComponent(hash, isDirectory: true)
            try FileManager.default.createDirectory(at: banks, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: version.appendingPathComponent("volumes", isDirectory: true), withIntermediateDirectories: true)
            try JSONEncoder().encode(package).write(to: banks.appendingPathComponent(hash + ".xklquestions"))
            let legacy = try ExamLearningEngine.fresh(bank: bank, hash: hash)
            try legacy.start(day: UInt32(try ConceptCalendar.studyDay(Date())))
            try legacy.toggle("A")
            guard let id = legacy.record.presentation?.id else { fatalError("Synthetic presentation missing") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let initialBytes = try encoder.encode(legacy.record)
            let initialURL = version.appendingPathComponent("current-state.json")
            try initialBytes.write(to: initialURL)
            try JSONSerialization.data(withJSONObject: ["format": 2, "bankSHA256": hash], options: [.sortedKeys])
                .write(to: qroot.appendingPathComponent("active-bank.json"))
            let loaded = ExamStore(baseDirectory: root)
            loaded.prepareDualFSRSIfNeeded()
            guard loaded.isDualFSRS, !loaded.storageBlocked, loaded.error == nil,
                  loaded.presentationID == id, loaded.selectedOptionIDs == ["A"],
                  try Data(contentsOf: initialURL) == initialBytes else {
                fatalError("Synthetic migration did not preserve its current item")
            }
            expectedPresentation = id; oldBytes = initialBytes; legacyURL = initialURL; store = loaded
        } catch { fatalError("Synthetic public exam preview failed: \(error)") }
    }
}

@MainActor struct PublicExamPreview: View {
    @StateObject private var fixture: PublicExamPreviewFixture
    @State private var showingPractice: Bool

    init() {
        let fixture = PublicExamPreviewFixture()
        _fixture = StateObject(wrappedValue: fixture)
        _showingPractice = State(initialValue: fixture.selectedCase == "question")
    }

    var body: some View {
        ExamView(store: fixture.store, showingPractice: $showingPractice)
            .task {
                // This proves the production view was mounted with a validated
                // synthetic store; screenshot inspection is separate from taps.
                try? await Task.sleep(for: .seconds(2))
                guard fixture.store.isDualFSRS, !fixture.store.storageBlocked,
                      fixture.store.presentationID == fixture.expectedPresentation,
                      fixture.store.selectedOptionIDs == ["A"],
                      (try? Data(contentsOf: fixture.legacyURL)) == fixture.oldBytes,
                      showingPractice == (fixture.selectedCase == "question") else { return }
                let receipt: [String: Any] = ["suite": "public-exam", "case": fixture.selectedCase,
                    "captureID": fixture.captureID, "ready": true, "syntheticOnly": true,
                    "isDualFSRS": true, "selectedOption": "A", "presentationPreserved": true,
                    "scope": "production ExamView mounted; screenshot only, no taps or physical phone"]
                do {
                    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("public-exam-preview-ready-" + fixture.captureID + ".json")
                    try data.write(to: path, options: .atomic)
                    print("PUBLIC_EXAM_PREVIEW_READY case=\(fixture.selectedCase)")
                } catch { print("PUBLIC_EXAM_PREVIEW_RECEIPT_FAILED \(error)") }
            }
    }
}
#endif
