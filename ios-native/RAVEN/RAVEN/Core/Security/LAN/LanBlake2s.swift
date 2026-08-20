//
//  LanBlake2s.swift
//  RAVEN
//
//  Minimal BLAKE2s-256 + HMAC-BLAKE2s for Noise_XX_25519_ChaChaPoly_BLAKE2s.
//  Scoped to LAN Noise only — CryptoKit has no BLAKE2s.
//

import Foundation

enum LanBlake2s {
    private static let digestLength = 32
    private static let blockSize = 64

    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    private static let sigma: [[UInt8]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private struct State {
        var h: [UInt32]
        var t: [UInt64] = [0, 0]
        var f: [UInt64] = [0, 0]
        var buf = [UInt8]()
        var buflen = 0
    }

    static func hash(_ data: Data) -> [UInt8] {
        var param = [UInt8](repeating: 0, count: blockSize)
        param[0] = UInt8(digestLength)
        param[2] = 1
        param[3] = 1
        var h = iv
        for i in 0..<8 {
            let j = i * 4
            let p = UInt32(param[j])
                | (UInt32(param[j + 1]) << 8)
                | (UInt32(param[j + 2]) << 16)
                | (UInt32(param[j + 3]) << 24)
            h[i] ^= p
        }

        var state = State(h: h, buf: [UInt8](repeating: 0, count: blockSize))
        update(&state, data: [UInt8](data))
        return finalize(&state)
    }

    static func hmac(key: [UInt8], message: Data) -> [UInt8] {
        var k = key
        if k.count > blockSize {
            k = hash(Data(k))
        }
        if k.count < blockSize {
            k.append(contentsOf: [UInt8](repeating: 0, count: blockSize - k.count))
        }
        var ipad = [UInt8](repeating: 0x36, count: blockSize)
        var opad = [UInt8](repeating: 0x5c, count: blockSize)
        for i in 0..<blockSize {
            ipad[i] ^= k[i]
            opad[i] ^= k[i]
        }
        var inner = Data(ipad)
        inner.append(message)
        let innerHash = hash(inner)
        var outer = Data(opad)
        outer.append(contentsOf: innerHash)
        return hash(outer)
    }

    private static func incrementCounter(_ state: inout State, _ inc: UInt64) {
        let carry = state.t[0] &+ inc < state.t[0]
        state.t[0] &+= inc
        state.t[1] &+= carry ? 1 : 0
    }

    private static func update(_ state: inout State, data: [UInt8]) {
        var offset = 0
        var inlen = data.count
        while inlen > 0 {
            let left = state.buflen
            let fill = blockSize - left
            if inlen > fill {
                for i in 0..<fill {
                    state.buf[left + i] = data[offset + i]
                }
                state.buflen += fill
                incrementCounter(&state, UInt64(blockSize))
                compress(&state, block: state.buf, lastBlock: false)
                state.buflen = 0
                offset += fill
                inlen -= fill
            } else {
                for i in 0..<inlen {
                    state.buf[left + i] = data[offset + i]
                }
                state.buflen += inlen
                offset += inlen
                inlen = 0
            }
        }
    }

    private static func finalize(_ state: inout State) -> [UInt8] {
        incrementCounter(&state, UInt64(state.buflen))
        state.f[0] = UInt64.max
        if state.buflen < blockSize {
            for i in state.buflen..<blockSize {
                state.buf[i] = 0
            }
        }
        compress(&state, block: state.buf, lastBlock: true)
        var out = [UInt8]()
        out.reserveCapacity(digestLength)
        for word in state.h {
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return Array(out.prefix(digestLength))
    }

    private static func compress(_ state: inout State, block: [UInt8], lastBlock: Bool) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let j = i * 4
            m[i] = UInt32(block[j])
                | (UInt32(block[j + 1]) << 8)
                | (UInt32(block[j + 2]) << 16)
                | (UInt32(block[j + 3]) << 24)
        }

        var v = state.h + iv
        v[12] ^= UInt32(truncatingIfNeeded: state.t[0])
        v[13] ^= UInt32(truncatingIfNeeded: state.t[0] >> 32)
        v[14] ^= UInt32(truncatingIfNeeded: state.t[1])
        v[15] ^= UInt32(truncatingIfNeeded: state.t[1] >> 32)
        if lastBlock {
            v[14] ^= 0xFFFF_FFFF
        }

        for round in 0..<10 {
            let s = sigma[round]
            g(&v, 0, 4, 8, 12, m[Int(s[0])], m[Int(s[1])])
            g(&v, 1, 5, 9, 13, m[Int(s[2])], m[Int(s[3])])
            g(&v, 2, 6, 10, 14, m[Int(s[4])], m[Int(s[5])])
            g(&v, 3, 7, 11, 15, m[Int(s[6])], m[Int(s[7])])
            g(&v, 0, 5, 10, 15, m[Int(s[8])], m[Int(s[9])])
            g(&v, 1, 6, 11, 12, m[Int(s[10])], m[Int(s[11])])
            g(&v, 2, 7, 8, 13, m[Int(s[12])], m[Int(s[13])])
            g(&v, 3, 4, 9, 14, m[Int(s[14])], m[Int(s[15])])
        }

        for i in 0..<8 {
            state.h[i] ^= v[i] ^ v[i + 8]
        }
    }

    private static func g(
        _ v: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int,
        _ x: UInt32,
        _ y: UInt32
    ) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotateRight(v[d] ^ v[a], by: 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], by: 12)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotateRight(v[d] ^ v[a], by: 8)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], by: 7)
    }

    private static func rotateRight(_ value: UInt32, by amount: Int) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
