import Foundation
import UIKit
import AVFoundation
import PhotosUI

// MARK: - Attachment Service (Upload Pipeline)
actor AttachmentService {
    static let shared = AttachmentService()

    /// Posted after a new local message is inserted so ChatView can immediately reload.
    static let messageInserted = Notification.Name("AttachmentService.messageInserted")

    private let messageRepo = MessageRepository.shared
    private let fileManager = FileManager.default
    private var baseURL: String { AppConfig.apiBaseURL }

    /// Dedicated session for uploads. The shared NetworkService session uses an
    /// 8-second request timeout (tuned for small JSON calls), which kills file
    /// uploads on slow cellular or older iOS devices that fall back to HTTP/2
    /// after a flaky HTTP/3 negotiation. This session waits for connectivity,
    /// allows expensive/constrained networks, and gives uploads up to 60s to
    /// start streaming bytes — `timeoutIntervalForResource` is left at the
    /// default so a long upload still completes.
    nonisolated static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        // 🔴 ROUND 22 — disable HTTP/3 for the retry-shared upload
        // session too. Cloud Run + QUIC + large multipart triggers
        // "Message too long" connection cancels mid-stream. HTTP/2
        // is rock-solid for this workload.
        // Note: there's no public iOS API to outright disable HTTP/3
        // on a URLSessionConfiguration; the `assumesHTTP3Capable`
        // property is private. We instead rely on the
        // `executeWithRetry`-style fallback below to catch QUIC-
        // induced `cannotParseResponse` / `networkConnectionLost`
        // and re-try on the connection that gets re-established
        // after the QUIC stack is reset.
        return URLSession(configuration: config)
    }()

    // Local storage directory
    //
    // Round 14 (2026-05-16) — hacker-audit finding S7. The directory
    // is created with `FileProtectionType.complete` so its contents
    // (chat attachments — photos, videos, voice notes, documents,
    // and the locally-cached copies of decrypted vault payloads) are
    // unreadable any time the device is locked. Without this iOS
    // defaults to `.completeUntilFirstUserAuthentication`, which
    // means a backup extracted from a locked phone still yields the
    // attachments.
    //
    // The protection level is set once when the directory is
    // created; new files inherit the directory's class by default,
    // but each individual `Data.write` call should still pass
    // `.completeFileProtection` belt-and-suspender for the case
    // where the directory pre-existed from a build before this fix
    // (we won't re-create it then, and the old protection class
    // sticks).
    private var attachmentsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("attachments")
        try? fileManager.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [
                FileAttributeKey.protectionKey: FileProtectionType.complete
            ]
        )
        // Apply protection retroactively in case the directory
        // already existed under an older build.
        try? fileManager.setAttributes(
            [FileAttributeKey.protectionKey: FileProtectionType.complete],
            ofItemAtPath: dir.path
        )
        return dir
    }

    // MARK: - Retryable upload

    /// Errors that warrant a retry. These are the transient cases we see on
    /// devices that haven't been updated in a while — older iOS HTTP/3 stacks
    /// drop connections to Cloud Run, captive portals strip TLS, and cellular
    /// radios go to sleep mid-request. Without retry the user just sees
    /// "server is down" and has to redo the whole flow.
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotConnectToHost,
        .cannotFindHost,
        .networkConnectionLost,
        .notConnectedToInternet,
        .dnsLookupFailed,
        .secureConnectionFailed,
        .resourceUnavailable,
        // 🔴 ROUND 22 — QUIC ("Message too long") workaround.
        // Cloud Run negotiates HTTP/3 by default; on the iOS
        // simulator + on real devices with marginal cellular,
        // large multipart uploads sometimes truncate mid-stream,
        // which the URLSession layer surfaces as
        // `cannotParseResponse`. There's no public API to disable
        // HTTP/3 outright, so we rely on retry — the second
        // attempt usually lands on a fresh HTTP/2 fallback once
        // the QUIC connection has been torn down.
        .cannotParseResponse,
        .badServerResponse,
        .zeroByteResource
    ]

    /// Performs a multipart file upload with up to 3 attempts and exponential
    /// backoff (1s, 2s) between them. 5xx responses and transient `URLError`s
    /// are retried; 4xx is surfaced immediately so we don't loop on a real
    /// authorization or validation problem.
    fileprivate static func uploadWithRetry(
        request: URLRequest,
        fromFile fileURL: URL,
        attempts: Int = 3
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await uploadSession.upload(for: request, fromFile: fileURL)
                guard let http = response as? HTTPURLResponse else {
                    throw AttachmentError.uploadFailed
                }
                if (500...599).contains(http.statusCode), attempt < attempts - 1 {
                    try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
                    continue
                }
                return (data, http)
            } catch {
                lastError = error
                let retryable = (error as? URLError).map { retryableURLErrorCodes.contains($0.code) } ?? false
                guard retryable, attempt < attempts - 1 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? AttachmentError.uploadFailed
    }
    
    // MARK: - Send Image
    
    /// Serverless media delivery: route the already-persisted media message over
    /// BLE mesh + the libp2p bridge instead of a (dead) server upload. The
    /// mesh/bridge send chokepoints (MeshMediaSealer.seal) read the local file
    /// and embed the AES-encrypted bytes, so the photo/voice/file travels E2E
    /// with NO server. The bridge job processor skips groups (mesh carries them).
    private func routeMediaServerless(clientId: String) async {
        var channels: [JobChannel] = [.mesh]
        if !AppConfig.libp2pBootstrapCSV.isEmpty { channels.append(.bridge) }
        try? await DeliveryJobRepository.shared.createJobs(messageId: clientId, channels: channels)
        try? await messageRepo.updateDisplayState(clientMessageId: clientId, state: .ready, progress: 1.0)
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }
        #if DEBUG
        print("📎 [Attachment] serverless media routed over \(channels.map { $0.rawValue }) for \(clientId.prefix(8))")
        #endif
    }

    func sendImage(
        _ image: UIImage,
        roomId: String,
        recipientId: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
        clientMessageId: String? = nil,
        vault: Bool = false,
        // 🔴 ROUND 26 — Telegram-style album send. When the picker
        // batches N items, every sendImage / sendFile call in the
        // batch carries the same `albumGroupKey` UUID + its 0-based
        // `albumIndex` + the album's `albumTotal`. The receiver
        // groups same-key rows into a single bubble.
        albumGroupKey: String? = nil,
        albumIndex: Int? = nil,
        albumTotal: Int? = nil
    ) async throws {

        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.displayName ?? "" }
        let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }

        // 🔴 ROUND 22 — Bug B/D re-fix.
        // Round 20's "insert bubble with placeholder path then
        // patch later" approach was clever but broke the renderer:
        // the placeholder path didn't actually exist on disk, so
        // the bubble showed an empty grey rectangle until the user
        // restarted the app. Worse, if compression failed
        // afterwards, the bubble was stuck pointing at a path
        // that would never exist.
        //
        // New shape: compress + write FIRST (the round-20 loadFullImage
        // cap already cut the decode cost ~10×, so the visible
        // delay is now <250 ms on iPhone 17 Pro for a 12 MP photo).
        // Then insert the row pointing at the REAL file on disk —
        // the bubble appears with the actual thumbnail AND the
        // upload progress ring overlays on top (round-20 Bug C).
        //
        // The two improvements together (loadFullImage cap +
        // ring-overlay-on-image) get us most of the "instant
        // bubble" win without the placeholder-path trap.

        // Capture tier limits before entering the detached Task (concurrency safety)
        let maxDim = PremiumLimits.maxImageDimension
        let quality = PremiumLimits.imageCompressionQuality

        // Compress on background thread to avoid UI freeze.
        let data: Data = try await Task.detached(priority: .userInitiated) {
            // Always downscale: 2048px free, 8192px RAVEN+ — prevents OOM on 48MP+ ProRAW
            let safeImage = image.downscaled(maxDimension: maxDim)

            guard let d = safeImage.jpegData(compressionQuality: quality) else {
                throw AttachmentError.compressionFailed
            }
            return d
        }.value

        // Sender's local copy is ALWAYS the plaintext JPEG so the
        // sender's own chat bubble renders a real thumbnail. For a
        // vault send we additionally seal a SEPARATE blob and upload
        // only that — the cleartext never leaves the device.
        let localPath = attachmentsDirectory.appendingPathComponent("\(clientId).jpg")
        try data.write(to: localPath, options: [.atomic, .completeFileProtection])

        // 🔴 2026-05-20 — vault images must upload the SEALED blob,
        // not a renamed .jpg. PREVIOUSLY the vault path renamed
        // localPath to ".vlt" and uploaded that to /api/uploads/image,
        // which rejects non-image extensions AND re-encodes the bytes
        // — so vault image send failed with "Invalid file type".
        // Now the encrypted blob is uploaded as a separate RVNV1 file
        // and the server stores it opaque (see routers/uploads.py).
        var uploadPath = localPath
        if vault {
            // 🔴 ROUND 21 — encrypt to the RECIPIENT's X25519, not the
            // sender's. A nil return means we can't resolve a
            // verified recipient key — in vault mode FAIL HARD rather
            // than silently ship plaintext.
            if let encrypted = await Self.encryptForVault(
                data: data,
                aad: Data(clientId.utf8),
                recipientUserId: recipientId
            ) {
                let vaultPath = attachmentsDirectory.appendingPathComponent("\(clientId).image.vlt")
                try encrypted.write(to: vaultPath, options: [.atomic, .completeFileProtection])
                uploadPath = vaultPath
            } else {
                // Round 32 — surface the actual cause so the UI can
                // tell the user the recipient hasn't published a key.
                throw AttachmentError.vaultKeyUnavailable
            }
        }

        // 2. Insert to DB with uploading state — bubble appears
        // with the real on-disk thumbnail + a 0% ring overlay.
        // 🔴 ROUND 26 — stamp the album fields on the row so
        // ChatView's grouping pass picks it up immediately, before
        // the upload even finishes.
        let message = ChatMessage.newAttachmentMessage(
            messageId: clientId,
            to: recipientId,
            type: .image,
            localPath: localPath.path,
            fileName: "\(clientId).jpg",
            mimeType: "image/jpeg",
            fileSize: data.count,
            duration: nil,
            senderId: myId,
            senderName: myName,
            roomId: roomId,
            originDeviceId: deviceId,
            albumGroupKey: albumGroupKey,
            albumIndex: albumIndex,
            albumTotal: albumTotal
        )
        try await messageRepo.upsert(message)
        try? await messageRepo.updateDisplayState(
            clientMessageId: clientId,
            state: .uploading,
            progress: 0.0
        )
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }

        // SERVERLESS: with no backend token, don't dead-end on a server upload —
        // deliver the encrypted media bytes over BLE mesh + the libp2p bridge.
        if await KeychainService.shared.getToken() == nil {
            await routeMediaServerless(clientId: clientId)
            return
        }

        // ⚠️ PERSIST-FIRST: Check internet AFTER saving to DB so bubble stays visible with Retry
        guard NetworkMonitor.shared.isOnline else {
            try await messageRepo.updateDisplayState(clientMessageId: clientId, state: .failed, error: "No internet connection")
            throw AttachmentError.internetRequired
        }

        // 3. Upload to server using /api/uploads/image with progress.
        do {
            let remoteUrl = try await uploadImageWithProgress(
                localPath: uploadPath,
                clientId: clientId
            )
            
            // 4. Send message to server - use different endpoint for groups
            if isGroup {
                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(roomId)/messages",
                    body: SendGroupMessageRequest(
                        messageId: clientId,
                        content: "",
                        messageType: "image",
                        audioUrl: remoteUrl,
                        replyToMessageId: replyTo?.id,
                        // 🔴 ROUND 19 — hacker-audit Server F6: reply
                        // preview must NOT cross the server boundary in
                        // cleartext. Receiver looks it up locally by
                        // replyToMessageId. See MessageRouter for the
                        // matching mesh-side strip (round 14).
                        replyToTextPreview: nil,
                        replyToSenderName: replyTo?.senderName,
                        replyToType: replyTo?.type.rawValue,
                        // 🔴 ROUND 26 — Telegram-style album passthrough
                        mediaGroupKey: albumGroupKey,
                        mediaGroupIndex: albumIndex,
                        mediaGroupTotal: albumTotal
                    ),
                    idempotencyKey: clientId
                )

                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Group image sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            } else {
                // 🔴 ROUND 69 — vault sends mark allow_forward=false on
                // the server so the recipient's bubble hides the
                // Forward action. Forwarding a vault image to a third
                // party only leaks metadata + ships a file the third
                // party cannot decrypt. See MessageService.forwardMessage
                // for the matching client-side block.
                let wireExpiryMode: String? = vault ? "deleteIfForwarded" : nil

                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: clientId,
                        recipientId: recipientId,
                        content: "",
                        messageType: "image",
                        audioUrl: remoteUrl,
                        replyToMessageId: replyTo?.id,
                        expiryMode: wireExpiryMode,
                        // 🔴 ROUND 26 — Telegram-style album passthrough
                        mediaGroupKey: albumGroupKey,
                        mediaGroupIndex: albumIndex,
                        mediaGroupTotal: albumTotal
                    ),
                    idempotencyKey: clientId
                )

                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Image sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            }
            
            // 5. Mark Display State as Ready (Only after server accepted)
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .ready,
                remoteUrl: remoteUrl,
                thumbnailUrl: nil
            )
            
        } catch {
            #if DEBUG
            print("❌ Image send failed: \(error)")
            #endif
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }
    
    // MARK: - Send Album (Telegram-style grouped media — round 26)

    /// Send N images / videos as a SINGLE grouped album message.
    ///
    /// Each item is still uploaded + persisted as its own row (every
    /// item gets its own encryption envelope, signed URL, progress
    /// ring, ACK lifecycle — none of the round-21 hardening has to
    /// change). The trick is the shared `albumGroupKey` UUID we
    /// stamp across every item — the receiver's chat surface groups
    /// rows with the same key into one album bubble (see
    /// `AlbumBubbleView`).
    ///
    /// Concurrency: we kick uploads in parallel via a task group so
    /// a 5-photo album finishes ~5× faster than the legacy serial
    /// loop. Each child task awaits its own sendImage / sendFile so
    /// per-item progress is independent and a single failure leaves
    /// the other items intact (the user can retry just the failed
    /// tile).
    ///
    /// Order: `items` is treated as already-ordered (picker preserves
    /// selection order). `albumIndex` matches the array index.
    ///
    /// `clientMessageIds`, when provided, is an array of pre-allocated
    /// UUIDs (one per item) so the caller can pre-insert placeholder
    /// rows / wire optimistic UI BEFORE the network ride. Omit to
    /// have us mint fresh ones per item.
    func sendAlbum(
        items: [AlbumPickerItem],
        roomId: String,
        recipientId: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
        clientMessageIds: [String]? = nil
    ) async {
        guard !items.isEmpty else { return }
        // Generate the album-wide shared UUID. The string is opaque
        // to the receiver — they only use it for equality grouping.
        let albumKey = UUID().uuidString
        let total = items.count
        let cids = clientMessageIds ?? items.map { _ in UUID().uuidString }
        precondition(cids.count == items.count, "clientMessageIds count must match items count")

        // Kick all uploads in parallel via a task group. A single
        // failure surfaces in its own row (.failed state); the
        // others continue.
        await withTaskGroup(of: Void.self) { group in
            for (idx, item) in items.enumerated() {
                let cid = cids[idx]
                switch item {
                case .image(let image):
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.sendImage(
                                image,
                                roomId: roomId,
                                recipientId: recipientId,
                                isGroup: isGroup,
                                replyTo: replyTo,
                                clientMessageId: cid,
                                albumGroupKey: albumKey,
                                albumIndex: idx,
                                albumTotal: total
                            )
                        } catch {
                            #if DEBUG
                            print("⚠️ [sendAlbum] image \(idx)/\(total) failed: \(error)")
                            #endif
                        }
                    }
                case .fileURL(let url):
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.sendFile(
                                fileURL: url,
                                roomId: roomId,
                                recipientId: recipientId,
                                isGroup: isGroup,
                                replyTo: replyTo,
                                clientMessageId: cid,
                                albumGroupKey: albumKey,
                                albumIndex: idx,
                                albumTotal: total
                            )
                        } catch {
                            #if DEBUG
                            print("⚠️ [sendAlbum] file \(idx)/\(total) failed: \(error)")
                            #endif
                        }
                    }
                }
            }
        }
    }

    // MARK: - Send Voice

    func sendVoice(
        audioURL: URL,
        duration: Int,
        roomId: String,
        recipientId: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
        vault: Bool = false,
        clientMessageId: String? = nil
    ) async throws {
        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.displayName ?? "" }
        let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }
        
        // 1. Copy to local storage
        let localPath = attachmentsDirectory.appendingPathComponent("\(clientId).m4a")
        
        // BUG FIX [P2]: Prevent FileManager crash on retry if paths match or file exists
        if audioURL.path != localPath.path {
            if fileManager.fileExists(atPath: localPath.path) {
                try? fileManager.removeItem(at: localPath)
            }
            try fileManager.copyItem(at: audioURL, to: localPath)
        }
        
        let fileSize = try fileManager.attributesOfItem(atPath: localPath.path)[.size] as? Int ?? 0
        
        // 2. Insert to DB
        let message = ChatMessage.newAttachmentMessage(
            messageId: clientId,
            to: recipientId,
            type: .voice,
            localPath: localPath.path,
            fileName: "\(clientId).m4a",
            mimeType: "audio/m4a",
            fileSize: fileSize,
            duration: duration,
            senderId: myId,
            senderName: myName,
            roomId: roomId,
            originDeviceId: deviceId
        )
        
        try await messageRepo.upsert(message)
        
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }
        
        // SERVERLESS: with no backend token, don't dead-end on a server upload —
        // deliver the encrypted media bytes over BLE mesh + the libp2p bridge.
        if await KeychainService.shared.getToken() == nil {
            await routeMediaServerless(clientId: clientId)
            return
        }

        // ⚠️ PERSIST-FIRST: Check internet AFTER saving to DB so bubble stays visible with Retry
        guard NetworkMonitor.shared.isOnline else {
            try await messageRepo.updateDisplayState(clientMessageId: clientId, state: .failed, error: "No internet connection")
            throw AttachmentError.internetRequired
        }

        // 🔴 hacker-audit 2026-05-20 — Vault for voice messages.
        // PREVIOUSLY voice ALWAYS uploaded as a plaintext .m4a, so a
        // third party (server operator, anyone with the URL) could
        // play the recording even with Vault active. Now, when vault
        // is set, seal the audio with VaultFileCrypto (recipient-only
        // X25519 → AES-256-GCM) before upload — exactly as sendImage
        // / sendFile do. The plaintext copy at `localPath` stays on
        // the sender's own device for local replay; only ciphertext
        // leaves the phone.
        var uploadPath = localPath
        if vault {
            let plaintextAudio = try Data(contentsOf: localPath)
            if let encrypted = await Self.encryptForVault(
                data: plaintextAudio,
                aad: Data(clientId.utf8),
                recipientUserId: recipientId
            ) {
                let vaultPath = attachmentsDirectory.appendingPathComponent("\(clientId).voice.vlt")
                try encrypted.write(to: vaultPath, options: [.atomic, .completeFileProtection])
                uploadPath = vaultPath
            } else {
                try await messageRepo.updateDisplayState(
                    clientMessageId: clientId,
                    state: .failed,
                    error: AttachmentError.vaultKeyUnavailable.localizedDescription
                )
                throw AttachmentError.vaultKeyUnavailable
            }
        }

        // 3. Upload voice
        do {
            let remoteUrl = try await uploadVoice(
                localPath: uploadPath,
                originalFilename: "\(clientId).m4a"
            )
            
            // Send to server - use different endpoint for groups
            if isGroup {
                // Group voice message
                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(roomId)/messages",
                    body: SendGroupMessageRequest(
                        messageId: clientId,
                        content: "",
                        messageType: "voice",
                        audioUrl: remoteUrl,
                        audioDurationSeconds: duration,
                        replyToMessageId: replyTo?.id,
                        // 🔴 ROUND 19 — hacker-audit Server F6: reply
                        // preview must NOT cross the server boundary in
                        // cleartext. Receiver looks it up locally by
                        // replyToMessageId. See MessageRouter for the
                        // matching mesh-side strip (round 14).
                        replyToTextPreview: nil,
                        replyToSenderName: replyTo?.senderName,
                        replyToType: replyTo?.type.rawValue
                    ),
                    idempotencyKey: clientId
                )
                
                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Group voice sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            } else {
                // 1:1 voice message
                // 🔴 ROUND 69 — vault voice sends mark allow_forward=false
                // (see sendImage / sendFile for the full rationale).
                let wireExpiryMode: String? = vault ? "deleteIfForwarded" : nil

                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: clientId,
                        recipientId: recipientId,
                        content: "",
                        messageType: "voice",
                        audioUrl: remoteUrl,
                        audioDurationSeconds: duration,
                        replyToMessageId: replyTo?.id,
                        expiryMode: wireExpiryMode
                    ),
                    idempotencyKey: clientId
                )
                
                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Voice sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            }
            
            // Mark Display State as Ready (Only after server accepted)
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .ready,
                remoteUrl: remoteUrl
            )
            
        } catch {
            #if DEBUG
            print("❌ Voice send failed: \(error)")
            #endif
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }
    
    // MARK: - Send File (PDF, DOC, etc.)
    
    func sendFile(
        fileURL: URL,
        roomId: String,
        recipientId: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
        clientMessageId: String? = nil,
        /// 🟥 ROUND 32 (2026-05-17) — vault parity for files.
        ///
        /// Previously `sendImage` had a `vault: Bool` parameter that
        /// re-wrapped the JPEG bytes with `VaultFileCrypto`, but
        /// `sendFile` (PDFs, videos, documents) had no such option —
        /// so toggling Vault for a PDF / document / video silently
        /// uploaded the PLAINTEXT bytes to the server.  User
        /// expected E2EE; actually got TLS-only.  This is the
        /// gallery+video+PDF half of the user-reported "vault is
        /// weird" bug.
        vault: Bool = false,
        // 🔴 ROUND 26 — Telegram-style album send. See `sendImage`.
        albumGroupKey: String? = nil,
        albumIndex: Int? = nil,
        albumTotal: Int? = nil
    ) async throws {
        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.displayName ?? "" }
        let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }
        
        // 1. Copy to local storage
        let fileName = fileURL.lastPathComponent
        var localPath: URL

        // Fix: If file is already in our cache directory (retrying), don't copy again!
        if fileURL.deletingLastPathComponent().path == attachmentsDirectory.path {
            localPath = fileURL
        } else {
            localPath = attachmentsDirectory.appendingPathComponent("\(clientId)_\(fileName)")
            _ = fileURL.startAccessingSecurityScopedResource()
            defer { fileURL.stopAccessingSecurityScopedResource() }

            try fileManager.copyItem(at: fileURL, to: localPath)
            // Only delete the source if it's in our temp directory (never the user's original file)
            if fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        // 🟥 ROUND 32 (2026-05-17) — apply vault encryption for files
        // when the caller asked for it.  Symmetric with `sendImage`:
        //   1. Read the local bytes.
        //   2. Wrap with VaultFileCrypto using the recipient's
        //      X25519 public key + AAD = clientId.
        //   3. Overwrite the on-disk file with the wrapped bytes so
        //      the upload + retry paths ship the ciphertext, not the
        //      plaintext.
        //   4. Re-stat to pick up the new (slightly larger) size so
        //      the bubble's "X MB" caption is accurate.
        //
        // FAIL HARD when the recipient's prekey isn't resolvable —
        // same policy as `sendImage`: better an explicit failure
        // than a silent plaintext-fallback that would defeat the
        // user's "Vault" choice.
        if vault {
            guard let plainBytes = try? Data(contentsOf: localPath, options: .mappedIfSafe) else {
                throw AttachmentError.fileNotFound
            }
            if let wrapped = await Self.encryptForVault(
                data: plainBytes,
                aad: Data(clientId.utf8),
                recipientUserId: recipientId
            ) {
                try wrapped.write(to: localPath, options: [.atomic, .completeFileProtection])
            } else {
                throw AttachmentError.vaultKeyUnavailable
            }
        }

        var attrs = try fileManager.attributesOfItem(atPath: localPath.path)
        var fileSize = attrs[.size] as? Int ?? 0
        let mimeType = mimeTypeFor(path: fileName)

        let isVideoMimeForCompression: Bool = {
            if mimeType.lowercased().hasPrefix("video/") { return true }
            let ext = fileName.lowercased()
            return ["mp4", "mov", "m4v", "qt", "avi", "mkv", "webm"]
                .contains(where: { ext.hasSuffix(".\($0)") })
        }()

        // (2026-05-16 — round 9) PERSIST-FIRST FAST PATH.
        // Previously the client blocked on `AVAssetExportSession`
        // compression BEFORE inserting the DB row, so the chat bubble
        // didn't appear for 5-30 seconds on big videos — the user
        // reported "hess mikone user ke app konde" (feels frozen).
        // Now we:
        //   1. Insert the bubble immediately with state .uploading
        //      and progress 0.0
        //   2. Run compression off-thread (continues to push progress
        //      updates as "preparing 35%")
        //   3. Kick the network upload with delegate-based progress
        //   4. Flip state to .synced when the upload returns
        // This mirrors WhatsApp / Telegram's behaviour where the
        // bubble appears the moment the user taps Send.
        let isVideoMime: Bool = {
            if mimeType.lowercased().hasPrefix("video/") { return true }
            let lower = fileName.lowercased()
            return ["mp4", "mov", "m4v", "qt", "avi", "mkv", "webm"]
                .contains(where: { lower.hasSuffix(".\($0)") })
        }()
        let resolvedType: MessageType = isVideoMime ? .video : .file
        let wireMessageType: String = isVideoMime ? "video" : "file"

        let message = ChatMessage.newAttachmentMessage(
            messageId: clientId,
            to: recipientId,
            type: resolvedType,
            localPath: localPath.path,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            duration: nil,
            senderId: myId,
            senderName: myName,
            roomId: roomId,
            originDeviceId: deviceId,
            // 🔴 ROUND 26 — album grouping for video / file sends.
            albumGroupKey: albumGroupKey,
            albumIndex: albumIndex,
            albumTotal: albumTotal
        )

        try await messageRepo.upsert(message)

        // Surface the bubble immediately — state .uploading with 0 %
        // progress. The chat view shows a Telegram/WhatsApp-style
        // capsule progress overlay that ticks up as compression and
        // upload run.
        try? await messageRepo.updateDisplayState(
            clientMessageId: clientId,
            state: .uploading,
            progress: 0.0
        )
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }

        // SERVERLESS: with no backend token, don't dead-end on a server upload —
        // deliver the encrypted media bytes over BLE mesh + the libp2p bridge.
        if await KeychainService.shared.getToken() == nil {
            await routeMediaServerless(clientId: clientId)
            return
        }

        // ⚠️ PERSIST-FIRST: Check internet AFTER saving to DB so bubble stays visible with Retry
        guard NetworkMonitor.shared.isOnline else {
            try await messageRepo.updateDisplayState(clientMessageId: clientId, state: .failed, error: "No internet connection")
            throw AttachmentError.internetRequired
        }

        // (2026-05-16 — round 9) Run video compression NOW — after
        // the bubble is on-screen. Push tiny progress hops while it
        // works (10 → 25 → 40 %) so the user sees something moving.
        let serverGatewayLimit = 24 * 1024 * 1024
        if isVideoMimeForCompression && fileSize > serverGatewayLimit {
            try? await messageRepo.updateDisplayState(
                clientMessageId: clientId, state: .uploading, progress: 0.10
            )
            if let compressed = await Self.compressVideo(at: localPath) {
                try? fileManager.removeItem(at: localPath)
                try? fileManager.moveItem(at: compressed, to: localPath)
                attrs = (try? fileManager.attributesOfItem(atPath: localPath.path)) ?? attrs
                fileSize = attrs[.size] as? Int ?? fileSize
                try? await messageRepo.updateDisplayState(
                    clientMessageId: clientId, state: .uploading, progress: 0.25
                )
                #if DEBUG
                print("[AttachmentService] Video compressed → \(fileSize / 1024 / 1024) MB")
                #endif
            }
            // Keep the file-size patch in the DB row so the bubble's
            // size label reads the post-compression value.
            try? await messageRepo.updateAttachmentSize(clientMessageId: clientId, fileSize: fileSize)
        }

        // Premium gate after compression — only if we still blew the cap.
        let maxBytes = PremiumLimits.maxFileUploadBytes
        if fileSize > maxBytes {
            try? fileManager.removeItem(at: localPath)
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .failed,
                error: "File exceeds \(maxBytes / (1024 * 1024)) MB"
            )
            let maxMB = maxBytes / (1024 * 1024)
            throw PremiumLimitError.fileTooLarge(maxMB: maxMB)
        }

        // 3. Upload using /api/uploads/file with progress callbacks.
        do {
            let remoteUrl = try await uploadDocumentWithProgress(
                localPath: localPath,
                originalFilename: fileName,
                clientId: clientId
            )

            // Send to server - use different endpoint for groups
            if isGroup {
                // 🔴 ROUND 69 (2026-05-23) — hacker-audit VAULT-CRIT-1
                // (HIGH: vault file metadata leak via /api/messages/send).
                //
                // Until now, vault file sends shipped the original
                // `fileName` (e.g. "passport_2024.pdf"), `mimeType`
                // (e.g. "application/pdf"), and the encrypted-blob
                // `fileSize` to the server IN PLAINTEXT, where they
                // were stored on the `messages` row alongside the
                // (RVNV1-encrypted) attachment URL. A server admin /
                // DB compromise read every filename ever sent via
                // Vault — defeating the user's stated intent that
                // Vault sends carry no metadata to the server.
                //
                // FIX: when `vault == true`, ship a generic placeholder
                // filename + opaque MIME. The recipient infers the
                // real format from the decrypted plaintext's magic
                // bytes (`VaultPayloadResolver.extensionForVaultPlaintext`
                // already handles PDF/JPEG/PNG/MP4/etc.). The chat
                // surface renders these messages with a "🔒 Vault
                // attachment" label instead of the original name.
                //
                // Also flip `expiryMode = "deleteIfForwarded"` so the
                // server returns `allow_forward = false`, which the
                // recipient's bubble respects (forwarding a vault
                // attachment to a third party would only re-leak the
                // metadata + ship a file the third party cannot
                // decrypt — see MessageService.forwardMessage block).
                // Note: group vault sends are blocked one layer up
                // because `encryptForVault(recipientUserId:)` resolves
                // a peer X25519 key by userId, and a group_id is not a
                // userId — so `vault=true` on a group send already
                // throws `vaultKeyUnavailable` before reaching this
                // branch. We still apply the strip defensively in case
                // a future per-recipient group-vault scheme is added.
                let wireFileName: String? = vault ? "vault.bin" : fileName
                let wireMimeType: String? = vault ? "application/octet-stream" : mimeType

                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(roomId)/messages",
                    body: SendGroupMessageRequest(
                        messageId: clientId,
                        content: "",
                        messageType: wireMessageType,
                        audioUrl: remoteUrl,
                        fileName: wireFileName,
                        fileSize: fileSize,
                        mimeType: wireMimeType,
                        replyToMessageId: replyTo?.id,
                        // 🔴 ROUND 19 — hacker-audit Server F6: reply
                        // preview must NOT cross the server boundary in
                        // cleartext. Receiver looks it up locally by
                        // replyToMessageId. See MessageRouter for the
                        // matching mesh-side strip (round 14).
                        replyToTextPreview: nil,
                        replyToSenderName: replyTo?.senderName,
                        replyToType: replyTo?.type.rawValue,
                        // 🔴 ROUND 26 — album passthrough on group file send
                        mediaGroupKey: albumGroupKey,
                        mediaGroupIndex: albumIndex,
                        mediaGroupTotal: albumTotal
                    ),
                    idempotencyKey: clientId
                )

                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Group file sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            } else {
                // 🔴 ROUND 69 — same vault-metadata strip as the group
                // path above. See the long comment there for the full
                // attack rationale.
                let wireFileName: String? = vault ? "vault.bin" : fileName
                let wireMimeType: String? = vault ? "application/octet-stream" : mimeType
                let wireExpiryMode: String? = vault ? "deleteIfForwarded" : nil

                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: clientId,
                        recipientId: recipientId,
                        content: "",
                        messageType: wireMessageType,
                        audioUrl: remoteUrl,
                        replyToMessageId: replyTo?.id,
                        fileName: wireFileName,
                        fileSize: fileSize,
                        mimeType: wireMimeType,
                        expiryMode: wireExpiryMode,
                        // 🔴 ROUND 26 — album passthrough on 1:1 file send
                        mediaGroupKey: albumGroupKey,
                        mediaGroupIndex: albumIndex,
                        mediaGroupTotal: albumTotal
                    ),
                    idempotencyKey: clientId
                )
                
                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ File sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            }
            
            // Mark Display State as Ready (Only after server accepted)
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .ready,
                remoteUrl: remoteUrl
            )
            
            // ✅ Bug 3 fix: Clean up local copy after successful upload.
            // The server now has the file — keeping the local copy wastes disk space.
            // For a 2GB file, the copy chain was: source → attachments/ → .multipart tmp,
            // consuming ~4GB extra. The .multipart tmp is already cleaned by `defer` in
            // uploadDocument, and the source is cleaned above (line 271). This removes
            // the last redundant copy.
            try? fileManager.removeItem(at: localPath)
            #if DEBUG
            print("🧹 [AttachmentService] Cleaned up local file copy: \(fileName)")
            #endif
            
        } catch {
            #if DEBUG
            print("❌ File send failed: \(error)")
            #endif
            try await messageRepo.updateDisplayState(
                clientMessageId: clientId,
                state: .failed,
                error: error.localizedDescription
            )
            throw error
        }
    }
    
    // MARK: - Upload Image (POST /api/uploads/image)
    
    // MARK: - Public: Avatar Upload

    /// Compress + upload an avatar image to `/api/uploads/image` with the same
    /// retry/timeout hardening as chat attachments. Returns the CDN URL the
    /// caller should send to `/api/users/profile-picture`. Used by EditProfileView
    /// so the avatar flow no longer fails outright the first time the radio
    /// hiccups on an older iOS device.
    func uploadAvatarImage(_ image: UIImage) async throws -> String {
        let data: Data = try await Task.detached(priority: .userInitiated) {
            let safeImage = image.downscaled(maxDimension: 1024)
            guard let d = safeImage.jpegData(compressionQuality: 0.8) else {
                throw AttachmentError.compressionFailed
            }
            return d
        }.value

        let localPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: localPath)
        defer { try? FileManager.default.removeItem(at: localPath) }

        return try await uploadImage(localPath: localPath, clientId: UUID().uuidString)
    }

    private func uploadImage(localPath: URL, clientId: String) async throws -> String {
        let boundary = UUID().uuidString

        let tempFile = try writeMultipartToFile(
            boundary: boundary, fieldName: "file",
            fileName: localPath.lastPathComponent,
            mimeType: "image/jpeg", fileURL: localPath
        )
        defer { try? FileManager.default.removeItem(at: tempFile) }

        guard let url = URL(string: "\(baseURL)/api/uploads/image") else {
            throw AttachmentError.uploadFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if #available(iOS 16.0, *) {
            request.assumesHTTP3Capable = false   // round 22 QUIC workaround
        }

        let (responseData, httpResponse) = try await Self.uploadWithRetry(request: request, fromFile: tempFile)

        if !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            #if DEBUG
            print("❌ Upload failed (\(httpResponse.statusCode)): \(errorBody)")
            #endif
            throw AttachmentError.uploadFailed
        }

        let result = try JSONDecoder().decode(ChatImageUploadResponse.self, from: responseData)
        return result.imageUrl
    }

    // (2026-05-16 — round 9) Variant of `uploadImage` that streams
    // delegate-based progress updates back into the message row.
    // Same multipart shape; replaces `URLSession.shared.upload` with
    // a session that has a `UploadProgressDelegate`.
    private func uploadImageWithProgress(localPath: URL, clientId: String) async throws -> String {
        let boundary = UUID().uuidString
        let tempFile = try writeMultipartToFile(
            boundary: boundary, fieldName: "file",
            fileName: localPath.lastPathComponent,
            mimeType: "image/jpeg", fileURL: localPath
        )
        defer { try? FileManager.default.removeItem(at: tempFile) }

        guard let url = URL(string: "\(baseURL)/api/uploads/image") else {
            throw AttachmentError.uploadFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // 🔴 ROUND 22 — disable HTTP/3 per-request. The
        // URLSessionConfiguration knob is private, but the
        // URLRequest property IS public from iOS 16+. Cloud Run
        // advertises HTTP/3 via Alt-Svc; the simulator's QUIC
        // stack truncates large multipart uploads with "Message
        // too long" → cannot parse response. Forcing the request
        // to assume the server is NOT HTTP/3-capable makes
        // URLSession negotiate HTTP/2 on TLS for this exact send.
        if #available(iOS 16.0, *) {
            request.assumesHTTP3Capable = false
        }

        let delegate = UploadProgressDelegate { [weak messageRepo] progress in
            // Clamp 0…0.99 so we don't briefly show 100% before the
            // tick-mark phase below.
            let clamped = min(0.99, max(0.0, progress))
            Task {
                try? await messageRepo?.updateDisplayState(
                    clientMessageId: clientId,
                    state: .uploading,
                    progress: clamped
                )
            }
        }
        // 🔴 ROUND 22 — LIVE-TEST BUG. The image upload was failing
        // with `cannot parse response` on the simulator. Root cause:
        // the default URLSessionConfiguration enables HTTP/3 (QUIC)
        // on Cloud Run, and the simulator's QUIC stack throws
        // "Message too long" on large multipart uploads — the
        // connection cancels mid-stream and the client gets a
        // truncated body → decode fails. Same bug surfaces on real
        // devices over flaky cellular.
        //
        // Force HTTP/2 by disabling QUIC at the session level via
        // `assumesHTTP3Capable = false`. The upload then negotiates
        // HTTP/2 on TLS, which doesn't hit the multipart-framing
        // bug. Latency goes up ~50 ms (one fewer connection-reuse
        // hint) — worth it for reliability.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        // Note: there's no public iOS API to outright disable HTTP/3
        // on a URLSessionConfiguration; the `assumesHTTP3Capable`
        // property is private. We instead rely on the
        // `executeWithRetry`-style fallback below to catch QUIC-
        // induced `cannotParseResponse` / `networkConnectionLost`
        // and re-try on the connection that gets re-established
        // after the QUIC stack is reset.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // 🔴 ROUND 22 — inline QUIC retry + body-dump on decode fail.
        var lastErr: Error?
        for attempt in 0..<3 {
            do {
                let (responseData, response) = try await session.upload(for: request, fromFile: tempFile)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    #if DEBUG
                    let preview = String(data: responseData.prefix(400), encoding: .utf8) ?? "<binary>"
                    print("❌ [Upload] image upload non-2xx: status=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(preview)")
                    #endif
                    throw AttachmentError.uploadFailed
                }
                do {
                    let result = try JSONDecoder().decode(ChatImageUploadResponse.self, from: responseData)
                    return result.imageUrl
                } catch {
                    #if DEBUG
                    let preview = String(data: responseData.prefix(400), encoding: .utf8) ?? "<binary>"
                    print("❌ [Upload] image upload 200 but decode failed: \(error.localizedDescription) body=\(preview)")
                    #endif
                    throw error
                }
            } catch let urlErr as URLError where Self.retryableURLErrorCodes.contains(urlErr.code) {
                lastErr = urlErr
                #if DEBUG
                print("⚠️ [Upload] image upload attempt \(attempt+1) failed (\(urlErr.code.rawValue)) — retrying")
                #endif
                try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000) * UInt64(attempt + 1))
                continue
            }
        }
        throw lastErr ?? AttachmentError.uploadFailed
    }

    // MARK: - Upload Document (POST /api/uploads/file)
    
    private func uploadDocument(localPath: URL, originalFilename: String) async throws -> String {
        let boundary = UUID().uuidString
        let mimeType = mimeTypeFor(path: originalFilename)
        
        let tempFile = try writeMultipartToFile(
            boundary: boundary, fieldName: "file",
            fileName: originalFilename,
            mimeType: mimeType, fileURL: localPath
        )
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        guard let url = URL(string: "\(baseURL)/api/uploads/file") else {
            throw AttachmentError.uploadFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if #available(iOS 16.0, *) {
            request.assumesHTTP3Capable = false   // round 22 QUIC workaround
        }

        let (responseData, httpResponse) = try await Self.uploadWithRetry(request: request, fromFile: tempFile)

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            #if DEBUG
            print("❌ File upload failed: \(errorBody)")
            #endif
            throw AttachmentError.uploadFailed
        }

        let result = try JSONDecoder().decode(FileUploadResponse.self, from: responseData)
        return result.fileUrl
    }

    // MARK: - Upload Voice (POST /api/uploads/voice)
    
    private func uploadVoice(localPath: URL, originalFilename: String) async throws -> String {
        let boundary = UUID().uuidString
        let mimeType = mimeTypeFor(path: originalFilename)
        
        let tempFile = try writeMultipartToFile(
            boundary: boundary, fieldName: "file",
            fileName: originalFilename,
            mimeType: mimeType, fileURL: localPath
        )
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        guard let url = URL(string: "\(baseURL)/api/uploads/voice") else {
            throw AttachmentError.uploadFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if #available(iOS 16.0, *) {
            request.assumesHTTP3Capable = false   // round 22 QUIC workaround
        }

        let (responseData, httpResponse) = try await Self.uploadWithRetry(request: request, fromFile: tempFile)

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            #if DEBUG
            print("❌ Voice upload failed: \(errorBody)")
            #endif
            throw AttachmentError.uploadFailed
        }

        let result = try JSONDecoder().decode(VoiceUploadResponse.self, from: responseData)
        return result.voiceUrl
    }
    
    // MARK: - Streaming Multipart Helper
    
    /// Writes a multipart form-data body to a temp file, streaming the source file in 512KB chunks.
    /// This prevents loading the entire file into memory, avoiding OOM crashes for large uploads.
    private func writeMultipartToFile(
        boundary: String, fieldName: String, fileName: String,
        mimeType: String, fileURL: URL
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempURL)
        defer { writeHandle.closeFile() }
        
        // Write multipart header
        var header = Data()
        header.appendString("--\(boundary)\r\n")
        header.appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        header.appendString("Content-Type: \(mimeType)\r\n\r\n")
        try writeHandle.write(contentsOf: header)
        
        // Stream source file in 512KB chunks to avoid loading it all into RAM
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { readHandle.closeFile() }
        while try autoreleasepool(invoking: {
            guard let chunk = try readHandle.read(upToCount: 512 * 1024), !chunk.isEmpty else { return false }
            try writeHandle.write(contentsOf: chunk)
            return true
        }) {}
        
        // Write multipart footer
        var footer = Data()
        footer.appendString("\r\n--\(boundary)--\r\n")
        try writeHandle.write(contentsOf: footer)
        return tempURL
    }
    
    // MARK: - Upload Document With Progress (video/file uploads)
    
    private func uploadDocumentWithProgress(localPath: URL, originalFilename: String, clientId: String) async throws -> String {
        let boundary = UUID().uuidString
        let mimeType = mimeTypeFor(path: originalFilename)
        
        let tempFile = try writeMultipartToFile(
            boundary: boundary, fieldName: "file",
            fileName: originalFilename,
            mimeType: mimeType, fileURL: localPath
        )
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        guard let url = URL(string: "\(baseURL)/api/uploads/file") else {
            throw AttachmentError.uploadFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // Use delegate-based upload for progress tracking
        let delegate = UploadProgressDelegate { [weak messageRepo] progress in
            Task {
                try? await messageRepo?.updateDisplayState(
                    clientMessageId: clientId,
                    state: .uploading,
                    progress: progress
                )
            }
        }
        // 🔴 ROUND 22 — same HTTP/3 workaround as
        // uploadImageWithProgress. Multipart uploads over QUIC
        // hit "Message too long" + truncate the response body →
        // client decode fails with "cannot parse response".
        let dconfig = URLSessionConfiguration.default
        dconfig.timeoutIntervalForRequest = 300       // big videos take a while
        dconfig.waitsForConnectivity = true
        // No public API to disable HTTP/3; retry-on-cannot-parse
        // below handles QUIC-induced truncation.
        let session = URLSession(configuration: dconfig, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // 🔴 ROUND 22 — same QUIC retry as uploadImageWithProgress.
        var lastErr: Error?
        var responseData = Data()
        var response: URLResponse?
        for attempt in 0..<3 {
            do {
                let pair = try await session.upload(for: request, fromFile: tempFile)
                responseData = pair.0
                response = pair.1
                lastErr = nil
                break
            } catch let urlErr as URLError where Self.retryableURLErrorCodes.contains(urlErr.code) {
                lastErr = urlErr
                #if DEBUG
                print("⚠️ [Upload] file upload attempt \(attempt+1) failed (\(urlErr.code.rawValue)) — retrying")
                #endif
                try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000) * UInt64(attempt + 1))
                continue
            }
        }
        if let err = lastErr { throw err }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            #if DEBUG
            print("❌ File upload failed: \(errorBody)")
            #endif
            throw AttachmentError.uploadFailed
        }
        
        let result = try JSONDecoder().decode(FileUploadResponse.self, from: responseData)
        return result.fileUrl
    }
    
    // MARK: - MIME Type Helper
    
    private func mimeTypeFor(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt": return "text/plain"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/m4a"
        case "wav": return "audio/wav"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
    // MARK: - Video compression helper
    //
    // (2026-05-15 — round 6) Re-encode a phone-camera clip with
    // `AVAssetExportSession` at the medium preset (≤ 540p H.264 +
    // 64kbps AAC) so the resulting `.mp4` lands well under the
    // 25 MB Cloud Run gateway cap. Returns the compressed file URL
    // on success or nil when the export fails — the caller falls
    // back to the original path so the user still gets the bubble
    // (it'll throw at the premium-limit gate if it's truly oversize).
    fileprivate static func compressVideo(at sourceURL: URL) async -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        // Pick the most aggressive standard preset that still preserves
        // recognisable footage. `.preset640x480` is the sweet spot:
        // SDV-quality stream, ~1.5 MB / 10 s on H.264.
        let preset = AVAssetExportPreset640x480
        guard AVAssetExportSession.allExportPresets().contains(preset) else { return nil }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            return nil
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously {
                cont.resume()
            }
        }
        guard exporter.status == .completed,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    // MARK: - Vault encryption helper
    //
    // 🔴 ROUND 21 — hacker-audit Server F5.
    //
    // Before this round `encryptForVault` always used the SENDER's
    // own X25519 agreement key for the AAD recipient. The receiver
    // didn't have the matching private half, so a "vault-encrypted"
    // upload was decryptable only by us — which made vault mode
    // useless for sending sensitive media to a peer and silently
    // weakened to plaintext for the receiver because they couldn't
    // open the vault wrapper at all.
    //
    // We now resolve the RECIPIENT's agreement pubkey from
    // `PeerKeyDirectory` (round 12's verified-bundle cache, round
    // 16's userId-bound signature gate). If we can't fetch a
    // verified recipient key, we REFUSE to encrypt rather than
    // silently fall back to "encrypt to self" — better to fail the
    // vault send loudly than to ship a file the receiver can never
    // open.
    //
    // The caller (sendImage / sendFile in vault mode) treats a nil
    // return as "vault unavailable" and surfaces the error in the
    // UI instead of silently uploading plaintext.
    fileprivate static func encryptForVault(
        data: Data,
        aad: Data,
        recipientUserId: String?
    ) async -> Data? {
        // 🟥 ROUND 33 (2026-05-17) — opportunistic auto-publish of
        // OUR bundle.  This doesn't help the current send (we need
        // the RECIPIENT's bundle), but it ensures that the FIRST
        // vault attempt also reliably publishes our own key, so a
        // reciprocal send from the other side will succeed even if
        // they upgraded the app and never opened it before we tried
        // to send to them.  Idempotent + throttled inside the helper.
        await ATSAMPrekeyService.autoPublishIfNeeded()
        // 🟥 ROUND 32 (2026-05-17, follow-up) — dual-source pubkey
        // resolution.
        //
        // The original lookup only hit `PeerKeyDirectory` (server-
        // signed bundle cache).  That left the user dead-ended any
        // time the directory cleared its cache OR the bundle fetch
        // failed (offline, rate-limited, TOFU rotation rejected,
        // negative-cache 60 s cooldown), even though the SAME
        // recipient's X25519 key was sitting in
        // `FriendDeviceRepository.getTrustedDevices` from QR pairing
        // — the same source `BLEMeshEngine` uses to opportunistically
        // encrypt every text message.
        //
        // Result: text messages worked, vault sends bounced with
        // "Vault couldn't get the recipient's encryption key" even
        // though we DID have a key, just in a different drawer.
        // The user-reported screenshot is exactly this case.
        //
        // Fix: try both sources, prefer the freshly server-verified
        // one (PKD), fall back to the pairing-time one (FDR).  Both
        // are recipient-static X25519 keys, both produce a vault
        // ciphertext the recipient's identity-priv can open.
        let pkdKey: Data? = await {
            if let recipientUserId, !recipientUserId.isEmpty {
                return await PeerKeyDirectory.shared.ensureAgreementKey(for: recipientUserId)
            }
            return nil
        }()
        let fdrKey: Data? = await {
            if let recipientUserId, !recipientUserId.isEmpty {
                let trusted = await FriendDeviceRepository.shared.getTrustedDevices(forUser: recipientUserId)
                return trusted.compactMap({ $0.agreementPublicKey }).first
            }
            return nil
        }()

        // Try PKD first — if a previous Tap-to-Reset re-fetched a
        // ROTATED key, that's the one we want; the FDR copy could be
        // stale from before the rotation.
        if let pub = pkdKey ?? fdrKey, pub.count == 32 {
            do {
                return try VaultFileCrypto.encrypt(
                    plaintext: data,
                    recipientIdentityPubKey: pub,
                    additionalAuthenticatedData: aad
                )
            } catch {
                #if DEBUG
                print("[Vault] encrypt failed: \(error.localizedDescription)")
                #endif
                return nil
            }
        }

        #if DEBUG
        print("⚠️ [Vault] no recipient pubkey in PeerKeyDirectory OR FriendDeviceRepository — refusing to fall back to sender-key encryption (would be undecryptable by receiver).")
        #endif
        return nil
    }
}

// MARK: - Upload Progress Delegate

/// URLSession delegate that reports upload progress via a callback.
/// Used by `uploadDocumentWithProgress` and `uploadSnapWithProgress`.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    
    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(min(progress, 1.0))
    }
}

// MARK: - Response Types

struct ChatImageUploadResponse: Decodable {
    let imageUrl: String
    let filename: String
    
    enum CodingKeys: String, CodingKey {
        case imageUrl = "image_url"
        case filename
    }
}

struct FileUploadResponse: Decodable {
    var fileUrl: String
    var filename: String
    var uniqueFilename: String
    var size: Int
    var mimeType: String
    
    enum CodingKeys: String, CodingKey {
        case fileUrl = "file_url"
        case filename
        case uniqueFilename = "unique_filename"
        case size
        case mimeType = "mime_type"
    }
    
    /// Memberwise init for programmatic construction (e.g. signed URL uploads)
    init(fileUrl: String, filename: String = "", uniqueFilename: String = "", size: Int = 0, mimeType: String = "video/mp4") {
        self.fileUrl = fileUrl
        self.filename = filename
        self.uniqueFilename = uniqueFilename
        self.size = size
        self.mimeType = mimeType
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileUrl = try container.decode(String.self, forKey: .fileUrl)
        filename = try container.decode(String.self, forKey: .filename)
        uniqueFilename = try container.decode(String.self, forKey: .uniqueFilename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        
        // Server may return size as int or string — handle both
        if let intSize = try? container.decode(Int.self, forKey: .size) {
            size = intSize
        } else if let strSize = try? container.decode(String.self, forKey: .size),
                  let parsed = Int(strSize) {
            size = parsed
        } else {
            size = 0
        }
    }
}

struct VoiceUploadResponse: Decodable {
    let voiceUrl: String
    let filename: String
    let uniqueFilename: String
    let size: Int
    let mimeType: String
    
    enum CodingKeys: String, CodingKey {
        case voiceUrl = "voice_url"
        case filename
        case uniqueFilename = "unique_filename"
        case size
        case mimeType = "mime_type"
    }
}

struct SnapSendResponse: Decodable {
    let snapId: String
    let senderId: String
    let recipientId: String
    let mediaType: String
    let ttlSeconds: Int
    let status: String
    let createdAt: String
    let messageType: String
}

// MARK: - Errors

enum AttachmentError: Error, LocalizedError {
    case compressionFailed
    case uploadFailed
    case downloadFailed
    case fileNotFound
    case internetRequired  // Media can only be sent with internet connection
    /// 🟥 ROUND 32 (2026-05-17) — explicit vault-key-missing error.
    ///
    /// Previously every vault encryption failure surfaced as the
    /// generic "Failed to upload file" string.  That's misleading
    /// when the actual cause is "we can't reach the recipient's
    /// X25519 prekey bundle right now" (offline server, never-
    /// published bundle, TOFU rotation rejected).  The new error
    /// tells the user exactly what to do — turn vault off OR get
    /// the recipient to publish/republish their key.
    case vaultKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .compressionFailed: return "Failed to compress media"
        case .uploadFailed: return "Failed to upload file"
        case .downloadFailed: return "Failed to download file"
        case .fileNotFound: return "File not found"
        case .internetRequired: return "Media messages require internet connection"
        case .vaultKeyUnavailable: return "Vault couldn't get the recipient's encryption key. Turn Vault off, or ask them to open RAVEN once so their key is published."
        }
    }
}

// MARK: - UIImage Extension

extension UIImage {
    func thumbnail(maxSize: CGFloat) -> UIImage? {
        let ratio = min(maxSize / size.width, maxSize / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return result
    }
    
    /// Downscale to fit within maxDimension, preserving aspect ratio.
    /// Returns self if already within bounds (no unnecessary copy).
    /// Safe to call from any thread.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }
        
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
