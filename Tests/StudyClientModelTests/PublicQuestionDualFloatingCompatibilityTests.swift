import Foundation
import XCTest
import StudyCore
@testable import StudyClientModel

/// All banks, ratings and archives in these tests are invented locally.
final class PublicQuestionDualFloatingCompatibilityTests: XCTestCase {
    @MainActor private func fixture() throws -> (ExamBank, PublicQuestionDualState, Data) {
        let bank = PublicQuestionDualFixtures.bank(5)
        let hash = PublicQuestionDualFixtures.hash
        let base = PublicQuestionDualFixtures.now
        let old = try ExamLearningEngine.fresh(bank: bank, hash: hash, now: base)
        try old.start(day: PublicQuestionDualFixtures.day, now: base)
        let bytes = try JSONEncoder().encode(old.record)
        let capture = try PublicDualLegacyCapture.read(snapshot: old.record.snapshot,
                                                        bankCount: bank.questions.count, now: base)
        let model = try PublicQuestionDualFSRS(migrating: bank, hash: hash, record: old.record,
            legacyRecordBytes: bytes, priorVolumeBytes: [], legacyTokens: capture.tokens,
            legacyItems: capture.items, now: base.addingTimeInterval(1))
        let presentation = try XCTUnwrap(model.presentation)
        try model.selectAndSubmit("A", presentationID: presentation.id, now: base.addingTimeInterval(2))
        return (bank, model.state, bytes)
    }

    @MainActor func testLastBitAndTinyRelativeDriftLoadsWithoutRewritingCache() async throws {
        let (bank, original, anchor) = try fixture()
        let id = try XCTUnwrap(original.daily.keys.first)
        var compatible = original
        var daily = try XCTUnwrap(compatible.daily[id]), all = try XCTUnwrap(compatible.all[id])
        daily.stability = daily.stability.nextUp
        daily.difficulty *= 1 + 5e-13
        all.stability *= 1 + 5e-13
        all.difficulty = all.difficulty.nextDown
        compatible.daily[id] = daily; compatible.all[id] = all
        XCTAssertNotEqual(compatible.daily[id], original.daily[id])
        XCTAssertNotEqual(compatible.all[id], original.all[id])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(compatible)
        let decoded = try JSONDecoder().decode(PublicQuestionDualState.self, from: before)
        let restored = try PublicQuestionDualFSRS(state: decoded, bank: bank, hash: PublicQuestionDualFixtures.hash)
        try restored.validateLegacy(recordBytes: anchor, priorVolumeBytes: [])
        XCTAssertEqual(restored.state, decoded)
        XCTAssertEqual(try encoder.encode(restored.state), before)
        XCTAssertEqual(restored.state.events, original.events)
        XCTAssertEqual(restored.state.queue, original.queue)
    }

    @MainActor func testRejectsMaterialDriftAndNonFiniteValuesOnBothTracks() async throws {
        let (bank, original, _) = try fixture()
        let id = try XCTUnwrap(original.daily.keys.first)
        func rejected(_ state: PublicQuestionDualState, line: UInt = #line) {
            XCTAssertThrowsError(try PublicQuestionDualFSRS(state: state, bank: bank,
                hash: PublicQuestionDualFixtures.hash), line: line)
        }
        var changed = original
        var memory = try XCTUnwrap(changed.daily[id]); memory.stability *= 1 + 2e-12
        changed.daily[id] = memory; rejected(changed)
        changed = original; memory = try XCTUnwrap(changed.all[id]); memory.difficulty *= 1 + 2e-12
        changed.all[id] = memory; rejected(changed)
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            changed = original; memory = try XCTUnwrap(changed.daily[id]); memory.stability = value
            changed.daily[id] = memory; rejected(changed)
            changed = original; memory = try XCTUnwrap(changed.all[id]); memory.difficulty = value
            changed.all[id] = memory; rejected(changed)
        }
        changed = original; memory = try XCTUnwrap(changed.daily[id]); memory.difficulty = 0.5
        changed.daily[id] = memory; rejected(changed)
    }

    @MainActor func testDiscreteScheduleKeysAndQueueRemainExact() async throws {
        let (bank, original, _) = try fixture()
        let id = try XCTUnwrap(original.daily.keys.first)
        func rejected(_ state: PublicQuestionDualState, line: UInt = #line) {
            XCTAssertThrowsError(try PublicQuestionDualFSRS(state: state, bank: bank,
                hash: PublicQuestionDualFixtures.hash), line: line)
        }
        var changed = original
        var memory = try XCTUnwrap(changed.daily[id]); memory.dueDay += 1
        memory.stability = memory.stability.nextUp
        changed.daily[id] = memory; rejected(changed)
        changed = original; memory = try XCTUnwrap(changed.daily[id]); memory.lastDay += 1
        changed.daily[id] = memory; rejected(changed)
        changed = original; memory = try XCTUnwrap(changed.all[id])
        memory.timestampMs = try XCTUnwrap(memory.timestampMs) + 1
        changed.all[id] = memory; rejected(changed)
        changed = original
        let moved = try XCTUnwrap(changed.daily.removeValue(forKey: id))
        changed.daily["invented-other-id"] = moved; rejected(changed)
        changed = original
        XCTAssertGreaterThanOrEqual(changed.queue.count, 2)
        changed.queue.swapAt(0, 1); rejected(changed)
    }
}
