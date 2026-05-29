// CoverTrafficEmitter.swift
//
// Phase E.1 — emit decoy frames on idle so a passive radio observer
// can't infer activity state from frame-rate. See
// `docs/RUM_V2_ROADMAP.md` §E.1 for the threat model.
//
// **Status**: scheduler-only today. Engine wiring deferred — when
// `SecurityConstants.coverTrafficEnabled` flips on, `BLEMeshEngine`
// (and siblings) will own the actual frame emission; this module just
// answers the question "should I emit a cover frame right now, and if
// not, when should I next ask?"
//
// BYTE-IDENTICAL sibling on Mac at
// `RAVEN-MacApp/RAVEN/Core/Security/CoverTrafficEmitter.swift`.

import Foundation

/// Decides when the engine should emit a cover-traffic frame.
///
/// Owned by the BLE engine and ticked from a single ``DispatchSourceTimer``.
/// State machine:
///
/// ```
/// .idle  ──[no real frame for `idleThresholdSeconds`]──▶  .armed
/// .armed ──[Poisson timer fires]──────────────────────▶  .emit one cover frame, back to .armed
/// .armed ──[real frame goes out]──────────────────────▶  .idle (timer reset)
/// ```
///
/// We use a Poisson process (exponentially-distributed inter-arrival
/// gaps) rather than a fixed interval because a fixed cadence is itself
/// a fingerprint — a passive observer who measures "frames arrive every
/// 90.0 s ±jitter" can subtract real traffic from cover.
public final class CoverTrafficEmitter {

    /// Override the system random for tests so the Poisson schedule is
    /// reproducible. Production callers pass nil and get
    /// `SystemRandomNumberGenerator`.
    private var rng: any RandomNumberGenerator
    private var lastRealFrameAt: Date
    /// Next time the engine should emit a cover frame. `nil` while
    /// we're in `.idle` (no real-traffic gap yet) or before the engine
    /// has called ``noteRealTraffic()`` for the first time.
    private var nextEmitAt: Date?
    /// Wall-clock provider — overridable for tests so we don't have to
    /// real-sleep through Poisson intervals.
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init,
                rng: (any RandomNumberGenerator)? = nil) {
        self.now = now
        self.rng = rng ?? SystemRandomNumberGenerator()
        self.lastRealFrameAt = now()
    }

    // MARK: - State transitions

    /// Engine calls this every time a real (non-cover) frame is sent.
    /// Resets the idle timer; cover scheduling pauses until idle
    /// threshold is crossed again.
    public func noteRealTraffic(at instant: Date? = nil) {
        lastRealFrameAt = instant ?? now()
        nextEmitAt = nil
    }

    /// Engine ticks this periodically (e.g. once per second). Returns
    /// `true` exactly once each time the Poisson timer fires — caller
    /// then encrypts a cover payload + broadcasts it.
    ///
    /// Returns `false` when:
    ///   - the feature is disabled,
    ///   - we haven't been idle long enough,
    ///   - the next-emit time hasn't arrived yet.
    public func shouldEmitNow() -> Bool {
        guard SecurityConstants.coverTrafficEnabled else { return false }

        let t = now()
        let idleFor = t.timeIntervalSince(lastRealFrameAt)
        guard idleFor >= SecurityConstants.Cover.idleThresholdSeconds else {
            // Engine is busy; no need to chaff.
            nextEmitAt = nil
            return false
        }

        if let scheduled = nextEmitAt {
            if t >= scheduled {
                // Fire and re-arm.
                nextEmitAt = t.addingTimeInterval(nextGap())
                return true
            }
            return false
        }

        // First arm after entering idle window.
        nextEmitAt = t.addingTimeInterval(nextGap())
        return false
    }

    /// Diagnostic — when does the emitter next plan to fire? Useful
    /// for engine logging and tests. nil before the first arm.
    public var scheduledNextEmit: Date? { nextEmitAt }

    // MARK: - Poisson sampling

    /// Draw the next inter-arrival gap from an exponential
    /// distribution with rate ``SecurityConstants/Cover/lambdaPerSecond``.
    /// Mean gap is `1 / lambda` (90 s by default); individual gaps can
    /// be much shorter or longer — that's the whole point.
    private func nextGap() -> TimeInterval {
        let lambda = SecurityConstants.Cover.lambdaPerSecond
        guard lambda > 0 else { return .greatestFiniteMagnitude }
        // Inverse-CDF transform: u in (0, 1] → -ln(u) / λ.
        // Clamp away from 0 to avoid infinity if the RNG hands us zero.
        let raw = Double.random(in: Double.ulpOfOne...1.0, using: &rng)
        return -log(raw) / lambda
    }
}

// MARK: - Cover payload helpers

extension CoverTrafficEmitter {
    /// Build a fixed-length random payload suitable for the cover
    /// frame body. Same length as ``SecurityConstants/Cover/payloadBucketBytes``
    /// so cover frames pad to the smallest envelope bucket and don't
    /// stand out by size.
    ///
    /// **Important**: this is the inner plaintext that gets handed to
    /// the Noise transport AEAD. After encryption + envelope encoding,
    /// the on-wire frame looks identical to a real text message of the
    /// same bucket size. A passive observer can't distinguish cover
    /// from real without breaking AEAD.
    ///
    /// Returns `nil` if the system CSPRNG fails — emitting an all-zero
    /// (or any predictable) cover frame would defeat the purpose of
    /// the cover-traffic exercise, so callers MUST check and skip the
    /// emission rather than substituting a fallback. The probability
    /// of `SecRandomCopyBytes` failing in normal operation is
    /// vanishingly small (basically only seen on devices with a wedged
    /// kernel-mode RNG), but treating "no entropy" as a hard fail
    /// keeps the privacy guarantee intact.
    public static func freshPayload() -> Data? {
        let size = SecurityConstants.Cover.payloadBucketBytes
        guard size > 0 else { return nil }
        var bytes = Data(count: size)
        let status = bytes.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress, buf.count > 0 else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, buf.count, base)
        }
        guard status == errSecSuccess else {
            // Defensive: zero the buffer before discarding so a memory
            // dump of the abandoned `Data` can't reveal whatever stale
            // bytes the allocator handed us. (CryptoKit-grade hygiene.)
            bytes.resetBytes(in: 0..<bytes.count)
            return nil
        }
        return bytes
    }
}
