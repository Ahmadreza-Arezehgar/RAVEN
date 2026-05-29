//
//  SocialRecoveryVSS.swift
//  RAVEN
//
//  🔴 v1.8 (2026-05-21) — verifiable secret sharing for social
//  recovery. v1.8 roadmap feature #1.
//
//  WHAT THIS ADDS
//  --------------
//  v1.7 shipped plain Shamir 3-of-5 social recovery (ShamirSecret-
//  Sharing.swift + SocialRecoveryService.swift). Plain Shamir has one
//  gap: at recovery time a trusted contact can hand back a CORRUPTED
//  share. Lagrange interpolation happily folds garbage into a garbage
//  key, and the user has no way to tell which contact cheated — or
//  that anyone cheated at all — until the restored key simply fails.
//
//  This file closes that gap with a commitment layer. At enrol time
//  the device publishes a one-way HASH COMMITMENT for every share and
//  one for the secret. At recovery time each returned share is checked
//  against its commitment, so a corrupt share is REJECTED and the
//  cheating contact is named — before reconstruction even runs.
//
//  WHY NOT TEXTBOOK FELDMAN VSS
//  ---------------------------
//  Feldman VSS publishes g^{a_j} commitments to the polynomial
//  coefficients and verifies a share with the homomorphic identity
//      g^{p(i)} == Π_j  C_j^{(i^j)}.
//  That identity only holds in a discrete-log group whose scalar
//  addition matches how the polynomial's exponents add. RAVEN's
//  Shamir is byte-wise over GF(2^8) (see ShamirSecretSharing.swift) —
//  its "addition" is XOR. No discrete-log group has XOR as its scalar
//  operation, so the Feldman identity cannot be evaluated over our
//  shares. Converting the scheme to a prime field WOULD admit textbook
//  Feldman, but it would also change ShamirShare's byte layout and
//  break every v1.7 user who has already distributed shares — a hard
//  no under the v1.8 "don't cut off current users" constraint.
//
//  HASH-COMMITMENT VSS — what it does and does not guarantee
//  ---------------------------------------------------------
//  • Binds each share: a contact CANNOT return a different share than
//    the one it was given without breaking SHA-256 preimage
//    resistance ⇒ a corrupt/forged share is detected and named.
//  • Binds the secret: the reconstructed key is checked against the
//    secret commitment AND against the owner fingerprint.
//  • It does NOT let a contact verify, at enrol time, that all shares
//    lie on ONE degree-(k-1) polynomial — the one extra property
//    textbook Feldman has that a hash commitment cannot give. In
//    RAVEN's threat model the dealer is the user's OWN device, which
//    has no incentive to mis-split its own key, and any dealer
//    inconsistency still surfaces at recovery as a secret-commitment
//    mismatch. So the practical guarantee — "no contact can feed you
//    a bad share undetected" — is fully met.
//
//  WIRE COMPATIBILITY
//  ------------------
//  Commitments ride as an OPTIONAL trailing block on RecoveryShare-
//  Envelope (magic "RVSF"). The envelope's own version byte stays 1,
//  so a v1.7 device parses the envelope and silently ignores the
//  trailing bytes. A v1.8 device recovering a v1.7 envelope sees no
//  commitments and falls back to best-effort verification against the
//  owner fingerprint. Nothing breaks in either direction — mesh
//  relay and bridge carry the envelope as an opaque blob regardless.

import Foundation
import CryptoKit
import Security

// MARK: - Commitment set

/// The hash commitments a device publishes when it enrols a secret
/// for social recovery: one commitment per share plus one for the
/// secret itself. Distributed to every trusted contact as a trailing
/// block on their `RecoveryShareEnvelope`, so the recovering device
/// can check a returned share without ever learning the share.
///
/// On-wire byte layout (matches `encode()` / `decode()`):
///   magic    : "RVSF" (4 bytes) — RAVEN Social-recovery VSS Format
///   version  : 1 (1 byte)
///   cmtLen   : 32 (1 byte) — bytes per commitment (SHA-256)
///   n        : 1 byte — number of share commitments
///   secret   : cmtLen bytes — commitment to the secret
///   shares   : n × cmtLen bytes — commitment to share 1, 2, … n
public struct RecoveryCommitmentSet: Equatable, Hashable {
    public static let magic: [UInt8] = [0x52, 0x56, 0x53, 0x46] // "RVSF"
    public static let version: UInt8 = 1

    /// Bytes per commitment. SHA-256 ⇒ 32. Fixed for format v1.
    public static let commitmentBytes = 32

    /// Commitment to the secret: `SocialRecoveryVSS.secretDigest`.
    public let secretCommitment: Data
    /// Commitment to share i, stored 0-based: `shareCommitments[i-1]`
    /// is the commitment for Shamir share index i. RAVEN's Shamir
    /// always issues contiguous indices 1…n, so positional storage is
    /// unambiguous.
    public let shareCommitments: [Data]

    public init(secretCommitment: Data, shareCommitments: [Data]) {
        self.secretCommitment = secretCommitment
        self.shareCommitments = shareCommitments
    }

    /// Number of share commitments — equals the enrolment's `n`.
    public var n: Int { shareCommitments.count }

    // MARK: Verification

    /// True iff `share` matches the commitment recorded for its index.
    /// A contact that returns a tampered share fails this check.
    public func verifies(share: ShamirShare, ownerFingerprint: Data) -> Bool {
        let idx = Int(share.index)
        guard idx >= 1, idx <= shareCommitments.count else { return false }
        let expected = shareCommitments[idx - 1]
        let actual = SocialRecoveryVSS.shareDigest(
            shareIndex: share.index,
            shareData: share.data,
            ownerFingerprint: ownerFingerprint
        )
        return SocialRecoveryVSS.constantTimeEqual(expected, actual)
    }

    /// True iff `secret` matches the secret commitment. Used as the
    /// final integrity gate after Lagrange reconstruction.
    public func verifies(secret: Data, ownerFingerprint: Data) -> Bool {
        let actual = SocialRecoveryVSS.secretDigest(
            secret: secret,
            ownerFingerprint: ownerFingerprint
        )
        return SocialRecoveryVSS.constantTimeEqual(secretCommitment, actual)
    }

    // MARK: Wire format

    /// Exact encoded size for an `n`-share set — handy for decoders.
    public static func encodedLength(n: Int) -> Int {
        // magic(4) + version(1) + cmtLen(1) + n(1) + secret(32) + n×32
        return 4 + 1 + 1 + 1 + commitmentBytes + n * commitmentBytes
    }

    public func encode() -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(UInt8(Self.commitmentBytes))
        out.append(UInt8(truncatingIfNeeded: shareCommitments.count))
        out.append(secretCommitment)
        for c in shareCommitments { out.append(c) }
        return out
    }

    /// Parse a commitment block. Returns `nil` on any malformed input
    /// — callers treat that as "no commitments" (fail-soft) rather
    /// than rejecting the surrounding envelope.
    public static func decode(_ raw: Data) -> RecoveryCommitmentSet? {
        // Normalise: a fresh buffer so startIndex == 0 even if `raw`
        // arrived as a slice of a larger envelope.
        let blob = Data(raw)
        let headerLen = 4 + 1 + 1 + 1
        guard blob.count >= headerLen + commitmentBytes else { return nil }
        var i = blob.startIndex
        guard Array(blob[i..<(i + 4)]) == magic else { return nil }
        i += 4
        guard blob[i] == version else { return nil }
        i += 1
        let cmtLen = Int(blob[i]); i += 1
        guard cmtLen == commitmentBytes else { return nil }
        let n = Int(blob[i]); i += 1
        let total = headerLen + commitmentBytes + n * commitmentBytes
        guard blob.count >= total else { return nil }
        let secret = blob.subdata(in: i..<(i + commitmentBytes))
        i += commitmentBytes
        var shares: [Data] = []
        shares.reserveCapacity(n)
        for _ in 0..<n {
            shares.append(blob.subdata(in: i..<(i + commitmentBytes)))
            i += commitmentBytes
        }
        return RecoveryCommitmentSet(
            secretCommitment: secret,
            shareCommitments: shares
        )
    }
}

// MARK: - VSS engine

/// Stateless helpers that compute and check the hash commitments.
/// Pure functions over `CryptoKit.SHA256` — no I/O, no Keychain, no
/// networking. Safe to call from any context.
public enum SocialRecoveryVSS {

    /// Domain-separation tag. Mixed into every digest so a commitment
    /// can never be replayed as some other RAVEN hash (an ATSAM
    /// transcript, a Vault `RVNV1` blob, …). Bump the trailing version
    /// only if the construction itself changes.
    public static let domain = Data("raven-social-recovery-vss-v1".utf8)

    /// Tag byte distinguishing the secret digest from share digests.
    /// Shamir share indices are always 1…n, so 0x00 is free for the
    /// secret and can never collide with a share's index byte.
    private static let secretTag: UInt8 = 0x00

    /// SHA-256 commitment to one share:
    ///   H( domain ‖ ownerFP ‖ [shareIndex] ‖ shareData )
    public static func shareDigest(
        shareIndex: UInt8,
        shareData: Data,
        ownerFingerprint: Data
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: domain)
        hasher.update(data: ownerFingerprint)
        hasher.update(data: Data([shareIndex]))
        hasher.update(data: shareData)
        return Data(hasher.finalize())
    }

    /// SHA-256 commitment to the secret:
    ///   H( domain ‖ ownerFP ‖ [0x00] ‖ secret )
    public static func secretDigest(
        secret: Data,
        ownerFingerprint: Data
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: domain)
        hasher.update(data: ownerFingerprint)
        hasher.update(data: Data([secretTag]))
        hasher.update(data: secret)
        return Data(hasher.finalize())
    }

    /// Build the full commitment set for an enrolment.
    public static func computeCommitments(
        secret: Data,
        shares: [ShamirShare],
        ownerFingerprint: Data
    ) -> RecoveryCommitmentSet {
        // Shamir issues contiguous indices 1…n; sort defensively so
        // shareCommitments[i-1] is always the commitment for index i.
        let ordered = shares.sorted { $0.index < $1.index }
        let shareCmts = ordered.map {
            shareDigest(
                shareIndex: $0.index,
                shareData: $0.data,
                ownerFingerprint: ownerFingerprint
            )
        }
        return RecoveryCommitmentSet(
            secretCommitment: secretDigest(
                secret: secret,
                ownerFingerprint: ownerFingerprint
            ),
            shareCommitments: shareCmts
        )
    }

    /// Constant-time equality for two digests. The length check itself
    /// is not secret — commitments are public and fixed-size.
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let ab = [UInt8](a)
        let bb = [UInt8](b)
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

#if DEBUG
extension SocialRecoveryVSS {
    /// One-shot self-check: enrol → verify every share → tamper →
    /// confirm rejection → round-trip the wire format. Returns true
    /// only if every invariant holds. Mirrors
    /// `ShamirSecretSharing.selfTest()`.
    public static func selfTest() -> Bool {
        do {
            // Random 32-byte secret + a plausible owner fingerprint
            // (the fingerprint really is SHA-256 of the secret).
            var secret = Data(count: 32)
            secret.withUnsafeMutableBytes { buf in
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
            }
            let ownerFP = Data(SHA256.hash(data: secret))

            let shares = try ShamirSecretSharing.split(secret: secret, k: 3, n: 5)
            let commitments = computeCommitments(
                secret: secret, shares: shares, ownerFingerprint: ownerFP
            )

            // 1. Every genuine share verifies.
            for s in shares {
                guard commitments.verifies(share: s, ownerFingerprint: ownerFP)
                else { return false }
            }
            // 2. The genuine secret verifies.
            guard commitments.verifies(secret: secret, ownerFingerprint: ownerFP)
            else { return false }

            // 3. A tampered share is REJECTED.
            var bad = [UInt8](shares[0].data)
            bad[0] ^= 0xFF
            let tampered = ShamirShare(index: shares[0].index, data: Data(bad))
            if commitments.verifies(share: tampered, ownerFingerprint: ownerFP) {
                return false
            }
            // 4. A tampered secret is REJECTED.
            var badSecret = [UInt8](secret)
            badSecret[0] ^= 0xFF
            if commitments.verifies(
                secret: Data(badSecret), ownerFingerprint: ownerFP
            ) {
                return false
            }
            // 5. A genuine share checked under the WRONG owner
            //    fingerprint fails (domain separation holds).
            let otherFP = Data(SHA256.hash(data: Data("other".utf8)))
            if commitments.verifies(share: shares[0], ownerFingerprint: otherFP) {
                return false
            }
            // 6. Commitment-set wire round-trip is loss-free and the
            //    encoded length matches the formula.
            guard let rt = RecoveryCommitmentSet.decode(commitments.encode()),
                  rt == commitments,
                  commitments.encode().count
                    == RecoveryCommitmentSet.encodedLength(n: 5)
            else { return false }

            return true
        } catch {
            return false
        }
    }
}
#endif
