import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// Uses only 1,000 invented questions and 3,525 genuine synthetic Pocket
/// operations. The printed times are measured on the test runner, not iPhone.
final class PublicQuestionDualPerformanceTests: XCTestCase {
    @MainActor func testReplay3525RealSyntheticAnswers() async throws {
        let base = PublicQuestionDualFixtures.now
        let bank = PublicQuestionDualFixtures.bank(1_000)
        let hash = PublicQuestionDualFixtures.hash
        let legacy = try ExamLearningEngine.fresh(bank: bank, hash: hash, now: base)
        var archives: [Data] = []
        var total = 0, dayOffset = 0, step = 0
        var now = base
        let fixtureStart = ProcessInfo.processInfo.systemUptime
        while total < 3_525 {
            if legacy.record.presentation == nil {
                guard dayOffset < 1_000 else { XCTFail("could not generate enough real synthetic attempts"); return }
                now = base.addingTimeInterval(Double(dayOffset) * 86_400)
                dayOffset += 1; step = 0
                try legacy.start(day: UInt32(try ConceptCalendar.studyDay(now)), now: now)
                if legacy.record.presentation == nil { continue }
            }
            now = base.addingTimeInterval(Double(dayOffset - 1) * 86_400 + Double(step + 1))
            step += 1
            let p = try XCTUnwrap(legacy.record.presentation)
            try legacy.selectAndSubmit(total % 8 == 0 ? "B" : "A", presentationID: p.id, now: now)
            try legacy.nextQuestion(presentationID: p.id, now: now)
            total += 1
            if legacy.record.attempts.count >= 400 && total < 3_525 {
                let archive = try JSONEncoder().encode(legacy.record)
                let digest = StudySHA256.hex(archive), info = try legacy.info
                try legacy.rotate(reference: ExamVolumeReference(filename: digest + ".json", sha256: digest,
                    firstSequence: legacy.logBase + 1, lastSequence: info.log_records,
                    attemptCount: legacy.record.attempts.count))
                archives.append(archive)
            }
        }
        let fixtureSeconds = ProcessInfo.processInfo.systemUptime - fixtureStart
        XCTAssertEqual(archives.count * 400 + legacy.record.attempts.count, 3_525)
        let bytes = try JSONEncoder().encode(legacy.record)
        let migratedAt = now.addingTimeInterval(1)
        let capture = try PublicDualLegacyCapture.read(snapshot: legacy.record.snapshot,
                                                       bankCount: bank.questions.count, now: migratedAt)
        var started = ProcessInfo.processInfo.systemUptime
        let dual = try PublicQuestionDualFSRS(migrating: bank, hash: hash, record: legacy.record,
            legacyRecordBytes: bytes, priorVolumeBytes: archives, legacyTokens: capture.tokens,
            legacyItems: capture.items, now: migratedAt)
        let migrationSeconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(dual.state.legacyAttempts.count, 3_525)
        XCTAssertEqual(dual.state.legacyRatings.count, 3_525)
        if dual.presentation == nil { try dual.start(now: migratedAt.addingTimeInterval(1)) }
        let p = try XCTUnwrap(dual.presentation)
        started = ProcessInfo.processInfo.systemUptime
        try dual.selectAndSubmit("A", presentationID: p.id, now: migratedAt.addingTimeInterval(2))
        let ratingSeconds = ProcessInfo.processInfo.systemUptime - started
        started = ProcessInfo.processInfo.systemUptime
        let stateBytes = try JSONEncoder().encode(dual.state)
        let encodeSeconds = ProcessInfo.processInfo.systemUptime - started
        started = ProcessInfo.processInfo.systemUptime
        let restoredState = try JSONDecoder().decode(PublicQuestionDualState.self, from: stateBytes)
        let restored = try PublicQuestionDualFSRS(state: restoredState, bank: bank, hash: hash)
        let restoreSeconds = ProcessInfo.processInfo.systemUptime - started
        started = ProcessInfo.processInfo.systemUptime
        try restored.validateLegacy(recordBytes: bytes, priorVolumeBytes: archives)
        let anchorSeconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(restored.state, dual.state)
        XCTAssertEqual(restored.state.events.filter { $0.kind == "answer" }.count, 1)
        print(String(format: "PUBLIC_DUAL_SYNTHETIC_3525 fixture=%.3fs migration=%.3fs rating=%.3fs encode=%.3fs restore=%.3fs anchor=%.3fs bytes=%d volumes=%d",
            fixtureSeconds, migrationSeconds, ratingSeconds, encodeSeconds, restoreSeconds, anchorSeconds,
            stateBytes.count, archives.count))
    }
}
