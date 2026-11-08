import Foundation
import XCTest
import CPocket
@testable import StudyClientModel

final class PublicDualLegacyCaptureTests: XCTestCase {
    private let day: UInt32 = 20_745

    private func localNoon(day: UInt32) throws -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let absolute = Date(timeIntervalSince1970: Double(day) * 86_400)
        var fields = utc.dateComponents([.year, .month, .day], from: absolute)
        fields.hour = 12
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        return try XCTUnwrap(local.date(from: fields))
    }

    private func fixture() throws -> Data {
        var stream = [UInt8](repeating: 0, count: 16); stream[0] = 3
        let due: UInt32 = (day - 1) | (1 << 16) | (1 << 20)
        let tomorrow: UInt32 = (day + 1) | (1 << 16) | (1 << 20)
        let complete: UInt32 = UInt32(UInt16.max) | (1 << 20) | (1 << 22)
        var cards = [UInt32](repeating: complete, count: 310)
        for i in 0..<267 { cards[i] = due }
        for i in 267..<275 { cards[i] = tomorrow }
        for i in 275..<300 { cards[i] = 0 }
        let handle = cards.withUnsafeBufferPointer { cardBuffer in
            stream.withUnsafeBufferPointer { streamBuffer in
                xkl_engine_import_cards(310, cardBuffer.baseAddress, day, UInt32.max, streamBuffer.baseAddress)
            }
        }
        let engine = try XCTUnwrap(handle)
        defer { xkl_engine_free(engine) }
        XCTAssertTrue(xkl_engine_start(engine, day, 1))
        XCTAssertTrue(xkl_engine_reveal(engine, 2))
        XCTAssertTrue(xkl_engine_answer_exam(engine, 1, 3, false, 1, 1, nil, nil))
        var data = Data(count: xkl_engine_snapshot_size(engine))
        let written = data.withUnsafeMutableBytes {
            xkl_engine_snapshot(engine, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        XCTAssertEqual(written, data.count)
        return data
    }

    func testCapturesAllLegacyObligationsWithoutChangingSnapshot() throws {
        let data = try fixture(), before = data
        let result = try PublicDualLegacyCapture.read(snapshot: data, bankCount: 310, now: localNoon(day: day + 1))
        XCTAssertEqual(data, before)
        XCTAssertEqual(result.tokens.count, 52)
        XCTAssertEqual(result.items.count, 292)
        XCTAssertEqual(result.tokens.first?.word, result.items.first?.word)
        XCTAssertEqual(result.items.filter { $0.category == 1 }.count, 50)
        XCTAssertEqual(result.items.filter { $0.category == 2 }.count, 217)
        XCTAssertEqual(result.items.filter { $0.category == 3 }.count, 25)
        XCTAssertFalse(result.items.contains { (267..<275).contains(Int($0.word)) })
        let failed = try XCTUnwrap(result.items.first { $0.word == 0 })
        XCTAssertEqual(failed.stageMask, 146)
        XCTAssertEqual(failed.failedRound, 1)
    }

    func testCorruptionClockRollbackAndWrongBankFailClosed() throws {
        var data = try fixture()
        XCTAssertThrowsError(try PublicDualLegacyCapture.read(snapshot: data, bankCount: 100, now: localNoon(day: day)))
        XCTAssertThrowsError(try PublicDualLegacyCapture.read(snapshot: data, bankCount: 310, now: localNoon(day: day - 1)))
        data[data.count - 1] ^= 1
        XCTAssertThrowsError(try PublicDualLegacyCapture.read(snapshot: data, bankCount: 310, now: localNoon(day: day)))
    }
}
