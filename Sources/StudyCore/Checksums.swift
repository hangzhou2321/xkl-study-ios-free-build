import Foundation

/// Dependency-free checksums shared by the durable handoff and wire framing.
public enum StudySHA256 {
    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> Data {
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
        ]
        var bytes = Array(data)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitCount >> shift)) }
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        @inline(__always) func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for base in stride(from: 0, to: bytes.count, by: 64) {
            for j in 0..<16 {
                let i = base + j * 4
                w[j] = UInt32(bytes[i]) << 24 | UInt32(bytes[i+1]) << 16 | UInt32(bytes[i+2]) << 8 | UInt32(bytes[i+3])
            }
            for j in 16..<64 {
                let a = w[j-15], b = w[j-2]
                w[j] = w[j-16] &+ (rotate(a,7) ^ rotate(a,18) ^ (a >> 3)) &+ w[j-7] &+ (rotate(b,17) ^ rotate(b,19) ^ (b >> 10))
            }
            var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], z=h[7]
            for j in 0..<64 {
                let t1 = z &+ (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) &+ ((e & f) ^ (~e & g)) &+ k[j] &+ w[j]
                let t2 = (rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                z=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
            }
            let v = [a,b,c,d,e,f,g,z]
            for j in 0..<8 { h[j] = h[j] &+ v[j] }
        }
        var out = Data()
        for value in h { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        return out
    }
}

public enum StudyCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 { c = (c & 1) == 1 ? (c >> 1) ^ 0xedb88320 : c >> 1 }
        return c
    }
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}
