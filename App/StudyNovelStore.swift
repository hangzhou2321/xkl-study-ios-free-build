import Combine
import Foundation
import StudyCore

@MainActor final class StudyNovelStore: ObservableObject {
    struct Book: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let chapterCount: Int
        var progress: StudyNovelProgress

        var nextUnread: Int? {
            (0..<progress.unlocked).first { !progress.readChapters.contains($0) }
        }
    }

    private struct Shelf: Codable, Equatable {
        var activeID: String?
        var books: [Book] = []
    }

    @Published private var shelf = Shelf()
    @Published private(set) var novel: StudyNovel?
    @Published var error: String?
    private let directory: URL
    private var persisted: Data?
    private var blocked = false

    var books: [Book] { shelf.books }
    var active: Book? { shelf.books.first { $0.id == shelf.activeID } }
    private var shelfFile: URL { directory.appendingPathComponent("shelf.json") }

    init(baseDirectory: URL? = nil) {
        directory = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("StudyNovels", isDirectory: true)
        guard FileManager.default.fileExists(atPath: shelfFile.path) else { return }
        do {
            let data = try Data(contentsOf: shelfFile)
            let saved = try JSONDecoder().decode(Shelf.self, from: data)
            guard Set(saved.books.map(\.id)).count == saved.books.count else { throw StudyNovelError.invalidFile }
            for book in saved.books {
                guard Self.validID(book.id), book.chapterCount > 0 else { throw StudyNovelError.invalidFile }
                try book.progress.validate(chapterCount: book.chapterCount)
            }
            if let id = saved.activeID {
                guard let entry = saved.books.first(where: { $0.id == id }) else { throw StudyNovelError.invalidFile }
                novel = try load(entry)
            }
            shelf = saved
            persisted = data
        } catch {
            blocked = true
            self.error = error.localizedDescription
        }
    }

    func importText(_ url: URL, records: [String: [ProfessionalRecallAttempt]]) {
        guard !blocked else { return }
        #if os(iOS) || os(macOS)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #endif
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  (1...StudyNovel.maximumFileSize).contains(size) else { throw StudyNovelError.invalidFile }
            let raw = try Data(contentsOf: url)
            let parsed = try StudyNovel.parse(raw, title: url.deletingPathExtension().lastPathComponent)
            if shelf.books.contains(where: { $0.id == parsed.id }) {
                select(parsed.id, records: records)
                return
            }
            var next = try updatedShelf(records: records)
            try checkHead()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = contentFile(parsed.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == raw else { throw StudyNovelError.invalidFile }
            } else {
                try DurableFile.write(raw, to: destination)
            }
            var progress = StudyNovelProgress()
            progress.startFrom(records)
            next.books.append(.init(id: parsed.id, title: parsed.title, chapterCount: parsed.chapters.count, progress: progress))
            next.activeID = parsed.id
            try save(next)
            novel = parsed
        } catch { self.error = error.localizedDescription }
    }

    func select(_ id: String, records: [String: [ProfessionalRecallAttempt]]) {
        guard !blocked, let index = shelf.books.firstIndex(where: { $0.id == id }) else { return }
        do {
            var next = try updatedShelf(records: records)
            if shelf.activeID == id { try save(next); return }
            let selected = try load(next.books[index])
            next.books[index].progress.startFrom(records)
            next.activeID = id
            try save(next)
            novel = selected
        } catch { self.error = error.localizedDescription }
    }

    func sync(_ records: [String: [ProfessionalRecallAttempt]]) {
        guard !blocked, active != nil else { return }
        do { try save(updatedShelf(records: records)) }
        catch { self.error = error.localizedDescription }
    }

    func open(_ index: Int) { updateReading { $0.open(index) } }
    func finish(_ index: Int) { updateReading { $0.finish(index) } }
    func bookmark(_ index: Int, paragraph: Int) { updateReading { $0.bookmark(index, paragraph: paragraph) } }

    private func updateReading(_ update: (inout StudyNovelProgress) -> Void) {
        guard !blocked, let index = shelf.books.firstIndex(where: { $0.id == shelf.activeID }) else { return }
        var next = shelf
        update(&next.books[index].progress)
        do { try save(next) }
        catch { self.error = error.localizedDescription }
    }

    private func updatedShelf(records: [String: [ProfessionalRecallAttempt]]) throws -> Shelf {
        var next = shelf
        if let index = next.books.firstIndex(where: { $0.id == next.activeID }) {
            let count = next.books[index].chapterCount
            try next.books[index].progress.consume(records, chapterCount: count)
        }
        return next
    }

    private func save(_ next: Shelf) throws {
        guard next != shelf else { return }
        try checkHead()
        let data = try JSONEncoder().encode(next)
        do {
            try DurableFile.write(data, to: shelfFile)
            guard try Data(contentsOf: shelfFile) == data else { throw StudyNovelError.invalidFile }
        } catch {
            blocked = true
            throw error
        }
        persisted = data
        shelf = next
        error = nil
    }

    private func checkHead() throws {
        let current = FileManager.default.fileExists(atPath: shelfFile.path) ? try Data(contentsOf: shelfFile) : nil
        guard current == persisted else { throw StudyNovelError.invalidFile }
    }

    private func load(_ entry: Book) throws -> StudyNovel {
        let file = contentFile(entry.id)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...StudyNovel.maximumFileSize).contains(size) else { throw StudyNovelError.invalidFile }
        let book = try StudyNovel.parse(Data(contentsOf: file), title: entry.title)
        guard book.id == entry.id, book.chapters.count == entry.chapterCount else {
            throw StudyNovelError.invalidFile
        }
        return book
    }

    private func contentFile(_ id: String) -> URL { directory.appendingPathComponent(id + ".txt") }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
