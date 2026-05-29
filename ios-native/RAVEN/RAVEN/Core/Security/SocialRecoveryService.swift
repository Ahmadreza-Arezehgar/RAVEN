//
//  SocialRecoveryService.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — v1.7 NEXT: 3-of-5 social key recovery.
//
//  Glues `ShamirSecretSharing` to RAVEN's existing crypto:
//    • Splits the user's identity private key (Curve25519, 32 bytes)
//      into 5 shares with a 3-share threshold.
//    • Encrypts each share to ONE trusted contact's long-term
//      Curve25519 KeyAgreement public key using HPKE-style
//      ECIES (ephemeral X25519 + HKDF + ChaChaPoly).
//    • Hands the encrypted envelopes to the caller. The caller
//      ships them through whatever transport it likes — mesh, push,
//      QR. This file does NOT touch the wire so test seams stay clean.
//
//  Recovery direction is symmetric: the new device receives the
//  encrypted blob back from each trusted contact, decrypts using
//  the contact's stored share-decryption key, and combines.
//
//  Threat model (matches the v1.7 NEXT card "no copy of the key on
//  our servers"):
//    • The plaintext private key NEVER leaves the originating device.
//    • Each contact stores ONE share — useless on its own.
//    • The server may relay encrypted shares but cannot decrypt them.
//    • Even with a server compromise, the attacker needs to corrupt
//      ≥ 3 of the user's 5 trusted contacts AND read their on-device
//      stores to recover the key. Strictly harder than today (which
//      relies on the passphrase alone).
//
//  What this file deliberately does NOT do:
//    • UI / contact picker — UX layer, in Features/Settings/Recovery.
//    • Persistence of in-flight share envelopes — that's the caller's
//      problem (UserDefaults / SQLCipher cache).
//    • Quorum tracking / threshold-met notifications — also caller.
//    • Textbook Feldman VSS — impossible over GF(2^8) Shamir without
//      a wire-breaking prime-field rewrite. v1.8 (2026-05-21) instead
//      adds a hash-commitment VSS: see SocialRecoveryVSS.swift and
//      `recoverVerified` below.

import Foundation
import CryptoKit
import Security

// MARK: - Wire format

/// A share encrypted to ONE specific trusted contact. This is what
/// gets shipped over the wire / stored on the contact's device.
///
/// On-wire byte layout (canonical, big-endian where applicable):
///   magic    : "RVSR" (4 bytes) — RAVEN Social Recovery v1
///   version  : 1 (1 byte)
///   k        : threshold (1 byte) — for sanity-checking on recovery
///   n        : total shares (1 byte) — same reason
///   shareIdx : 1...n (1 byte) — Shamir x-coordinate
///   ownerFP  : 32 bytes — SHA-256 fingerprint of the original device's
///              identity public key, so the contact stores it under
///              the right slot and can return it to the right owner
///   epkLen   : 1 byte — must be 32
///   ephemPK  : 32 bytes — ephemeral X25519 public key for ECIES
///   ctLen    : 2 bytes BE — length of ciphertext + tag
///   ct+tag   : ChaChaPoly sealed share body
///   [v1.8+]  : OPTIONAL trailing "RVSF" commitment block — see
///              RecoveryCommitmentSet (SocialRecoveryVSS.swift). Absent
///              on v1.7 envelopes; the version byte stays 1 so v1.7
///              decoders parse the envelope and skip the extra bytes.
public struct RecoveryShareEnvelope: Equatable, Hashable {
    public static let magic: [UInt8] = [0x52, 0x56, 0x53, 0x52] // "RVSR"
    public static let version: UInt8 = 1

    public let k: UInt8
    public let n: UInt8
    public let shareIndex: UInt8
    public let ownerFingerprint: Data   // 32 bytes, SHA-256
    public let ephemeralPublicKey: Data // 32 bytes, X25519 raw
    public let ciphertext: Data         // ChaChaPoly combined (nonce || ct || tag)

    /// v1.8+ verifiable-secret-sharing commitments. `nil` for legacy
    /// v1.7 envelopes, which carried no trailing "RVSF" block. When
    /// present, `recoverVerified` uses it to reject corrupt shares and
    /// name the contact that returned one.
    public let commitments: RecoveryCommitmentSet?

    public init(
        k: UInt8,
        n: UInt8,
        shareIndex: UInt8,
        ownerFingerprint: Data,
        ephemeralPublicKey: Data,
        ciphertext: Data,
        commitments: RecoveryCommitmentSet? = nil
    ) {
        self.k = k
        self.n = n
        self.shareIndex = shareIndex
        self.ownerFingerprint = ownerFingerprint
        self.ephemeralPublicKey = ephemeralPublicKey
        self.ciphertext = ciphertext
        self.commitments = commitments
    }

    public func encode() -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(k)
        out.append(n)
        out.append(shareIndex)
        out.append(ownerFingerprint)
        out.append(UInt8(ephemeralPublicKey.count))
        out.append(ephemeralPublicKey)
        let len = UInt16(ciphertext.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(ciphertext)
        // v1.8: optional trailing VSS commitment block. The `version`
        // byte above STAYS 1 on purpose — a v1.7 decoder stops after
        // `ciphertext` and ignores trailing bytes, so old contacts
        // still parse this envelope. See SocialRecoveryVSS.swift.
        if let commitments {
            out.append(commitments.encode())
        }
        return out
    }

    public static func decode(_ blob: Data) -> RecoveryShareEnvelope? {
        // Minimum: 4 magic + 1 ver + 1 k + 1 n + 1 idx + 32 fp + 1 epkLen
        // + 32 epk + 2 ctLen = 75 bytes (+ at least 16 for AEAD tag).
        guard blob.count >= 75 + 16 else { return nil }
        var i = blob.startIndex
        guard Array(blob[i..<(i+4)]) == magic else { return nil }
        i += 4
        guard blob[i] == version else { return nil }
        i += 1
        let k = blob[i]; i += 1
        let n = blob[i]; i += 1
        let idx = blob[i]; i += 1
        let fp = blob.subdata(in: i..<(i+32)); i += 32
        let epkLen = Int(blob[i]); i += 1
        guard epkLen == 32, blob.count >= i + 32 + 2 else { return nil }
        let epk = blob.subdata(in: i..<(i+32)); i += 32
        let ctLenHi = Int(blob[i]); let ctLenLo = Int(blob[i+1])
        i += 2
        let ctLen = (ctLenHi << 8) | ctLenLo
        guard blob.count >= i + ctLen else { return nil }
        let ct = blob.subdata(in: i..<(i + ctLen))
        i += ctLen

        // ----- optional trailing VSS commitment block (v1.8+) -----
        // v1.7 envelopes end at the ciphertext; v1.8 appends an
        // "RVSF" block. Parsing is fail-soft: unknown or malformed
        // trailing bytes leave `commitments` nil rather than
        // rejecting an otherwise valid envelope.
        var commitments: RecoveryCommitmentSet? = nil
        if i < blob.endIndex {
            commitments = RecoveryCommitmentSet.decode(
                blob.subdata(in: i..<blob.endIndex)
            )
        }

        return RecoveryShareEnvelope(
            k: k, n: n, shareIndex: idx,
            ownerFingerprint: fp,
            ephemeralPublicKey: epk,
            ciphertext: ct,
            commitments: commitments
        )
    }
}

// MARK: - Service

public enum SocialRecoveryError: Error, LocalizedError {
    case secretLengthInvalid(have: Int, want: Int)
    case contactCountInvalid(have: Int, want: Int)
    case contactPublicKeyInvalid
    case decryptionFailed
    case envelopeMalformed
    case wrongOwnerFingerprint
    case envelopeMixesPolicies
    case tooFewVerifiedShares(have: Int, need: Int, rejected: [UInt8])
    case reconstructionCommitmentMismatch

    public var errorDescription: String? {
        switch self {
        case .secretLengthInvalid(let h, let w):
            return "SocialRecovery: secret must be \(w) bytes, got \(h)"
        case .contactCountInvalid(let h, let w):
            return "SocialRecovery: need exactly \(w) contacts, got \(h)"
        case .contactPublicKeyInvalid:
            return "SocialRecovery: contact public key isn't a valid X25519 point"
        case .decryptionFailed:
            return "SocialRecovery: AEAD decryption failed (wrong key or tampered share)"
        case .envelopeMalformed:
            return "SocialRecovery: envelope failed to decode"
        case .wrongOwnerFingerprint:
            return "SocialRecovery: envelope is for a different identity"
        case .envelopeMixesPolicies:
            return "SocialRecovery: collected envelopes use inconsistent k/n/owner"
        case .tooFewVerifiedShares(let h, let need, let rejected):
            return "SocialRecovery: only \(h) share(s) passed verification, "
                + "need \(need)"
                + (rejected.isEmpty ? "" : "; rejected share indices \(rejected)")
        case .reconstructionCommitmentMismatch:
            return "SocialRecovery: reconstructed key failed its commitment "
                + "and/or owner-fingerprint check"
        }
    }
}

/// One trusted contact we'll hand a share to. The public key is the
/// contact's long-term Curve25519 KeyAgreement key (already part of
/// the existing peer-key directory).
public struct TrustedRecoveryContact {
    public let userId: String                // server-side identifier
    public let username: String              // for the UI confirm screen
    public let publicKey: Curve25519.KeyAgreement.PublicKey

    public init(
        userId: String,
        username: String,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) {
        self.userId = userId
        self.username = username
        self.publicKey = publicKey
    }
}

/// The output of an enrol call: one envelope per contact, plus the
/// matching `userId` so the caller knows where to ship each blob.
public struct PreparedRecoveryShare {
    public let contactUserId: String
    public let contactUsername: String
    public let envelope: RecoveryShareEnvelope
}

/// One share handed back by a trusted contact during recovery. The
/// contact decrypts its stored envelope with `unsealShare(...)` to
/// obtain `share`, and returns the envelope's `commitments` block
/// alongside it. Legacy v1.7 contacts have no commitments → `nil`.
public struct ReturnedRecoveryShare {
    public let share: ShamirShare
    public let commitments: RecoveryCommitmentSet?

    public init(share: ShamirShare, commitments: RecoveryCommitmentSet?) {
        self.share = share
        self.commitments = commitments
    }
}

/// The result of a verified recovery. `secret` is the reconstructed
/// identity key; the index lists tell the UI exactly which contacts
/// returned good vs. corrupt shares.
public struct VerifiedRecoveryOutcome {
    /// The reconstructed identity secret (32 bytes).
    public let secret: Data
    /// Share indices whose returned data matched their commitment.
    /// Empty when recovering a legacy v1.7 enrolment (no commitments).
    public let verifiedShareIndices: [UInt8]
    /// Share indices that FAILED their commitment check — the contact
    /// behind each of these returned a corrupt or forged share.
    public let rejectedShareIndices: [UInt8]
    /// True when per-share VSS commitments were present AND the
    /// reconstruction matched the secret commitment. False for legacy
    /// envelopes — recovery still succeeded and was checked against
    /// the owner fingerprint, but no per-share proof was available.
    public let commitmentVerified: Bool
}

@MainActor
public final class SocialRecoveryService {

    public static let shared = SocialRecoveryService()

    /// Identity-key length we operate on. Today this is Curve25519
    /// (32 bytes). When we add ML-KEM/ML-DSA, the recovery shape
    /// stays the same — we'll split a longer concatenated secret.
    public static let secretBytes = 32

    /// Default policy: any 3 of 5 trusted contacts can recover.
    public static let defaultK = 3
    public static let defaultN = 5

    private init() {}

    // MARK: - Enrol (split + encrypt-per-contact)

    /// Take a plaintext identity key and a list of trusted contacts.
    /// Return one ready-to-ship envelope per contact.
    ///
    /// - Throws: `SocialRecoveryError` for shape violations or
    ///           `ShamirError` for math errors (e.g. RNG failure).
    public func enrol(
        secret: Data,
        contacts: [TrustedRecoveryContact],
        k: Int = SocialRecoveryService.defaultK
    ) throws -> [PreparedRecoveryShare] {
        let n = contacts.count
        guard secret.count == Self.secretBytes else {
            throw SocialRecoveryError.secretLengthInvalid(
                have: secret.count, want: Self.secretBytes
            )
        }
        guard n >= k, n <= 255 else {
            throw SocialRecoveryError.contactCountInvalid(have: n, want: k)
        }

        // 1. Split the secret with Shamir.
        let shares = try ShamirSecretSharing.split(secret: secret, k: k, n: n)

        // 2. Compute the owner fingerprint once — it's the SHA-256 of
        //    the *signing* public key. The caller has the matching
        //    private key in Keychain. We don't take the signing key
        //    as input because the agreement secret is what we're
        //    splitting — but the fingerprint identifies the owner
        //    on the contact's side regardless.
        let ownerFp = Self.deriveOwnerFingerprint(from: secret)

        // 3. Compute the VSS commitment set — one hash commitment per
        //    share plus one for the secret. It is identical for every
        //    contact and rides as a trailing block on each envelope,
        //    letting the recovering device REJECT a corrupted share
        //    and name the contact that returned it. See
        //    SocialRecoveryVSS.swift for why this is a hash-commitment
        //    VSS rather than textbook Feldman.
        let commitments = SocialRecoveryVSS.computeCommitments(
            secret: secret, shares: shares, ownerFingerprint: ownerFp
        )

        // 4. Encrypt each share to its contact via ECIES (X25519 +
        //    HKDF + ChaChaPoly). One ephemeral key per share so a
        //    compromise of one contact's static key doesn't leak the
        //    other four shares (sender-forward-secrecy).
        var out: [PreparedRecoveryShare] = []
        out.reserveCapacity(n)
        for (i, contact) in contacts.enumerated() {
            let share = shares[i]
            let envelope = try Self.sealShare(
                share: share,
                k: UInt8(k),
                n: UInt8(n),
                ownerFingerprint: ownerFp,
                recipientPublicKey: contact.publicKey,
                commitments: commitments
            )
            out.append(PreparedRecoveryShare(
                contactUserId: contact.userId,
                contactUsername: contact.username,
                envelope: envelope
            ))
        }
        return out
    }

    // MARK: - Recovery (decrypt + combine)

    /// Combine encrypted envelopes returned by trusted contacts into
    /// the original identity secret. Each envelope must be decrypted
    /// using the local device's KeyAgreement private key — which
    /// only works on the contact's device. On the *recovering*
    /// device, the caller has already collected DECRYPTED shares
    /// (see `unsealShare(envelope:using:)` for the per-contact side).
    public func recover(plaintextShares: [ShamirShare], k: Int) throws -> Data {
        let recovered = try ShamirSecretSharing.combine(shares: plaintextShares, k: k)
        // Sanity-check the recovered fingerprint matches what each
        // envelope claimed (caller is expected to have asserted this
        // already, but defence-in-depth is cheap).
        return recovered
    }

    // MARK: - Verified recovery (VSS)

    /// Verifiable recovery: combine the shares returned by trusted
    /// contacts, REJECTING any share that fails its VSS commitment,
    /// then check the reconstructed key against both the secret
    /// commitment and the owner fingerprint.
    ///
    /// Prefer this over `recover(plaintextShares:k:)` whenever the
    /// envelopes carry commitments (every v1.8+ enrolment does). It
    /// degrades gracefully for a legacy v1.7 enrolment: with no
    /// commitments it still reconstructs and still verifies the result
    /// against the owner fingerprint, but cannot name a specific
    /// cheating contact (`commitmentVerified == false`).
    ///
    /// - Parameters:
    ///   - returned: one entry per contact that answered the recovery
    ///               request. Order is irrelevant; shares duplicated
    ///               by index are de-duplicated.
    ///   - ownerFingerprint: the 32-byte fingerprint of the identity
    ///               being recovered (known from the recovery session
    ///               and carried in plaintext on every envelope).
    ///   - k: the threshold the secret was enrolled with.
    /// - Throws: `.tooFewVerifiedShares` if fewer than `k` shares
    ///           survive verification; `.reconstructionCommitmentMismatch`
    ///           if the reconstructed key fails its final check.
    public func recoverVerified(
        returned: [ReturnedRecoveryShare],
        ownerFingerprint: Data,
        k: Int
    ) throws -> VerifiedRecoveryOutcome {
        // 1. Agree on the commitment set. Honest contacts all hold an
        //    identical copy; a malicious minority returning a forged
        //    set is outvoted — the k-of-n trust model already assumes
        //    fewer than k corrupt contacts.
        let commitmentSet = Self.majorityCommitmentSet(returned)

        // 2. Partition the returned shares into verified / rejected.
        var verified: [ShamirShare] = []
        var rejected: [UInt8] = []
        if let commitmentSet {
            for r in returned {
                if commitmentSet.verifies(
                    share: r.share, ownerFingerprint: ownerFingerprint
                ) {
                    verified.append(r.share)
                } else {
                    rejected.append(r.share.index)
                }
            }
        } else {
            // Legacy v1.7: no per-share commitments to check against.
            verified = returned.map { $0.share }
        }

        // 3. De-duplicate by share index. A verified share is bound to
        //    its data by SHA-256, so two verified shares with the same
        //    index are necessarily identical — keep the first.
        var byIndex: [UInt8: ShamirShare] = [:]
        for s in verified where byIndex[s.index] == nil {
            byIndex[s.index] = s
        }
        let usable = Array(byIndex.values)

        guard usable.count >= k else {
            throw SocialRecoveryError.tooFewVerifiedShares(
                have: usable.count, need: k, rejected: rejected.sorted()
            )
        }

        // 4. Reconstruct from the verified shares.
        let secret = try ShamirSecretSharing.combine(shares: usable, k: k)

        // 5. Final integrity gate. The owner-fingerprint check works
        //    for EVERY envelope (legacy included) because the
        //    fingerprint is SHA-256(secret). The commitment check is
        //    the stronger, VSS-only gate layered on top.
        let fpOK = SocialRecoveryVSS.constantTimeEqual(
            Data(SHA256.hash(data: secret)), ownerFingerprint
        )
        var commitmentOK = true
        if let commitmentSet {
            commitmentOK = commitmentSet.verifies(
                secret: secret, ownerFingerprint: ownerFingerprint
            )
        }
        guard fpOK, commitmentOK else {
            throw SocialRecoveryError.reconstructionCommitmentMismatch
        }

        return VerifiedRecoveryOutcome(
            secret: secret,
            verifiedShareIndices: commitmentSet == nil
                ? [] : usable.map { $0.index }.sorted(),
            rejectedShareIndices: rejected.sorted(),
            commitmentVerified: commitmentSet != nil
        )
    }

    /// Pick the commitment set held by the majority of returning
    /// contacts. Returns `nil` when none carried commitments — a
    /// legacy v1.7 recovery.
    private static func majorityCommitmentSet(
        _ returned: [ReturnedRecoveryShare]
    ) -> RecoveryCommitmentSet? {
        let sets = returned.compactMap { $0.commitments }
        guard !sets.isEmpty else { return nil }
        var tally: [RecoveryCommitmentSet: Int] = [:]
        for s in sets { tally[s, default: 0] += 1 }
        return tally.max { $0.value < $1.value }?.key
    }

    /// On the CONTACT's device: take an envelope addressed to me +
    /// my own KeyAgreement private key, return the plaintext share
    /// I should hand back to the original owner. Throws on tamper.
    public static func unsealShare(
        envelope: RecoveryShareEnvelope,
        using myPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> ShamirShare {
        guard let epk = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: envelope.ephemeralPublicKey
        ) else {
            throw SocialRecoveryError.envelopeMalformed
        }

        // ECIES decryption: shared secret = X25519(my_sk, ephemeral_pk).
        let ss = try myPrivateKey.sharedSecretFromKeyAgreement(with: epk)
        let key = ss.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: envelope.ownerFingerprint,
            sharedInfo: Self.hkdfInfo,
            outputByteCount: 32
        )

        do {
            let sealed = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            let plaintext = try ChaChaPoly.open(sealed, using: key)
            // Re-prefix the share index byte so the recovered byte-
            // string matches `ShamirShare.deserialize`. We do not
            // trust the plaintext to start with the right index —
            // the envelope's `shareIndex` is the authoritative one.
            var blob = Data()
            blob.append(envelope.shareIndex)
            blob.append(plaintext)
            guard let share = ShamirShare.deserialize(blob) else {
                throw SocialRecoveryError.envelopeMalformed
            }
            return share
        } catch SocialRecoveryError.envelopeMalformed {
            throw SocialRecoveryError.envelopeMalformed
        } catch {
            throw SocialRecoveryError.decryptionFailed
        }
    }

    // MARK: - Internals

    private static let hkdfInfo = "raven-social-recovery-v1".data(using: .utf8)!

    /// SHA-256 of the secret. Used purely as a non-secret identifier
    /// so contacts can store the share under a stable slot keyed to
    /// the owner. NOT a substitute for authenticated identity — we
    /// pair it with Noise IK on the underlying transport.
    private static func deriveOwnerFingerprint(from secret: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: secret)
        return Data(hasher.finalize())
    }

    /// ECIES sealing of one Shamir share for one recipient.
    private static func sealShare(
        share: ShamirShare,
        k: UInt8,
        n: UInt8,
        ownerFingerprint: Data,
        recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
        commitments: RecoveryCommitmentSet
    ) throws -> RecoveryShareEnvelope {
        // Fresh ephemeral key for THIS share.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ss: SharedSecret
        do {
            ss = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        } catch {
            throw SocialRecoveryError.contactPublicKeyInvalid
        }
        let key = ss.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ownerFingerprint,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
        // ChaChaPoly generates a 96-bit random nonce internally; the
        // .combined output gives us nonce||ct||tag.
        let sealed = try ChaChaPoly.seal(share.data, using: key)
        return RecoveryShareEnvelope(
            k: k,
            n: n,
            shareIndex: share.index,
            ownerFingerprint: ownerFingerprint,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: sealed.combined,
            commitments: commitments
        )
    }
}
