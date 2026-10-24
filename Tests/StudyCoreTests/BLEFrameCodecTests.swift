import XCTest
@testable import StudyCore

final class BLEFrameCodecTests: XCTestCase {
    func testKnownChecksumVectors() {
        XCTAssertEqual(StudySHA256.hex(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(StudySHA256.hex(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(StudySHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(StudyCRC32.checksum(Data("123456789".utf8)),0xcbf43926)
    }

    func testTwentyByteATTFragmentsDuplicateFramesAndWholeReplay() throws {
        let message=Data((0..<513).map { UInt8(truncatingIfNeeded:$0) })
        let frames=try BLEFrameCodec.encode(message:message,transferID:42,mtu:20)
        XCTAssertTrue(frames.allSatisfy { $0.count <= 20 })
        var decoder=BLEFrameCodec(), result:Data?
        for frame in frames {
            if let output=try decoder.consume(frame) { XCTAssertNil(result); result=output }
            XCTAssertNil(try decoder.consume(frame))
        }
        XCTAssertEqual(result,message)
        XCTAssertFalse(decoder.hasPartialMessage)
        for frame in frames { XCTAssertNil(try decoder.consume(frame)) }
    }

    func testDisconnectAndRestartResendsWholeMessage() throws {
        let message=Data(repeating:42,count:701)
        let frames=try BLEFrameCodec.encode(message:message,transferID:99,mtu:20)
        var decoder=BLEFrameCodec()
        for frame in frames.prefix(5) { XCTAssertNil(try decoder.consume(frame)) }
        XCTAssertTrue(decoder.hasPartialMessage)
        decoder.cancelCurrent()
        var completed:Data?
        for frame in frames { if let data=try decoder.consume(frame) { completed=data } }
        XCTAssertEqual(completed,message)
    }

    func testDamagedPayloadFailsCRCAndDoesNotEmit() throws {
        let message=Data(repeating:65,count:31)
        var frames=try BLEFrameCodec.encode(message:message,transferID:2,mtu:20)
        frames[2][12] ^= 1
        var decoder=BLEFrameCodec()
        for frame in frames.dropLast() { XCTAssertNil(try decoder.consume(frame)) }
        XCTAssertThrowsError(try decoder.consume(frames.last!)) { XCTAssertEqual($0 as? BLEFrameError,.checksumMismatch) }
        XCTAssertFalse(decoder.hasPartialMessage)
    }

    func testDifferentDuplicateOutOfOrderAndConcurrentMessageRejected() throws {
        let frames=try BLEFrameCodec.encode(message:Data(repeating:42,count:40),transferID:3)
        var decoder=BLEFrameCodec()
        XCTAssertNil(try decoder.consume(frames[0]))
        var damaged=frames[0]; damaged[12] ^= 1
        XCTAssertThrowsError(try decoder.consume(damaged)) { XCTAssertEqual($0 as? BLEFrameError,.changedDuplicate) }
        XCTAssertThrowsError(try decoder.consume(frames[1])) { XCTAssertEqual($0 as? BLEFrameError,.outOfOrder) }
        XCTAssertNil(try decoder.consume(frames[0]))
        let other=try BLEFrameCodec.encode(message:Data([1,2,3]),transferID:4)
        XCTAssertThrowsError(try decoder.consume(other[0])) { XCTAssertEqual($0 as? BLEFrameError,.unexpectedTransfer) }
    }

    func testMaximumAndMalformedLengthsRejectedBeforeAllocation() throws {
        XCTAssertThrowsError(try BLEFrameCodec.encode(message:Data(repeating:0,count:BLEFrameCodec.maximumWireSize+1),transferID:1))
        XCTAssertThrowsError(try BLEFrameCodec.encode(message:Data(),transferID:0))
        XCTAssertThrowsError(try BLEFrameCodec.encode(message:Data(),transferID:1,mtu:19))
        var decoder=BLEFrameCodec(maximumMessageSize:64)
        let tooLarge=try BLEFrameCodec.encode(message:Data(repeating:0,count:65),transferID:5)
        XCTAssertThrowsError(try decoder.consume(tooLarge[0])) { XCTAssertEqual($0 as? BLEFrameError,.messageTooLarge) }
        XCTAssertThrowsError(try decoder.consume(Data([1,2,3])))
    }

    func testEmptyMessageAndNegotiatedLargeMTU() throws {
        var decoder=BLEFrameCodec()
        let empty=try BLEFrameCodec.encode(message:Data(),transferID:7)
        XCTAssertEqual(empty.count,1)
        XCTAssertEqual(try decoder.consume(empty[0]),Data())
        let message=Data(repeating:0xa5,count:2_300_000)
        let frames=try BLEFrameCodec.encode(message:message,transferID:8,mtu:512)
        var result:Data?
        for frame in frames { if let out=try decoder.consume(frame) { result=out } }
        XCTAssertEqual(result,message)
    }
}
