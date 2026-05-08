// Pure-Swift MD5 implementation.
//
// We need MD5 for the longpoll-category derivation
// (md5(md5(apiToken) + str(radioID))[..9]) and we want zero third-party deps.
// On Apple platforms we *could* use CommonCrypto, but on Linux there's no
// equivalent in Foundation. Implementing the algorithm in ~70 lines keeps the
// SDK pure-SwiftPM and identical across platforms.
//
// The implementation follows RFC 1321. NOT for security-sensitive work — it's
// here only because the AudD streams API uses MD5 as an identifier-derivation
// function (no security claim). Output is the lowercase hex digest.
import Foundation

func Audd_md5Hex(_ input: String) -> String {
    let bytes = Array(input.utf8)
    let digest = md5(bytes)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private let md5Constants: [UInt32] = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
]

private let md5Shifts: [UInt32] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
]

private func md5(_ input: [UInt8]) -> [UInt8] {
    var msg = input
    let originalBitLength = UInt64(input.count) * 8

    // Padding: append 0x80 then zeros until length % 64 == 56
    msg.append(0x80)
    while msg.count % 64 != 56 {
        msg.append(0x00)
    }
    // Append original length in bits as little-endian 64-bit
    for i in 0..<8 {
        msg.append(UInt8((originalBitLength >> (8 * i)) & 0xff))
    }

    var a0: UInt32 = 0x67452301
    var b0: UInt32 = 0xefcdab89
    var c0: UInt32 = 0x98badcfe
    var d0: UInt32 = 0x10325476

    let chunkCount = msg.count / 64
    for chunk in 0..<chunkCount {
        var m = [UInt32](repeating: 0, count: 16)
        for j in 0..<16 {
            let i = chunk * 64 + j * 4
            m[j] = UInt32(msg[i])
                | (UInt32(msg[i + 1]) << 8)
                | (UInt32(msg[i + 2]) << 16)
                | (UInt32(msg[i + 3]) << 24)
        }
        var a = a0, b = b0, c = c0, d = d0
        for i in 0..<64 {
            var f: UInt32
            var g: Int
            if i < 16 {
                f = (b & c) | ((~b) & d)
                g = i
            } else if i < 32 {
                f = (d & b) | ((~d) & c)
                g = (5 * i + 1) % 16
            } else if i < 48 {
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            } else {
                f = c ^ (b | (~d))
                g = (7 * i) % 16
            }
            f = f &+ a &+ md5Constants[i] &+ m[g]
            a = d
            d = c
            c = b
            b = b &+ leftRotate(f, by: md5Shifts[i])
        }
        a0 = a0 &+ a
        b0 = b0 &+ b
        c0 = c0 &+ c
        d0 = d0 &+ d
    }

    var digest = [UInt8](repeating: 0, count: 16)
    for (i, value) in [a0, b0, c0, d0].enumerated() {
        digest[i * 4 + 0] = UInt8(value & 0xff)
        digest[i * 4 + 1] = UInt8((value >> 8) & 0xff)
        digest[i * 4 + 2] = UInt8((value >> 16) & 0xff)
        digest[i * 4 + 3] = UInt8((value >> 24) & 0xff)
    }
    return digest
}

private func leftRotate(_ x: UInt32, by amount: UInt32) -> UInt32 {
    return (x << amount) | (x >> (32 - amount))
}
