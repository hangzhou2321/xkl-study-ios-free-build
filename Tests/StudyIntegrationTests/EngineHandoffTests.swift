import Foundation
import XCTest
import CPocket
import StudyCore

final class EngineHandoffTests: XCTestCase {
    let deck = "6509be5b320089b638219af4da5b42280e62c9960a6ba7cad67b225b8ec30e42"

    func seed() throws -> OpaquePointer {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/personal-state.bin")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Private personal seed stays local and is deliberately absent in cloud source builds")
        }
        let data = try Data(contentsOf: url)
        let stream: [UInt8] = Array(1...16)
        let pointer = data.withUnsafeBytes { raw in
            stream.withUnsafeBufferPointer { s in
                xkl_engine_seed(raw.bindMemory(to: UInt8.self).baseAddress, data.count, s.baseAddress)
            }
        }
        return try XCTUnwrap(pointer)
    }

    func snapshot(_ engine: OpaquePointer) throws -> Data {
        let count = xkl_engine_snapshot_size(engine)
        var data = Data(count: count)
        let written = data.withUnsafeMutableBytes { raw in
            xkl_engine_snapshot(engine, raw.bindMemory(to: UInt8.self).baseAddress, count)
        }
        XCTAssertEqual(written, count)
        return data
    }

    func restore(_ data: Data) throws -> OpaquePointer {
        try XCTUnwrap(data.withUnsafeBytes { raw in
            xkl_engine_restore(raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        })
    }

    func coordinator(_ initial: Data, _ id: String, active: Bool, peer: String) throws -> SyncCoordinator {
        let state = try SyncState.initial(profileID: "personal-profile", deviceID: id, deckVersion: deck,
                                          snapshot: initial, active: active, trustedPeerIDs: [peer])
        return try SyncCoordinator(state: state, snapshotValidator: { data in
            let p = data.withUnsafeBytes { raw in
                xkl_engine_restore(raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            guard let p else { throw SyncError.invalidSnapshot }
            xkl_engine_free(p)
        })
    }

    func apply(_ input: SyncInput, to coordinator: inout SyncCoordinator) throws -> SyncEffects {
        let transition = try coordinator.propose(input)
        // The real app fsyncs/atomically replaces the same archive before this call.
        return try coordinator.acknowledgePersistence(transition, persistedState: transition.encodedState)
    }

    func handoff(_ source: inout SyncCoordinator, _ destination: inout SyncCoordinator) throws {
        let offer = try XCTUnwrap(apply(.beginHandoff(peerID: destination.state.deviceID), to: &source).outgoing.first)
        XCTAssertFalse(source.state.canStudy)
        let wire = try offer.encoded()
        var codec = BLEFrameCodec()
        var received: Data?
        for frame in try BLEFrameCodec.encode(message: wire, transferID: 31, mtu: 185) {
            if let completed = try codec.consume(frame) { received = completed }
        }
        let decoded = try SyncEnvelope.decode(XCTUnwrap(received))
        let ready = try XCTUnwrap(apply(.receive(decoded), to: &destination).outgoing.first)
        XCTAssertFalse(destination.state.canStudy)
        let commit = try XCTUnwrap(apply(.receive(ready), to: &source).outgoing.first)
        let ack = try XCTUnwrap(apply(.receive(commit), to: &destination).outgoing.first)
        _ = try apply(.receive(ack), to: &source)
        XCTAssertTrue(destination.state.canStudy)
        XCTAssertFalse(source.state.canStudy)
        XCTAssertEqual(source.state.headHash, destination.state.headHash)
    }

    func testRealPersonalProgressAndWholeTaskSurviveRoundTrip() throws {
        let first = try seed()
        defer { xkl_engine_free(first) }
        let initial = try snapshot(first)
        XCTAssertEqual((0..<UInt32(25644)).filter { xkl_engine_card(first, $0) != 0 }.count, 8550)
        var phone = try coordinator(initial, "phone", active: true, peer: "epaper")
        var device = try coordinator(initial, "epaper", active: false, peer: "phone")
        XCTAssertTrue(xkl_engine_start(first, 20745, 1000))
        XCTAssertTrue(xkl_engine_reveal(first, 2000))
        XCTAssertTrue(xkl_engine_answer(first, 1, 3000))
        let progressed = try snapshot(first)
        _ = try apply(.localSnapshot(progressed), to: &phone)
        try handoff(&phone, &device)
        let second = try restore(device.state.snapshot)
        defer { xkl_engine_free(second) }
        for id in 0..<UInt32(25644) {
            XCTAssertEqual(xkl_engine_card(first, id), xkl_engine_card(second, id))
        }
        var a = xkl_info_t(), b = xkl_info_t()
        XCTAssertTrue(xkl_engine_info(first, &a)); XCTAssertTrue(xkl_engine_info(second, &b))
        XCTAssertEqual(a.total_remaining, b.total_remaining)
        XCTAssertEqual(a.stage, b.stage)
        XCTAssertTrue(xkl_engine_start(second, 20745, 1))
        XCTAssertFalse(xkl_engine_answer(second, 0, 2))
        XCTAssertTrue(xkl_engine_reveal(second, 3))
        XCTAssertTrue(xkl_engine_answer(second, 3, 4))
        _ = try apply(.localSnapshot(try snapshot(second)), to: &device)
        try handoff(&device, &phone)
        XCTAssertEqual(phone.state.snapshot, try snapshot(second))
        let third = try restore(phone.state.snapshot)
        defer { xkl_engine_free(third) }
        for id in 0..<UInt32(25644) {
            XCTAssertEqual(xkl_engine_card(second, id), xkl_engine_card(third, id))
        }
    }
}
