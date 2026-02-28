// RAVEN - Media Service
// Converted from Flutter media_chunking_service.dart, profile_picture_service.dart

import Foundation
import UIKit
import PhotosUI
import AVFoundation

/// Handles media upload, download, and processing
actor MediaService {
    static let shared = MediaService()
    
    private let maxImageSize = 1024 * 1024 * 5  // 5MB
    private let maxFileSize = 1024 * 1024 * 50  // 50MB
    private let thumbnailSize: CGFloat = 200
    
    private init() {}
    
    // MARK: - Image Processing
    
    /// Compress and resize image for upload
    func processImage(_ image: UIImage) -> Data? {
        // Resize if too large
        let maxDimension: CGFloat = 1920
        var processedImage = image
        
        if image.size.width > maxDimension || image.size.height > maxDimension {
            processedImage = image.resized(maxDimension: maxDimension)
        }
        
        // Compress
        return processedImage.compressed(maxSizeKB: maxImageSize / 1024)
    }
    
    /// Generate thumbnail for image
    func generateThumbnail(_ image: UIImage) -> Data? {
        let thumbnail = image.resized(maxDimension: thumbnailSize)
        return thumbnail.jpegData(compressionQuality: 0.6)
    }
    
    // MARK: - Upload
    
    /// Upload image and return URL
    func uploadImage(_ image: UIImage, onProgress: ((Double) -> Void)? = nil) async throws -> String {
        guard let data = processImage(image) else {
            throw MediaError.processingFailed
        }
        
        let fileName = "image_\(UUID().uuidString).jpg"
        return try await APIService.shared.uploadImage(data: data, fileName: fileName)
    }
    
    /// Upload file and return URL
    func uploadFile(_ url: URL, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResponse {
        let data = try Data(contentsOf: url)
        
        guard data.count <= maxFileSize else {
            throw MediaError.fileTooLarge
        }
        
        let mimeType = getMimeType(for: url.pathExtension)
        let fileName = url.lastPathComponent
        
        return try await APIService.shared.uploadFile(data: data, fileName: fileName, mimeType: mimeType, onProgress: onProgress)
    }
    
    /// Upload voice memo
    func uploadVoice(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        let fileName = "voice_\(UUID().uuidString).m4a"
        return try await APIService.shared.uploadVoice(data: data, fileName: fileName)
    }
    
    // MARK: - Download
    
    /// Download file to local storage
    func downloadFile(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw MediaError.invalidURL
        }
        
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MediaError.downloadFailed
        }
        
        // Move to permanent location
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDir = documentsDir.appendingPathComponent("media", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        
        let fileName = url.lastPathComponent
        let destURL = mediaDir.appendingPathComponent(fileName)
        
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        
        return destURL
    }
    
    // MARK: - Profile Picture
    
    /// Upload and update profile picture
    func updateProfilePicture(_ image: UIImage) async throws -> String {
        let imageUrl = try await uploadImage(image)
        _ = try await APIService.shared.updateProfilePicture(imageUrl: imageUrl)
        return imageUrl
    }
    
    // MARK: - Helpers
    
    private func getMimeType(for ext: String) -> String {
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "pdf": "application/pdf",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "mp3": "audio/mpeg",
            "m4a": "audio/mp4",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "zip": "application/zip",
            "txt": "text/plain"
        ]
        return mimeTypes[ext.lowercased()] ?? "application/octet-stream"
    }
    
    /// Get cached file path
    func getCachedPath(for urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cachedPath = documentsDir.appendingPathComponent("media/\(url.lastPathComponent)")
        
        if FileManager.default.fileExists(atPath: cachedPath.path) {
            return cachedPath
        }
        return nil
    }
    
    /// Clear media cache
    func clearCache() throws {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDir = documentsDir.appendingPathComponent("media")
        try FileManager.default.removeItem(at: mediaDir)
    }
}

// MARK: - Media Errors
enum MediaError: LocalizedError {
    case processingFailed
    case fileTooLarge
    case invalidURL
    case downloadFailed
    case uploadFailed
    
    var errorDescription: String? {
        switch self {
        case .processingFailed: return "Failed to process image"
        case .fileTooLarge: return "File is too large (max 50MB)"
        case .invalidURL: return "Invalid URL"
        case .downloadFailed: return "Download failed"
        case .uploadFailed: return "Upload failed"
        }
    }
}
