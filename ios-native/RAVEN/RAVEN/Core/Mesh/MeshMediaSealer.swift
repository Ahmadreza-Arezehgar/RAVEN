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
import CryptoKit

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
        // Serverless media: a random AES-256 content key (base64). The ACTUAL
        // media bytes are AES-GCM-encrypted with this key and ride OUTSIDE this
        // bundle in the envelope's `mediaCipher` field (Noise messages cap at
        // 64 KB, so big media can't live inside the Noise-sealed bundle — only
        // the 32-byte key does). nil for legacy URL-only senders.
        var contentKey: String? = nil
    }

    /// Max raw file size we embed inline. Bigger files fall back to the legacy
    /// URL path (server, when one exists). Keeps a single envelope within what
    /// the bridge (bumped frame cap) + chunked BLE mesh can carry.
    // 6 MB raw. After the content-key AES-GCM + base64 (mediaCipher) + the
    // bridge's outer JSON+base64 the wire grows ~1.8×, so 6 MB stays well under
    // the 24 MiB bridge frame cap. Photos compress below this; bigger files fall
    // back to the legacy URL path.
    static let maxEmbedBytes = 6 * 1024 * 1024

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

        var bundle = MediaBundle(
            mediaUrl: envelope.mediaUrl,
            thumbnailUrl: envelope.thumbnailUrl,
            fileName: envelope.fileName,
            mimeType: envelope.mimeType,
            fileSize: envelope.fileSize,
            audioDuration: envelope.audioDuration
        )

        // SERVERLESS MEDIA: when the outbound mediaUrl is a LOCAL file (the
        // sender can't upload to a server), encrypt its bytes with a random
        // AES-256 content key and ship the ciphertext in envelope.mediaCipher;
        // the key + metadata ride in this Noise-sealed bundle. The receiver
        // recovers the key, AES-opens the cipher, writes it to a local file.
        if let localBytes = Self.readLocalFile(bundle.mediaUrl), localBytes.count <= maxEmbedBytes {
            let key = SymmetricKey(size: .bits256)
            if let box = try? AES.GCM.seal(localBytes, using: key), let combined = box.combined {
                envelope.mediaCipher = combined.base64EncodedString()
                bundle.contentKey = key.withUnsafeBytes { Data(Array($0)).base64EncodedString() }
                bundle.mediaUrl = nil
                if bundle.fileSize == nil { bundle.fileSize = localBytes.count }
            }
        }

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
            if let (cipherB64, version) = await GroupKeyService.shared.encrypt(jsonStr, groupId: groupId) {
                sealedB64 = cipherB64
                // Stamp the key version so the receiver's `unseal` can look up
                // the matching group key — without this, `unseal`'s group
                // branch (which requires `envelope.groupKeyVersion`) never runs
                // and all group media metadata is silently dropped on receive.
                envelope.groupKeyVersion = version
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
              var bundle = try? JSONDecoder().decode(MediaBundle.self, from: data) else {
            // Decrypt or decode failed — leave legacy fields nil.
            // Clear `mediaSealed` so a downstream double-unseal
            // doesn't get confused.
            envelope.mediaSealed = nil
            return
        }

        // SERVERLESS MEDIA: recover the content key from the (Noise-sealed)
        // bundle, AES-open the ciphertext that rode in envelope.mediaCipher,
        // write the bytes to a local cache file, and point mediaUrl at it
        // (file://) so the existing render path loads it with NO server. The
        // AES-GCM tag fails closed on any relay tampering → media-missing.
        if let keyB64 = bundle.contentKey, let keyData = Data(base64Encoded: keyB64),
           let cipherB64 = envelope.mediaCipher, let cipher = Data(base64Encoded: cipherB64),
           let box = try? AES.GCM.SealedBox(combined: cipher),
           let raw = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
           let localURL = Self.writeLocalFile(raw, msgId: envelope.clientMessageId, fileName: bundle.fileName, mimeType: bundle.mimeType) {
            bundle.mediaUrl = localURL.absoluteString
            if bundle.fileSize == nil { bundle.fileSize = raw.count }
            envelope.mediaCipher = nil  // consumed
        }

        envelope.mediaUrl       = bundle.mediaUrl
        envelope.thumbnailUrl   = bundle.thumbnailUrl
        envelope.fileName       = bundle.fileName
        envelope.mimeType       = bundle.mimeType
        envelope.fileSize       = bundle.fileSize
        envelope.audioDuration  = bundle.audioDuration
        envelope.mediaSealed    = nil
    }

    // MARK: - Local file helpers (serverless inline media)

    /// Read a genuinely-LOCAL media file for embedding. Returns nil for http(s)
    /// URLs (those are already a server-hosted blob, not ours to inline) and for
    /// missing files.
    private static func readLocalFile(_ urlString: String?) -> Data? {
        guard let s = urlString, !s.isEmpty,
              !s.hasPrefix("http://"), !s.hasPrefix("https://") else { return nil }
        let url: URL
        if s.hasPrefix("file://") {
            guard let u = URL(string: s) else { return nil }
            url = u
        } else {
            url = URL(fileURLWithPath: s)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Write received inline media bytes to a stable local cache file and return
    /// its file:// URL. Keyed on the message id so re-delivery is idempotent.
    private static func writeLocalFile(_ raw: Data, msgId: String, fileName: String?, mimeType: String?) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("raven_media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nameExt = (fileName as NSString?)?.pathExtension ?? ""
        let ext = !nameExt.isEmpty ? nameExt : (extForMime(mimeType) ?? "bin")
        let safe = msgId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let url = dir.appendingPathComponent("\(safe).\(ext)")
        // Idempotent: if we already wrote this message's media, reuse it.
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do { try raw.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private static func extForMime(_ mime: String?) -> String? {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        case "audio/m4a", "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/mpeg": return "mp3"
        case "video/mp4", "video/quicktime": return "mp4"
        case "application/pdf": return "pdf"
        default: return nil
        }
    }
}
