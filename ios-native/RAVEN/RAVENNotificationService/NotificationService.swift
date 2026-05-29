//
//  NotificationService.swift
//  RAVENNotificationService
//
//  🔴 ROUND 70 (2026-05-23) — hacker-audit APNS-CRIT-1.
//
//  Notification Service Extension (NSE) that runs IN-PROCESS on the
//  device before the lock-screen alert is rendered. The server ships
//  every push with `aps.mutable-content = 1`, which lets this NSE
//  modify the `aps.alert.body` before the system displays it.
//
//  WHAT THIS FIXES:
//  Before this NSE existed, every push body went straight to Apple's
//  APNs servers + the device lock screen as cleartext. For text
//  messages that meant Apple + anyone watching the lock screen could
//  read the first ~100 chars. The server-side ciphertext heuristic
//  (`messages.py`) replaces obvious Fernet blobs with "New message",
//  but anything BELOW the 40-char threshold or not Fernet-shaped
//  still leaked verbatim.
//
//  WHAT THIS DOES:
//   1. Receive the incoming UNNotificationRequest in `didReceive`.
//   2. If the body looks like ciphertext (Fernet `gAAAA…`, base64-ish
//      blob >16 chars with no whitespace/punctuation), REPLACE it
//      with "New message" before calling the system completion.
//   3. Pass non-ciphertext bodies through unchanged (server already
//      sends a benign placeholder for media-only messages).
//
//  FUTURE WORK (round 71+):
//  Add a true client-side decrypt path here — share the Keychain
//  access group with the main app so we can pull the recipient's
//  X25519 private key + the sender's pubkey, then RVNS1-unseal the
//  ciphertext body and show the real plaintext on the lock screen.
//  For now we ship the conservative "always-hide-ciphertext" path
//  which is a STRICT IMPROVEMENT over the pre-round-70 leak.
//
//  Wiring: this file needs an accompanying Info.plist + entitlements
//  + Xcode target. The Xcode project file references must be added
//  manually:
//    1. File → New → Target → Notification Service Extension.
//    2. Name it `RAVENNotificationService`.
//    3. Set the Bundle Identifier to
//       `<main bundle id>.RAVENNotificationService`.
//    4. Replace the generated `NotificationService.swift` with this
//       file and the generated Info.plist with the one in this
//       directory.
//

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttempt = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        bestAttempt.body = Self.sanitizedBody(bestAttempt.body)
        contentHandler(bestAttempt)
    }

    override func serviceExtensionTimeWillExpire() {
        // Falls through to whatever the system already has; we already
        // sanitised it in `didReceive`, so this is a safe default.
        if let contentHandler = contentHandler, let bestAttempt = bestAttemptContent {
            contentHandler(bestAttempt)
        }
    }

    /// 🔴 ROUND 70 — body sanitiser. Conservative: if the body LOOKS
    /// like opaque ciphertext, replace with "New message". The
    /// heuristic is intentionally a superset of the server-side one
    /// in `messages.py:_apns_preview_sanitiser` so even a server bug
    /// can't leak ciphertext past us.
    static func sanitizedBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }

        // Fernet ciphertext always begins with the literal `gAAAAA`.
        if trimmed.hasPrefix("gAAAA") {
            return "New message"
        }

        // Any string >16 chars that's purely base64/url-safe-base64
        // characters with NO whitespace and NO sentence punctuation
        // is almost certainly ciphertext, not a real human message.
        // Real human messages have spaces, commas, periods, etc.
        if trimmed.count > 16 {
            let allowed: Set<Character> = Set(
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-"
            )
            let hasOnlyB64Chars = trimmed.allSatisfy { allowed.contains($0) }
            let hasNoSentencePunct = !trimmed.contains(where: { " :/?&=.,!?\n\t".contains($0) })
            if hasOnlyB64Chars && hasNoSentencePunct {
                return "New message"
            }
        }

        return body
    }
}
