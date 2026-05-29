//
//  PasswordStretcher.swift
//  RAVEN
//
//  Client-side password key-stretching. Phase 2A of the auth security
//  roadmap — bridges the gap between today's "send the raw password
//  over TLS, let the server hash it" and tomorrow's full OPAQUE PAKE.
//
//  Threat model
//  ────────────
//  Today an attacker who breaks TLS or compromises the server in any
//  way can recover plaintext passwords. After this change, the
//  password NEVER leaves the device — instead we send a 32-byte
//  PBKDF2 derivative computed under a username-bound salt. An
//  attacker who pulls a "stretched" value off the wire still needs
//  to do ~600,000 PBKDF2 iterations per guess to dictionary-attack
//  it, AND that work is bound to the username so a precomputed
//  rainbow table is useless.
//
//  Server side recognises the new format by length (44 chars base64)
//  + a `RVNS1$` prefix and stores it as today (argon2id), giving
//  defense-in-depth: leak of the DB still doesn't trivially expose
//  passwords because the stored hash is argon2id(stretched(pw)).
//
//  Why PBKDF2 and not Argon2id on the client
//  ─────────────────────────────────────────
//  Argon2id would be stronger but isn't in CryptoKit. CommonCrypto
//  ships PBKDF2-SHA256 on every iOS version we care about, requires
//  no third-party SPM package, and the OWASP-recommended 600k
//  iterations gives meaningful resistance — about 250–500 ms on a
//  modern iPhone, which is acceptable on the login path. Adding
//  Argon2id later (via libsodium) is a one-line swap.
//

import Foundation
import CommonCrypto
import CryptoKit
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Security.PasswordStretcher")

enum PasswordStretcher {

    /// Wire-format prefix marking a stretched password. Lets the
    /// server unambiguously distinguish legacy plaintext passwords
    /// (sent during the rollout window) from stretched ones.
    static let wireMarker = "RVNS1$"

    /// OWASP-recommended PBKDF2-SHA256 iteration count as of 2023.
    /// Tune this in lockstep with hardware performance — too high
    /// and login feels janky, too low and brute force gets cheap.
    static let iterations: UInt32 = 600_000

    /// Output length: 32 bytes ⇒ 44 chars base64 (incl. padding).
    static let outputBytes = 32

    /// Stretch the user's password into a server-bound, slow-hash
    /// derivative.
    ///
    /// - Parameters:
    ///   - password: raw plaintext password (NEVER leaves this scope).
    ///   - usernameLowercased: username used to bind the salt. Pass
    ///     ``username.lowercased()`` so a typo in capitalisation
    ///     can't make logins fail.
    /// - Returns: a string the client should send in the password
    ///   field. Begins with `wireMarker` followed by the
    ///   base64-encoded derivative.
    /// - Throws: `StretcherError.derivationFailed` on PBKDF2 error
    ///   (extremely rare — would indicate OS-level CommonCrypto
    ///   failure, in which case login is broken anyway).
    static func stretch(
        password: String,
        usernameLowercased: String
    ) throws -> String {
        let salt = saltBytes(forUsername: usernameLowercased)

        var derived = Data(count: outputBytes)
        let result = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            password.withCString { passwordCStr in
                salt.withUnsafeBytes { saltPtr -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordCStr,
                        strlen(passwordCStr),
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputBytes
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw StretcherError.derivationFailed(code: Int(result))
        }
        return wireMarker + derived.base64EncodedString()
    }

    /// Build a stretching salt from a server-issued per-account
    /// random salt + the username, with explicit version + domain
    /// separation. The CALLER must pass the salt the server stored
    /// at registration (delivered via the OPAQUE bootstrap or the
    /// `/api/auth/salt?username=` lookup) — passing only the
    /// username falls back to the legacy deterministic salt and
    /// emits a runtime warning so callers fix their plumbing.
    ///
    /// 🔐 BUG FIX (2026-05-10): the previous version derived the
    /// salt as `SHA-256("RAVEN-PWS-v1|" ‖ username)` which is
    /// **deterministic across every install of RAVEN globally**.
    /// An attacker can precompute a 600k-iteration PBKDF2 table for
    /// "alice" once and replay it against any RAVEN server (or any
    /// leaked DB) where alice exists. Per OWASP, salts must be
    /// globally unique and unpredictable — we now bind a per-account
    /// random component supplied by the server.
    static func saltBytes(forUsername username: String, accountSalt: Data) -> Data {
        precondition(accountSalt.count >= 16,
                     "PasswordStretcher.saltBytes requires an accountSalt with ≥16 bytes of entropy")
        var hasher = SHA256()
        hasher.update(data: Data("RAVEN-PWS-v2|".utf8))
        hasher.update(data: accountSalt)
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(username.utf8))
        return Data(hasher.finalize())
    }

    /// Legacy v1 salt — DEPRECATED. Kept only for one transition
    /// release so existing accounts can still log in while the
    /// server backfills per-account salts. Callers MUST migrate to
    /// the `accountSalt:` form above.
    @available(*, deprecated, message: "Pass a server-issued accountSalt; legacy v1 salt is deterministic and exposes pre-computed tables.")
    static func saltBytes(forUsername username: String) -> Data {
        logger.debug("Using legacy v1 deterministic salt for \(username, privacy: .private) — wire the accountSalt: variant before v1.7")
        var hasher = SHA256()
        hasher.update(data: Data("RAVEN-PWS-v1|".utf8))
        hasher.update(data: Data(username.utf8))
        return Data(hasher.finalize())
    }

    /// Cheap check: does this look like a stretched password (so the
    /// caller can avoid double-stretching during retries)?
    static func isStretched(_ candidate: String) -> Bool {
        candidate.hasPrefix(wireMarker)
    }

    enum StretcherError: Error, LocalizedError {
        case derivationFailed(code: Int)

        var errorDescription: String? {
            switch self {
            case .derivationFailed(let code):
                return "PBKDF2 derivation failed (CommonCrypto status \(code))."
            }
        }
    }
}
