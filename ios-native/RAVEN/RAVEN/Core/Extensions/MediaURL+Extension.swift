import Foundation

// MARK: - URL Helpers for Media Paths
extension String {
    /// Convert path to full media URL (handles relative paths like /uploads/...)
    var asMediaURL: URL? {
        AppConfig.mediaURL(from: self)
    }
}

extension Optional where Wrapped == String {
    /// Convert optional path to full media URL
    var asMediaURL: URL? {
        guard let self = self else { return nil }
        return AppConfig.mediaURL(from: self)
    }
}
