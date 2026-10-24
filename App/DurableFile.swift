import Foundation
import Darwin

/// Same-directory replacement with a synchronized file and directory. The caller
/// must still fail closed on errors after rename and reload the durable journal.
enum DurableFile {
    static func write(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".pending-\(UUID().uuidString)")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) }
        guard descriptor >= 0 else { throw posixError("无法创建学习记录") }
        var fileOpen = true
        defer {
            if fileOpen { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: temporary.path)
#endif
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError("学习记录未写完整") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("学习记录未完成持久化") }
        guard Darwin.close(descriptor) == 0 else { fileOpen = false; throw posixError("学习记录文件关闭失败") }
        fileOpen = false
        let renameResult = temporary.path.withCString { from in
            destination.path.withCString { to in Darwin.rename(from, to) }
        }
        guard renameResult == 0 else { throw posixError("无法替换学习记录") }
        let directoryFD = parent.path.withCString { Darwin.open($0, O_RDONLY) }
        guard directoryFD >= 0 else { throw posixError("无法核对学习记录目录") }
        defer { Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else { throw posixError("学习记录目录尚未完成持久化，请重新打开应用核对") }
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(operation)：\(String(cString: strerror(code)))"])
    }
}
