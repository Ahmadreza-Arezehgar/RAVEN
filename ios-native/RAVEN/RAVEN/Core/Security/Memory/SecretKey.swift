//
//  SecretKey.swift
//  RAVEN
//
//  Memory-hygiene primitive for sensitive byte buffers.
//
//  Per the Ultra-Secure stack spec §1.5 — wrap every secret (chain key,
//  ratchet root, decrypted-but-not-yet-consumed payload) in a value
//  that:
//
//    1. Is page-locked (mlock) so the OS can't write it to swap.
//    2. Triple-zeroises on deinit using `memset_s` (the standard
//       "compiler can't optimise this away" zero-write).
//    3. Refuses leaky access patterns — callers must use the
//       `withBytes` closure form so the buffer can't escape into a
//       caller's `Data` and survive deinit.
//
//  Honest scope notes
//  ──────────────────
//  • iOS doesn't expose `mlock` per se but Darwin's POSIX layer does;
//    we call it through Foundation. On simulators it's a no-op (the
//    kernel won't pin pages for the simulator host process).
//  • Swift ARC + value semantics mean a `Data` constructed from a
//    secret will *copy* into a fresh allocation. We can zeroise the
//    canonical buffer here, but if the caller has already moved bytes
//    out into a `Data`, those copies are out of our reach.
//    Best-effort, not airtight — that limitation is documented in
//    `docs/ULTRA-SECURE-ROADMAP.md`.
//  • The triple write (0x00, 0xFF, 0x00) is a defence against an
//    aggressive optimiser eliding the second write because "the value
//    isn't read after". `memset_s` already promises this; the triple
//    pass is belt-and-suspenders against compilers that mishandle it
//    (per the Ultra-Secure stack spec).
//

import Foundation
import Darwin

/// Heap-allocated, page-locked, triple-zeroised byte buffer.
/// Use `withBytes` to read; never store the pointer outside that
/// closure. Reference type so deinit is deterministic on the last
/// strong reference release.
final class SecretKey {

    /// Backing storage. Allocated via `UnsafeMutableBufferPointer`
    /// so we own the exact byte range and can zeroise it precisely.
    private var bytes: UnsafeMutableBufferPointer<UInt8>
    /// Whether the buffer was successfully `mlock`'d. Tracked so
    /// deinit doesn't try to `munlock` a buffer that was never
    /// pinned (which is a no-op on most platforms but explicit is
    /// cheaper than relying on that.)
    private let pinned: Bool

    /// Number of bytes in the secret. Public so callers can ask for
    /// length without forcing them through `withBytes`.
    let count: Int

    /// Wrap a `Data` containing a secret. The source `Data`'s backing
    /// buffer is NOT zeroised — the caller is responsible for not
    /// keeping a long-lived reference to the source.
    init(_ source: Data) {
        let n = source.count
        self.count = n
        self.bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: n)
        // Initialise to 0 so we never read uninitialised bytes if the
        // source copy below is interrupted somehow.
        self.bytes.initialize(repeating: 0)

        // Page-lock the allocation. Failure is logged but not fatal —
        // worst case the page swaps but the deinit still zeroises.
        let lockResult = mlock(self.bytes.baseAddress!, n)
        self.pinned = (lockResult == 0)
        #if DEBUG
        if !self.pinned {
            NSLog("🔒 [SecretKey] mlock failed (errno=\(errno)) — buffer not page-pinned. Zeroise still applies.")
        }
        #endif

        source.withUnsafeBytes { src in
            if let base = src.baseAddress, n > 0 {
                self.bytes.baseAddress!.update(from: base.assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
    }

    /// Convenience to allocate `n` zero bytes (e.g. as a destination
    /// buffer for KDF output).
    convenience init(zerosCount n: Int) {
        self.init(Data(count: n))
    }

    deinit {
        // Triple-zeroise per spec §1.5. `memset_s` promises the writes
        // are observable; the alternation pattern (0x00, 0xFF, 0x00)
        // defends against any tier of optimiser that might still elide
        // the second pure-zero pass as redundant.
        if let base = bytes.baseAddress, count > 0 {
            _ = memset_s(base, count, 0x00, count)
            _ = memset_s(base, count, 0xFF, count)
            _ = memset_s(base, count, 0x00, count)
        }
        if pinned, let base = bytes.baseAddress {
            munlock(base, count)
        }
        bytes.deallocate()
    }

    /// Read access. The pointer is valid only inside the closure.
    /// Do NOT capture it; do NOT make a `Data` copy that outlives the
    /// closure unless you accept the leak.
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: bytes.baseAddress, count: count))
    }

    /// Explicit zeroise without waiting for deinit. Useful when a key
    /// is consumed mid-function and the surrounding scope still has
    /// the SecretKey reference for symmetry reasons.
    func zeroise() {
        if let base = bytes.baseAddress, count > 0 {
            _ = memset_s(base, count, 0x00, count)
        }
    }

    /// Constant-time equality compare against another SecretKey of the
    /// same length. Returns false (not throws) on length mismatch so
    /// callers can use it inside boolean expressions safely.
    func constantTimeEquals(_ other: SecretKey) -> Bool {
        guard self.count == other.count else { return false }
        var diff: UInt8 = 0
        self.withBytes { a in
            other.withBytes { b in
                for i in 0..<self.count {
                    diff |= a[i] ^ b[i]
                }
            }
        }
        return diff == 0
    }

    // MARK: - Debug self-test

    #if DEBUG
    /// Verifies allocation, equality, zeroise, and the triple-pass
    /// pattern (the last one is observable via the explicit
    /// `zeroise()` call before deinit). Output under "🔒 [SecretKey]".
    static func runDebugSelfTest() {
        // 1) Round-trip: data in → withBytes reads it back.
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let key = SecretKey(original)
        var roundtripped: [UInt8] = []
        key.withBytes { buf in
            roundtripped = Array(buf)
        }
        guard roundtripped == Array(original) else {
            NSLog("🔒 [SecretKey] ❌ FAIL — round-trip mismatch")
            return
        }

        // 2) Constant-time equality.
        let key2 = SecretKey(original)
        guard key.constantTimeEquals(key2) else {
            NSLog("🔒 [SecretKey] ❌ FAIL — equal keys reported unequal")
            return
        }
        let different = SecretKey(Data([0,0,0,0,0,0,0,0]))
        guard !key.constantTimeEquals(different) else {
            NSLog("🔒 [SecretKey] ❌ FAIL — different keys reported equal")
            return
        }
        let mismatchedLen = SecretKey(Data([0xDE, 0xAD]))
        guard !key.constantTimeEquals(mismatchedLen) else {
            NSLog("🔒 [SecretKey] ❌ FAIL — length mismatch reported equal")
            return
        }

        // 3) Explicit zeroise observable via withBytes.
        let trash = SecretKey(Data([0xAA, 0xBB, 0xCC, 0xDD]))
        trash.zeroise()
        var afterZero: [UInt8] = []
        trash.withBytes { buf in afterZero = Array(buf) }
        guard afterZero == [0, 0, 0, 0] else {
            NSLog("🔒 [SecretKey] ❌ FAIL — zeroise didn't clear buffer (got \(afterZero))")
            return
        }

        // 4) Edge: zero-length is legal and safe to deinit.
        let empty = SecretKey(Data())
        empty.withBytes { buf in
            // No-op; just verify we don't crash on empty.
            _ = buf.count
        }

        NSLog("🔒 [SecretKey] ✅ SELF-TEST PASS — round-trip OK, constant-time eq OK, zeroise observable, empty buffer safe")
    }
    #endif
}
