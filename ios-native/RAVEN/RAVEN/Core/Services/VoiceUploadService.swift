import Foundation

// MARK: - Voice Upload Service
/// Uploads voice recordings to the server via multipart form-data.
/// Returns the CDN URL for use in voice posts and voice comments.
enum VoiceUploadService {
    
    struct VoiceUploadResult {
        let voiceUrl: String
        let filename: String
        let size: Int
    }
    
    /// Upload a voice file to `/api/uploads/voice`.
    /// - Parameter fileURL: Local file URL of the recorded m4a
    /// - Returns: Server-returned CDN URL and metadata
    static func upload(fileURL: URL) async throws -> VoiceUploadResult {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        
        #if DEBUG
        print("📤 [VoiceUpload] Uploading \(fileSize) bytes from \(fileURL.lastPathComponent)")
        #endif
        
        // Build multipart file on disk (avoids loading entire voice file into RAM)
        let boundary = UUID().uuidString
        let filename = fileURL.lastPathComponent
        let mimeType = "audio/mp4"
        let tempURL = try buildMultipartFile(source: fileURL, boundary: boundary, filename: filename, mimeType: mimeType)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // Create request
        let urlString = "\(AppConfig.apiBaseURL)/api/uploads/voice"
        guard let url = URL(string: urlString) else {
            throw VoiceUploadError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Add auth token
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            throw VoiceUploadError.noAuthToken
        }
        
        // Stream upload from disk — no full-file RAM allocation
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
        
        // Debug log
        if let jsonString = String(data: responseData, encoding: .utf8) {
            #if DEBUG
            print("📤 [VoiceUpload] Response: \(jsonString)")
            #endif
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            #if DEBUG
            print("❌ [VoiceUpload] Failed with status \(statusCode)")
            #endif
            throw VoiceUploadError.serverError(statusCode)
        }
        
        // Parse response
        let result = try JSONDecoder().decode(VoiceUploadResponse.self, from: responseData)
        
        #if DEBUG
        print("✅ [VoiceUpload] Uploaded: \(result.voiceUrl)")
        #endif
        
        return VoiceUploadResult(
            voiceUrl: result.voiceUrl,
            filename: result.filename,
            size: result.size
        )
    }
    
    /// Build a multipart/form-data file on disk by streaming.
    /// Writes headers, then appends source file data, then writes closing boundary.
    /// Returns the temp file URL — caller must clean up.
    private static func buildMultipartFile(
        source: URL, boundary: String, filename: String, mimeType: String
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("voice_upload_\(UUID().uuidString).tmp")
        
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { handle.closeFile() }
        
        // Write multipart header
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        var headerData = Data()
        headerData.appendString(header)
        try handle.write(contentsOf: headerData)
        
        // Stream source file in chunks (64KB) to avoid loading into RAM
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { sourceHandle.closeFile() }
        let chunkSize = 64 * 1024
        while try autoreleasepool(invoking: {
            guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            try handle.write(contentsOf: chunk)
            return true
        }) {}
        
        // Write closing boundary
        let footer = "\r\n--\(boundary)--\r\n"
        var footerData = Data()
        footerData.appendString(footer)
        try handle.write(contentsOf: footerData)
        
        return tempURL
    }
    
    // MARK: - Error
    enum VoiceUploadError: LocalizedError {
        case invalidURL
        case noAuthToken
        case serverError(Int)
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid upload URL"
            case .noAuthToken: return "Not authenticated"
            case .serverError(let code): return "Upload failed (HTTP \(code))"
            case .invalidResponse: return "Invalid server response"
            }
        }
    }
    
    // MARK: - Response Model
    private struct VoiceUploadResponse: Decodable {
        let voiceUrl: String
        let filename: String
        let size: Int
        
        enum CodingKeys: String, CodingKey {
            case voiceUrl = "voice_url"
            case filename
            case size
        }
    }
}
