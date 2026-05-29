//
//  MessagePreviewFormatter.swift
//  RAVEN
//
//  One source of truth for "what should this message look like in a
//  notification body?" — used by APNs alert pushes, mesh-delivered
//  local notifications, and in-app toasts.
//
//  Why centralised
//  ───────────────
//  Three call sites used to produce the body string independently —
//  PushNotificationService, RAVENApp's mesh handler, and the toast
//  pipeline. They drifted: photo notifications said "Sent you a
//  message" while voice ones used the raw filename, etc. This file
//  fixes the divergence.
//
//  E2EE compatibility
//  ──────────────────
//  When the user has E2EE on and the inner text isn't yet decrypted
//  in the receiving process (e.g. APNs alert delivered to the
//  unattended app), the body field looks like base64 ciphertext.
//  We detect that via `String.looksEncrypted` and fall back to the
//  type-only label ("📷 Photo") instead of leaking gibberish into
//  the lock-screen.
//

import Foundation

enum MessagePreviewFormatter {

    /// Maximum body length on a lock-screen banner. iOS will truncate
    /// after ~100 chars anyway, but trimming server-side keeps the
    /// notification payload small.
    static let maxBodyChars = 120

    /// Format a notification body from raw metadata.
    ///
    /// - Parameters:
    ///   - messageType: server-supplied wire string ("text", "image",
    ///                  "video", "voice", "file", "location", etc.).
    ///                  Case-insensitive. Nil → treated as text.
    ///   - body:        the message text payload (or whatever the
    ///                  server claims is the preview). May be empty,
    ///                  may be ciphertext if E2EE leaked through.
    ///   - audioDurationSeconds: voice-message duration, if known.
    ///   - fileName:    attachment filename, if available.
    static func format(
        messageType: String?,
        body: String?,
        audioDurationSeconds: Int? = nil,
        fileName: String? = nil
    ) -> String {

        let cleanBody: String? = {
            // 🔴 ROUND 28 (2026-05-17) — strip invisible Unicode in
            // addition to plain whitespace. PREVIOUSLY: only
            // `trimmingCharacters(in: .whitespacesAndNewlines)`
            // ran, so a server payload that carried just an LRM /
            // RLM / ZWSP / variation selector / control char (real
            // shape for E2EE messages whose inner content the
            // server can't see, and for some platform handoff
            // payloads) passed the `!isEmpty` check intact. The
            // toast then rendered with a body line that was
            // visually empty but technically non-empty — exactly
            // the "box khali" bug the user kept seeing. Now we
            // filter out every Unicode scalar in the `control` or
            // `format` category before checking emptiness, so the
            // type-aware fallback ("💬 Message", "📷 Photo", …)
            // kicks in for these cases.
            guard let raw = body else { return nil }
            let visible = raw.unicodeScalars.filter { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return false
                default:
                    return true
                }
            }
            let stripped = String(String.UnicodeScalarView(visible))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            // Don't leak ciphertext to the lock screen. The
            // type-based fallback below will paint a clean preview.
            if stripped.looksEncrypted { return nil }
            return stripped
        }()

        switch (messageType ?? "text").lowercased() {

        case "text":
            return cleanBody.map { truncate($0) } ?? "💬 Message"

        case "image", "photo":
            // For images with a caption, show "📷 caption text" so
            // captions still get surfaced.
            if let body = cleanBody {
                return "📷 " + truncate(body)
            }
            return "📷 Photo"

        case "video":
            if let body = cleanBody {
                return "🎬 " + truncate(body)
            }
            return "🎬 Video"

        case "video_note", "videonote":
            return "🎥 Video note"

        case "ephemeral_photo", "ephemeralphoto", "snap":
            return "📸 Snap photo"

        case "voice", "audio":
            if let secs = audioDurationSeconds, secs > 0 {
                return "🎤 Voice message · \(formatDuration(secs))"
            }
            return "🎤 Voice message"

        case "file", "document":
            if let name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "📎 \(truncate(name))"
            }
            return "📎 File"

        case "location":
            return "📍 Location"

        case "poll":
            if let body = cleanBody {
                return "📊 Poll: " + truncate(body, max: maxBodyChars - 8)
            }
            return "📊 Poll"

        case "post_share", "postshare":
            return "📬 Shared a post"

        case "system":
            return cleanBody.map { truncate($0) } ?? "📢 Notification"

        default:
            // Unknown future types — degrade gracefully to whatever
            // text we have, otherwise a generic placeholder.
            return cleanBody.map { truncate($0) } ?? "💬 Message"
        }
    }

    /// Strongly-typed convenience for the in-process path that has a
    /// `ChatMessage` in hand (mesh receive, in-app toasts).
    /// Pulls the audio duration / filename automatically.
    static func format(message: ChatMessage) -> String {
        let durationSecs: Int? = message.audioDurationSeconds.map { Int($0) }
        return format(
            messageType: message.type.rawValue,
            body: message.text,
            audioDurationSeconds: durationSecs,
            fileName: message.fileName
        )
    }

    // MARK: - Helpers

    static func truncate(_ s: String, max: Int = MessagePreviewFormatter.maxBodyChars) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    /// Render seconds as `12s` / `1m 5s` / `2m 14s`. Locale-stable —
    /// notifications are formatted before the user sees them, so we
    /// keep this simple and consistent.
    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
