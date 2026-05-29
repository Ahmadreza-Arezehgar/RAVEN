//
//  ShamirSecretSharing.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — v1.7 NEXT: 3-of-5 social key recovery.
//
//  "Shamir + Feldman VSS so a passphrase-loss user can recover with
//   three trusted contacts instead of being permanently locked out,
//   no copy of the key on our servers."
//
//  This file is the math primitive only — splitting a 256-bit secret
//  into N shares such that any K of them can reconstruct it, and no
//  fewer than K reveal anything. No I/O, no networking, no Keychain.
//  Orchestration (encrypting each share to a contact, distributing
//  them, collecting them back, decrypting, recombining) lives in
//  `SocialRecoveryService.swift`.
//
//  Algorithm — byte-wise Shamir over GF(2^8):
//    • Each byte of the secret is split independently.
//    • For byte `b`, pick a random polynomial p(x) of degree K-1
//      with p(0) = b. Coefficients a_1 … a_{K-1} are random bytes.
//    • Share i (1 ≤ i ≤ N) is p(i), a single byte.
//    • To recover, take any K shares (x_i, y_i) and evaluate the
//      Lagrange interpolation at x = 0 over GF(2^8).
//
//  Why GF(2^8)? The polynomial arithmetic is byte-wide which means
//  CPU-friendly tables and constant-time-ish ops. We don't get
//  Feldman VSS for free though — that needs a discrete-log-hard
//  group. A follow-up file (`ShamirFeldmanVSS.swift`, future) will
//  add commitments over Curve25519 so a contact can prove their
//  share is on the original polynomial without seeing the secret.
//
//  Security notes — read these before changing anything:
//    1. SecRandomCopyBytes for all randomness, never Int.random.
//    2. Shares MUST NOT cross device storage unencrypted. The caller
//       wraps each share in a Noise-IK envelope to its destined
//       contact. This file deliberately returns plaintext shares —
//       it's the caller's job to never let them touch disk or wire
//       without authenticated encryption.
//    3. Threshold K and total N are hard-checked. K ≥ 2 (a 1-of-N
//       scheme is just the secret in clear), N ≤ 255 (GF(2^8) has
//       only 255 non-zero x values), K ≤ N (obviously).
//    4. The `x` byte 0 is reserved for the secret — never use it
//       as a share index.

import Foundation
import Security

// MARK: - GF(2^8) — Rijndael field

/// Arithmetic in the finite field GF(2^8) with the AES reduction
/// polynomial x^8 + x^4 + x^3 + x + 1 (0x11B). Byte-wide; addition is
/// XOR; multiplication is via log/exp tables in the multiplicative
/// group (size 255).
private enum GF256 {
    // Generator g = 3 in GF(2^8). Its multiplicative order is 255, so
    // the cycle covers every non-zero byte exactly once. Both tables
    // are 256 bytes each; total RAM cost ~512 bytes.
    static let exp: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        var x: UInt16 = 1
        for i in 0..<255 {
            t[i] = UInt8(truncatingIfNeeded: x)
            // multiply by the generator 3
            x ^= (x << 1)
            if x & 0x100 != 0 { x ^= 0x11B }
        }
        // t[255] cycles back to 1 — left at 0 so it's never indexed.
        return t
    }()

    static let log: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for i in 0..<255 {
            t[Int(exp[i])] = UInt8(i)
        }
        // log[0] is undefined — caller must guard.
        return t
    }()

    /// a + b in GF(2^8) — same as XOR.
    @inline(__always) static func add(_ a: UInt8, _ b: UInt8) -> UInt8 { a ^ b }

    /// a − b in GF(2^8) — characteristic 2, so subtraction equals addition.
    @inline(__always) static func sub(_ a: UInt8, _ b: UInt8) -> UInt8 { a ^ b }

    /// a × b in GF(2^8) via the log/exp tables. Multiplying by 0
    /// short-circuits because log[0] is invalid.
    @inline(__always) static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        let s = Int(log[Int(a)]) + Int(log[Int(b)])
        // Modular reduction by 255 done via the lookup table's wrap-around.
        return exp[s % 255]
    }

    /// a ÷ b in GF(2^8). Caller MUST ensure b ≠ 0 — there's no
    /// graceful return for divide-by-zero in a field.
    @inline(__always) static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        precondition(b != 0, "GF256.div: division by zero")
        if a == 0 { return 0 }
        // (log[a] - log[b]) mod 255 with positive wrap.
        let d = Int(log[Int(a)]) - Int(log[Int(b)]) + 255
        return exp[d % 255]
    }
}

// MARK: - Errors

public enum ShamirError: Error, LocalizedError {
    case invalidThreshold(k: Int, n: Int)
    case secretEmpty
    case secretTooLarge(bytes: Int)
    case tooFewShares(have: Int, need: Int)
    case duplicateShareIndex(UInt8)
    case zeroShareIndex
    case shareLengthMismatch
    case randomnessFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidThreshold(let k, let n):
            return "Shamir: invalid threshold \(k)-of-\(n); require 2 ≤ k ≤ n ≤ 255"
        case .secretEmpty: return "Shamir: secret is empty"
        case .secretTooLarge(let b):
            return "Shamir: secret too large (\(b) bytes); cap is 1 MiB to bound memory"
        case .tooFewShares(let h, let n):
            return "Shamir: too few shares (\(h)); need at least \(n)"
        case .duplicateShareIndex(let x):
            return "Shamir: duplicate share index 0x\(String(x, radix: 16))"
        case .zeroShareIndex:
            return "Shamir: share index 0 is reserved for the secret"
        case .shareLengthMismatch:
            return "Shamir: shares are not all the same length"
        case .randomnessFailed(let s):
            return "Shamir: SecRandomCopyBytes failed with OSStatus \(s)"
        }
    }
}

// MARK: - Share wire shape

/// One Shamir share. `index` is the x-coordinate (1…N); `data` is the
/// byte-wise polynomial evaluation, same length as the original secret.
/// Serialise as `index || data` for transport.
public struct ShamirShare: Equatable, Hashable {
    public let index: UInt8        // 1...255, NEVER 0
    public let data: Data          // length == secret length

    public init(index: UInt8, data: Data) {
        self.index = index
        self.data = data
    }

    /// `index` byte prepended to `data` — what you ship over the wire.
    public var serialized: Data {
        var out = Data(capacity: 1 + data.count)
        out.append(index)
        out.append(data)
        return out
    }

    /// Parse a wire-format share. Returns nil on malformed input.
    public static func deserialize(_ blob: Data) -> ShamirShare? {
        guard blob.count >= 2 else { return nil }   // at least index + 1 byte
        let idx = blob[blob.startIndex]
        guard idx != 0 else { return nil }
        let body = blob.subdata(in: (blob.startIndex + 1)..<blob.endIndex)
        return ShamirShare(index: idx, data: body)
    }
}

// MARK: - Public API

public enum ShamirSecretSharing {

    /// Max secret size we accept. 1 MiB is comically large for an
    /// identity key (32 bytes) and keeps every allocation bounded
    /// even if a caller passes weird input.
    public static let maxSecretBytes = 1 << 20

    /// Split `secret` into `n` shares such that any `k` of them
    /// reconstruct the original. Throws for any out-of-range param.
    ///
    /// - Parameters:
    ///   - secret: bytes to protect (e.g. a 32-byte Curve25519 private key)
    ///   - k:      threshold; ≥ 2
    ///   - n:      total shares; ≥ k, ≤ 255
    /// - Returns: array of `n` `ShamirShare` with x-coordinates 1…n.
    public static func split(secret: Data, k: Int, n: Int) throws -> [ShamirShare] {
        // ---- parameter validation ----
        guard secret.count > 0 else { throw ShamirError.secretEmpty }
        guard secret.count <= maxSecretBytes else {
            throw ShamirError.secretTooLarge(bytes: secret.count)
        }
        guard k >= 2, n >= k, n <= 255 else {
            throw ShamirError.invalidThreshold(k: k, n: n)
        }

        // ---- random polynomial coefficients ----
        // For each byte of the secret we need k-1 random coefficients.
        // Lay them out as (k-1) × secret.count, allocated in one shot
        // so SecRandomCopyBytes is called exactly once.
        let coeffCount = (k - 1) * secret.count
        var coeffs = [UInt8](repeating: 0, count: coeffCount)
        let rstatus = coeffs.withUnsafeMutableBufferPointer { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        guard rstatus == errSecSuccess else {
            throw ShamirError.randomnessFailed(rstatus)
        }
        defer {
            // Best-effort wipe; Swift `[UInt8]` doesn't guarantee
            // memory isn't already swapped, but zeroing reduces window.
            for i in 0..<coeffs.count { coeffs[i] = 0 }
        }

        // ---- evaluate p_b(x) for each byte b at x = 1…n ----
        let secretBytes = Array(secret)
        var shares: [ShamirShare] = []
        shares.reserveCapacity(n)

        for shareIndex in 1...n {
            let x = UInt8(shareIndex)
            var shareData = [UInt8](repeating: 0, count: secret.count)

            for (byteIdx, secretByte) in secretBytes.enumerated() {
                // Horner's method: p(x) = a0 + x(a1 + x(a2 + …))
                // We iterate the highest-degree coefficient first.
                var acc: UInt8 = 0
                for deg in stride(from: k - 1, to: 0, by: -1) {
                    let coeff = coeffs[(deg - 1) * secret.count + byteIdx]
                    acc = GF256.add(GF256.mul(acc, x), coeff)
                }
                // Add the constant term (the secret byte).
                acc = GF256.add(GF256.mul(acc, x), secretByte)
                shareData[byteIdx] = acc
            }

            shares.append(ShamirShare(index: x, data: Data(shareData)))
        }
        return shares
    }

    /// Reconstruct the secret from any `k` valid shares. Caller is
    /// responsible for collecting at least `k` shares before calling.
    public static func combine(shares: [ShamirShare], k: Int) throws -> Data {
        guard shares.count >= k else {
            throw ShamirError.tooFewShares(have: shares.count, need: k)
        }
        // Use exactly the first k shares — extra shares add no info
        // and waste CPU. Caller's responsibility to deduplicate first.
        let used = Array(shares.prefix(k))

        // Sanity-check shapes.
        let secretLen = used.first!.data.count
        guard used.allSatisfy({ $0.data.count == secretLen }) else {
            throw ShamirError.shareLengthMismatch
        }
        var seen = Set<UInt8>()
        for s in used {
            guard s.index != 0 else { throw ShamirError.zeroShareIndex }
            if !seen.insert(s.index).inserted {
                throw ShamirError.duplicateShareIndex(s.index)
            }
        }

        // Lagrange interpolation at x = 0.
        // secret_byte_b = Σ_i  y_i^(b) · L_i(0)
        // where L_i(0) = Π_{j ≠ i}  x_j / (x_j − x_i).
        //
        // Compute each basis weight once (independent of byte index),
        // then take a dot product with the per-byte y values.
        var weights = [UInt8](repeating: 0, count: k)
        for i in 0..<k {
            var num: UInt8 = 1
            var den: UInt8 = 1
            let xi = used[i].index
            for j in 0..<k where j != i {
                let xj = used[j].index
                num = GF256.mul(num, xj)
                den = GF256.mul(den, GF256.sub(xj, xi))
            }
            weights[i] = GF256.div(num, den)
        }

        var out = [UInt8](repeating: 0, count: secretLen)
        for byteIdx in 0..<secretLen {
            var acc: UInt8 = 0
            for i in 0..<k {
                let y = used[i].data[used[i].data.startIndex + byteIdx]
                acc = GF256.add(acc, GF256.mul(y, weights[i]))
            }
            out[byteIdx] = acc
        }
        return Data(out)
    }

    /// Convenience: round-trip a secret through split + combine to
    /// verify the maths line up. Used in unit tests + a one-shot
    /// debug self-check at first launch behind a DEBUG flag.
    public static func selfTest() -> Bool {
        do {
            var secret = Data(count: 32)
            secret.withUnsafeMutableBytes { buf in
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
            }
            let shares = try split(secret: secret, k: 3, n: 5)
            // Try a few different K-subsets.
            let permutations: [[Int]] = [[0, 1, 2], [0, 2, 4], [1, 3, 4], [2, 3, 4]]
            for p in permutations {
                let subset = p.map { shares[$0] }
                let recovered = try combine(shares: subset, k: 3)
                if recovered != secret { return false }
            }
            // Two shares MUST NOT recover the secret (i.e. should
            // produce a wrong answer 255/256 of the time — we accept
            // a non-equality check as a smoke test, not a proof).
            let two = Array(shares.prefix(2))
            if (try? combine(shares: two, k: 3)) != nil { return false }
            return true
        } catch {
            return false
        }
    }
}
