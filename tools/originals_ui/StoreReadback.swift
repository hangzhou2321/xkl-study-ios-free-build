import Foundation

@main
struct OriginalPracticeHostReadback {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-originals-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hint = "real-bank-offline-v1:item/host-synthetic-hint"
        let choice = "real-bank-offline-v1:item/host-synthetic-choice"
        let position = "original-course-v1:circuit"
        let store = try OriginalPracticeStorage(directory: dir)
        try store.apply(key: hint, value: "assisted")
        try store.apply(key: choice, value: "{\"selected\":\"B\",\"correct\":false}")
        try store.apply(key: position, value: String(repeating: "synthetic.", count: 16))
        let reopened = try OriginalPracticeStorage(directory: dir)
        guard reopened.values == [hint: "assisted", choice: "{\"selected\":\"B\",\"correct\":false}", position: String(repeating: "synthetic.", count: 16)] else { throw NSError(domain: "host.reopen", code: 1) }
        try reopened.apply(key: hint, value: nil)
        try reopened.apply(key: choice, value: "B")
        try reopened.apply(key: position, value: "two")
        let final = try OriginalPracticeStorage(directory: dir)
        guard final.values == [choice: "B",position: "two"],store.values == final.values else { throw NSError(domain: "host.reopen", code: 2) }
        print("PASS_DARWIN_STORAGE aliases=3 atomicResize=true remove=true coldReopen=true")
    }
}
