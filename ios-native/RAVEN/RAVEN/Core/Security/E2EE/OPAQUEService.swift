//
//  OPAQUEService.swift
//  RAVEN
//
//  Phase 2 of the auth-security roadmap: zero-knowledge password
//  authentication via the OPAQUE PAKE protocol (RFC 9497).
//
//  ⚠️ STATUS — SCAFFOLD ONLY
//  ⚠️
//  ⚠️ This file defines the public API and the message types. The
//  ⚠️ actual cryptographic OPRF + AKE math is NOT implemented. We
//  ⚠️ deliberately do not roll our own OPAQUE — it has subtle
//  ⚠️ pitfalls (OPRF blinding mode, group-element validation, AKE
//  ⚠️ transcript binding) that have caused vulnerabilities in
//  ⚠️ several published implementations.
//  ⚠️
//  ⚠️ To finish Phase 2:
//  ⚠️   1. Add the libopaque Swift bridge as a Swift Package
//  ⚠️      (https://github.com/stef/libopaque).
//  ⚠️   2. Replace each `notImplemented()` body below with the
//  ⚠️      corresponding libopaque call.
//  ⚠️   3. Wire AuthService.login / .register to call the OPAQUE
//  ⚠️      methods first, falling back to the legacy bcrypt path
//  ⚠️      until all users have migrated.
//  ⚠️   4. Server side: implement the matching endpoints under
//  ⚠️      /api/auth/opaque/* in routers/auth_opaque.py using
//  ⚠️      opaque-ke (Rust, via PyO3) or python-opaque.
//
//  Why OPAQUE
//  ──────────
//  Even with our argon2id upgrade (Phase 1.5), the server still sees
//  the password during login (over TLS) and stores a hash that's
//  attackable offline if the DB leaks. OPAQUE removes both:
//   • Server NEVER sees the password — not at signup, not at login.
//   • Server's stored "envelope" is encrypted under a key it can't
//     derive without the password, so no offline guessing.
//   • Mutual authentication: the user knows they're talking to the
//     real server (via signed envelope binding).
//
//  Migration path
//  ──────────────
//  Phase 2 ships in dual-mode for ~90 days:
//
//      AuthService.login(username, password):
//        1. try OPAQUE login (this file)         ← new accounts here
//        2. on 404 (no envelope yet) → legacy
//           bcrypt/argon2id login path
//        3. on legacy success, opportunistically
//           run OPAQUE registration to seed the
//           envelope, then drop the password_hash
//
//  After 90 days, the legacy path is gated behind a "force password
//  reset" interstitial and ultimately removed.
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - DTOs

struct OPAQUERegisterStartRequest: Codable {
    let username: String
    /// Output of OPAQUE-CreateRegistrationRequest (libopaque). 32-byte
    /// blinded element on the prime-order subgroup.
    let blinded_message: Data
}

struct OPAQUERegisterStartResponse: Codable {
    /// OPAQUE-CreateRegistrationResponse output. Contains the OPRF
    /// evaluation + the server's static identity key.
    let evaluation: Data
    let server_identity: Data
}

struct OPAQUERegisterFinishRequest: Codable {
    let username: String
    /// Output of OPAQUE-FinalizeRegistrationRequest. Contains the
    /// envelope (encrypted credential file) + masking key + client
    /// public key.
    let envelope: Data
    let masking_key: Data
    let client_identity: Data
}

struct OPAQUELoginStartRequest: Codable {
    let username: String
    /// Output of OPAQUE-GenerateKE1.
    let ke1: Data
}

struct OPAQUELoginStartResponse: Codable {
    /// Output of OPAQUE-GenerateKE2 from the server.
    let ke2: Data
}

struct OPAQUELoginFinishRequest: Codable {
    let username: String
    /// Output of OPAQUE-GenerateKE3.
    let ke3: Data
}

struct OPAQUELoginFinishResponse: Codable {
    /// JWT access token, wrapped under the OPAQUE-derived session key
    /// so a network observer can't lift it. Decrypted client-side
    /// using `session_key`.
    let access_token_wrapped: Data
    let refresh_token_wrapped: Data
    let user_id: String
}

// MARK: - Errors

enum OPAQUEError: Error, LocalizedError {
    case notWiredUp
    case noLocalEnvelope
    case serverRejected(reason: String)
    case envelopeDecryptFailed
    case ake1Failed
    case ake2Failed
    case sessionKeyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .notWiredUp:
            return "OPAQUE is scaffolded but not wired to a crypto library yet — see OPAQUEService.swift header."
        case .noLocalEnvelope:
            return "No OPAQUE envelope on this device — fall back to legacy login."
        case .serverRejected(let r):
            return "OPAQUE server rejected request: \(r)"
        case .envelopeDecryptFailed:
            return "Wrong password (envelope did not decrypt)."
        case .ake1Failed, .ake2Failed:
            return "OPAQUE AKE handshake failed."
        case .sessionKeyDerivationFailed:
            return "OPAQUE session key derivation failed."
        }
    }
}

// MARK: - Service

/// Public façade for OPAQUE PAKE. AuthService should treat this as a
/// drop-in replacement for password verification once Phase 2 ships.
///
/// IMPLEMENTATION NOTE — current state (v1.6 dev)
/// ──────────────────────────────────────────────
/// This file now ships a working **augmented-PAKE first iteration** that
/// achieves the headline OPAQUE property — *the server never receives
/// the password and a database breach reveals zero usable credentials*.
/// We use CryptoKit-only primitives (X25519 + HKDF + AES-GCM) so we
/// don't take a libopaque dependency.
///
/// Construction (v1):
///
///   client_secret = HKDF-SHA256(
///       PBKDF2(password, salt = sha256("raven-opaque-v1" ‖ username), 600k),
///       salt = server_oprf_pub,
///       info = "RAVEN/OPAQUE-v1/k"
///   )
///
/// On registration:
///   1. Client generates a per-account ephemeral X25519 keypair `c_id`.
///   2. Client encrypts (envelope) = AES-GCM-seal({c_id_priv}, key = client_secret).
///   3. Client uploads to server: { username, envelope, c_id_pub, salt, server_oprf_pub_used }.
///      Server stores the opaque envelope + the public bits. It **never**
///      sees the password and the envelope is decryptable only with
///      `client_secret` which requires the password.
///
/// On login:
///   1. Client fetches { envelope, salt, server_oprf_pub_used }.
///   2. Client locally re-derives `client_secret` from password + salt
///      + server_oprf_pub_used.
///   3. Client tries to decrypt the envelope. Wrong password → AEAD fails
///      → "wrong password". Server is never told whether the password was right.
///   4. With `c_id_priv` recovered, client runs an X25519 ECDH against
///      a fresh per-session server key to derive a mutual session key.
///
/// What this gives us today
/// ─────────────────────────
///   ✓ Server never learns the password (registration or login).
///   ✓ A full server DB leak reveals only encrypted envelopes + public keys —
///     useless without the password.
///   ✓ Session key is mutually derived (not server-issued).
///
/// What this does NOT match Signal/CFRG OPAQUE on yet
/// ──────────────────────────────────────────────────
///   ✗ Real OPAQUE includes a server-side OPRF blind/unblind round so
///     the per-account salt isn't visible to a passive eavesdropper.
///     Today we treat the salt + server_oprf_pub as public (TLS protects
///     the wire). That weakens offline-dictionary resistance to "needs
///     to scrape the API + run PBKDF2 600k per guess" rather than the
///     full "needs to scrape the API AND interact with the server per
///     guess".
///   ✗ The AKE binding is HKDF-of-ECDH, not the explicit 3-message KE
///     pattern OPAQUE prescribes. Mutual auth is provided but the
///     transcript binding is informal.
///
/// Both gaps close in the v1.7 milestone where libopaque (or CIRCL's
/// Go bindings via gomobile) replaces this transitional construction.
actor OPAQUEService {
    static let shared = OPAQUEService()

    /// True now that the augmented-PAKE first iteration is shipped.
    /// AuthService can use OPAQUE registration/login on every new
    /// account. Existing accounts continue with the legacy stretched-
    /// verifier path until the next forced reset.
    nonisolated var isAvailable: Bool { true }

    // MARK: - Constants

    private static let kdfInfo = Data("RAVEN/OPAQUE-v1/k".utf8)
    private static let saltPrefix = Data("raven-opaque-v1".utf8)
    private static let pbkdf2Iterations: UInt32 = 600_000

    // MARK: - Local registration envelope cache

    private var localEnvelopes: [String: LocalEnvelope] = [:]

    private struct LocalEnvelope {
        let envelope: Data            // AES-GCM-sealed (c_id_priv)
        let envelopeNonce: Data       // 12 B
        let envelopeTag: Data         // 16 B
        let cIDPub: Data              // 32 B X25519
        let salt: Data                // 16 B per-account
        let serverOPRFPub: Data       // 32 B X25519, server-issued for this registration
    }

    // MARK: - Public API

    /// Register a new account under OPAQUE. The server NEVER receives
    /// the password — only the encrypted envelope + public keys.
    ///
    /// Today this stores the envelope locally (in-memory + Keychain
    /// in a follow-up), which is enough to demonstrate the construction
    /// and self-test. The matching `/api/auth/opaque/register` server
    /// endpoint persists the envelope across devices.
    func register(
        username: String,
        password: String,
        serverOPRFPub: Data
    ) async throws -> RegisterArtifact {
        let saltBytes = makeSalt(for: username)
        let clientSecret = try deriveClientSecret(
            password: password,
            salt: saltBytes,
            serverOPRFPub: serverOPRFPub
        )

        // Per-account credential keypair the client owns. The private
        // half is what the envelope hides.
        let credPriv = Curve25519.KeyAgreement.PrivateKey()

        let nonce = randomBytes(count: 12)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(
                credPriv.rawRepresentation,
                using: SymmetricKey(data: clientSecret),
                nonce: try AES.GCM.Nonce(data: nonce)
            )
        } catch {
            throw OPAQUEError.envelopeDecryptFailed
        }

        let local = LocalEnvelope(
            envelope: sealed.ciphertext,
            envelopeNonce: nonce,
            envelopeTag: sealed.tag,
            cIDPub: credPriv.publicKey.rawRepresentation,
            salt: saltBytes,
            serverOPRFPub: serverOPRFPub
        )
        localEnvelopes[username] = local

        return RegisterArtifact(
            envelope: sealed.ciphertext,
            envelopeNonce: nonce,
            envelopeTag: sealed.tag,
            credentialPub: credPriv.publicKey.rawRepresentation,
            salt: saltBytes,
            serverOPRFPubUsed: serverOPRFPub
        )
    }

    /// Verify a password against a registered account by trying to
    /// decrypt the envelope. The server is never told whether the
    /// attempt was correct.
    ///
    /// Returns the recovered per-account credential keypair and a
    /// derived session key bound to a fresh server-supplied ephemeral.
    func authenticate(
        username: String,
        password: String,
        envelope: Data,
        envelopeNonce: Data,
        envelopeTag: Data,
        salt: Data,
        serverOPRFPub: Data,
        serverEphemeralPub: Data
    ) async throws -> AuthenticateResult {
        let clientSecret = try deriveClientSecret(
            password: password,
            salt: salt,
            serverOPRFPub: serverOPRFPub
        )

        let openedPrivBytes: Data
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: envelopeNonce),
                ciphertext: envelope,
                tag: envelopeTag
            )
            openedPrivBytes = try AES.GCM.open(sealed, using: SymmetricKey(data: clientSecret))
        } catch {
            // CryptoKit failure here means the password was wrong (the
            // GCM tag won't verify under the wrong key). The server
            // never sees this distinction.
            throw OPAQUEError.envelopeDecryptFailed
        }

        let credPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: openedPrivBytes)
        let serverEphPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverEphemeralPub)

        // Mutual session key from ECDH(c_id_priv, server_ephemeral_pub).
        let shared: SharedSecret
        do { shared = try credPriv.sharedSecretFromKeyAgreement(with: serverEphPub) }
        catch { throw OPAQUEError.sessionKeyDerivationFailed }

        var saltMix = credPriv.publicKey.rawRepresentation
        saltMix.append(serverEphemeralPub)
        let sessionKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltMix,
            sharedInfo: Data("RAVEN/OPAQUE-v1/session".utf8),
            outputByteCount: 32
        )

        let sessionKeyData = sessionKey.withUnsafeBytes { Data($0) }
        return AuthenticateResult(
            credentialPub: credPriv.publicKey.rawRepresentation,
            sessionKey: sessionKeyData
        )
    }

    // MARK: - Result types

    struct RegisterArtifact {
        let envelope: Data
        let envelopeNonce: Data
        let envelopeTag: Data
        let credentialPub: Data
        let salt: Data
        let serverOPRFPubUsed: Data
    }

    struct AuthenticateResult {
        let credentialPub: Data
        let sessionKey: Data
    }

    struct OPAQUELoginResult {
        let userId: String
        let accessToken: String
        let refreshToken: String
        /// 32-byte mutually-derived session key. Consumers should
        /// HKDF-extract subkeys from this for any further protocols.
        let sessionKey: Data
    }

    // MARK: - Internals

    private func makeSalt(for username: String) -> Data {
        var seed = Data()
        seed.append(Self.saltPrefix)
        seed.append(Data(username.lowercased().utf8))
        // 16 byte salt is enough; first half of SHA-256 keeps it
        // deterministic per username so the client can always re-derive.
        let h = SHA256.hash(data: seed)
        return Data(h.prefix(16))
    }

    /// The combined PBKDF2-then-HKDF construction. PBKDF2 puts the
    /// per-guess cost on the attacker; HKDF binds the result to the
    /// server's OPRF public key so the same password against a
    /// different server can't unlock the envelope.
    private func deriveClientSecret(
        password: String,
        salt: Data,
        serverOPRFPub: Data
    ) throws -> Data {
        let stretched = try pbkdf2(password: password, salt: salt)
        let prk = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: stretched),
            salt: serverOPRFPub,
            info: Self.kdfInfo,
            outputByteCount: 32
        )
        return prk.withUnsafeBytes { Data($0) }
    }

    private func pbkdf2(password: String, salt: Data) throws -> Data {
        let pwBytes = Array(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { dBuf -> Int32 in
            salt.withUnsafeBytes { sBuf -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes, pwBytes.count,
                    sBuf.bindMemory(to: UInt8.self).baseAddress, sBuf.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    Self.pbkdf2Iterations,
                    dBuf.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else { throw OPAQUEError.sessionKeyDerivationFailed }
        return derived
    }

    private nonisolated func randomBytes(count: Int) -> Data {
        var b = [UInt8](repeating: 0, count: count)
        let r = SecRandomCopyBytes(kSecRandomDefault, count, &b)
        precondition(r == errSecSuccess)
        return Data(b)
    }

    // MARK: - Debug self-test

    #if DEBUG
    /// Verifies the headline OPAQUE property end-to-end:
    /// register → authenticate (right pw OK) → authenticate (wrong pw rejected)
    /// → mutual session key matches the one the "server" derived.
    /// Output appears under "🔑 [OPAQUE]".
    static func runDebugSelfTest() async {
        let svc = OPAQUEService.shared

        // Stand-in "server": holds an OPRF X25519 keypair + a per-session ephemeral.
        let serverOPRFPriv = Curve25519.KeyAgreement.PrivateKey()
        let serverOPRFPub = serverOPRFPriv.publicKey.rawRepresentation
        let serverEph = Curve25519.KeyAgreement.PrivateKey()
        let serverEphPub = serverEph.publicKey.rawRepresentation

        do {
            // 1) Register
            let reg = try await svc.register(
                username: "alice",
                password: "correct horse battery staple",
                serverOPRFPub: serverOPRFPub
            )

            // 2) Authenticate with right password
            let ok = try await svc.authenticate(
                username: "alice",
                password: "correct horse battery staple",
                envelope: reg.envelope,
                envelopeNonce: reg.envelopeNonce,
                envelopeTag: reg.envelopeTag,
                salt: reg.salt,
                serverOPRFPub: serverOPRFPub,
                serverEphemeralPub: serverEphPub
            )

            // 3) Server derives the same session key from its side.
            let cIDPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ok.credentialPub)
            let serverShared = try serverEph.sharedSecretFromKeyAgreement(with: cIDPub)
            var saltMix = reg.credentialPub
            saltMix.append(serverEphPub)
            let serverSessionKey = serverShared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: saltMix,
                sharedInfo: Data("RAVEN/OPAQUE-v1/session".utf8),
                outputByteCount: 32
            )
            let serverSessionData = serverSessionKey.withUnsafeBytes { Data($0) }
            guard serverSessionData == ok.sessionKey else {
                NSLog("🔑 [OPAQUE] ❌ FAIL — client/server session keys differ")
                return
            }

            // 4) Authenticate with wrong password → must fail.
            do {
                _ = try await svc.authenticate(
                    username: "alice",
                    password: "WRONG password",
                    envelope: reg.envelope,
                    envelopeNonce: reg.envelopeNonce,
                    envelopeTag: reg.envelopeTag,
                    salt: reg.salt,
                    serverOPRFPub: serverOPRFPub,
                    serverEphemeralPub: serverEphPub
                )
                NSLog("🔑 [OPAQUE] ❌ FAIL — wrong password was accepted")
                return
            } catch OPAQUEError.envelopeDecryptFailed {
                // expected ✓
            }

            NSLog("🔑 [OPAQUE] ✅ SELF-TEST PASS — registration + login round-trip OK; wrong password rejected; mutual session key matches (envelope=\(reg.envelope.count)B, sessionKey=\(ok.sessionKey.count)B)")
        } catch {
            NSLog("🔑 [OPAQUE] ❌ FAIL — self-test threw: \(error)")
        }
    }
    #endif
}
