import SwiftUI
@preconcurrency import AVFoundation

// `ImageUploadResponse`, `VideoUploadResult`, and `CreatePostBody`
// are defined in `CreatePostView.swift` (Phase 4 promoted them to
// internal so the upload manager can share the same shapes). No
// local re-declarations needed.

// MARK: - Post Upload Job
/// All the data needed to upload a post in the background.
/// Captured from CreatePostView at submit time so the view can dismiss immediately.
struct PostUploadJob: Identifiable {
    let id = UUID()
    let content: String
    let visibility: String
    let media: [PostMediaItem]
    let hasVoiceRecording: Bool
    let voiceFileURL: URL?
    let voiceDuration: TimeInterval
    let voiceWaveform: [Float]
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let clientPostId: String
    let clientRequestId: String
    let showOnRavenShot: Bool
    /// Structured @mention entities from the composer's MentionPicker.
    /// Sent as `entities` on the create-post API. Server uses these to
    /// resolve mentions correctly (carries the user_id, so it works for
    /// usernames containing dots/hyphens that the regex misses).
    var mentionEntities: [MentionEntity]? = nil
}

// MARK: - Upload State
enum PostUploadState: Equatable {
    case idle
    case uploading(progress: String)  // e.g. "Uploading media 1/3..."
    case success
    case failed(message: String)
    
    static func == (lhs: PostUploadState, rhs: PostUploadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.uploading(let a), .uploading(let b)): return a == b
        case (.success, .success): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Post Upload Manager
/// Singleton that manages background post uploads.
/// CreatePostView hands off a job and dismisses immediately.
/// This manager shows toast banners and updates FeedStore.
@MainActor @Observable
final class PostUploadManager {
    static let shared = PostUploadManager()
    
    var state: PostUploadState = .idle
    var showToast = false
    
    /// The most recent failed job (for retry)
    private var lastFailedJob: PostUploadJob?
    private var autoDismissTask: Task<Void, Never>?
    
    private let networkService = NetworkService.shared
    
    private init() {}
    
    // MARK: - Submit (called from CreatePostView)
    
    func submit(job: PostUploadJob) {
        state = .uploading(progress: "Posting...")
        showToast = true
        lastFailedJob = nil
        
        // Insert placeholder post into feed immediately (optimistic)
        let placeholder = Post(
            id: job.clientPostId,
            authorId: job.authorId,
            authorUsername: job.authorUsername,
            authorAvatar: job.authorAvatar,
            content: job.content,
            imageUrl: nil,
            timestamp: Date(),
            editedAt: nil,
            likes: 0,
            comments: 0,
            reposts: 0,
            viewCount: 0,
            isLocal: true,
            isLiked: false,
            isReposted: false,
            visibility: job.visibility,
            distanceM: nil,
            postType: job.hasVoiceRecording ? "voice" : (job.media.isEmpty ? "text" : (job.media.contains(where: { $0.isVideo }) ? "video" : "image")),
            roomId: nil,
            source: job.visibility == "friends" ? .forYou : .nearby,
            showOnRavenShot: job.showOnRavenShot
        )
        
        FeedStore.shared.insertPostOptimistically(placeholder)
        
        // Start background upload
        Task {
            await performUpload(job: job)
        }
    }
    
    // MARK: - Retry
    
    func retry() {
        guard let job = lastFailedJob else { return }
        lastFailedJob = nil
        submit(job: job)
    }
    
    // MARK: - Dismiss toast
    
    func dismissToast() {
        withAnimation(.easeOut(duration: 0.25)) {
            showToast = false
        }
        // Reset state after animation
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if case .success = state { state = .idle }
            if case .failed = state { /* keep for retry */ }
        }
    }
    
    // MARK: - Background Upload
    
    private func performUpload(job: PostUploadJob) async {
        // 🟠 BUG FIX (2026-05-10): wrap the upload in a UIKit
        // beginBackgroundTask so iOS grants the additional ~30 s
        // window if the user briefly switches apps mid-upload. The
        // class is named "background uploader" but the previous
        // implementation used `URLSessionConfiguration.default`
        // (no actual background session) and did NOT mark the work
        // as a background task — backgrounding mid-upload killed
        // the URLSession task and the post UI stuck on
        // "Uploading…" forever. Until we wire a real
        // `URLSessionConfiguration.background(withIdentifier:)`
        // session (delegate-based; significant refactor), this
        // wrapper covers the common app-switch case.
        let bgTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "RAVEN-PostUpload") {
                // Expiration handler — iOS is about to suspend us.
                // Mark the in-flight job as failed so the user gets
                // a retry button instead of a forever-spinner.
                Task { @MainActor in
                    PostUploadManager.shared.state = .failed(message: "Upload paused — backgrounded too long")
                }
            }
        }
        defer {
            Task { @MainActor in
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
        }
        do {
            // Step 1: Upload media
            var uploadedMediaPayloads: [PostMediaPayload] = []
            if !job.media.isEmpty {
                state = .uploading(progress: "Uploading media...")
                
                #if DEBUG
                print("📤 [BG Upload] Starting media upload: \(job.media.count) items")
                for (i, item) in job.media.enumerated() {
                    switch item.media {
                    case .image: print("   [\(i)] type=image")
                    case .video(let url, _): print("   [\(i)] type=video file=\(url.lastPathComponent)")
                    }
                }
                #endif
                
                uploadedMediaPayloads = try await withThrowingTaskGroup(of: (Int, PostMediaPayload).self) { group in
                    for (index, item) in job.media.enumerated() {
                        group.addTask {
                            switch item.media {
                            case .image(let image):
                                let url = try await Self.uploadImage(image)
                                return (index, PostMediaPayload(url: url, mediaType: "image", thumbnailUrl: nil))
                                
                            case .video(let videoURL, let thumbnail):
                                let result = try await Self.uploadVideo(videoURL: videoURL, thumbnail: thumbnail)
                                return (index, PostMediaPayload(url: result.videoUrl, mediaType: "video", thumbnailUrl: result.thumbnailUrl))
                            }
                        }
                    }
                    var results = [(Int, PostMediaPayload)]()
                    var completed = 0
                    for try await result in group {
                        results.append(result)
                        completed += 1
                        // ⚡ UX: Show real progress (e.g. "Uploading media 2/3...")
                        await MainActor.run {
                            PostUploadManager.shared.state = .uploading(progress: "Uploading media \(completed)/\(job.media.count)...")
                        }
                    }
                    return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
                }
                
                #if DEBUG
                print("📤 [BG Upload] \(uploadedMediaPayloads.count) media items uploaded")
                #endif
            }
            
            // Step 2: Upload voice if present
            var uploadedVoiceUrl: String?
            var uploadedVoiceDuration: Int?
            var uploadedWaveform: [Float]?
            
            if job.hasVoiceRecording, let fileURL = job.voiceFileURL {
                state = .uploading(progress: "Uploading voice...")
                let result = try await VoiceUploadService.upload(fileURL: fileURL)
                uploadedVoiceUrl = result.voiceUrl
                uploadedVoiceDuration = Int(job.voiceDuration)
                uploadedWaveform = job.voiceWaveform
                
                #if DEBUG
                print("🎤 [BG Upload] Voice uploaded: \(result.voiceUrl)")
                #endif
            }
            
            // Step 3: Create post on server
            state = .uploading(progress: "Publishing...")
            
            let firstImageUrl = uploadedMediaPayloads.first(where: { $0.mediaType == "image" })?.url
                ?? uploadedMediaPayloads.first?.thumbnailUrl
            
            let deviceLocation = FeedStore.shared.currentLocation
            let body = CreatePostBody(
                content: job.content,
                visibility: job.visibility,
                imageUrl: firstImageUrl,
                imageUrls: uploadedMediaPayloads.isEmpty ? nil : uploadedMediaPayloads.filter({ $0.mediaType == "image" }).map(\.url),
                mediaItems: uploadedMediaPayloads.isEmpty ? nil : uploadedMediaPayloads,
                latitude: deviceLocation?.coordinate.latitude,
                longitude: deviceLocation?.coordinate.longitude,
                voiceUrl: uploadedVoiceUrl,
                voiceDuration: uploadedVoiceDuration,
                waveform: uploadedWaveform,
                clientRequestId: job.clientRequestId,
                showOnRavenShot: job.showOnRavenShot ? true : nil,
                entities: job.mentionEntities
            )
            
            let newPost: Post = try await networkService.post(
                path: "/api/posts/create",
                body: body
            )
            
            #if DEBUG
            print("✅ [BG Upload] Post created: id=\(newPost.id)")
            #endif
            
            // Step 4: Replace placeholder with real post
            await FeedStore.shared.updatePost(clientPostId: job.clientPostId, with: newPost)
            
            // Also cache to DB
            let feedType: FeedType = (job.visibility == "friends") ? .friends : .local
            Task.detached {
                try? await PostRepository.shared.upsert(newPost, feedType: feedType)
            }
            
            // Step 5: Show success
            Haptics.success()
            state = .success
            
            // Auto-dismiss toast after 2 seconds
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                dismissToast()
            }
            
        } catch {
            #if DEBUG
            print("❌ [BG Upload] FAILED at state: \(state)")
            print("❌ [BG Upload] Error: \(error)")
            print("❌ [BG Upload] Error type: \(type(of: error))")
            let nsError = error as NSError
            print("❌ [BG Upload] Domain: \(nsError.domain), Code: \(nsError.code)")
            print("❌ [BG Upload] UserInfo: \(nsError.userInfo)")
            #endif
            
            Haptics.error()
            
            // Remove the placeholder from feed
            await FeedStore.shared.markPostFailed(clientPostId: job.clientPostId)
            
            // Save for retry
            lastFailedJob = job
            state = .failed(message: error.localizedDescription)
            
            // Keep toast visible for retry (auto-dismiss after 8 seconds)
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                dismissToast()
            }
        }
    }
    
    // MARK: - Upload Helpers (static, safe for background Task)
    
    private static func uploadImage(_ image: UIImage) async throws -> String {
        let data: Data = try await Task.detached(priority: .userInitiated) {
            var img = image
            let maxDimension: CGFloat = PremiumLimits.maxImageDimension
            if img.size.width > maxDimension || img.size.height > maxDimension {
                let scale = min(maxDimension / img.size.width, maxDimension / img.size.height)
                let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                img = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
            }
            let quality = PremiumLimits.imageCompressionQuality
            guard let d = img.jpegData(compressionQuality: quality) else {
                throw NSError(domain: "PostUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
            }
            return d
        }.value
        
        let result: ImageUploadResponse = try await NetworkService.shared.uploadMultipart(
            path: "/api/uploads/image",
            fileData: data,
            fileName: "post_image.jpg",
            mimeType: "image/jpeg"
        )
        return result.imageUrl
    }
    
    private static func uploadVideo(videoURL: URL, thumbnail: UIImage) async throws -> VideoUploadResult {
        // 1. Compress video — 1080p HEVC for free, 4K HEVC for RAVEN+
        let compressedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed_\(UUID().uuidString).mp4")
        
        #if DEBUG
        print("🎬 [uploadVideo] Starting compression: \(videoURL.lastPathComponent)")
        #endif
        
        // HEVC (H.265): ~40% smaller than H.264 at same visual quality.
        // All iPhones since iPhone 7 have hardware HEVC encoder.
        let preset = PremiumLimits.isPremium ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHEVC1920x1080
        let asset = AVURLAsset(url: videoURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "PostUpload", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create video export session"])
        }
        
        exportSession.outputURL = compressedURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // ⚡ Cap output file size — AVFoundation auto-reduces bitrate to fit.
        if !PremiumLimits.isPremium {
            exportSession.fileLengthLimit = Int64(95 * 1024 * 1024)
        }
        
        // ⚡ PERF: Prepare thumbnail data on a background thread WHILE video compresses
        let thumbDataTask = Task.detached(priority: .userInitiated) { () -> Data in
            return thumbnail.jpegData(compressionQuality: 0.5) ?? Data()
        }
        
        #if DEBUG
        let duration = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(duration)
        print("🎬 [uploadVideo] Source duration: \(String(format: "%.1f", durationSec))s, preset: \(preset)")
        #endif
        
        // AVAssetExportSession is non-Sendable in iOS 18 SDK headers, so the
        // @Sendable completion closure can't capture it directly. Wrap it
        // in an `@unchecked Sendable` box — exportAsynchronously fires the
        // callback once on a private serial queue, so reading status/error
        // through the box is safe.
        let sessionBox = UncheckedSendableBox(exportSession)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionBox.value.exportAsynchronously {
                switch sessionBox.value.status {
                case .completed: continuation.resume()
                case .failed:
                    let err = sessionBox.value.error
                    #if DEBUG
                    print("❌ [uploadVideo] Export failed: \(err?.localizedDescription ?? "unknown")")
                    #endif
                    continuation.resume(throwing: err ?? NSError(domain: "PostUpload", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video compression failed"]))
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: NSError(domain: "PostUpload", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video compression failed"]))
                }
            }
        }
        
        defer { try? FileManager.default.removeItem(at: compressedURL) }
        
        // 2. Check file size
        let attrs = try FileManager.default.attributesOfItem(atPath: compressedURL.path)
        let fileSize = attrs[.size] as? Int ?? 0
        let maxBytes = PremiumLimits.maxFileUploadBytes
        
        #if DEBUG
        print("🎬 [uploadVideo] Compressed: \(fileSize) bytes (\(fileSize / (1024 * 1024)) MB), max: \(maxBytes / (1024 * 1024)) MB")
        #endif
        
        if fileSize > maxBytes {
            let maxMB = maxBytes / (1024 * 1024)
            throw NSError(domain: "PostUpload", code: 4, userInfo: [NSLocalizedDescriptionKey: "Video too large (\(fileSize / (1024 * 1024))MB, max \(maxMB)MB)"])
        }
        
        // ⚡ PERF: Upload video + thumbnail IN PARALLEL (was sequential before)
        let thumbData = await thumbDataTask.value
        
        async let videoUpload = uploadVideoStreaming(fileURL: compressedURL)
        async let thumbUpload: ImageUploadResponse = NetworkService.shared.uploadMultipart(
            path: "/api/uploads/image",
            fileData: thumbData,
            fileName: "post_video_thumb.jpg",
            mimeType: "image/jpeg"
        )
        
        let (videoResult, thumbResult) = try await (videoUpload, thumbUpload)
        
        #if DEBUG
        print("✅ [uploadVideo] Video + thumbnail uploaded in parallel!")
        print("   Video: \(videoResult.fileUrl.prefix(60))...")
        print("   Thumb: \(thumbResult.imageUrl.prefix(60))...")
        #endif
        
        // Clean up source
        try? FileManager.default.removeItem(at: videoURL)
        
        return VideoUploadResult(videoUrl: videoResult.fileUrl, thumbnailUrl: thumbResult.imageUrl)
    }
    
    /// Uploads video directly to GCS using a pre-signed URL — bypasses Cloud Run's 32MB body limit.
    ///
    /// Flow:
    /// 1. Ask server for a signed GCS PUT URL via POST /api/uploads/video/sign
    /// 2. PUT video bytes directly to GCS (no size limit from Cloud Run proxy)
    /// 3. Return the final public/CDN URL
    ///
    /// Fallback: If signed URL is unavailable (dev mode / GCS down), falls back to multipart upload.
    private static func uploadVideoStreaming(fileURL: URL) async throws -> FileUploadResponse {
        // Step 1: Try signed URL approach (production / GCS available)
        do {
            let signedResult = try await getSignedUploadURL(fileExt: ".mp4", contentType: "video/mp4")
            
            #if DEBUG
            print("🔐 [uploadVideoStreaming] Got signed URL, uploading directly to GCS...")
            #endif
            
            // Step 2: PUT the video file directly to GCS
            guard let uploadURL = URL(string: signedResult.uploadUrl) else {
                throw NSError(domain: "PostUpload", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid signed URL"])
            }
            
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 3600
            
            // Dedicated session for large uploads
            let uploadSession: URLSession = {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 3600
                config.timeoutIntervalForResource = 7200
                config.allowsCellularAccess = true
                config.allowsExpensiveNetworkAccess = true
                config.allowsConstrainedNetworkAccess = true
                config.waitsForConnectivity = true
                return URLSession(configuration: config)
            }()
            
            // Upload the raw video file directly to GCS (no multipart wrapping needed)
            let (responseData, response) = try await uploadSession.upload(for: request, fromFile: fileURL)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown"
                #if DEBUG
                print("❌ [uploadVideoStreaming] GCS upload failed HTTP \(statusCode): \(errorBody.prefix(200))")
                #endif
                throw NSError(domain: "PostUpload", code: 6, userInfo: [NSLocalizedDescriptionKey: "Video upload to storage failed (HTTP \(statusCode))"])
            }
            
            #if DEBUG
            print("✅ [uploadVideoStreaming] GCS upload OK → \(signedResult.fileUrl.prefix(60))...")
            #endif
            
            // Return a FileUploadResponse-compatible result. The
            // canonical `FileUploadResponse` (in AttachmentService)
            // is `Decodable`-only with extra required fields
            // (filename, size, mimeType) that aren't available from
            // a signed-URL upload, so we mint a wrapper with safe
            // defaults that exposes the same `fileUrl` accessor.
            return FileUploadResponse(
                fileUrl: signedResult.fileUrl,
                filename: signedResult.gcsPath,
                uniqueFilename: signedResult.gcsPath,
                size: 0,
                mimeType: "video/mp4"
            )
            
        } catch {
            // 🟥 ROUND 48 (2026-05-17) — broaden the fallback gate.
            //
            // Bug: the previous `where signError.code == 503` filter
            // only caught GCS-unavailable.  But the more common
            // failure today is HTTP 404 from `/api/uploads/video/sign`
            // itself (the endpoint never shipped server-side).  That
            // produced PostUpload code=5, which fell THROUGH the
            // catch and propagated out of uploadVideoStreaming,
            // failing EVERY video upload with a cryptic
            // "Signed URL request failed" error.  iOS users couldn't
            // post videos at all — the user-reported "boice ya video
            // upload konm" regression.
            //
            // Fix: any error from the signed-URL path falls back to
            // multipart through Cloud Run.  We lose the >32MB upload
            // capability until the server ships `/api/uploads/video/sign`,
            // but small videos (the 99% case) work again.
            #if DEBUG
            print("⚠️ [uploadVideoStreaming] Signed URL path failed (\(error.localizedDescription)) — falling back to multipart upload through /api/uploads/file")
            #endif
            return try await uploadVideoMultipart(fileURL: fileURL)
        }
    }
    
    /// Request a GCS signed upload URL from the server.
    private static func getSignedUploadURL(fileExt: String, contentType: String) async throws -> SignedUploadResult {
        guard let url = URL(string: "\(AppConfig.apiBaseURL)/api/uploads/video/sign") else {
            throw NSError(domain: "PostUpload", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body = ["file_ext": fileExt, "content_type": contentType]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "PostUpload", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if httpResponse.statusCode == 503 {
            // GCS unavailable — signal fallback
            throw NSError(domain: "PostUpload", code: 503, userInfo: [NSLocalizedDescriptionKey: "Cloud storage unavailable"])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "PostUpload", code: 5, userInfo: [NSLocalizedDescriptionKey: "Signed URL request failed: \(errorBody)"])
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SignedUploadResult.self, from: data)
    }
    
    /// Fallback: multipart upload through Cloud Run (for dev mode / small files under 32MB).
    private static func uploadVideoMultipart(fileURL: URL) async throws -> FileUploadResponse {
        let boundary = UUID().uuidString
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempURL)
        defer {
            writeHandle.closeFile()
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        // Write multipart header
        var header = Data()
        header.append("--\(boundary)\r\n".data(using: .utf8)!)
        header.append("Content-Disposition: form-data; name=\"file\"; filename=\"post_video.mp4\"\r\n".data(using: .utf8)!)
        header.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        try writeHandle.write(contentsOf: header)
        
        // Stream source file in 512KB chunks
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { readHandle.closeFile() }
        while try autoreleasepool(invoking: {
            guard let chunk = try readHandle.read(upToCount: 512 * 1024), !chunk.isEmpty else { return false }
            try writeHandle.write(contentsOf: chunk)
            return true
        }) {}
        
        // Write multipart footer
        var footer = Data()
        footer.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try writeHandle.write(contentsOf: footer)
        
        // Build request
        guard let url = URL(string: "\(AppConfig.apiBaseURL)/api/uploads/file") else {
            throw NSError(domain: "PostUpload", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let uploadSession: URLSession = {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3600
            config.allowsCellularAccess = true
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            config.waitsForConnectivity = true
            return URLSession(configuration: config)
        }()
        
        let (responseData, response) = try await uploadSession.upload(for: request, fromFile: tempURL)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            #if DEBUG
            print("❌ [uploadVideoMultipart] Server error HTTP \(statusCode): \(errorBody)")
            #endif
            // 🔴 ROUND 31 (2026-05-18) — clean user-facing message
            // for the 413 fallback case. Cloud Run caps request bodies
            // at 32 MB, so the multipart fallback dies for any video
            // larger than that. Pre-R31 the user got the raw HTML
            // body ("<title>413 Request Entity Too Large</title>")
            // bubbled up as the alert text — confusing and useless.
            // Surface a clear "too large for the fallback path; the
            // signed-URL path will handle this once the server's IAM
            // sign permission is in place" message instead.
            let userMessage: String = {
                switch statusCode {
                case 413:
                    return "Video too large for direct upload (over 32 MB). " +
                           "Update RAVEN — the latest build uses a streaming uploader that handles larger files."
                case 401, 403:
                    return "You're signed out. Sign back in and try again."
                case 500...599:
                    return "Server is having trouble right now. Try again in a minute."
                default:
                    return "Video upload failed (HTTP \(statusCode))."
                }
            }()
            throw NSError(
                domain: "PostUpload",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: userMessage,
                    // Keep the raw body around for debug surfaces (the
                    // shake-to-bug-report dump and the in-app log
                    // viewer) without exposing it in the alert.
                    "RawResponseBody": errorBody,
                    "HTTPStatusCode": statusCode,
                ]
            )
        }

        let decoder = JSONDecoder()
        return try decoder.decode(FileUploadResponse.self, from: responseData)
    }
}

// MARK: - Signed Upload Response Model
/// Server response from POST /api/uploads/video/sign
struct SignedUploadResult: Decodable {
    let uploadUrl: String
    let fileUrl: String
    let gcsPath: String
}

// MARK: - Upload Toast View (Liquid Glass Capsule)
/// Floating toast in Apple Liquid Glass style — capsule with ultraThinMaterial backdrop.
struct PostUploadToast: View {
    let state: PostUploadState
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
    
    var body: some View {
        HStack(spacing: 10) {
            // Status icon — animated
            ZStack {
                Circle()
                    .fill(iconAccent.opacity(0.15))
                    .frame(width: 28, height: 28)
                
                Group {
                    switch state {
                    case .idle:
                        EmptyView()
                    case .uploading:
                        ProgressView()
                            .tint(iconAccent)
                            .scaleEffect(0.7)
                    case .success:
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconAccent)
                    case .failed:
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(iconAccent)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
            
            // Status text
            Group {
                switch state {
                case .idle:
                    EmptyView()
                case .uploading(let progress):
                    Text(progress)
                        .font(.system(size: 14, weight: .medium))
                case .success:
                    Text("Posted!")
                        .font(.system(size: 14, weight: .semibold))
                case .failed:
                    Text("Failed to post")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundStyle(.primary)
            .transition(.opacity)
            
            // Action button (only for failed state)
            if case .failed = state {
                Button {
                    Haptics.light()
                    onRetry()
                } label: {
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // `.glassSurface(in:)` lived in the design-system module that
        // got reverted; re-create the look inline via an
        // `.ultraThinMaterial`-backed capsule so the toast still
        // matches the other glass chrome.
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture {
            if case .failed = state {
                Haptics.light()
                onRetry()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state)
    }
    
    private var iconAccent: Color {
        switch state {
        case .idle: return .clear
        case .uploading: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }
}

/// Tiny Sendable wrapper for class instances that aren't themselves Sendable
/// (e.g. AVAssetExportSession). The wrapper itself is `@unchecked Sendable`,
/// so the surrounding `@Sendable` closure compiles; thread safety still has
/// to be argued by the caller (here: AVFoundation invokes the completion
/// handler exactly once on its private serial queue).
final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
