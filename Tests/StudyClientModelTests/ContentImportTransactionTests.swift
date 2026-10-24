import Foundation
import XCTest
@testable import StudyClientModel

final class ContentImportTransactionTests: XCTestCase {
    private enum Failure: Error, Equatable { case injected }

    func testPreparationFailureKeepsOldStateUsableAndNeverBeginsInstall() throws {
        var phases: [String] = []
        XCTAssertThrowsError(try ContentImportTransaction.perform(prepare: {
            phases.append("prepare")
            throw Failure.injected
        }, writeContent: { phases.append("write") },
           activateContent: { phases.append("activate") },
           persistBoundary: { phases.append("persist") },
           onCommitFailure: { phases.append("lock") })) {
            XCTAssertEqual($0 as? Failure, .injected)
        }
        XCTAssertEqual(phases, ["prepare"])
    }

    func testEveryCommitPhaseFailureLocksExactlyOnceAndStopsLaterPhases() throws {
        for failedPhase in ["write", "activate", "persist"] {
            var phases: [String] = []
            func run(_ phase: String) throws {
                phases.append(phase)
                if phase == failedPhase { throw Failure.injected }
            }
            XCTAssertThrowsError(try ContentImportTransaction.perform(
                prepare: { try run("prepare") }, writeContent: { try run("write") },
                activateContent: { try run("activate") }, persistBoundary: { try run("persist") },
                onCommitFailure: { phases.append("lock") })) {
                XCTAssertEqual($0 as? Failure, .injected)
            }
            let all = ["prepare", "write", "activate", "persist"]
            let end = try XCTUnwrap(all.firstIndex(of: failedPhase))
            XCTAssertEqual(phases, Array(all.prefix(end + 1)) + ["lock"])
        }
    }

    func testErrorsAfterReplacementPreserveActualDurableBytesWithoutRollback() throws {
        for failedPhase in ["write", "persist"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = directory.appendingPathComponent("content")
            let archive = directory.appendingPathComponent("archive")
            let oldContent = Data("old-content".utf8), newContent = Data("new-content".utf8)
            let oldArchive = Data("unchanged-snapshot-and-log; old-boundary".utf8)
            let newArchive = Data("unchanged-snapshot-and-log; appended-boundary".utf8)
            try oldContent.write(to: content)
            try oldArchive.write(to: archive)
            var locked = false
            XCTAssertThrowsError(try ContentImportTransaction.perform(prepare: {}, writeContent: {
                try newContent.write(to: content, options: .atomic)
                if failedPhase == "write" { throw Failure.injected }
            }, activateContent: {}, persistBoundary: {
                try newArchive.write(to: archive, options: .atomic)
                throw Failure.injected
            }, onCommitFailure: { locked = true }))
            XCTAssertTrue(locked)
            XCTAssertEqual(try Data(contentsOf: content), newContent)
            XCTAssertEqual(try Data(contentsOf: archive), failedPhase == "write" ? oldArchive : newArchive)
        }
    }

    func testSuccessRunsAllPhasesWithoutFailureCallback() throws {
        var phases: [String] = []
        try ContentImportTransaction.perform(prepare: { phases.append("prepare") },
            writeContent: { phases.append("write") }, activateContent: { phases.append("activate") },
            persistBoundary: { phases.append("persist") }, onCommitFailure: { phases.append("lock") })
        XCTAssertEqual(phases, ["prepare", "write", "activate", "persist"])
    }
}
