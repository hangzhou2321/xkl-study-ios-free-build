import Foundation
import Combine
import ImageIO
import StudyCore

private struct MathDiskArchive: Codable {
    var format = "xkl-math-disk-v1"
    var contentSHA256: String
    var events: [MathEvent]
    var importedPackageSHA256: String?
}

@MainActor final class MathStore: ObservableObject {
    @Published private(set) var engine: MathEngine?
    @Published var error: String?
    @Published private(set) var blocked = false
    var syllabus: Int?; var source: String?; var mode = "unseen"
    private let directory: URL
    private let clock: () -> Date
    private let writeData: (Data, URL) throws -> Void
    private var importedPackageSHA256: String?
    private var persistedContentHash: String?
    private var archiveURL: URL { directory.appendingPathComponent("archive.json") }
    init(directory: URL? = nil, clock: @escaping () -> Date = { Date() }, write: @escaping (Data, URL) throws -> Void = { try DurableFile.write($0,to:$1) }) {
        self.clock=clock
        self.writeData=write
        self.directory=directory ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("MathPractice",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:archiveURL.path) {
                let data=try Data(contentsOf:archiveURL); guard data.count <= MathContent.maximumBytes * 2 else { throw MathFailure.invalid("数学档案过大。") }
                let disk=try JSONDecoder().decode(MathDiskArchive.self,from:data)
                guard disk.format == "xkl-math-disk-v1", disk.contentSHA256.count == 64,
                      disk.contentSHA256.allSatisfy({ $0.isHexDigit }) else { throw MathFailure.invalid("数学档案引用无效。") }
                let bytes=try Data(contentsOf:self.directory.appendingPathComponent(disk.contentSHA256+".xklmath"))
                guard StudySHA256.hex(bytes) == disk.contentSHA256 else { throw MathFailure.invalid("数学内容校验失败。") }
                persistedContentHash=disk.contentSHA256
                importedPackageSHA256=disk.importedPackageSHA256
                let content=try MathContent.load(bytes); try Self.validateImages(content)
                engine=try MathEngine(archive:MathArchive(content:content,events:disk.events))
            }
        } catch { blocked=true; self.error=error.localizedDescription }
        if !blocked { processInbox() }
    }
    static func validateImages(_ content: MathContent) throws {
        for asset in content.assets {
            guard let data=Data(base64Encoded:asset.dataBase64), let image=CGImageSourceCreateWithData(data as CFData,nil),
                  CGImageSourceGetCount(image) == 1, let properties=CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
                  let width=properties[kCGImagePropertyPixelWidth] as? Int, let height=properties[kCGImagePropertyPixelHeight] as? Int,
                  width == asset.width, height == asset.height, CGImageSourceCreateThumbnailAtIndex(image,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceShouldCacheImmediately:false] as CFDictionary) != nil else {
                throw MathFailure.invalid("数学JPEG无法解码或尺寸与声明不一致。")
            }
        }
    }
    func importContent(from url: URL, expectedSHA256: String? = nil, expectedCourseID: String? = nil) {
        guard !blocked else { return }
        let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= MathContent.maximumBytes else { throw MathFailure.invalid("数学包超过256MiB。") }
            let bytes=try Data(contentsOf:url)
            guard expectedSHA256 == nil || StudySHA256.hex(bytes) == expectedSHA256 else { throw MathFailure.invalid("数学收件在导入前发生改变。") }
            let content=try MathContent.load(bytes)
            guard expectedCourseID == nil || content.id == expectedCourseID else { throw MathFailure.invalid("数学收件课程ID不匹配。") }
            try Self.validateImages(content)
            let candidate: MathEngine
            if let old=engine {
                guard old.archive.content.id == content.id else { throw MathFailure.invalid("此入口已有另一数学课程，不能覆盖其记录。") }
                try content.validateUpdate(from:old.archive.content)
                var record=old.archive; record.content=content; candidate=try MathEngine(archive:record)
                try writeData(try Data(contentsOf:archiveURL),directory.appendingPathComponent("backup-\(UUID().uuidString).json"))
            } else { candidate=try MathEngine(archive:MathArchive(content:content)) }
            try persist(candidate,contentChanged:true,packageSHA256:StudySHA256.hex(bytes)); engine=candidate; error=nil
        } catch { self.error=error.localizedDescription }
    }
    struct InboxRequest: Codable { var contentFile: String; var expectedSHA256: String; var courseID: String }
    struct InboxReceipt: Codable {
        var format = "xkl-math-inbox-receipt-v1"
        var requestSHA256: String; var contentSHA256: String?; var activeContentSHA256: String?; var courseID: String?
        var success: Bool; var message: String; var eventCount: Int; var questionCount: Int; var createdAt: Date
    }
    func processInbox(directory inboxOverride: URL? = nil) {
        guard !blocked else { return }
        let inbox=inboxOverride ?? directory.deletingLastPathComponent().appendingPathComponent("MathInbox",isDirectory:true)
        let requestURL=inbox.appendingPathComponent("request.json"), receiptURL=inbox.appendingPathComponent("receipt.json")
        guard FileManager.default.fileExists(atPath:requestURL.path) else { return }
        var requestHash="unreadable", contentHash: String?, courseID: String?
        do {
            let inboxValues=try inbox.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard inboxValues.isDirectory == true, inboxValues.isSymbolicLink != true else { throw MathFailure.invalid("数学收件目录不能是符号链接。") }
            let requestValues=try requestURL.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard requestValues.isRegularFile == true, requestValues.isSymbolicLink != true,
                  let size=requestValues.fileSize, size <= 65_536 else { throw MathFailure.invalid("数学收件请求不是受限普通文件。") }
            let bytes=try Data(contentsOf:requestURL); requestHash=StudySHA256.hex(bytes)
            let request=try JSONDecoder().decode(InboxRequest.self,from:bytes); courseID=request.courseID; contentHash=request.expectedSHA256
            // A success receipt is only a shortcut when the durable current
            // content and imported package hashes still match this exact request.
            if importedPackageSHA256 == request.expectedSHA256,
               engine?.archive.content.id == request.courseID,
               let receiptBytes=try? Data(contentsOf:receiptURL),
               let receipt=try? JSONDecoder().decode(InboxReceipt.self,from:receiptBytes),
               receipt.success, receipt.requestSHA256 == requestHash,
               receipt.contentSHA256 == request.expectedSHA256,
               receipt.activeContentSHA256 == persistedContentHash, persistedContentHash != nil {
                return
            }
            let name=request.contentFile
            guard !name.hasPrefix("."), name.hasSuffix(".xklmath"), !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }),
                  request.expectedSHA256.count == 64, request.expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  !request.courseID.isEmpty else { throw MathFailure.invalid("数学收件文件名、摘要或课程ID无效。") }
            let file=inbox.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == inbox.resolvingSymlinksInPath().standardizedFileURL else { throw MathFailure.invalid("数学收件文件越过收件目录。") }
            let values=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let count=values.fileSize, count <= MathContent.maximumBytes else { throw MathFailure.invalid("数学收件包不是受限普通文件。") }
            let data=try Data(contentsOf:file)
            guard StudySHA256.hex(data) == request.expectedSHA256 else { throw MathFailure.invalid("数学收件SHA256不匹配。") }
            let content=try MathContent.load(data)
            guard content.id == request.courseID else { throw MathFailure.invalid("数学收件课程ID不匹配。") }
            importContent(from:file,expectedSHA256:request.expectedSHA256,expectedCourseID:request.courseID)
            guard error == nil, !blocked, engine?.archive.content.id == request.courseID else { throw MathFailure.invalid(error ?? "数学收件未完成导入。") }
            let receipt=InboxReceipt(requestSHA256:requestHash,contentSHA256:contentHash,activeContentSHA256:persistedContentHash,courseID:courseID,success:true,message:"已由App校验并导入数学独立目录。",eventCount:engine?.archive.events.count ?? 0,questionCount:content.questions.count,createdAt:Date())
            try writeData(try JSONEncoder().encode(receipt),receiptURL)
        } catch {
            self.error=error.localizedDescription
            let receipt=InboxReceipt(requestSHA256:requestHash,contentSHA256:contentHash,activeContentSHA256:persistedContentHash,courseID:courseID,success:false,message:error.localizedDescription,eventCount:engine?.archive.events.count ?? 0,questionCount:engine?.archive.content.questions.count ?? 0,createdAt:Date())
            try? writeData(try JSONEncoder().encode(receipt),receiptURL)
        }
    }
    func questions(now: Date = Date()) -> [MathQuestion] {
        guard let engine else { return [] }
        let queued=engine.queue(now:now,syllabus:syllabus,source:source,wrongOnly:mode == "wrong")
        if mode == "unseen" { return queued.filter { engine.daily[$0.id] == nil } }
        if mode == "due" { return queued.filter { engine.daily[$0.id] != nil }.filter { q in
            !engine.archive.events.contains { $0.questionID == q.id && $0.kind == "grade" && $0.day == MathEngine.day(now) }
        } }
        if mode == "retry" { return queued.filter { q in engine.archive.events.contains { $0.questionID == q.id && $0.kind == "grade" && $0.day == MathEngine.day(now) } } }
        return queued
    }
    func start() { guard let q=questions(now:clock()).first else { return }; change { try $0.present(q,now:clock()) } }
    func reveal() { change { try $0.reveal(now:clock()) } }
    func answerPage() { change { try $0.answerPage(now:Date()) } }
    func grade(_ remembered: Bool, presentationID: UUID) {
        guard !blocked, let p=engine?.presentation, p.id == presentationID, p.revealed else { return }
        // Commit the actual grade first. A later PRESENT failure must never
        // roll back that completed rating or synthesize a rating for the next card.
        guard change({ try $0.grade(remembered:remembered,now:clock()) }) else { return }
        guard let next=questions(now:clock()).first else { return }
        _ = change { try $0.present(next,now:clock()) }
    }
    func leave() { guard var candidate=engine else { return }; candidate.clearPresentation(); engine=candidate }
    func export() throws -> URL {
        guard let engine else { throw MathFailure.invalid("尚未导入数学课程。") }
        let url=directory.appendingPathComponent("math-records-export.json")
        try writeData(try JSONEncoder().encode(engine.archive),url); return url
    }
    @discardableResult private func change(_ action: (inout MathEngine) throws -> Void) -> Bool {
        guard !blocked, var candidate=engine else { return false }
        do { try action(&candidate); try persist(candidate); engine=candidate; error=nil; return true }
        catch { self.error=error.localizedDescription; return false }
    }
    private func persist(_ candidate: MathEngine, contentChanged: Bool = false, packageSHA256: String? = nil) throws {
        do {
            let hash: String
            if contentChanged || persistedContentHash == nil {
                let bytes=try JSONEncoder().encode(candidate.archive.content)
                hash=StudySHA256.hex(bytes)
                let url=directory.appendingPathComponent(hash+".xklmath")
                if FileManager.default.fileExists(atPath:url.path) {
                    guard try Data(contentsOf:url) == bytes else { throw MathFailure.invalid("数学内容版本冲突。") }
                } else { try writeData(bytes,url) }
            } else { hash=persistedContentHash! }
            try writeData(try JSONEncoder().encode(MathDiskArchive(contentSHA256:hash,events:candidate.archive.events,importedPackageSHA256:packageSHA256 ?? importedPackageSHA256)),archiveURL)
            persistedContentHash=hash
            if let packageSHA256 { importedPackageSHA256=packageSHA256 }
        }
        catch { blocked=true; throw error }
    }
}
