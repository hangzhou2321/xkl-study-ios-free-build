import Foundation
import Combine
import StudyCore

/// Personal marks are isolated from card definitions and every scheduler file.
/// The enclosing handbook export includes this directory via its normal scan.
@MainActor final class HandbookHighlightStore: ObservableObject {
    let subject: ConceptSubject
    @Published private(set) var state: HandbookHighlightState
    @Published private(set) var blocked = false
    @Published private(set) var error: String?
    private let directory: URL
    private let writer: (Data, URL) throws -> Void
    private var durableHash: String?
    private var currentURL: URL { directory.appendingPathComponent("current.json") }

    init(subject: ConceptSubject, baseDirectory: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = DurableFile.write) {
        self.subject = subject; self.writer = writer
        let base = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        directory = base.appendingPathComponent("HandbookWordRecall/\(subject.rawValue)/personal-highlights", isDirectory: true)
        state = HandbookHighlightState(subject: subject)
        do {
            if FileManager.default.fileExists(atPath: currentURL.path) {
                let raw = try Self.read(currentURL)
                let saved = try JSONDecoder().decode(HandbookHighlightState.self, from: raw)
                guard saved.subject == subject else { throw ExamError.invalid("个人标红记录所属科目不一致。") }
                try saved.validate()
                state = saved; durableHash = StudySHA256.hex(raw)
            }
        } catch {
            blocked = true; self.error = "个人标红记录无法读取，原文件已保留。\n" + error.localizedDescription
        }
    }

    func apply(document: HandbookHighlightDocument, selection: NSRange, remove: Bool) {
        guard !blocked else { return }
        let candidate: HandbookHighlightState
        do {
            candidate = try state.applying(document, selection: selection, remove: remove)
        } catch {
            self.error = error.localizedDescription
            return
        }
        save(candidate)
    }

    /// Explicitly clears only this subject's personal marks. It never edits
    /// source colours, a card definition or any learning-progress file.
    func clearAll() {
        guard !blocked else { return }
        var candidate = state
        candidate.spans = []
        save(candidate)
    }

    private func save(_ candidate: HandbookHighlightState) {
        guard candidate != state else { error = nil; return }
        do {
            try ensure(directory)
            let original = try currentData()
            try checkHead(original)
            if let original {
                let hash = StudySHA256.hex(original), revisions = directory.appendingPathComponent("revisions", isDirectory: true)
                try ensure(revisions)
                let archive = revisions.appendingPathComponent(hash + ".json")
                if FileManager.default.fileExists(atPath: archive.path) {
                    guard try Self.read(archive) == original else { throw ExamError.invalid("个人标红旧档案不一致。") }
                } else { try writer(original, archive) }
                guard try Self.read(archive) == original else { throw ExamError.invalid("个人标红旧档案未完整保存。") }
            }
            try checkHead(try currentData())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(candidate)
            try writer(bytes, currentURL)
            guard try Self.read(currentURL) == bytes else { throw ExamError.invalid("个人标红未完整保存。") }
            state = candidate; durableHash = StudySHA256.hex(bytes); error = nil
        } catch {
            // A writer can fail after its atomic replacement; never publish or
            // retry over an uncertain head. Reopening validates the durable file.
            blocked = true; self.error = "标红未能确认保存，已有标记和背卡记录已保留；请重新打开卡片核对。\n" + error.localizedDescription
        }
    }
    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 40 * 1_024 * 1_024 else {
            throw ExamError.invalid("个人标红记录不是可读取的普通文件。")
        }
        return try Data(contentsOf: url)
    }
    private func currentData() throws -> Data? {
        FileManager.default.fileExists(atPath: currentURL.path) ? try Self.read(currentURL) : nil
    }
    private func checkHead(_ bytes: Data?) throws {
        guard bytes.map(StudySHA256.hex) == durableHash else { throw ExamError.invalid("个人标红在别处发生变化，请重新打开。") }
    }
    private func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ExamError.invalid("个人标红目录不可用。") }
    }
}
