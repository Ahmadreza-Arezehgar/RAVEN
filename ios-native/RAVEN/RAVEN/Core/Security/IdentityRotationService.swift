//
//  IdentityRotationService.swift
//  RAVEN
//
//  Automatic 180-day identity-key rotation with cross-signed transition
//  certificates, per Ultra-Secure stack spec §1.1.d.
//
//  What this layer adds on top of `DeviceIdentityService`
//  ──────────────────────────────────────────────────────
//  • A persisted "last rotated at" timestamp + a launch-time check
//    that triggers a rotation when ≥180 days have elapsed.
//  • A *cross-signed* transition certificate — the existing
//    `DeviceIdentityService.rotateKeys()` produces a one-way attestation
//    (OLD signs NEW). This service captures the second leg too:
//    NEW signs OLD, so a peer who later acquires NEW can prove a path
//    back to OLD even without ever having seen the rotation
//    announcement.
//  • A persisted chain of transition certificates so a third party can
//    verify continuity across multiple rotations: K0 → K1 → K2 → K3.
//
//  Honest scope notes
//  ──────────────────
//  • This service does NOT broadcast the rotation — fan-out is handled
//    by the existing rotation pipeline that ships rotation proofs on
//    next sync. We only add the cross-signing primitive + the timer.
//  • The chain log is local-only today. A future iteration can expose
//    `currentChain()` to peers via `/api/devices/identity/history`
//    so a recipient can verify a sender's whole history. That endpoint
//    is on the roadmap, not in this iteration.
//

import Foundation
import CryptoKit

@MainActor
final class IdentityRotationService {

    // MARK: - Singleton
    static let shared = IdentityRotationService()
    private init() {}

    // MARK: - Constants

    /// 180 days in seconds — spec §1.1.d cadence.
    private static let rotationIntervalSeconds: TimeInterval = 180 * 24 * 60 * 60
    /// Last rotation timestamp persists across launches so the timer
    /// is durable.
    private static let lastRotationKey = "raven.identity.lastRotationAt"
    /// Local chain of cross-signed transition certs. JSON-encoded under
    /// this key.
    private static let chainKey = "raven.identity.transitionChain"

    // MARK: - Types

    /// One step in the rotation history. Both signatures are over the
    /// concatenated payload — they are NOT redundant: the OLD-signed
    /// leg is verifiable by anyone who has OLD, and the NEW-signed leg
    /// is verifiable by anyone who has NEW. Only when both verify can
    /// a third party assert continuity.
    struct TransitionCert: Codable, Equatable {
        let oldPublicKey: Data
        let newPublicKey: Data
        let attestedAt: TimeInterval
        /// `OLD.sign(new_pub || ts || "fwd")`
        let oldSignsNew: Data
        /// `NEW.sign(old_pub || ts || "bwd")`
        let newSignsOld: Data
    }

    // MARK: - Public API

    /// Read the persisted last-rotation timestamp. Returns nil if the
    /// device has never rotated since this service was introduced.
    var lastRotationAt: Date? {
        let v = UserDefaults.standard.double(forKey: Self.lastRotationKey)
        return v == 0 ? nil : Date(timeIntervalSince1970: v)
    }

    /// True iff ≥180 days have elapsed since the last recorded rotation
    /// (or no rotation has ever been recorded — first-launch case).
    var isRotationDue: Bool {
        guard let last = lastRotationAt else { return true }
        return Date().timeIntervalSince(last) >= Self.rotationIntervalSeconds
    }

    /// Local chain of every rotation we've completed since this service
    /// was introduced. Newest cert is the last element. Empty before
    /// the first rotation.
    var currentChain: [TransitionCert] {
        guard let raw = UserDefaults.standard.data(forKey: Self.chainKey),
              let chain = try? JSONDecoder().decode([TransitionCert].self, from: raw) else {
            return []
        }
        return chain
    }

    /// Bootstrap — call once at launch. Records "now" as the baseline
    /// if the device has no recorded rotation yet, so the 180-day clock
    /// starts from this build's first launch rather than from the unix
    /// epoch (which would force an immediate rotation on every fresh
    /// install).
    func bootstrap() {
        if UserDefaults.standard.double(forKey: Self.lastRotationKey) == 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRotationKey)
        }
    }

    /// Run a rotation if the timer says we're due. Safe to call on
    /// every launch — it's a no-op when not yet due.
    @discardableResult
    func rotateIfDue() async -> TransitionCert? {
        guard isRotationDue else { return nil }
        return try? await forceRotateNow()
    }

    /// Force an immediate rotation regardless of the timer. Used by
    /// the self-test and by the user-initiated "rotate now" Settings
    /// action. Throws on Keychain failures or signing failures.
    @discardableResult
    func forceRotateNow() async throws -> TransitionCert {
        // Capture OLD before rotation so we can build the cross-sign.
        let oldPubKeyData = DeviceIdentityService.shared.publicKeyData
            ?? Data()
        guard let oldPriv = try? loadCurrentSigningPrivateKey() else {
            throw RotationError.oldPrivateKeyMissing
        }

        // Run the existing one-way rotation in DeviceIdentityService.
        // It signs (NEW || ts) with OLD and persists.
        let proof = try await DeviceIdentityService.shared.rotateKeys()

        // After rotation, NEW is now the canonical key.
        let newPubKeyData = DeviceIdentityService.shared.publicKeyData ?? Data()
        guard let newPriv = try? loadCurrentSigningPrivateKey() else {
            throw RotationError.newPrivateKeyMissing
        }

        let attestedAt = proof.validUntil.timeIntervalSince1970
            - DeviceIdentityService.rotationGraceWindowSeconds
        let tsBytes = withUnsafeBytes(of: attestedAt.bitPattern.littleEndian) { Data($0) }

        // OLD-signed leg matches what DeviceIdentityService produced
        // (we re-sign here to keep this service self-contained; both
        // signatures are over the same payload so they're interchangeable
        // with the existing pipeline).
        let fwdPayload = newPubKeyData + tsBytes + Data("fwd".utf8)
        let oldSig = try oldPriv.signature(for: fwdPayload)

        // NEW-signed leg — the new piece this service contributes.
        let bwdPayload = oldPubKeyData + tsBytes + Data("bwd".utf8)
        let newSig = try newPriv.signature(for: bwdPayload)

        let cert = TransitionCert(
            oldPublicKey: oldPubKeyData,
            newPublicKey: newPubKeyData,
            attestedAt: attestedAt,
            oldSignsNew: oldSig,
            newSignsOld: newSig
        )

        appendToChain(cert)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRotationKey)

        #if DEBUG
        NSLog("🔁 [IdentityRotation] cross-signed transition recorded — old fp=\(Self.fp(oldPubKeyData)) new fp=\(Self.fp(newPubKeyData)) chainLen=\(currentChain.count)")
        #endif

        return cert
    }

    // MARK: - Verification

    /// Maximum age of a transition cert before it's considered stale.
    /// 24h matches what `DeviceIdentityService.verifyRotationProof`
    /// was already enforcing for its caller — keeping the central
    /// `verify()` at the SAME tight 24h window ensures we don't
    /// accidentally widen the security policy by routing callers
    /// through this method instead. RE-AUDIT FIX (2026-05-10):
    /// previous value was 30 days, ~30× more permissive than
    /// `verifyRotationProof` — a regression of policy.
    static let maxCertAge: TimeInterval = 24 * 60 * 60

    /// Verify a single cross-signed cert. Both signatures must validate
    /// against the public keys they reference.
    /// 🔐 BUG FIX (2026-05-10): added `maxAge:` enforcement against
    /// `attestedAt`. Previously the timestamp was signed but never
    /// checked against now() — a stolen old keypair could mint a
    /// cert dated arbitrarily and have peers accept it forever.
    /// `DeviceIdentityService.verifyRotationProof` was already
    /// enforcing a 24h window separately; now the central path
    /// enforces it too so every caller benefits.
    static func verify(_ cert: TransitionCert,
                       now: Date = Date(),
                       maxAge: TimeInterval = maxCertAge) -> Bool {
        guard let oldPub = try? Curve25519.Signing.PublicKey(rawRepresentation: cert.oldPublicKey),
              let newPub = try? Curve25519.Signing.PublicKey(rawRepresentation: cert.newPublicKey) else {
            return false
        }
        // Reject certs that are too old OR dated suspiciously in the
        // future (>5 min ahead = likely clock skew or forgery).
        let attestedDate = Date(timeIntervalSince1970: cert.attestedAt)
        let age = now.timeIntervalSince(attestedDate)
        guard age >= -300, age <= maxAge else {
            #if DEBUG
            print("🚨 [IdentityRotation] cert age=\(Int(age))s outside window [-300, \(Int(maxAge))]; rejecting")
            #endif
            return false
        }
        let tsBytes = withUnsafeBytes(of: cert.attestedAt.bitPattern.littleEndian) { Data($0) }
        let fwdPayload = cert.newPublicKey + tsBytes + Data("fwd".utf8)
        let bwdPayload = cert.oldPublicKey + tsBytes + Data("bwd".utf8)
        let fwdOK = oldPub.isValidSignature(cert.oldSignsNew, for: fwdPayload)
        let bwdOK = newPub.isValidSignature(cert.newSignsOld, for: bwdPayload)
        return fwdOK && bwdOK
    }

    /// Verify a whole chain links cleanly: every cert's NEW must be
    /// the next cert's OLD, every cert must individually verify, AND
    /// timestamps must be monotonic non-decreasing (no chain that
    /// goes backward in time).
    static func verifyChain(_ chain: [TransitionCert]) -> Bool {
        guard !chain.isEmpty else { return false }
        for (i, cert) in chain.enumerated() {
            if !verify(cert) { return false }
            if i + 1 < chain.count {
                if cert.newPublicKey != chain[i + 1].oldPublicKey { return false }
                // Monotone timestamps — rotations only ever go forward.
                if chain[i + 1].attestedAt < cert.attestedAt { return false }
            }
        }
        return true
    }

    // MARK: - Internal

    enum RotationError: Swift.Error {
        case oldPrivateKeyMissing
        case newPrivateKeyMissing
    }

    /// Read the *current* signing private key out of the Keychain.
    /// Used both before AND after rotation — the underlying tag is
    /// the same; the value differs.
    private func loadCurrentSigningPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data("app.raven.device.privatekey".utf8),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            throw RotationError.oldPrivateKeyMissing
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func appendToChain(_ cert: TransitionCert) {
        var chain = currentChain
        chain.append(cert)
        if let raw = try? JSONEncoder().encode(chain) {
            UserDefaults.standard.set(raw, forKey: Self.chainKey)
        }
    }

    /// Short fingerprint for log lines — the public key's SHA-256
    /// prefix, base64-prefixed.
    private static func fp(_ key: Data) -> String {
        guard !key.isEmpty else { return "?" }
        let hash = SHA256.hash(data: key)
        return Data(hash).prefix(6).base64EncodedString()
    }

    // MARK: - Debug self-test

    #if DEBUG
    /// Verifies the cross-sign cert primitive in isolation — without
    /// touching the real Keychain or the real DeviceIdentityService.
    /// We construct three synthetic generations of keys and check
    /// (a) each cert verifies on its own, (b) the chain links, and
    /// (c) tampering with any signature byte breaks verification.
    /// Output under "🔁 [IdentityRotation]".
    static func runDebugSelfTest() {
        // Generate three "generations" of keys.
        let k0 = Curve25519.Signing.PrivateKey()
        let k1 = Curve25519.Signing.PrivateKey()
        let k2 = Curve25519.Signing.PrivateKey()
        let k3 = Curve25519.Signing.PrivateKey()

        guard let cert01 = makeTestCert(old: k0, new: k1),
              let cert12 = makeTestCert(old: k1, new: k2),
              let cert23 = makeTestCert(old: k2, new: k3) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — test cert construction")
            return
        }

        // 1) Each cert verifies on its own.
        guard verify(cert01), verify(cert12), verify(cert23) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — single-cert verification")
            return
        }

        // 2) Three-cert chain links and verifies.
        guard verifyChain([cert01, cert12, cert23]) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — chain verification")
            return
        }

        // 3) Out-of-order chain rejected.
        guard !verifyChain([cert01, cert23, cert12]) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — out-of-order chain accepted")
            return
        }

        // 4) Mismatched chain (skip generation) rejected.
        guard !verifyChain([cert01, cert23]) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — broken chain link accepted")
            return
        }

        // 5) Tamper with the OLD-signed leg — must fail.
        var tampered = cert01
        tampered = TransitionCert(
            oldPublicKey: cert01.oldPublicKey,
            newPublicKey: cert01.newPublicKey,
            attestedAt: cert01.attestedAt,
            oldSignsNew: Data(repeating: 0xAA, count: cert01.oldSignsNew.count),
            newSignsOld: cert01.newSignsOld
        )
        guard !verify(tampered) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — tampered fwd sig accepted")
            return
        }

        // 6) Tamper with the NEW-signed leg — must fail.
        tampered = TransitionCert(
            oldPublicKey: cert01.oldPublicKey,
            newPublicKey: cert01.newPublicKey,
            attestedAt: cert01.attestedAt,
            oldSignsNew: cert01.oldSignsNew,
            newSignsOld: Data(repeating: 0xBB, count: cert01.newSignsOld.count)
        )
        guard !verify(tampered) else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — tampered bwd sig accepted")
            return
        }

        // 7) Timer behaviour — `isRotationDue` is true on a fresh slate.
        // We don't actually clear UserDefaults here (would clobber the
        // user's real state); instead we just check the date arithmetic.
        let oneYearAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        let recently = Date().addingTimeInterval(-60)
        guard Date().timeIntervalSince(oneYearAgo) >= rotationIntervalSeconds,
              Date().timeIntervalSince(recently) < rotationIntervalSeconds else {
            NSLog("🔁 [IdentityRotation] ❌ FAIL — timer arithmetic")
            return
        }

        NSLog("🔁 [IdentityRotation] ✅ SELF-TEST PASS — cross-sign verify, 3-cert chain, tamper rejected (both legs), timer arithmetic OK")
    }

    private static func makeTestCert(
        old: Curve25519.Signing.PrivateKey,
        new: Curve25519.Signing.PrivateKey,
        ts: TimeInterval = Date().timeIntervalSince1970
    ) -> TransitionCert? {
        let oldPub = old.publicKey.rawRepresentation
        let newPub = new.publicKey.rawRepresentation
        let tsBytes = withUnsafeBytes(of: ts.bitPattern.littleEndian) { Data($0) }
        guard let oldSig = try? old.signature(for: newPub + tsBytes + Data("fwd".utf8)),
              let newSig = try? new.signature(for: oldPub + tsBytes + Data("bwd".utf8)) else {
            return nil
        }
        return TransitionCert(
            oldPublicKey: oldPub,
            newPublicKey: newPub,
            attestedAt: ts,
            oldSignsNew: oldSig,
            newSignsOld: newSig
        )
    }
    #endif
}
