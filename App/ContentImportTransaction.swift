import Foundation

/// Coordinates a content-only update. This is not a two-file atomic commit:
/// either durable write can fail after replacement. Once installation starts,
/// the caller must stop using its in-memory state on every failure and reload
/// the actual files before allowing further learning.
enum ContentImportTransaction {
    static func perform(prepare: () throws -> Void,
                        writeContent: () throws -> Void,
                        activateContent: () throws -> Void,
                        persistBoundary: () throws -> Void,
                        onCommitFailure: () -> Void) throws {
        // A failed validation/backup has not replaced the active content.
        try prepare()
        do {
            try writeContent()
            try activateContent()
            try persistBoundary()
        } catch {
            // Do not guess whether an error happened before or after rename,
            // and do not overwrite a possibly committed archive with a rollback.
            onCommitFailure()
            throw error
        }
    }
}
