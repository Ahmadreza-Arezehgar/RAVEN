//
//  ATSAMMessageSealer.swift
//  RAVEN — ATSAM
//
//  🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #44 / #59.
//
//  Per-message AEAD body sealer that uses the ATSAM hybrid root for
//  key material. Drops in alongside the existing Noise-transport
//  sealer (`MessageContentSealer`) so:
//
//    • When a peer is ATSAM-paired (root key stored in
//      `ATSAMRootStorage`), the sender prefers this path.
//      Wire payload starts with the `"RVNA1\0\0\0"` magic — the
//      receiver detects the magic and routes here too.
//
//    • When a peer has NO ATSAM pairing, the legacy sealer keeps
//      working with its `"RVNS1\0\0\0"` Noise wire. No existing
//      conversation breaks because every receiver still recognises
//      the legacy magic.
//
//  Bridge / mesh / group implications:
//    • Bridge: ATSAM ciphertext is opaque base64 in the JSON
//      `content` field. Server stores it as-is; bridge node
//      forwards it as-is. No bridge code change required.
//    • Mesh: same wire payload goes into the BLE-envelope `text`
//      field. Relay nodes see opaque base64.
//    • Group: scope-limited for now — the existing per-group
//      AES-GCM key (`GroupKeyService`) keeps protecting group
//      bodies. ATSAM root binds 1:1 pairs; a future stage will
//      define a group-key tree built from per-member ATSAM
//      sub-keys. See Phase 2 in Task #59.
//    • Media metadata is sealed by the same `MessageContentSealer`,
//      so dropping ATSAM into that sealer also covers media.
//
//  Wire format:
//
//    ┌──────────┬────────┬──────────┬────────────┬──────────┐
//    │ 8 bytes  │ 1 byte │ 1 byte   │ 12 bytes   │ N bytes  │
//    │ RVNA1\0\0│ ver=1  │ suite=1  │ nonce      │ ct + tag │
//    └──────────┴────────┴──────────┴────────────┴──────────┘
//
//  `suite` is reserved for a future post-quantum AEAD swap. For
//  now suite=1 means ChaCha20-Poly1305 over ATSAM-derived keys.
//
//  Key derivation:
//
//    K_msg = HKDF-Expand(
//      key  = ATSAMKeyTree.subKey(.atsamMsgSeal),
//      info = "ATSAM/v1/msg-seal" || \0 || senderUserId || \0
//             || recipientUserId,
//      L    = 32
//    )
//
//  AEAD AAD:
//
//    aad = SHA-256(
//      "ATSAM/v1/msg-seal/aad" || \0
//      || senderUserId || \0
//      || recipientUserId || \0
//      || msgId
//    )
//
//  Both bindings overlap with the existing Noise sealer's AAD on
//  purpose — same defence against ciphertext-rerouting attacks.
//
//  🛡️ SECURITY:
//    - PQC: the root mixes X25519 + ML-KEM-768. An adversary must
//      defeat BOTH to recover the root. HKDF's PRG property
//      guarantees `K_msg` is uniform-random unless the root is.
//    - Forward secrecy: the per-message nonce is freshly drawn for
//      every send; reusing a (key, nonce) pair would catastrophically
//      break ChaCha20-Poly1305, so we use `AES.GCM.SealedBox`
//      semantics via CryptoKit's `ChaChaPoly` which generates a
//      fresh nonce on each `seal(_:using:)` call.
//    - Replay: receiver's `MessageContentSealer.SealedReplayWindow`
//      already gates duplicate `(peerPID, msgId)` deliveries. The
//      ATSAM unseal path reuses that same window.
//    - Cross-peer rerouting: AAD binds (sender, recipient, msgId)
//      → AEAD fails if the server tries to re-point ciphertext.
//

import Foundation
import CryptoKit

/// New label for the per-message AEAD key. Listed here (not in
/// `ATSAMConstants.swift`) so the integration commit is one file;
/// migrating to the central catalog is trivial once the layer
/// is permanent.
extension ATSAMConstants.KDFLabel {
    /// Per-pair seed for the message-sealing key. The actual K_msg
    /// is HKDF-Expand'd from this seed with (sender, recipient)
    /// user IDs in the info string — see ATSAMMessageSealer.
    static let atsamMsgSealSeed = ATSAMConstants.KDFLabel(rawValue: "ATSAM/v1/msg-seal")
}

enum ATSAMMessageSealer {

    // MARK: - Wire format

    /// 8-byte magic. `RVNA1` = "RAVEN ATSAM v1". Padded to 8 bytes
    /// for byte-alignment parity with the legacy Noise (`RVNS1`)
    /// and plaintext (`RVNP1`) magics.
    static let magic: Data = Data([0x52, 0x56, 0x4E, 0x41, 0x31, 0x00, 0x00, 0x00])
    static let magicLength: Int = 8

    /// Protocol version + suite. v1 / suite-1 = ChaCha20-Poly1305
    /// over ATSAM HKDF-derived 32-byte keys.
    private static let protocolByte: UInt8 = 0x01
    private static let suiteByte: UInt8 = 0x01

    /// Hard cap on emitted wire bytes. Mirrors `MessageContentSealer`'s
    /// 256 KB cap so a malicious sender can't fan a multi-MB blob
    /// into the chat surface.
    private static let maxWireBytes: Int = 256 * 1024

    /// AAD domain string. Distinct from the legacy sealer so a
    /// receiver that mistakenly fed an RVNA1 frame to the Noise
    /// path fails the AEAD check cleanly.
    private static let aadDomain = Data("ATSAM/v1/msg-seal/aad".utf8)

    // MARK: - Result types

    struct Result {
        let base64: String
        let didSeal: Bool   // true iff ATSAM path actually ran
    }

    // MARK: - Seal

    /// Try to seal `plaintext` for the given recipient using the
    /// peer's ATSAM root. Returns `nil` when no root is paired —
    /// the caller should then fall back to `MessageContentSealer`.
    ///
    /// `senderUserId` and `recipientUserId` get bound into both the
    /// per-message key info string AND the AEAD AAD — same defence
    /// against ciphertext-rerouting attacks the Noise sealer uses.
    static func seal(plaintext: String,
                     senderUserId: String,
                     recipientUserId: String,
                     msgId: String) async -> Result? {

        // Reject empty plaintext (incl. whitespace-only).
        // Hacker-agent #6 finding: " " was passing the original
        // `isEmpty` check and producing valid ghost bubbles.
        guard !plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Reject empty / NUL-containing IDs.
        //
        // 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
        // Task #60. Hacker agent #2 + #6 finding: AAD/info strings
        // use 0x00 as a field separator. A userId containing `\0`
        // collapses the separator, so two distinct (sender, recipient,
        // msgId) triples can hash to identical AAD/info bytes —
        // allowing cross-context ciphertext reuse. Reject any input
        // that contains a NUL byte to keep the canonical encoding
        // injective.
        guard !senderUserId.isEmpty, !recipientUserId.isEmpty,
              !msgId.isEmpty,
              !senderUserId.contains("\0"),
              !recipientUserId.contains("\0"),
              !msgId.contains("\0") else {
            return nil
        }

        // Look up the peer's ATSAM root.
        guard let root = await ATSAMRootStorage.shared.root(for: recipientUserId) else {
            return nil
        }
        let tree = ATSAMKeyTree(root: root)

        // 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
        // Task #61. Hacker agent #4 finding: a static K_msg per
        // direction with random 96-bit nonce risks catastrophic
        // ChaCha20-Poly1305 break on (key, nonce) collision —
        // realistic threat under multi-device / backup-restore
        // scenarios where two devices independently draw nonces.
        //
        // Fix: rotate K_msg per message by mixing `msgId` into the
        // HKDF info string. Sender and receiver both have the
        // msgId on the wire (sender stamps it, receiver reads from
        // request/envelope), so the derivation stays symmetric.
        let key = deriveMessageKey(
            tree: tree,
            senderUserId: senderUserId,
            recipientUserId: recipientUserId,
            msgId: msgId
        )
        let aad = buildAAD(
            senderUserId: senderUserId,
            recipientUserId: recipientUserId,
            msgId: msgId
        )

        let body = Data(plaintext.utf8)
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(body, using: key, authenticating: aad)
        } catch {
            // ChaChaPoly.seal can only fail on absurd input sizes
            // (>= 2^32 bytes). Treat as a soft fail so the caller
            // falls back to Noise — never ship plaintext.
            return nil
        }

        let nonce = Data(sealed.nonce)
        guard nonce.count == 12 else { return nil }

        var wire = Data()
        wire.append(magic)
        wire.append(protocolByte)
        wire.append(suiteByte)
        wire.append(nonce)
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)

        guard wire.count <= maxWireBytes else { return nil }

        return Result(base64: wire.base64EncodedString(), didSeal: true)
    }

    // MARK: - Unseal

    /// Try to unseal an RVNA1 wire frame. Returns `nil` for
    /// structurally-broken input so the caller can fall through
    /// to the legacy paths (RVNS1 / RVNP1).
    static func unseal(encoded: String,
                       senderUserId: String,
                       recipientUserId: String,
                       msgId: String) async -> String? {

        // Size guard. Hacker #6 finding: min legal frame is
        // 39 bytes (magic 8 + ver/suite 2 + nonce 12 + tag 16 +
        // ≥1 ct byte). Empty ciphertext is not allowed (sender
        // rejects empty plaintext).
        guard encoded.count <= maxWireBytes * 2 else { return nil }
        guard let wire = Data(base64Encoded: encoded),
              wire.count >= magicLength + 2 + 12 + 16 + 1 else {
            return nil
        }
        guard wire.count <= maxWireBytes else { return nil }

        // Magic check — caller already verified via `looksLikeATSAM`
        // but we re-check to fail safe.
        guard wire.prefix(magicLength) == magic else { return nil }

        // Header: version + suite.
        let headerStart = magicLength
        let proto = wire[headerStart]
        let suite = wire[headerStart + 1]
        guard proto == protocolByte, suite == suiteByte else { return nil }

        let nonceStart = headerStart + 2
        let nonceEnd = nonceStart + 12
        let ctTagStart = nonceEnd
        let tagStart = wire.count - 16
        guard tagStart > ctTagStart else { return nil }

        let nonceBytes = wire.subdata(in: nonceStart..<nonceEnd)
        let ctBytes = wire.subdata(in: ctTagStart..<tagStart)
        let tagBytes = wire.subdata(in: tagStart..<wire.count)

        // 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
        // Task #60. Reject empty / NUL-containing IDs to keep the
        // canonical AAD/info encoding injective. Same rule as the
        // seal path; receiver MUST refuse what sender refused.
        guard !senderUserId.isEmpty, !recipientUserId.isEmpty,
              !msgId.isEmpty,
              !senderUserId.contains("\0"),
              !recipientUserId.contains("\0"),
              !msgId.contains("\0") else {
            return nil
        }

        // The peer that SENT to us is `senderUserId`. We share the
        // same ATSAM root with them, stored under their userId.
        guard let root = await ATSAMRootStorage.shared.root(for: senderUserId) else {
            return nil
        }
        let tree = ATSAMKeyTree(root: root)

        // 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
        // Task #61. Mix msgId into K_msg derivation (matching the
        // seal path) so every message gets a fresh AEAD key. See
        // seal() for the rationale.
        let key = deriveMessageKey(
            tree: tree,
            senderUserId: senderUserId,
            recipientUserId: recipientUserId,
            msgId: msgId
        )
        let aad = buildAAD(
            senderUserId: senderUserId,
            recipientUserId: recipientUserId,
            msgId: msgId
        )

        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        } catch {
            return nil
        }

        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ctBytes,
                tag: tagBytes
            )
        } catch {
            return nil
        }

        let pt: Data
        do {
            pt = try ChaChaPoly.open(sealed, using: key, authenticating: aad)
        } catch {
            // AEAD failure — either tampering, wrong root (peer
            // re-paired since we cached), or someone tried to ship
            // ciphertext under a magic they don't actually own.
            return nil
        }

        guard let str = String(data: pt, encoding: .utf8) else { return nil }
        return str
    }

    /// Cheap magic-prefix check the caller uses to decide whether
    /// the legacy `MessageContentSealer` should fall through to
    /// this sealer's `unseal` path.
    static func looksLikeATSAM(encoded: String) -> Bool {
        guard let wire = Data(base64Encoded: encoded),
              wire.count >= magicLength else { return false }
        return wire.prefix(magicLength) == magic
    }

    // MARK: - Key derivation

    /// Derive the per-message AEAD key from the ATSAM tree's
    /// per-pair seed + (sender, recipient, msgId) info.
    ///
    /// 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
    /// Task #61. `msgId` mixed into the info string per the hacker
    /// agent finding — keeps K_msg fresh per message, neutering
    /// the nonce-collision blast radius if random nonces ever
    /// collide. Sender and receiver both have msgId on the wire,
    /// so the derivation stays symmetric.
    ///
    /// Reuses HKDF-Expand with the seed as IKM rather than the
    /// raw root — defence-in-depth: the per-pair seed is already
    /// domain-separated from BBE / Ghost Route / PV-Stealth keys,
    /// so even a buggy callsite that leaks `K_msg` only compromises
    /// message sealing, not the other ATSAM layers.
    private static func deriveMessageKey(tree: ATSAMKeyTree,
                                         senderUserId: String,
                                         recipientUserId: String,
                                         msgId: String) -> SymmetricKey {
        let seed = tree.subKey(for: .atsamMsgSealSeed)
        var info = Data()
        info.append(Data("ATSAM/v1/msg-seal".utf8))
        info.append(0x00)
        info.append(Data(senderUserId.utf8))
        info.append(0x00)
        info.append(Data(recipientUserId.utf8))
        info.append(0x00)
        info.append(Data(msgId.utf8))
        // Static salt for defence-in-depth (hacker agent #9).
        // RFC 5869 permits skipping salt when IKM is already a
        // strong key (our seed is), but adding the domain-tagged
        // salt costs nothing.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: Data("ATSAM/v1/msg-seal/salt".utf8),
            info: info,
            outputByteCount: 32
        )
        return derived
    }

    /// Build the AEAD AAD. SHA-256-hashed so the wire AAD is
    /// fixed-length regardless of userId encoding quirks (an
    /// attacker can't vary userId UTF-8 to manipulate AAD bytes).
    private static func buildAAD(senderUserId: String,
                                 recipientUserId: String,
                                 msgId: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: aadDomain)
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(senderUserId.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(recipientUserId.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(msgId.utf8))
        return Data(hasher.finalize())
    }
}
