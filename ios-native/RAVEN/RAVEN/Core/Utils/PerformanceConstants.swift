//
//  PerformanceConstants.swift
//  RAVEN
//
//  Pre-compiled regex patterns and formatters.
//  Creating NSRegularExpression / DateFormatter on every call is extremely
//  expensive during scroll — these static lets guarantee single allocation.
//

import Foundation

enum PerformanceConstants {
    // MARK: - Regex
    
    /// Pre-compiled regex for detecting base64/encrypted content.
    /// Used by looksEncrypted() across ChatMessage, Conversation, InboxView, etc.
    static let base64Regex = try? NSRegularExpression(pattern: "^[A-Za-z0-9+/=_:-]+$")
    
    /// Hashtag detection (#word)
    static let hashtagRegex = try? NSRegularExpression(pattern: "#(\\w+)", options: [])
    
    /// Mention detection (@word)
    static let mentionRegex = try? NSRegularExpression(pattern: "@\\w+", options: [])
    
    // MARK: - Date Formatters
    
    /// ISO8601 with fractional seconds (matches server format)
    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    /// Standard ISO8601 (no fractional seconds)
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
    
    // MARK: - Data Detectors
    
    /// Pre-compiled link detector — NSDataDetector creation is extremely expensive.
    /// Reused by String.detectedURLs to avoid stutter during scroll.
    static let linkDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
}

// MARK: - Encrypted Content Detection Extension

extension String {
    /// Check if this string looks like encrypted/encoded data (base64, Fernet tokens, JWTs, etc.)
    /// Used across notifications, conversation display, and mesh message handling.
    var looksEncrypted: Bool {
        if self.isEmpty { return false }
        
        // Prevent long URLs from being flagged as encrypted blobs
        if self.hasPrefix("http://") || self.hasPrefix("https://") || self.hasPrefix("raven://") { return false }
        
        if self.hasPrefix("gAAAA") || self.hasPrefix("eyJ") { return true }
        
        // Long strings without spaces are likely encrypted blobs
        let noSpaces = !self.contains(" ")
        if noSpaces && self.count > 40 { return true }
        
        // Space-joined encrypted parts (e.g. encrypted firstName + lastName)
        let parts = self.split(separator: " ")
        if parts.contains(where: { $0.count > 40 }) { return true }
        
        return false
    }
}
