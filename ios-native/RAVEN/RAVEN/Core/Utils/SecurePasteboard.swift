//
//  SecurePasteboard.swift
//  RAVEN
//
//  Round 14 (2026-05-16) — hacker-audit finding S9.
//
//  Wraps `UIPasteboard.general` with the privacy flags every copy
//  of sensitive content (chat messages, device fingerprints,
//  recovery codes, comments, transcripts) should set:
//
//    • `.localOnly = true` — the bytes stay on this device. iOS's
//      Universal Clipboard (Handoff) and other cross-device paste
//      paths are bypassed. Without this, anything copied here can
//      be silently fetched by a Mac on the same iCloud account.
//    • `.expirationDate = now + 60 s` — iOS automatically clears
//      the pasteboard after the window. Any background pasteboard
//      poller (and there are many — third-party keyboards, ad SDKs,
//      analytics suites) has a much smaller window to read the
//      bytes.
//
//  Plain status messages like "Copied!" don't need this — only
//  user content / identity material / secrets.

import UIKit
import UniformTypeIdentifiers

enum SecurePasteboard {
    /// Copy `text` with privacy-preserving flags. Defaults: local-
    /// only and auto-expire in 60 seconds. Caller can override the
    /// expiry for longer-lived payloads (e.g. recovery codes that
    /// need to be pasted into a different app).
    static func copy(_ text: String, expiresIn seconds: TimeInterval = 60) {
        let utf8Key = UTType.utf8PlainText.identifier
        UIPasteboard.general.setItems(
            [[utf8Key: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(seconds)
            ]
        )
    }
}
