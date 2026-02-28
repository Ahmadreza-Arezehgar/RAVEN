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
    
    // Local storage directory
    private var attachmentsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("attachments")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    // MARK: - Send Image
    
    func sendImage(
        _ image: UIImage,
        roomId: String,
        recipientId: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
        clientMessageId: String? = nil
    ) async throws {
        
        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.displayName ?? "" }
        let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }
        
        // Capture tier limits before entering the detached Task (concurrency safety)
        let maxDim = PremiumLimits.maxImageDimension
        let quality = PremiumLimits.imageCompressionQuality
        
        // Compress on background thread to avoid UI freeze
        let data: Data = try await Task.detached(priority: .userInitiated) {
            // Always downscale: 2048px free, 8192px RAVEN+ — prevents OOM on 48MP+ ProRAW
            let safeImage = image.downscaled(maxDimension: maxDim)
            
            guard let d = safeImage.jpegData(compressionQuality: quality) else {
                throw AttachmentError.compressionFailed
            }
            return d
        }.value
        
        let localPath = attachmentsDirectory.appendingPathComponent("\(clientId).jpg")
        try data.write(to: localPath)
        
        // 2. Insert to DB with uploading state
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
            originDeviceId: deviceId
        )
        
        try await messageRepo.upsert(message)
        
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }
        
        // ⚠️ PERSIST-FIRST: Check internet AFTER saving to DB so bubble stays visible with Retry
        guard NetworkMonitor.shared.isOnline else {
            try await messageRepo.updateDisplayState(clientMessageId: clientId, state: .failed, error: "No internet connection")
            throw AttachmentError.internetRequired
        }
        
        // 3. Upload to server using /api/uploads/image
        do {
            let remoteUrl = try await uploadImage(localPath: localPath, clientId: clientId)
            
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
                        replyToTextPreview: replyTo?.safeReplySnippet,
                        replyToSenderName: replyTo?.senderName,
                        replyToType: replyTo?.type.rawValue
                    ),
                    idempotencyKey: clientId
                )
                
                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Group image sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            } else {
                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: clientId,
                        recipientId: recipientId,
                        content: "",
                        messageType: "image",
                        audioUrl: remoteUrl,
                        replyToMessageId: replyTo?.id
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
    
    // MARK: - Send Voice
    
    func sendVoice(
        audioURL: URL,
        duration: Int,
        roomId: String,
        recipientId: String,
        isGroup: Bool = false,
        replyTo: ChatMessage? = nil,
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
        
        // ⚠️ PERSIST-FIRST: Check internet AFTER saving to DB so bubble stays visible with Retry
        guard NetworkMonitor.shared.isOnline else {
            try await messageRepo.updateDisplayState(clientMessageId: clientId, state: .failed, error: "No internet connection")
            throw AttachmentError.internetRequired
        }
        
        // 3. Upload voice
        do {
            let remoteUrl = try await uploadVoice(
                localPath: localPath,
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
                        replyToTextPreview: replyTo?.safeReplySnippet,
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
                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: clientId,
                        recipientId: recipientId,
                        content: "",
                        messageType: "voice",
                        audioUrl: remoteUrl,
                        audioDurationSeconds: duration,
                        replyToMessageId: replyTo?.id
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
        clientMessageId: String? = nil
    ) async throws {
        let clientId = clientMessageId ?? UUID().uuidString
        let myId = await KeychainService.shared.getUserId() ?? ""
        let myName = await MainActor.run { AuthService.shared.currentUser?.displayName ?? "" }
        let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }
        
        // 1. Copy to local storage
        let fileName = fileURL.lastPathComponent
        let localPath: URL

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
        
        let attrs = try fileManager.attributesOfItem(atPath: localPath.path)
        let fileSize = attrs[.size] as? Int ?? 0
        let mimeType = mimeTypeFor(path: fileName)
        
        // RAVEN+ file size gate: Free 25MB, RAVEN+ 2GB
        let maxBytes = PremiumLimits.maxFileUploadBytes
        if fileSize > maxBytes {
            try? fileManager.removeItem(at: localPath)
            let maxMB = maxBytes / (1024 * 1024)
            throw PremiumLimitError.fileTooLarge(maxMB: maxMB)
        }
        
        // 2. Insert to DB
        let message = ChatMessage.newAttachmentMessage(
            messageId: clientId,
            to: recipientId,
            type: .file,
            localPath: localPath.path,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            duration: nil,
            senderId: myId,
            senderName: myName,
            roomId: roomId,
            originDeviceId: deviceId
        )
        
        try await messageRepo.upsert(message)
        
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }
        
        // ⚠️ PERSIST-FIRST: Check internet AFTER saving to DB so bubble stays visible with Retry
        guard NetworkMonitor.shared.isOnline else {
            try await messageRepo.updateDisplayState(clientMessageId: clientId, state: .failed, error: "No internet connection")
            throw AttachmentError.internetRequired
        }
        
        // 3. Upload using /api/uploads/file
        do {
            let remoteUrl = try await uploadDocument(localPath: localPath, originalFilename: fileName)
            
            // Send to server - use different endpoint for groups
            if isGroup {
                let response: GroupMessageResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(roomId)/messages",
                    body: SendGroupMessageRequest(
                        messageId: clientId,
                        content: "",
                        messageType: "file",
                        audioUrl: remoteUrl,
                        fileName: fileName,
                        fileSize: fileSize,
                        mimeType: mimeType,
                        replyToMessageId: replyTo?.id,
                        replyToTextPreview: replyTo?.safeReplySnippet,
                        replyToSenderName: replyTo?.senderName,
                        replyToType: replyTo?.type.rawValue
                    ),
                    idempotencyKey: clientId
                )
                
                try await messageRepo.updateServerId(clientMessageId: clientId, serverId: response.id)
                #if DEBUG
                print("✅ Group file sent successfully, server_id: \(response.id.prefix(8))")
                #endif
            } else {
                let response: SendMessageResponse = try await NetworkService.shared.post(
                    path: "/api/messages/send",
                    body: SendMessageRequest(
                        messageId: clientId,
                        recipientId: recipientId,
                        content: "",
                        messageType: "file",
                        audioUrl: remoteUrl,
                        replyToMessageId: replyTo?.id,
                        fileName: fileName,
                        fileSize: fileSize,
                        mimeType: mimeType
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
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempFile)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentError.uploadFailed
        }
        
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
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempFile)
        
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
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempFile)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
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
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        
        let (responseData, response) = try await session.upload(for: request, fromFile: tempFile)
        
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
    let fileUrl: String
    let filename: String
    let uniqueFilename: String
    let size: Int
    let mimeType: String
    
    enum CodingKeys: String, CodingKey {
        case fileUrl = "file_url"
        case filename
        case uniqueFilename = "unique_filename"
        case size
        case mimeType = "mime_type"
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
    
    var errorDescription: String? {
        switch self {
        case .compressionFailed: return "Failed to compress media"
        case .uploadFailed: return "Failed to upload file"
        case .downloadFailed: return "Failed to download file"
        case .fileNotFound: return "File not found"
        case .internetRequired: return "Media messages require internet connection"
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
