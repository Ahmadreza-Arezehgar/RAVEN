//
//  LanDeterministicEd25519.swift
//  RAVEN
//
//  RFC 8032 deterministic Ed25519 sign for LAN bind KAT parity with Rust
//  ed25519-dalek. CryptoKit uses hedged signing and cannot match shared vectors.
//  Ported from TweetNaCl/ref10 shape (Apache-2.0 swift-os kernel/crypto/ed25519).
//

import CryptoKit
import Foundation

enum LanDeterministicEd25519 {
    static func publicKey(seed: Data) -> Data {
        precondition(seed.count == 32)
        var out = [UInt8](repeating: 0, count: 32)
        seed.withUnsafeBytes { seedPtr in
            out.withUnsafeMutableBytes { outPtr in
                ed25519PublicKey(seed: seedPtr.baseAddress!, publicKey: outPtr.baseAddress!)
            }
        }
        return Data(out)
    }

    static func sign(seed: Data, message: Data) -> Data {
        precondition(seed.count == 32)
        var sig = [UInt8](repeating: 0, count: 64)
        seed.withUnsafeBytes { seedPtr in
            message.withUnsafeBytes { msgPtr in
                sig.withUnsafeMutableBytes { sigPtr in
                    ed25519Sign(
                        message: msgPtr.baseAddress!,
                        messageLen: message.count,
                        seed: seedPtr.baseAddress!,
                        signature: sigPtr.baseAddress!
                    )
                }
            }
        }
        return Data(sig)
    }
}

// MARK: - RFC 8032 core (TweetNaCl field shape)

private typealias Gf = [Int64]

private let gf0: Gf = Array(repeating: 0, count: 16)
private let gf1: Gf = [1] + Array(repeating: 0, count: 15)
private let gfD: Gf = [
    0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
    0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203,
]
private let gfD2: Gf = [
    0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
    0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406,
]
private let gfX: Gf = [
    0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
    0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169,
]
private let gfY: Gf = [
    0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
]
private let gfI: Gf = [
    0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
    0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83,
]
private let orderL: [UInt8] = [
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
]

private struct Point {
    var x = gf0
    var y = gf1
    var z = gf1
    var t = gf0
}

private func sha512Bytes(_ input: UnsafeRawPointer, _ len: Int, _ out: UnsafeMutablePointer<UInt8>) {
    let digest = SHA512.hash(data: Data(bytes: input, count: len))
    digest.withUnsafeBytes { raw in
        guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        out.update(from: src, count: 64)
    }
}

private func car25519(_ o: inout Gf) {
    for i in 0..<16 {
        o[i] += (1 << 16)
        let c = o[i] >> 16
        if i < 15 {
            o[i + 1] += c - 1
        } else {
            o[0] += 38 * (c - 1)
        }
        o[i] -= c << 16
    }
}

private func sel25519(_ p: inout Gf, _ q: inout Gf, _ b: Int64) {
    let c = ~(b - 1)
    for i in 0..<16 {
        let t = c & (p[i] ^ q[i])
        p[i] ^= t
        q[i] ^= t
    }
}

private func pack25519(_ o: UnsafeMutablePointer<UInt8>, _ n: Gf) {
    var t = n
    car25519(&t); car25519(&t); car25519(&t)
    var m = gf0
    for _ in 0..<2 {
        m[0] = t[0] - 0xffed
        for i in 1..<15 {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
            m[i - 1] &= 0xffff
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
        let b = (m[15] >> 16) & 1
        m[14] &= 0xffff
        sel25519(&t, &m, 1 - b)
    }
    for i in 0..<16 {
        o[2 * i] = UInt8(truncatingIfNeeded: t[i])
        o[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
    }
}

private func unpack25519(_ o: inout Gf, _ n: UnsafePointer<UInt8>) {
    for i in 0..<16 {
        o[i] = Int64(n[2 * i]) + (Int64(n[2 * i + 1]) << 8)
    }
    o[15] &= 0x7fff
}

private func fadd(_ o: inout Gf, _ a: Gf, _ b: Gf) { for i in 0..<16 { o[i] = a[i] + b[i] } }
private func fsub(_ o: inout Gf, _ a: Gf, _ b: Gf) { for i in 0..<16 { o[i] = a[i] - b[i] } }

private func fmul(_ o: inout Gf, _ a: Gf, _ b: Gf) {
    var t = [Int64](repeating: 0, count: 31)
    for i in 0..<16 {
        for j in 0..<16 { t[i + j] += a[i] * b[j] }
    }
    for i in 0..<15 { t[i] += 38 * t[i + 16] }
    for i in 0..<16 { o[i] = t[i] }
    car25519(&o)
    car25519(&o)
}

private func fsquare(_ o: inout Gf, _ a: Gf) { fmul(&o, a, a) }

private func inv25519(_ o: inout Gf, _ i: Gf) {
    var c = i
    var a = 253
    while a >= 0 {
        fsquare(&c, c)
        if a != 2 && a != 4 { fmul(&c, c, i) }
        a -= 1
    }
    o = c
}

private func pow2523(_ o: inout Gf, _ i: Gf) {
    var c = i
    var a = 250
    while a >= 0 {
        fsquare(&c, c)
        if a != 1 { fmul(&c, c, i) }
        a -= 1
    }
    o = c
}

private func pointAdd(_ p: inout Point, _ q: Point) {
    var a = gf0, b = gf0, c = gf0, d = gf0, e = gf0, f = gf0, g = gf0, h = gf0, t = gf0
    fsub(&a, p.y, p.x); fsub(&t, q.y, q.x); fmul(&a, a, t)
    fadd(&b, p.x, p.y); fadd(&t, q.x, q.y); fmul(&b, b, t)
    fmul(&c, p.t, q.t); fmul(&c, c, gfD2)
    fmul(&d, p.z, q.z); fadd(&d, d, d)
    fsub(&e, b, a); fsub(&f, d, c); fadd(&g, d, c); fadd(&h, b, a)
    fmul(&p.x, e, f); fmul(&p.y, h, g); fmul(&p.z, g, f); fmul(&p.t, e, h)
}

private func pointCSwap(_ p: inout Point, _ q: inout Point, _ b: Int64) {
    sel25519(&p.x, &q.x, b); sel25519(&p.y, &q.y, b)
    sel25519(&p.z, &q.z, b); sel25519(&p.t, &q.t, b)
}

private func par25519(_ a: Gf) -> UInt8 {
    var bytes = [UInt8](repeating: 0, count: 32)
    pack25519(&bytes, a)
    return bytes[0] & 1
}

private func pointPack(_ r: UnsafeMutablePointer<UInt8>, _ p: Point) {
    var zi = gf0, tx = gf0, ty = gf0
    inv25519(&zi, p.z)
    fmul(&tx, p.x, zi); fmul(&ty, p.y, zi)
    pack25519(r, ty)
    r[31] ^= par25519(tx) << 7
}

private func pointScalarMult(_ q: inout Point, _ p: inout Point, _ s: UnsafePointer<UInt8>) {
    q = Point()
    var i = 255
    while i >= 0 {
        let b = Int64((s[i / 8] >> (i & 7)) & 1)
        pointCSwap(&q, &p, b)
        pointAdd(&p, q)
        pointAdd(&q, q)
        pointCSwap(&q, &p, b)
        i -= 1
    }
}

private func pointScalarBase(_ q: inout Point, _ s: UnsafePointer<UInt8>) {
    var p = Point()
    p.x = gfX; p.y = gfY; p.z = gf1
    fmul(&p.t, gfX, gfY)
    pointScalarMult(&q, &p, s)
}

private func modL(_ r: UnsafeMutablePointer<UInt8>, _ x: inout [Int64]) {
    var i = 63
    while i >= 32 {
        var carry: Int64 = 0
        for j in (i - 32)..<(i - 12) {
            x[j] += carry - 16 * x[i] * Int64(orderL[j - (i - 32)])
            carry = (x[j] + 128) >> 8
            x[j] -= carry << 8
        }
        x[i - 12] += carry
        x[i] = 0
        i -= 1
    }
    var carry: Int64 = 0
    for j in 0..<32 {
        x[j] += carry - (x[31] >> 4) * Int64(orderL[j])
        carry = x[j] >> 8
        x[j] &= 255
    }
    for j in 0..<32 { x[j] -= carry * Int64(orderL[j]) }
    for j in 0..<32 {
        x[j + 1] += x[j] >> 8
        r[j] = UInt8(truncatingIfNeeded: x[j] & 255)
    }
}

private func reduce64(_ r: UnsafeMutablePointer<UInt8>) {
    var x = [Int64](repeating: 0, count: 64)
    for i in 0..<64 { x[i] = Int64(r[i]) }
    for i in 0..<64 { r[i] = 0 }
    modL(r, &x)
}

private func ed25519PublicKey(seed: UnsafeRawPointer, publicKey out: UnsafeMutableRawPointer) {
    var d = [UInt8](repeating: 0, count: 64)
    sha512Bytes(seed, 32, &d)
    d[0] &= 248; d[31] &= 127; d[31] |= 64
    var p = Point()
    d.withUnsafeBufferPointer { ptr in
        pointScalarBase(&p, ptr.baseAddress!)
    }
    pointPack(out.assumingMemoryBound(to: UInt8.self), p)
}

private func ed25519Sign(
    message: UnsafeRawPointer,
    messageLen: Int,
    seed: UnsafeRawPointer,
    signature out: UnsafeMutableRawPointer
) {
    let msg = message.assumingMemoryBound(to: UInt8.self)
    let sig = out.assumingMemoryBound(to: UInt8.self)
    var d = [UInt8](repeating: 0, count: 64)
    sha512Bytes(seed, 32, &d)
    d[0] &= 248; d[31] &= 127; d[31] |= 64
    var pub = [UInt8](repeating: 0, count: 32)
    ed25519PublicKey(seed: seed, publicKey: &pub)

    var prefixMsg = [UInt8](repeating: 0, count: 32 + messageLen)
    for i in 0..<32 { prefixMsg[i] = d[32 + i] }
    for i in 0..<messageLen { prefixMsg[32 + i] = msg[i] }
    var r = [UInt8](repeating: 0, count: 64)
    prefixMsg.withUnsafeBufferPointer { ptr in
        sha512Bytes(ptr.baseAddress!, ptr.count, &r)
    }
    reduce64(&r)
    var rp = Point()
    r.withUnsafeBufferPointer { ptr in
        pointScalarBase(&rp, ptr.baseAddress!)
    }
    pointPack(sig, rp)

    var ram = [UInt8](repeating: 0, count: 64 + messageLen)
    for i in 0..<32 { ram[i] = sig[i] }
    for i in 0..<32 { ram[32 + i] = pub[i] }
    for i in 0..<messageLen { ram[64 + i] = msg[i] }
    var h = [UInt8](repeating: 0, count: 64)
    ram.withUnsafeBufferPointer { ptr in
        sha512Bytes(ptr.baseAddress!, ptr.count, &h)
    }
    reduce64(&h)

    var x = [Int64](repeating: 0, count: 64)
    for i in 0..<32 { x[i] = Int64(r[i]) }
    for i in 0..<32 {
        for j in 0..<32 { x[i + j] += Int64(h[i]) * Int64(d[j]) }
    }
    modL(sig + 32, &x)
}
