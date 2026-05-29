//
//  MeshMediaSealer.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — hacker-audit Mesh F1 (CRITICAL).
//
//  Before this round the six attachment metadata fields
//  (`mediaUrl`, `thumbnailUrl`, `fileName`, `mimeType`, `fileSize`,
//  `audioDuration`) rode the BLE wire in PLAINTEXT inside every
//  `MeshEnvelope`. The signed-only broadcast path (per-peer ECDH was
//  best-effort) meant a passive BLE peer along the mesh route could:
//
//    1. JSON-decode the SignedMeshPayload.
//    2. Read `mu`/`tu`/`fn`/`mt`/`fs`/`ad` in cleartext.
//    3. `curl` the photo/PDF/voice note straight from Cloud Storage.
//
//  The matching server-side gap (eternal public-read URLs on
//  `storage.googleapis.com`) was closed in the round-26 Server F1
//  patch — uploads now mint a 15-minute V4 signed URL and the
//  GCS bucket is private. But a relay node that captured the
//  signed URL during the window still has 15 minutes to grab the
//  file. Sealing the metadata closes that residual leak too.
//
//  Two transport shapes:
//
//    • 1:1 mesh — seal via `MessageContentSealer` (Noise transport
//      AEAD bound to sender+recipient+msgId, RVNS1 envelope).
//      Falls back to RVNP1 plaintext when no Noise session is up,
//      same as the text path — the receiver renders the legacy
//      fields as before but the sender's lock badge correctly
//      shows "not E2E".
//
//    • Group mesh — seal via `GroupKeyService.encrypt` with the
//      group's symmetric key + version. Non-members can't decrypt;
//      member-on-relay is unavoidable by definition (they hold the
//      key anyway).
//
//  Wire shape inside the envelope:
//
//    `mediaSealed` (codingKey `msl`) holds the sealed Base64 blob.
//    The legacy six fields are ALL nulled on the outbound wire so a
//    passive listener gets nothing. On receive, this helper unseals
//    `mediaSealed` and re-populates the legacy six fields IN PLACE,
//    so the rest of the message pipeline (`fromMeshEnvelope`,
//    `MessageRepository.upsert`, the chat UI) continues to work
//    unchanged.
//
//  Back-compat: an envelope from a pre-round-26 sender will arrive
//  with `mediaSealed == nil` and the legacy fields populated. The
//  unseal helper detects that case and returns without modifying
//  the envelope — the receiver still renders the message, just
//  without the privacy gain.
//

import Foundation

enum MeshMediaSealer {

    /// JSON shape of the bundled metadata. Stable across rounds —
    /// add fields only at the end, never rename, never drop.
    struct MediaBundle: Codable {
        var mediaUrl: String?
        var thumbnailUrl: String?
        var fileName: String?
        var mimeType: String?
        var fileSize: Int?
        var audioDuration: Int?
    }

    /// True iff the envelope has any of the six legacy media fields
    /// populated. Used to skip the seal entirely on text-only sends.
    private static func hasMediaPayload(_ envelope: MeshEnvelope) -> Bool {
        if envelope.mediaUrl != nil { return true }
        if envelope.thumbnailUrl != nil { return true }
        if envelope.fileName != nil { return true }
        if envelope.mimeType != nil { return true }
        if envelope.fileSize != nil { return true }
        if envelope.audioDuration != nil { return true }
        return false
    }

    /// Bundle the six media fields, seal, and write to
    /// `mediaSealed`. NULLs the legacy fields IN PLACE so the wire
    /// envelope carries no plaintext metadata.
    ///
    /// Call this BEFORE `toSecureEnvelope() + signEnvelope()` at
    /// every mesh transmit chokepoint. Idempotent — re-sealing an
    /// envelope that already has `mediaSealed` populated is a no-op.
    static func seal(envelope: inout MeshEnvelope) async {
        // Idempotency guard — already sealed by an earlier hop.
        if envelope.mediaSealed != nil { return }
        // Nothing to seal — text-only / system message.
        guard hasMediaPayload(envelope) else { return }

        let bundle = MediaBundle(
            mediaUrl: envelope.mediaUrl,
            thumbnailUrl: envelope.thumbnailUrl,
            fileName: envelope.fileName,
            mimeType: envelope.mimeType,
            fileSize: envelope.fileSize,
            audioDuration: envelope.audioDuration
        )

        guard let json = try? JSONEncoder().encode(bundle),
              let jsonStr = String(data: json, encoding: .utf8),
              !jsonStr.isEmpty else {
            // Encode failure — fail-CLOSED. Drop the legacy fields
            // even though we couldn't seal, so a buggy encoder
            // doesn't accidentally leak.
            envelope.mediaUrl = nil
            envelope.thumbnailUrl = nil
            envelope.fileName = nil
            envelope.mimeType = nil
            envelope.fileSize = nil
            envelope.audioDuration = nil
            return
        }

        let sealedB64: String?
        let isGroup = envelope.isGroup ?? false
        if isGroup {
            // Group path — AES-GCM with the cached group key.
            // recipientId for groups carries the group id.
            let groupId = envelope.recipientId
            if let (cipherB64, _) = await GroupKeyService.shared.encrypt(jsonStr, groupId: groupId) {
                sealedB64 = cipherB64
            } else {
                // No key available — fail-CLOSED rather than ship
                // the metadata in cleartext. The outer enqueue path
                // for groups already aborts in this case (see
                // `MessageRouter.enqueueMesh`), but defend in depth.
                sealedB64 = nil
            }
        } else {
            // 1:1 path — Noise transport via MessageContentSealer.
            // The recipient unseals using the same (sender,
            // recipient, msgId) AAD binding.
            //
            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — fail-
            // closed: refuse to ship the plaintext (RVNP1) fallback
            // for media metadata too. Pre-fix `sealed.base64` was
            // non-empty even when `sealed.isEncrypted == false`
            // because the sealer wrapped the JSON in RVNP1 magic
            // (plaintext-with-header). A relay along the path
            // could base64-decode the wire + strip the magic +
            // read the media URL, file name, MIME, size, audio
            // duration — i.e. all the metadata we're trying to
            // hide. Now we only ship a wire blob that the sealer
            // confirmed is genuine AEAD ciphertext; the receiver
            // sees the attachment-missing placeholder otherwise,
            // which is the right failure mode per security policy.
            let sealed = await MessageContentSealer.seal(
                plaintext: jsonStr,
                senderUserId: envelope.senderId,
                recipientUserId: envelope.recipientId,
                recipientAgreementPubKey: nil,
                msgId: envelope.clientMessageId + ":media"
            )
            if sealed.isEncrypted, !sealed.base64.isEmpty {
                sealedB64 = sealed.base64
            } else {
                #if DEBUG
                print("🔒 [MediaSealer] REFUSING to ship plaintext-fallback media metadata for \(envelope.clientMessageId.prefix(8)) — sealer reason=\(sealed.reason)")
                #endif
                sealedB64 = nil
            }
        }

        // ALWAYS strip the legacy plaintext fields — even if the
        // seal failed. A nil sealed blob means the receiver sees
        // no media metadata at all (chat bubble shows attachment-
        // missing placeholder), which is the right failure mode
        // vs. leaking metadata to every relay along the path.
        envelope.mediaUrl = nil
        envelope.thumbnailUrl = nil
        envelope.fileName = nil
        envelope.mimeType = nil
        envelope.fileSize = nil
        envelope.audioDuration = nil
        envelope.mediaSealed = sealedB64
    }

    /// Inverse of `seal`. Detects `mediaSealed`, unseals to a
    /// `MediaBundle`, and re-populates the legacy six fields IN
    /// PLACE so the downstream `fromMeshEnvelope` works unchanged.
    ///
    /// No-op when `mediaSealed` is nil (pre-round-26 sender). When
    /// the unseal fails — corrupted blob, missing key, wrong
    /// recipient — the legacy fields stay nil; the chat surface
    /// then shows the bubble without the attachment, same as a
    /// truly-missing media row.
    static func unseal(envelope: inout MeshEnvelope, myUserId: String) async {
        guard let sealed = envelope.mediaSealed, !sealed.isEmpty else { return }

        let jsonStr: String?
        let isGroup = envelope.isGroup ?? false
        if isGroup, let version = envelope.groupKeyVersion {
            jsonStr = await GroupKeyService.shared.decrypt(
                sealed, groupId: envelope.recipientId, version: version
            )
        } else if !isGroup {
            let unsealed = await MessageContentSealer.unseal(
                encoded: sealed,
                senderUserId: envelope.senderId,
                recipientUserId: myUserId,
                senderAgreementPubKey: nil,
                msgId: envelope.clientMessageId + ":media"
            )
            jsonStr = unsealed?.plaintext
        } else {
            jsonStr = nil
        }

        guard let jsonStr,
              let data = jsonStr.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(MediaBundle.self, from: data) else {
            // Decrypt or decode failed — leave legacy fields nil.
            // Clear `mediaSealed` so a downstream double-unseal
            // doesn't get confused.
            envelope.mediaSealed = nil
            return
        }

        envelope.mediaUrl       = bundle.mediaUrl
        envelope.thumbnailUrl   = bundle.thumbnailUrl
        envelope.fileName       = bundle.fileName
        envelope.mimeType       = bundle.mimeType
        envelope.fileSize       = bundle.fileSize
        envelope.audioDuration  = bundle.audioDuration
        envelope.mediaSealed    = nil
    }
}
