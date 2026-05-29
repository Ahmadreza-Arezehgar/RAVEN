//
//  ATSAMKeyTree.swift
//  RAVEN — ATSAM
//
//  HKDF sub-key tree rooted at `ATSAMRootKey`. Every downstream
//  layer (BBE, Ghost Handshake, Ghost Route, PV-Stealth, PV seed
//  channel) derives its working key by calling `subKey(for: <label>)`.
//
//  Why a typed tree instead of letting callers HKDF themselves:
//
//    1. Single source of truth for label strings — adding a new
//       layer requires extending `ATSAMConstants.KDFLabel`, which
//       is checked at the central spec file rather than scattered
//       through call sites.
//    2. Compiler enforces non-overlap: two distinct labels are two
//       distinct `KDFLabel` values, and HKDF's PRG property
//       guarantees their outputs are indistinguishable from
//       independent uniform-random keys.
//    3. Caching: derived sub-keys can be cached on the tree
//       instance (lazy), avoiding the cost of re-HKDF on every
//       message. BBE in particular reads `K_BBE^(t)` once per
//       epoch.
//
//  Key-tree topology (PDF §7):
//
//      K_root
//        ├── K_BBE         (= subKey(.bbeDiscovery))
//        ├── K_BBE_rat     (= subKey(.bbeRatchet))
//        ├── K_pair_master (= subKey(.bbePairMaster))
//        ├── K_live        (= subKey(.ghostHandshakeLive))
//        ├── K_route       (= subKey(.ghostRouteRecipientTag))
//        ├── K_lookup      (= subKey(.pvStealthLookup))
//        └── K_pv_seed     (= subKey(.pvSeed))
//
//  Each branch is independently uniform-random given `K_root` is
//  uniform-random — provable from HKDF's PRG security.
//

import Foundation
import CryptoKit

/// HKDF key tree rooted at an `ATSAMRootKey`. Sub-keys are derived
/// lazily and cached for the lifetime of the tree instance.
final class ATSAMKeyTree: @unchecked Sendable {

    /// The root key — never exposed externally. All access goes
    /// through `subKey(for:)`.
    private let root: ATSAMRootKey

    /// Cache of derived sub-keys, keyed by label. Lazy population:
    /// the first call to `subKey(for: .bbeDiscovery)` populates the
    /// cache; subsequent calls return the cached bytes.
    ///
    /// Concurrency: `ATSAMKeyTree` is `@unchecked Sendable`. Reads
    /// and writes to `cache` are serialised through an unfair lock
    /// — the cache is keyed by label and each label populates
    /// exactly once, so contention is minimal.
    private var cache: [ATSAMConstants.KDFLabel: Data] = [:]
    private let cacheLock = NSLock()

    /// Build a key tree from a derived root. Caller owns the
    /// `ATSAMRootKey`; this struct just borrows it.
    init(root: ATSAMRootKey) {
        self.root = root
    }

    // MARK: - Sub-key derivation

    /// Derive (or fetch cached) sub-key for the given label.
    /// Output is `outputBytes` long (default 32 — matches every
    /// HMAC-SHA256 / AEAD key in the spec).
    ///
    /// Thread-safe; multiple callers may invoke concurrently and
    /// will see the same cached bytes.
    func subKey(for label: ATSAMConstants.KDFLabel,
                outputBytes: Int = ATSAMConstants.Sizes.subKeyBytes) -> Data {
        // Cache lookup under lock.
        cacheLock.lock()
        if let cached = cache[label], cached.count == outputBytes {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Compute outside the lock — HKDF is pure / no shared state.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: root._rootBytes),
            info: label.bytes,
            outputByteCount: outputBytes
        )
        let derivedBytes = derived.withUnsafeBytes { Data($0) }

        // Store back.
        cacheLock.lock()
        // Only cache the default-size derivation; non-default-size
        // derivations are rare and not worth the cache memory.
        if outputBytes == ATSAMConstants.Sizes.subKeyBytes {
            cache[label] = derivedBytes
        }
        cacheLock.unlock()

        return derivedBytes
    }

    // MARK: - Convenience accessors (named for code-search)

    /// BBE per-pair discovery key (`K_BBE`). Drives slot derivation
    /// at the BBE layer once it's built.
    var bbeDiscoveryKey: Data { subKey(for: .bbeDiscovery) }

    /// BBE ratchet key (`K_BBE_rat`). Mixed into each epoch's
    /// rolling beacon state.
    var bbeRatchetKey: Data { subKey(for: .bbeRatchet) }

    /// BBE per-pair master key (`K_pair_master`). Stable across
    /// epochs; drives the sequential-partition sort.
    var bbePairMasterKey: Data { subKey(for: .bbePairMaster) }

    /// Ghost Handshake live-confirmation key (`K_live`).
    var ghostHandshakeKey: Data { subKey(for: .ghostHandshakeLive) }

    /// Ghost Route recipient-tag derivation key (`K_route`).
    var ghostRouteKey: Data { subKey(for: .ghostRouteRecipientTag) }

    /// PV-Stealth rotating-lookup-tag key (`K_lookup`).
    var pvStealthLookupKey: Data { subKey(for: .pvStealthLookup) }

    /// PV pad seed-channel key (`K_pv_seed`). Wraps the pad
    /// exchange between Secure Enclave-protected devices.
    var pvSeedKey: Data { subKey(for: .pvSeed) }
}
