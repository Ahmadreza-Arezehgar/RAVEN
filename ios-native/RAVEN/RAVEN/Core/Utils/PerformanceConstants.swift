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
    ///
    /// History: an older version flagged any whitespace-separated token longer
    /// than 40 chars as encrypted. That false-positives legitimate posts with
    /// long URLs in them (news bot, link previews, anything with a tracking
    /// query string) and made those posts invisible on profile + reply tabs.
    /// The fix tokenises on the full whitespace set (so a URL on its own line
    /// is its own token) and exempts tokens that look like URLs or contain
    /// URL punctuation (`/`, `:`, `?`, `&`, `=`, `.`).
    var looksEncrypted: Bool {
        if self.isEmpty { return false }

        // Whole-string URL — never encrypted.
        if self.hasPrefix("http://") || self.hasPrefix("https://") || self.hasPrefix("raven://") { return false }

        // Unambiguous ciphertext / JWT prefixes — real signal, keep flagging.
        if self.hasPrefix("gAAAA") || self.hasPrefix("eyJ") { return true }

        // Tokenise on ALL whitespace (spaces AND newlines). Splitting on " "
        // alone glued newline-separated URLs into a single long "word" and was
        // the source of the false-positive that hid news-bot posts.
        let parts = self.split(whereSeparator: { $0.isWhitespace || $0.isNewline })

        // A long token is "innocent" if it looks like a URL or contains URL
        // punctuation — base64 ciphertext is purely [A-Za-z0-9_+/=-], so any
        // token with `/`, `:`, `?`, `&`, `=`, or `.` is almost certainly not
        // a Fernet blob.
        func isInnocentLongToken<S: StringProtocol>(_ t: S) -> Bool {
            if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("raven://") || t.hasPrefix("www.") { return true }
            return t.contains("/") || t.contains(":") || t.contains("?") || t.contains("&") || t.contains("=") || t.contains(".")
        }

        // Single long token (no whitespace at all) — only flag if it doesn't
        // look like a URL/identifier.
        if parts.count == 1 && self.count > 40 {
            return !isInnocentLongToken(parts[0])
        }

        // Multi-token: a single >40-char "word" only counts as suspicious if
        // it has none of the URL-punctuation tells.
        for p in parts where p.count > 40 {
            if !isInnocentLongToken(p) { return true }
        }

        return false
    }

    /// Sanitize a string for display on the lock screen / push
    /// banner / in-app toast. Round 13 — hacker-audit finding N7.
    ///
    /// Push payloads come from the server but include attacker-
    /// controlled chat content (sender names, message bodies). Two
    /// classes of attack we close here:
    ///
    /// 1. **Bidi / control / zero-width hijacks**: characters like
    ///    U+202E (RIGHT-TO-LEFT OVERRIDE) and U+200B (ZERO-WIDTH
    ///    SPACE) let an attacker disguise a banner as something
    ///    else (e.g. spoof a bank-confirmation prompt). We strip the
    ///    entire Cn/Cc/Cf category EXCEPT line break / tab.
    /// 2. **Oversized payload**: APNs caps at 4 KB total; a 3.9 KB
    ///    body line crashes older SpringBoards or pushes the action
    ///    buttons off-screen on the lock screen. We hard-cap to the
    ///    `maxLength` the caller hands us.
    ///
    /// Use this at every `content.title = …` / `content.body = …`
    /// assignment in `PushNotificationService` and on any
    /// notification-derived toast text.
    func sanitizedForPush(maxLength: Int = 256) -> String {
        guard !self.isEmpty else { return self }

        // Strip control / format / private-use scalars that aren't
        // newline or tab. `\u{2066}` … `\u{2069}` (isolate),
        // `\u{202A}` … `\u{202E}` (override), `\u{200B}` … `\u{200F}`
        // (zero-width / bidi marks) all fall in .formatCharacter.
        let filteredScalars = self.unicodeScalars.lazy.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            let cat = scalar.properties.generalCategory
            // Block Cc (control), Cf (format / bidi), Cs (surrogate),
            // Co (private use). Keep everything else, including
            // emoji + non-Latin scripts.
            switch cat {
            case .control, .format, .surrogate, .privateUse:
                return false
            default:
                return true
            }
        }
        var sanitized = String(String.UnicodeScalarView(filteredScalars))

        // Collapse runs of whitespace so "  \n\t  hi" doesn't burn
        // the visible space budget on indentation. Keep single
        // spaces.
        sanitized = sanitized.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        // Hard cap on length. iOS truncates with an ellipsis past
        // the visible bound anyway; doing it ourselves means the
        // remaining payload doesn't sit in memory.
        if sanitized.count > maxLength {
            let endIndex = sanitized.index(sanitized.startIndex, offsetBy: maxLength)
            sanitized = String(sanitized[..<endIndex]) + "…"
        }

        return sanitized
    }
}
