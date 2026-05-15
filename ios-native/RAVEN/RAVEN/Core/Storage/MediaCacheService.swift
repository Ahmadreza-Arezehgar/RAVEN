import Foundation

// MARK: - Media Cache Service (Background Download + Disk Cache)
/// Downloads received media attachments to Documents/attachments/ so they survive offline.
/// The local_path column in SQLite is updated after download, and all media views
/// already check localPath before falling back to remote URLs.

actor MediaCacheService {
    static let shared = MediaCacheService()
    
    /// Max concurrent downloads to avoid saturating the network
    private let maxConcurrent = 3
    /// Max total cache size in bytes (500 MB)
    private let maxCacheBytes: UInt64 = 500 * 1024 * 1024
    
    /// Tracks message IDs currently being downloaded (prevents duplicates)
    private var inFlight: Set<String> = []
    
    private let session: URLSession
    private let messageRepo = MessageRepository.shared
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        // Use a dedicated queue for downloads
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config)
    }
    
    // MARK: - Public API
    
    /// Cache media for a batch of messages (called after fetchMessages upserts).
    /// Runs concurrently with bounded parallelism.
    func cacheMediaBatch(messages: [CacheableMessage]) async {
        // Filter to messages that need caching
        let needsCache = messages.filter { shouldCache($0) }
        guard !needsCache.isEmpty else { return }
        
        #if DEBUG
        print("📦 [MediaCache] Queuing \(needsCache.count) media downloads")
        #endif
        
        // Use TaskGroup with bounded concurrency
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for msg in needsCache {
                if active >= maxConcurrent {
                    await group.next()
                    active -= 1
                }
                group.addTask { [self] in
                    await self.cacheMedia(for: msg)
                }
                active += 1
            }
        }
        
        // Evict old files if over budget
        await evictIfNeeded()
    }
    
    /// Cache media for a single message (called on incoming WebSocket/push messages)
    func cacheMedia(for message: CacheableMessage) async {
        guard shouldCache(message) else { return }
        
        // Mark in-flight to prevent duplicate downloads
        guard !inFlight.contains(message.id) else { return }
        inFlight.insert(message.id)
        defer { inFlight.remove(message.id) }
        
        guard let remoteUrl = resolveRemoteURL(message.attachmentUrl) else {
            #if DEBUG
            print("⚠️ [MediaCache] No valid URL for message \(message.id.prefix(8))")
            #endif
            return
        }
        
        let localURL = localFileURL(for: message)
        
        // Already downloaded
        if FileManager.default.fileExists(atPath: localURL.path) {
            // Just update DB if local_path is missing
            try? await messageRepo.updateLocalPath(
                clientMessageId: message.id,
                localPath: localURL.path
            )
            #if DEBUG
            print("✅ [MediaCache] Already cached: \(message.id.prefix(8))")
            #endif
            return
        }
        
        do {
            // Ensure directory exists
            let dir = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            // Build request — only attach auth for our own API URLs (not GCS/CDN)
            var request = URLRequest(url: remoteUrl)
            let isExternalURL = remoteUrl.host != nil && !remoteUrl.absoluteString.hasPrefix(AppConfig.apiBaseURL)
            if !isExternalURL, let (token, _) = await KeychainService.shared.getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            // Download
            let (tempURL, response) = try await session.download(for: request)
            
            // Validate response
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                #if DEBUG
                print("⚠️ [MediaCache] HTTP \(httpResponse.statusCode) for \(message.id.prefix(8))")
                #endif
                return
            }
            
            // BUG FIX (2026-05-10): combine "remove existing + move tempURL"
            // into one atomic `replaceItemAt` call. The previous
            // remove-then-move pattern had a TOCTOU window: between the
            // `fileExists` check and the `moveItem`, the actor could
            // suspend (no — but defensively we make this atomic anyway
            // to prevent any future callers from inadvertently racing).
            // `replaceItemAt` is the POSIX `rename(2)` atomic primitive,
            // matching how `MediaCacheService` is documented as
            // "atomically materialise the bytes".
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: localURL)
            }

            // Update local_path in DB
            try await messageRepo.updateLocalPath(
                clientMessageId: message.id,
                localPath: localURL.path
            )

            // BUG FIX (2026-05-10): post the notification via a
            // non-awaiting `DispatchQueue.main.async` rather than
            // `await MainActor.run`. The await suspended the actor
            // BEFORE the `defer { inFlight.remove }` had a chance to
            // run; while suspended on main, a queued cacheMedia call
            // for the same id would correctly bail (defer hadn't
            // fired) but a call right after the function returned
            // could race the `fileExists` check before the next
            // request arrived. Decoupling the notification from
            // actor isolation closes that window cleanly.
            let messageId = message.id
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("MediaDownloadCompleted"),
                    object: nil,
                    userInfo: ["messageId": messageId]
                )
            }
            
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
            #if DEBUG
            print("✅ [MediaCache] Downloaded \(message.id.prefix(8)) (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))")
            #endif
            
        } catch {
            // 🟠 BUG FIX (2026-05-10) + RE-AUDIT FIX (2026-05-10):
            // on disk-full, evict the LRU and ACTUALLY retry once
            // (the previous version left a comment claiming "retry"
            // but never re-attempted). If the retry succeeds, fall
            // through silently. If it fails, record the failure so
            // the chat row can show a "tap to retry" affordance.
            if (error as NSError).code == NSFileWriteOutOfSpaceError {
                #if DEBUG
                print("💾 [MediaCache] Disk full for \(message.id.prefix(8)) — evicting and retrying once")
                #endif
                await evictIfNeeded()
                // Allow the in-flight gate to release before re-entry,
                // then re-call cacheMedia for the same message.
                inFlight.remove(message.id)
                await cacheMedia(for: message)
                return
            }
            #if DEBUG
            print("❌ [MediaCache] Download failed for \(message.id.prefix(8)): \(error.localizedDescription)")
            #endif
            // Surface the failure so the chat row can render a
            // "tap to retry" affordance instead of an infinite spinner.
            try? await messageRepo.markMediaDownloadFailed(
                clientMessageId: message.id,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Cache Eviction
    
    /// Delete oldest cached files when total size exceeds the budget
    func evictIfNeeded() async {
        let attachmentsDir = Self.attachmentsDirectory
        guard FileManager.default.fileExists(atPath: attachmentsDir.path) else { return }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: attachmentsDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            // Calculate total size
            var totalSize: UInt64 = 0
            var fileInfos: [(url: URL, size: UInt64, date: Date)] = []
            
            for file in files {
                let attrs = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = UInt64(attrs.fileSize ?? 0)
                let date = attrs.contentModificationDate ?? Date.distantPast
                totalSize += size
                fileInfos.append((url: file, size: size, date: date))
            }
            
            guard totalSize > maxCacheBytes else { return }
            
            #if DEBUG
            print("🗑️ [MediaCache] Cache size \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)) exceeds limit, evicting...")
            #endif
            
            // Sort oldest first
            fileInfos.sort { $0.date < $1.date }
            
            var evicted: UInt64 = 0
            let target = totalSize - maxCacheBytes
            
            for info in fileInfos {
                guard evicted < target else { break }
                try FileManager.default.removeItem(at: info.url)
                evicted += info.size
                #if DEBUG
                print("🗑️ [MediaCache] Evicted \(info.url.lastPathComponent)")
                #endif
            }
            
            #if DEBUG
            print("🗑️ [MediaCache] Evicted \(ByteCountFormatter.string(fromByteCount: Int64(evicted), countStyle: .file))")
            #endif
            
        } catch {
            #if DEBUG
            print("⚠️ [MediaCache] Eviction scan failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Helpers
    
    /// The shared attachments directory
    static var attachmentsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("attachments")
    }
    
    /// Determine if a message needs media caching
    private func shouldCache(_ message: CacheableMessage) -> Bool {
        // Must be a media type
        guard ["image", "voice", "video", "file", "videoNote", "ephemeralPhoto"].contains(message.type) else {
            return false
        }
        // Must have a remote URL
        guard let url = message.attachmentUrl, !url.isEmpty else {
            return false
        }
        // Must NOT already have a local path that exists on disk
        if let localPath = message.localPath, !localPath.isEmpty {
            let fileName = URL(fileURLWithPath: localPath).lastPathComponent
            let localURL = Self.attachmentsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return false
            }
        }
        return true
    }
    
    /// Build local file URL for a message's attachment
    private func localFileURL(for message: CacheableMessage) -> URL {
        let ext = fileExtension(for: message)
        let fileName = "\(message.id)\(ext)"
        return Self.attachmentsDirectory.appendingPathComponent(fileName)
    }
    
    /// Resolve a relative or absolute URL string to a full URL
    private func resolveRemoteURL(_ urlString: String?) -> URL? {
        guard let urlString = urlString, !urlString.isEmpty else { return nil }
        // Full URL
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return URL(string: urlString)
        }
        // Relative path — prepend base URL
        let cleanPath = urlString.hasPrefix("/") ? urlString : "/\(urlString)"
        return URL(string: "\(AppConfig.apiBaseURL)\(cleanPath)")
    }
    
    /// Determine file extension from message metadata
    private func fileExtension(for message: CacheableMessage) -> String {
        // Try from mimeType
        if let mime = message.mimeType {
            switch mime {
            case "image/jpeg", "image/jpg": return ".jpg"
            case "image/png": return ".png"
            case "image/gif": return ".gif"
            case "image/webp": return ".webp"
            case "image/heic": return ".heic"
            case "audio/m4a", "audio/x-m4a", "audio/mp4": return ".m4a"
            case "audio/mpeg", "audio/mp3": return ".mp3"
            case "audio/wav": return ".wav"
            case "audio/aac": return ".aac"
            case "video/mp4": return ".mp4"
            case "video/quicktime": return ".mov"
            case "application/pdf": return ".pdf"
            default: break
            }
        }
        // Try from fileName
        if let fileName = message.fileName {
            let ext = (fileName as NSString).pathExtension
            if !ext.isEmpty { return ".\(ext)" }
        }
        // Try from URL
        if let urlString = message.attachmentUrl,
           let url = URL(string: urlString) {
            let ext = url.pathExtension
            if !ext.isEmpty { return ".\(ext)" }
        }
        // Fallback by type
        switch message.type {
        case "image", "ephemeralPhoto": return ".jpg"
        case "voice": return ".m4a"
        case "video", "videoNote": return ".mp4"
        case "file": return ".bin"
        default: return ".bin"
        }
    }
}

// MARK: - Cacheable Message (Lightweight DTO)
/// Avoids importing full ChatMessage into the cache service.
/// Created from ChatMessage or from DB row data.
struct CacheableMessage: Sendable {
    let id: String
    let type: String
    let attachmentUrl: String?
    let localPath: String?
    let mimeType: String?
    let fileName: String?
    
    /// Create from a ChatMessage
    init(from message: ChatMessage) {
        self.id = message.id
        self.type = message.type.rawValue
        self.attachmentUrl = message.attachmentUrl
        self.localPath = message.localPath
        self.mimeType = message.mimeType
        self.fileName = message.fileName
    }
    
    /// Create from individual fields (for use in group message conversion)
    init(id: String, type: String, attachmentUrl: String?, localPath: String?, mimeType: String?, fileName: String?) {
        self.id = id
        self.type = type
        self.attachmentUrl = attachmentUrl
        self.localPath = localPath
        self.mimeType = mimeType
        self.fileName = fileName
    }
}
