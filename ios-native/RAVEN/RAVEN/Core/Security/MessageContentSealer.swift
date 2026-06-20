//
//  MessageContentSealer.swift
//  RAVEN
//
//  CRITICAL SECURITY FIX (2026-05-16 — round 10):
//  Until round 10 the three server-routed DM send paths
//  (`OutboxManager`, `MessageRouter`, `DeliveryJobRunner`) all
//  POSTed the message text to `/api/messages/send` **as cleartext**.
//  This file became the single canonical seal helper so every
//  server-bound send path actually does end-to-end encryption.
//
//  HARDENING ROUND (2026-05-16 — round 13, hacker audit):
//  • AAD now binds sender ID, recipient ID, msgId, and a protocol
//    version into a domain-separated hash — a malicious server can
//    no longer swap ciphertext across (sender, recipient) pairs by
//    re-pointing the msgId. (audit finding C2)
//  • Base64-decode failure no longer echoes attacker-controlled
//    bytes back to the UI as `.legacy` plaintext. We return a
//    non-renderable sentinel so the bubble shows "[unreadable]"
//    instead of arbitrary attacker text. (audit finding C3)
//  • Length guards on both sides: empty plaintext is rejected on
//    seal (an empty bubble is never a real message); on unseal we
//    require RVNS1 payloads carry at least the 16-byte AEAD tag.
//    (audit finding C4)
//  • Total wire size capped at 256 KB so a malicious server can't
//    fan a 4 GB blob into our chat surface and OOM us.
//
//  Wire format:
//
//    ┌──────────┬──────────────────────────────────────────────┐
//    │ 8 bytes  │ "RVNS1\0\0\0" magic for sealed (Noise CT)    │
//    │ N bytes  │ Noise transport ciphertext                   │
//    └──────────┴──────────────────────────────────────────────┘
//
//    ┌──────────┬──────────────────────────────────────────────┐
//    │ 8 bytes  │ "RVNP1\0\0\0" magic for plaintext fallback   │
//    │ N bytes  │ UTF-8 message body                           │
//    └──────────┴──────────────────────────────────────────────┘
//
//  Both shapes are Base64-encoded before being shoved into the JSON
//  `content` field so the server stores opaque bytes either way.
//  The receiver checks the magic, decrypts the sealed shape, and
//  surfaces a "Not end-to-end encrypted" badge in the chat surface
//  for the plaintext shape.

import Foundation
import CryptoKit
import Security

enum MessageContentSealer {

    // 8-byte magic markers. Padding to 8 keeps the header byte-
    // aligned with `VaultFileCrypto`'s `RVNV1` header.
    static let sealedMagic   = Data([0x52, 0x56, 0x4E, 0x53, 0x31, 0x00, 0x00, 0x00])  // RVNS1\0\0\0
    static let plainMagic    = Data([0x52, 0x56, 0x4E, 0x50, 0x31, 0x00, 0x00, 0x00])  // RVNP1\0\0\0
    /// Serverless first-contact: the body rides inside a self-contained Noise IK
    /// message-1 (1-RTT, fresh ephemeral). Lets two peers who only exchanged
    /// static keys via QR seal/open E2E without a prior pairing handshake.
    static let handshakeMagic = Data([0x52, 0x56, 0x4E, 0x48, 0x31, 0x00, 0x00, 0x00]) // RVNH1\0\0\0
    static let magicLength   = 8

    /// Protocol domain string mixed into the AAD. Bumping this
    /// invalidates every legacy ciphertext in flight, so do it only
    /// when the wire format genuinely changes.
    private static let aadDomain = Data("raven-sealer-v2".utf8)

    /// Total wire-bytes hard cap. 256 KB is far above any legitimate
    /// chat message (4 KB max is the Cloud Run header cap) and well
    /// below the heap budget we have for a single decode. A
    /// malicious server that fans a multi-GB blob at the chat
    /// surface gets rejected here instead of OOM'ing the renderer.
    private static let maxWireBytes = 256 * 1024

    /// Minimum byte count after the magic header on a RVNS1 frame —
    /// the ChaCha20-Poly1305 AEAD tag is 16 bytes and even a one-
    /// byte plaintext lands at >= 17 bytes. Anything smaller is
    /// definitionally invalid and rejected before going to the
    /// Noise decrypt path.
    private static let minSealedRest = 17

    /// Round 17 (2026-05-16) — hacker-audit finding C11 (lite).
    ///
    /// A wire-format-breaking replay window (explicit counter on
    /// every RVNS1 frame) is out of scope for the round-13 sealer
    /// landing, but we can get most of the benefit with a purely
    /// receiver-side msgId filter:
    ///
    ///   • Track the last N msgIds we've successfully decrypted
    ///     per peerPID, in-memory only.
    ///   • Reject any inbound RVNS1 whose `msgId` is already in the
    ///     peer's window — short-circuits BEFORE the AEAD attempt,
    ///     which means a replayed frame can't even consume the
    ///     consecutive-AEAD-fail budget that gates eviction.
    ///
    /// This stops two attack patterns:
    ///   1. A relay node along the mesh path that records frames
    ///      and re-injects them after the session has been re-keyed
    ///      to probe the cipher state.
    ///   2. An attacker on the server-bridge path that replays an
    ///      old frame hoping the dedupe at the DB layer fires AFTER
    ///      the cipher state has been "touched" enough times to
    ///      cause downstream weirdness.
    ///
    /// The cost: a legitimate retransmit (mesh spray-and-wait, BLE
    /// flake) hits the rejection path and is silently dropped. That
    /// matches what the DB-layer UNIQUE constraint already does on
    /// `client_message_id`, so the user-visible behaviour is
    /// unchanged — only the kernel-mode AEAD work is skipped.
    private static let replayWindow = SealedReplayWindow()

    /// 🔐 ROUND 76 (2026-05-24) — Hacker #9 V1. Expose a purge hook on
    /// the (otherwise file-private) replay window so AuthService.logout()
    /// can wipe it. Without this, the persisted seen-set in UserDefaults
    /// survived logout and the next signed-in user inherited replay
    /// state from the previous account.
    static func purgeReplayWindow() async {
        await replayWindow.purge()
    }

    // MARK: - Seal (legacy shim)

    /// Legacy shim — keeps callers from round-10 compiling. Prefer
    /// the 5-arg overload that takes both user IDs so the AAD can
    /// bind the (sender, recipient) pair.
    static func seal(
        plaintext: String,
        recipientAgreementPubKey: Data?,
        msgId: String
    ) async -> SealedContent {
        return await seal(
            plaintext: plaintext,
            senderUserId: nil,
            recipientUserId: nil,
            recipientAgreementPubKey: recipientAgreementPubKey,
            msgId: msgId
        )
    }

    /// Round-12 shim that takes `recipientUserId` but not
    /// `senderUserId` — kept for incremental migration of callers.
    static func seal(
        plaintext: String,
        recipientUserId: String?,
        recipientAgreementPubKey: Data?,
        msgId: String
    ) async -> SealedContent {
        return await seal(
            plaintext: plaintext,
            senderUserId: nil,
            recipientUserId: recipientUserId,
            recipientAgreementPubKey: recipientAgreementPubKey,
            msgId: msgId
        )
    }

    // MARK: - Seal (canonical)

    /// Encrypt `plaintext` to the recipient identified by
    /// `recipientUserId` / `recipientAgreementPubKey` (X25519, 32
    /// bytes) using the existing Noise transport session in
    /// `NoiseSessionStore`.
    ///
    /// The AAD is bound to all of (`senderUserId`, `recipientUserId`,
    /// `msgId`, protocol domain). A malicious server cannot:
    ///   • swap ciphertext into a different message slot (msgId
    ///     differs → AEAD fail),
    ///   • re-route a ciphertext from Alice→Bob into Alice→Eve
    ///     (recipientUserId differs → AEAD fail),
    ///   • re-attribute a ciphertext from Alice to Mallory
    ///     (senderUserId differs → AEAD fail).
    /// (Audit finding C2.)
    static func seal(
        plaintext: String,
        senderUserId: String?,
        recipientUserId: String?,
        recipientAgreementPubKey: Data?,
        msgId: String
    ) async -> SealedContent {
        // Hardening: reject empty plaintext outright. An empty bubble
        // is never a legitimate user-typed message and lets a server
        // generate "ghost" bubbles from forged sends. (Audit C4.)
        guard !plaintext.isEmpty else {
            return SealedContent(
                base64: "",
                isEncrypted: false,
                reason: .noRecipientKey
            )
        }

        let body = Data(plaintext.utf8)
        let resolvedSender = await Self.resolveSelfUserId(senderUserId)

        // 🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #59.
        // Prefer ATSAM hybrid (X25519 + ML-KEM-768) sealing when
        // the peer has been ATSAM-paired (root key cached in
        // `ATSAMRootStorage`). This gives PQC protection for the
        // body without changing the bridge/mesh/group code paths
        // — the resulting wire bytes still ride opaque through
        // every relay (same as the legacy Noise sealer).
        //
        // 🔴 ROUND 71 phase 3 follow-up #7 (2026-05-24) — Task #67.
        // REGRESSION FIX from #5's hardening (#63): the prior
        // hardening guarded `resolvedSender` BEFORE checking
        // whether ATSAM was even applicable. When resolvedSender
        // came back nil (Keychain locked momentarily, background
        // context, racy login flow), the function returned
        // `SealedContent(base64: "")` — an EMPTY body that the
        // sender shipped through the bridge as nothing → A→C
        // bubbles arrived empty, C→A send paths errored out.
        // The fail-closed rule should ONLY apply to peers we
        // ACTUALLY have an ATSAM root for; everyone else falls
        // through to the legacy Noise path that has its own
        // fail-closed semantics (Noise session existence check).
        if let rUid = recipientUserId, !rUid.isEmpty,
           let sUid = resolvedSender, !sUid.isEmpty,
           let atsamRoot = await ATSAMRootStorage.shared.root(for: rUid) {
            // Peer IS ATSAM-paired. Now seal — and only NOW does
            // fail-closed apply (if ATSAM seal fails despite a
            // cached root, something is wrong — don't ship
            // plaintext, return empty so outbox retries).
            _ = atsamRoot  // root presence is the gate; sealer
                           // re-fetches inside.
            if let atsam = await ATSAMMessageSealer.seal(
                plaintext: plaintext,
                senderUserId: sUid,
                recipientUserId: rUid,
                msgId: msgId
            ) {
                return SealedContent(
                    base64: atsam.base64,
                    isEncrypted: true,
                    reason: .atsamHybrid
                )
            }
            // ATSAM root cached but seal returned nil — that's
            // unexpected. Fall through to Noise rather than
            // shipping empty bytes; Noise has its own session
            // check.
        }

        let ad = Self.buildAAD(
            senderUserId: resolvedSender,
            recipientUserId: recipientUserId,
            msgId: msgId
        )

        // Resolve the recipient pubkey: caller-supplied wins, fall
        // back to directory (which may go to the network on miss).
        var resolvedPub: Data? = nil
        if let pub = recipientAgreementPubKey, pub.count == 32 {
            resolvedPub = pub
        } else if let uid = recipientUserId, !uid.isEmpty {
            resolvedPub = await PeerKeyDirectory.shared.ensureAgreementKey(for: uid)
        }

        if let pub = resolvedPub, pub.count == 32 {
            let peerPID = peerID(fromPublicKey: pub)
            // NoiseSessionStore is MainActor-isolated, hop over.
            let ct: Data? = await MainActor.run {
                NoiseSessionStore.shared.encrypt(body, ad: ad, forPeer: peerPID)
            }
            if let ct {
                var wire = Data()
                wire.append(sealedMagic)
                wire.append(ct)
                guard wire.count <= maxWireBytes else {
                    // Don't ship a wire payload bigger than the cap —
                    // a message that would round-trip 256+KB of
                    // ciphertext almost certainly indicates a bug in
                    // the caller (e.g. someone passing a multi-MB
                    // attachment as `text`).
                    return SealedContent(
                        base64: "",
                        isEncrypted: false,
                        reason: .noSession
                    )
                }
                return SealedContent(
                    base64: wire.base64EncodedString(),
                    isEncrypted: true,
                    reason: .noiseTransport
                )
            }

            // No established transport session → land the body 1-RTT inside a
            // self-contained Noise IK message-1 addressed to the recipient's
            // static key. The receiver opens it statelessly — this is what makes
            // a purely serverless QR-only contact E2E without any pairing
            // round-trip (previously this fell through to RVNP1 plaintext).
            if let peerStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub) {
                let m1: Data? = await MainActor.run {
                    NoiseSessionStore.shared.writeHandshake1Stateless(toPeer: peerStatic, payload: body)
                }
                if let m1 {
                    var hsWire = Data()
                    hsWire.append(handshakeMagic)
                    hsWire.append(m1)
                    if hsWire.count <= maxWireBytes {
                        return SealedContent(
                            base64: hsWire.base64EncodedString(),
                            isEncrypted: true,
                            reason: .noiseTransport
                        )
                    }
                }
            }
        }

        // Fallback: prefix with the plaintext magic so the receiver
        // can render a "not end-to-end encrypted" badge instead of
        // silently treating the body as if it were sealed.
        var wire = Data()
        wire.append(plainMagic)
        wire.append(body)
        return SealedContent(
            base64: wire.base64EncodedString(),
            isEncrypted: false,
            reason: resolvedPub == nil ? .noRecipientKey : .noSession
        )
    }

    // MARK: - Unseal (legacy shim)

    static func unseal(
        encoded: String,
        senderAgreementPubKey: Data?,
        msgId: String
    ) async -> UnsealedContent? {
        return await unseal(
            encoded: encoded,
            senderUserId: nil,
            recipientUserId: nil,
            senderAgreementPubKey: senderAgreementPubKey,
            msgId: msgId
        )
    }

    static func unseal(
        encoded: String,
        senderUserId: String?,
        senderAgreementPubKey: Data?,
        msgId: String
    ) async -> UnsealedContent? {
        return await unseal(
            encoded: encoded,
            senderUserId: senderUserId,
            recipientUserId: nil,
            senderAgreementPubKey: senderAgreementPubKey,
            msgId: msgId
        )
    }

    // MARK: - Unseal (canonical)

    /// Undo `seal(...)`. Returns the original plaintext + an
    /// indication of whether the payload was sealed. Returns nil when
    /// the wire blob is structurally garbage — the chat surface then
    /// shows "[unreadable]" instead of attacker-controlled bytes.
    /// (Audit finding C3.)
    static func unseal(
        encoded: String,
        senderUserId: String?,
        recipientUserId: String?,
        senderAgreementPubKey: Data?,
        msgId: String
    ) async -> UnsealedContent? {
        // Length guard up front: a >256 KB Base64 input expands to
        // ~192 KB of bytes — well past anything legitimate.
        guard encoded.count <= maxWireBytes * 2 else {
            return UnsealedContent(plaintext: "", isEncrypted: false, reason: .decryptFailed)
        }
        guard let wire = Data(base64Encoded: encoded), wire.count >= magicLength else {
            // Hardening: a malicious server could push a non-Base64
            // string here and the old code would `return
            // plaintext: encoded` — straight from attacker to the
            // bubble. Return a non-renderable sentinel; the bubble
            // will show "[unreadable]" instead of attacker text.
            // (Audit finding C3.)
            return nil
        }
        guard wire.count <= maxWireBytes else {
            return UnsealedContent(plaintext: "", isEncrypted: false, reason: .decryptFailed)
        }

        let magic = wire.prefix(magicLength)
        let rest = wire.subdata(in: magicLength..<wire.count)

        // 🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #59.
        // ATSAM hybrid path. Magic `RVNA1\0\0\0` indicates the
        // sender encrypted via `ATSAMMessageSealer` (ChaCha20-Poly1305
        // over an ATSAM HKDF-derived key, AAD bound to sender +
        // recipient + msgId). Receiver looks up its cached root
        // for `senderUserId`, derives the same K_msg, AEAD-opens.
        // Fails closed on missing root or AEAD mismatch — we never
        // return attacker bytes.
        //
        // 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
        // Task #62. Hacker agent #5 finding: RVNA1 path was
        // bypassing the SealedReplayWindow that protects RVNS1
        // frames from cross-process replay. Bracket the AEAD open
        // with the same replay-window guard so a recorded RVNA1
        // ciphertext can't be replayed into the chat surface twice.
        if magic == ATSAMMessageSealer.magic {
            let resolvedRecipient = await Self.resolveSelfUserId(recipientUserId)
            guard let sUid = senderUserId, !sUid.isEmpty,
                  let rUid = resolvedRecipient, !rUid.isEmpty else {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .noSenderKey)
            }
            // Replay-window peerPID: hash the sender's userId
            // (we don't have an X25519 pubkey here — the ATSAM
            // root is the trust anchor, but we want a stable
            // 16-byte peer id for the window). SHA-256-prefix of
            // the senderUserId is stable across sessions and
            // cheap to compute.
            let peerPID = Self.peerIDForUserId(sUid)
            if await Self.replayWindow.isReplay(peerPID: peerPID, msgId: msgId) {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }
            if let plain = await ATSAMMessageSealer.unseal(
                encoded: encoded,
                senderUserId: sUid,
                recipientUserId: rUid,
                msgId: msgId
            ) {
                // Record AFTER successful decrypt so a future
                // replay of the same msgId from this peer trips
                // the guard above. Mirrors the RVNS1 path.
                await Self.replayWindow.record(peerPID: peerPID, msgId: msgId)
                return UnsealedContent(plaintext: plain, isEncrypted: true, reason: .atsamHybrid)
            }
            // Magic matched but AEAD failed → either tampered, peer
            // re-paired, or sender shipped under wrong root.
            return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
        }

        if magic == handshakeMagic {
            // Serverless first-contact: the body rode inside a Noise IK
            // message-1. Open it statelessly (no cached session) and surface the
            // embedded payload. The IK handshake authenticates the sender (we
            // recover their static key); on mesh/bridge the envelope's Ed25519
            // signature + identity binding authenticate it again at the
            // transport layer.
            guard rest.count >= minSealedRest else {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }
            let opened: (payload: Data, peerStatic: Data)? = await MainActor.run {
                NoiseSessionStore.shared.openHandshake1Stateless(message1: rest)
            }
            guard let opened, let str = String(data: opened.payload, encoding: .utf8) else {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }
            // If the caller told us who the sender should be, the static key the
            // IK handshake recovered MUST match — else it's an impersonation.
            if let expected = senderAgreementPubKey, expected.count == 32, opened.peerStatic != expected {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }
            // Replay guard keyed on the recovered sender + msgId (mirrors RVNS1).
            let hsPeerPID = peerID(fromPublicKey: opened.peerStatic)
            if await Self.replayWindow.isReplay(peerPID: hsPeerPID, msgId: msgId) {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }
            await Self.replayWindow.record(peerPID: hsPeerPID, msgId: msgId)
            return UnsealedContent(plaintext: str, isEncrypted: true, reason: .noiseTransport)
        }

        if magic == sealedMagic {
            // Hardening C4: a ChaCha20-Poly1305 AEAD frame can't be
            // smaller than its 16-byte tag + at least one ciphertext
            // byte. Reject without going into the cipher state so we
            // don't trigger the AEAD-fail → session-evict path.
            guard rest.count >= minSealedRest else {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }
            // Resolve sender key: explicit arg wins, else PeerKey
            // directory (which may fetch + verify from the server).
            var resolvedPub: Data? = nil
            if let pub = senderAgreementPubKey, pub.count == 32 {
                resolvedPub = pub
            } else if let uid = senderUserId, !uid.isEmpty {
                resolvedPub = await PeerKeyDirectory.shared.ensureAgreementKey(for: uid)
            }
            guard let pub = resolvedPub, pub.count == 32 else {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .noSenderKey)
            }
            let peerPID = peerID(fromPublicKey: pub)

            // Round 17 — hacker-audit C11 (lite). Reject this
            // sealed frame BEFORE the AEAD attempt if we already
            // decrypted the same (peerPID, msgId) in this session.
            // Stops a replay from consuming the consecutive-AEAD-
            // fail budget that gates `NoiseSessionStore` eviction
            // AND prevents in-session ciphertext-probing attacks.
            if await Self.replayWindow.isReplay(peerPID: peerPID, msgId: msgId) {
                return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
            }

            // AAD must mirror what the sender used. Recipient ID is
            // OUR userId (we resolve it if the caller didn't pass
            // one). Sender ID came in as `senderUserId`.
            let resolvedRecipient = await Self.resolveSelfUserId(recipientUserId)
            let ad = Self.buildAAD(
                senderUserId: senderUserId,
                recipientUserId: resolvedRecipient,
                msgId: msgId
            )
            let pt: Data? = await MainActor.run {
                NoiseSessionStore.shared.decrypt(rest, ad: ad, fromPeer: peerPID)
            }
            if let pt {
                // Reject a decrypted body that isn't valid UTF-8 —
                // the only thing we ever seal is `Data(text.utf8)`,
                // so an invalid decode means session confusion or
                // ciphertext tampering past the AEAD (shouldn't
                // happen, but cheap to assert).
                guard let str = String(data: pt, encoding: .utf8) else {
                    return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
                }
                // Successful decrypt — record so a future replay of
                // the same msgId from this peer trips the guard
                // above.
                await Self.replayWindow.record(peerPID: peerPID, msgId: msgId)
                return UnsealedContent(plaintext: str, isEncrypted: true, reason: .noiseTransport)
            }
            return UnsealedContent(plaintext: "", isEncrypted: true, reason: .decryptFailed)
        }

        if magic == plainMagic {
            // Reject non-UTF-8 RVNP1 too — same reason: only legit
            // senders write valid UTF-8 here.
            guard let str = String(data: rest, encoding: .utf8) else {
                return UnsealedContent(plaintext: "", isEncrypted: false, reason: .decryptFailed)
            }
            return UnsealedContent(plaintext: str, isEncrypted: false, reason: .explicitPlaintext)
        }

        // Unknown magic — refuse to echo attacker bytes. Earlier
        // versions returned `.legacy` here with the raw input as
        // plaintext, which let a server inject arbitrary bubble text.
        // (Audit finding C3.) For genuinely pre-round-10 messages
        // the caller should use the dedicated `unsealLegacyText`
        // helper below; that path is explicit, opt-in, and the
        // bubble UI must mark the result as legacy.
        return nil
    }

    /// Explicit accessor for the pre-round-10 plaintext path. Returns
    /// the raw `encoded` string as plaintext, marked `.legacy`. This
    /// is the ONLY way to surface a pre-magic-header payload in the
    /// chat UI — and the caller is responsible for ensuring the
    /// bubble renders the result with the legacy/unencrypted badge.
    ///
    /// Splitting this off from the regular unseal path is what stops
    /// a malicious server from achieving the same effect by sending a
    /// non-Base64 string and tricking the legacy fallback.
    static func unsealLegacyText(_ encoded: String) -> UnsealedContent {
        UnsealedContent(plaintext: encoded, isEncrypted: false, reason: .legacy)
    }

    // MARK: - AAD construction

    /// Builds the AAD that binds the Noise ciphertext to a specific
    /// (sender, recipient, msgId, protocol-domain) tuple.
    ///
    /// Hashed at the end so the actual AAD is fixed-length and
    /// independent of userId length quirks (e.g. an attacker can't
    /// vary userId encoding to manipulate AAD bytes). SHA-256 is
    /// fine here — it's a domain-separated transcript hash, not a
    /// password.
    private static func buildAAD(
        senderUserId: String?,
        recipientUserId: String?,
        msgId: String
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: aadDomain)
        hasher.update(data: Data([0x00]))                                 // separator
        hasher.update(data: Data((senderUserId ?? "").utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data((recipientUserId ?? "").utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(msgId.utf8))
        return Data(hasher.finalize())
    }

    /// If the caller didn't pass a userId, hop to KeychainService.
    /// Used by both seal (sender side = us) and unseal (recipient
    /// side = us).
    private static func resolveSelfUserId(_ supplied: String?) async -> String? {
        if let supplied, !supplied.isEmpty { return supplied }
        return await KeychainService.shared.getUserId()
    }

    // Convenience: hash-down a 32-byte X25519 public key to the
    // shorter peer ID NoiseSessionStore keys by.
    private static func peerID(fromPublicKey publicKey: Data) -> Data {
        let hash = SHA256.hash(data: publicKey)
        return Data(hash.prefix(16))
    }

    /// 🔴 ROUND 71 phase 3 follow-up #5 hardening (2026-05-24) —
    /// Task #62. Stable 16-byte peerPID derived from a userId, used
    /// as the replay-window key for the RVNA1 (ATSAM) path. The
    /// RVNS1 path uses `peerID(fromPublicKey:)` keyed on the
    /// sender's X25519 pubkey — for ATSAM we don't carry that on
    /// the wire, so we derive a stable peerPID from the userId
    /// instead. Domain-tagged to prevent any cross-collision
    /// between the two peerPID schemes.
    fileprivate static func peerIDForUserId(_ userId: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("raven-atsam-peerpid".utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(userId.utf8))
        return Data(hasher.finalize().prefix(16))
    }
}

// MARK: - Replay window

/// Per-peer sliding window of recently-decrypted msgIds. Used by
/// `MessageContentSealer.unseal` to short-circuit replays before
/// they hit the Noise transport state.
///
/// 🔴 ROUND 70 — was in-memory only; persisted across process exits
/// so a cold-start replay (attacker holds the captured frame across
/// our process exit) still trips the guard.
///
/// 🔴 ROUND 72 — H2.V1 (#87): persistence moved from UserDefaults to
/// the Keychain. UserDefaults is a plaintext plist that ships in
/// iTunes/Finder backups and is readable/writable by anything in the
/// app sandbox — an attacker who edited the backup could ERASE the
/// seen-set and re-deliver captured frames. The window now lives in
/// the Keychain (`AfterFirstUnlockThisDeviceOnly`, non-synchronizable
/// → never in backups, never on iCloud) and is authenticated with an
/// HMAC-SHA256 tag under a per-install random key. On tag-mismatch we
/// start empty: the window is best-effort defense-in-depth; the
/// per-message AEAD is the real integrity guarantee, so a lost window
/// can only admit an AEAD-authentic duplicate, never a forgery.
/// The DB UNIQUE constraint
/// at the chat-surface layer was unreliable (see round-70 audit:
/// no UNIQUE on `client_message_id` exists server-side anyway) and
/// fires AFTER the Noise transport state has already moved.
///
/// Window size is per-peer to stop a chatty peer from evicting a
/// quieter peer's entries.
actor SealedReplayWindow {
    /// Number of recent msgIds retained per peer. 512 ≈ ~1 hour of
    /// chat at a brisk pace — plenty to catch the practical replay
    /// scenarios without eating much RAM (peerPID is 16 bytes,
    /// msgId is ≤ 36 bytes, so ~26 KB per peer at the cap).
    private let perPeerCap = 512

    /// Insertion-ordered map: peerPID → ordered set of msgIds.
    /// Using a plain `[Data: [String]]` because Swift's `Set` is
    /// unordered and we need FIFO eviction.
    private var seen: [Data: [String]] = [:]

    /// 🔴 ROUND 72 — H2.V1 (#87). Keychain-resident, HMAC-authenticated
    /// store. The window blob is `tag(32) ‖ json` where `json` maps
    /// base64(peerPID) → [msgId] (bounded by perPeerCap) and `tag` is
    /// HMAC-SHA256(json) under a per-install random key.
    private static let kcService = "app.raven.ios.sealer.replay"
    private static let kcWindowAccount = "replayWindow.v2"      // tag(32) ‖ json
    private static let kcMacKeyAccount = "replayWindow.mac.v1"  // 32-byte HMAC key
    /// Legacy UserDefaults key (round 70). Deleted on first load so the
    /// attacker-mutable plaintext copy doesn't linger after migration.
    private static let legacyDefaultsKey = "raven.sealer.replayWindow.v1"
    private var loaded = false

    /// Load persisted window on first use. Done lazily inside the
    /// actor to avoid a launch-time wait.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        // One-time migration: drop the old plaintext UserDefaults blob.
        // We deliberately do NOT import it — it is exactly the
        // attacker-mutable data H2.V1 is about. Starting empty costs at
        // most a single AEAD-authentic duplicate right after upgrade.
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)

        guard let blob = Self.kcGet(account: Self.kcWindowAccount),
              blob.count > 32,
              let macKey = Self.macKey() else { return }
        let tag = blob.prefix(32)
        let body = blob.subdata(in: 32..<blob.count)
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: body, using: macKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: body)
        else {
            // Tampered or corrupted — start clean. (AEAD remains the
            // real integrity guarantee; see actor doc.)
            return
        }
        for (peerB64, ids) in decoded {
            guard let peer = Data(base64Encoded: peerB64) else { continue }
            seen[peer] = ids
        }
    }

    /// Save the current window to the Keychain, authenticated with the
    /// per-install HMAC key. Cheap — JSON encode of a bounded dict.
    private func save() {
        var encoded: [String: [String]] = [:]
        for (peer, ids) in seen {
            encoded[peer.base64EncodedString()] = ids
        }
        guard let json = try? JSONEncoder().encode(encoded),
              let macKey = Self.macKey() else { return }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: json, using: macKey))
        var blob = Data()
        blob.append(tag)
        blob.append(json)
        Self.kcSet(blob, account: Self.kcWindowAccount)
    }

    /// True iff (peerPID, msgId) has been seen + recorded already.
    /// Use this on a successful decrypt — the contract is "I'm
    /// about to attempt decrypt, has this msgId already arrived?"
    func isReplay(peerPID: Data, msgId: String) -> Bool {
        loadIfNeeded()
        guard let list = seen[peerPID] else { return false }
        return list.contains(msgId)
    }

    /// Record a freshly-decrypted msgId. Eviction is FIFO at the
    /// per-peer cap.
    func record(peerPID: Data, msgId: String) {
        loadIfNeeded()
        var list = seen[peerPID] ?? []
        // Guard against accidental double-record in racing decrypts.
        guard !list.contains(msgId) else { return }
        list.append(msgId)
        if list.count > perPeerCap {
            list.removeFirst(list.count - perPeerCap)
        }
        seen[peerPID] = list
        save()
    }

    /// Drop everything — used by tests / logout paths.
    func purge() {
        seen.removeAll()
        Self.kcDelete(account: Self.kcWindowAccount)
        // Belt-and-suspenders: clear any legacy plaintext remnant too.
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    // MARK: - Keychain helpers (device-bound, non-synchronizable)

    /// Fetch (or lazily generate + persist) the 32-byte HMAC key that
    /// authenticates the persisted window. Keychain-resident so a
    /// backup thief can't forge a valid window blob offline.
    private static func macKey() -> SymmetricKey? {
        if let existing = kcGet(account: kcMacKeyAccount), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard status == errSecSuccess else { return nil }
        kcSet(bytes, account: kcMacKeyAccount)
        return SymmetricKey(data: bytes)
    }

    private static func kcSet(_ data: Data, account: String) {
        kcDelete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func kcGet(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func kcDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Result types

struct SealedContent {
    let base64: String
    let isEncrypted: Bool
    let reason: SealReason

    enum SealReason {
        case noiseTransport     // Properly sealed with a Noise session
        case noSession          // We have the pubkey but no live session
        case noRecipientKey     // Caller didn't supply the recipient's pubkey
        // 🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #59.
        case atsamHybrid        // Sealed via ATSAM (X25519 + ML-KEM-768)
    }
}

struct UnsealedContent {
    let plaintext: String
    let isEncrypted: Bool
    let reason: UnsealReason

    enum UnsealReason {
        case noiseTransport     // Decrypted with a Noise session
        case explicitPlaintext  // Sender admitted it wasn't encrypted (RVNP1)
        case legacy             // No magic header — pre-round-10 payload
        case decryptFailed      // Magic was RVNS1/RVNA1 but decrypt failed
        case noSenderKey        // We didn't have the sender's pubkey to try
        // 🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) — Task #59.
        case atsamHybrid        // Decrypted via ATSAM hybrid path
    }
}
