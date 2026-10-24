import Foundation

public enum BLEFrameError: Error, Equatable {
    case messageTooLarge, invalidMTU, invalidHeader, unexpectedTransfer, outOfOrder
    case changedDuplicate, invalidLength, checksumMismatch
}

/// Each ATT value is one frame, never a concatenation of multiple frames.
/// Header (12 bytes): 58 4b, version=1, start/end flags, transfer UInt32 LE,
/// stream offset UInt32 LE. Stream is length UInt32 LE, CRC32 UInt32 LE, JSON.
/// Retrying an identical ATT frame is harmless. Out-of-order frames fail closed.
public struct BLEFrameCodec {
    public static let maximumWireSize = 4 * 1024 * 1024
    public static let headerSize = 12
    private let limit: Int
    private var transfer: UInt32?
    private var stream = Data()
    private var completedIDs: [UInt32] = []
    public var hasPartialMessage: Bool { transfer != nil }
    public var receivedByteCount: Int { stream.count }

    public init(maximumMessageSize: Int = BLEFrameCodec.maximumWireSize) {
        self.limit = max(0, min(maximumMessageSize, Self.maximumWireSize))
    }

    public static func encode(message: Data, transferID: UInt32, mtu: Int = 20) throws -> [Data] {
        guard message.count <= maximumWireSize else { throw BLEFrameError.messageTooLarge }
        guard mtu >= 20, mtu <= 65_535 else { throw BLEFrameError.invalidMTU }
        guard transferID != 0 else { throw BLEFrameError.invalidHeader }
        var stream = Data()
        put(UInt32(message.count), into: &stream)
        put(StudyCRC32.checksum(message), into: &stream)
        stream.append(message)
        let chunkSize = mtu - headerSize
        var frames: [Data] = []
        frames.reserveCapacity((stream.count + chunkSize - 1) / chunkSize)
        for offset in stride(from: 0, to: stream.count, by: chunkSize) {
            let end = min(offset + chunkSize, stream.count)
            let flags: UInt8 = (offset == 0 ? 1 : 0) | (end == stream.count ? 2 : 0)
            var frame = Data([0x58, 0x4b, 1, flags])
            put(transferID, into: &frame)
            put(UInt32(offset), into: &frame)
            frame.append(stream.subdata(in: offset..<end))
            frames.append(frame)
        }
        return frames
    }

    /// Decoder state can be kept across short disconnects. A new connection may
    /// reset it and resend the whole envelope; protocol transaction IDs dedupe it.
    public mutating func cancelCurrent() { transfer = nil; stream.removeAll(keepingCapacity: false) }

    public mutating func consume(_ frame: Data) throws -> Data? {
        do { return try consumeChecked(frame) }
        catch { cancelCurrent(); throw error }
    }

    private mutating func consumeChecked(_ frame: Data) throws -> Data? {
        let f = Array(frame)
        guard f.count > Self.headerSize, f.count <= 65_535,
              f[0] == 0x58, f[1] == 0x4b, f[2] == 1, f[3] & ~3 == 0 else { throw BLEFrameError.invalidHeader }
        let id = Self.get(f, 4), offset = Int(Self.get(f, 8)), flags = f[3]
        guard id != 0, (offset == 0) == (flags & 1 != 0) else { throw BLEFrameError.invalidHeader }
        if completedIDs.contains(id) { return nil }
        let body = Data(f.dropFirst(Self.headerSize))
        guard offset <= limit + 8, body.count <= limit + 8 - offset else { throw BLEFrameError.messageTooLarge }
        if transfer == nil {
            guard offset == 0 else { throw BLEFrameError.outOfOrder }
            transfer = id
        }
        guard transfer == id else { throw BLEFrameError.unexpectedTransfer }
        if offset < stream.count {
            guard offset + body.count <= stream.count else { throw BLEFrameError.changedDuplicate }
            guard stream.subdata(in: offset..<(offset + body.count)) == body else { throw BLEFrameError.changedDuplicate }
            return nil
        }
        guard offset == stream.count else { throw BLEFrameError.outOfOrder }
        stream.append(body)
        guard stream.count >= 8 else {
            if flags & 2 != 0 { throw BLEFrameError.invalidLength }
            return nil
        }
        let header = Array(stream.prefix(8))
        let size = Int(Self.get(header, 0))
        guard size <= limit else { throw BLEFrameError.messageTooLarge }
        guard stream.count <= size + 8 else { throw BLEFrameError.invalidLength }
        if flags & 2 == 0 {
            guard stream.count < size + 8 else { throw BLEFrameError.invalidLength }
            return nil
        }
        guard stream.count == size + 8 else { throw BLEFrameError.invalidLength }
        let message = stream.subdata(in: 8..<stream.count)
        guard StudyCRC32.checksum(message) == Self.get(header, 4) else { throw BLEFrameError.checksumMismatch }
        completedIDs.append(id)
        if completedIDs.count > 64 { completedIDs.removeFirst() }
        cancelCurrent()
        return message
    }

    private static func put(_ value: UInt32, into data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    private static func get(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24
    }
}
