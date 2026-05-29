//
//  MessageEncryptionStatusStore.swift
//  RAVEN
//
//  Round 12 (2026-05-16).
//
//  Per-message ephemeral side-table tracking whether the bubble we
//  rendered was Noise-sealed end-to-end (`.sealed`) or fell back to
//  the explicit-plaintext / legacy path (`.plaintext`). The receive
//  path in `MessageStore` writes here; the bubble UI reads here.
//
//  Why side-table instead of a column on ChatMessage:
//    • Adding a `Bool` to `ChatMessage` requires a SQLite schema
//      migration AND every ChatMessage(...) initialiser to be
//      updated AND every test fixture to be touched. The badge is
//      visual UX — losing the state on a fresh restart is fine; the
//      next sync re-reads the envelope magic and re-populates.
//    • Side-table keeps the change contained to the chat module and
//      means we can iterate on the UI surface without churning the
//      DB.
//
//  Threading: backed by an actor for writes (so the receive path
//  can hop onto it from any context), with a `@MainActor`
//  `@Observable` mirror exposed to SwiftUI views.

import Foundation
import SwiftUI

enum MessageEncryptionStatus: Sendable, Equatable {
    /// Message body was sealed/decoded from RVNS1 — Noise-sealed
    /// transport ciphertext with a verified per-msg AAD.
    case sealed

    /// Sender's app emitted RVNP1 — i.e. the sender knew there
    /// was no Noise session and explicitly flagged the body as
    /// not-end-to-end-encrypted. Less alarming than `.legacy`:
    /// the sender's app is at least round-10+ and intends to
    /// upgrade once a session lands. Round 15.
    case plaintextExplicit

    /// Either the inbound payload had NO magic header at all (a
    /// pre-round-10 sender's app), or our local seal couldn't pin
    /// down a recipient pubkey at all. Renders the strongest
    /// "Not encrypted" warning. Round 15.
    case plaintextLegacy

    /// Message had the sealed magic but we couldn't decrypt — the
    /// peer rotated keys mid-conversation OR the session was evicted.
    /// Surface a distinct "couldn't decrypt" indicator.
    case sealedButFailed

    /// Back-compat alias for round-12 callers; new code should pick
    /// `.plaintextExplicit` or `.plaintextLegacy` based on signal.
    static let plaintext: MessageEncryptionStatus = .plaintextLegacy
}

actor MessageEncryptionStatusStore {
    static let shared = MessageEncryptionStatusStore()

    private var statuses: [String: MessageEncryptionStatus] = [:]

    private init() {}

    func status(for messageId: String) -> MessageEncryptionStatus? {
        statuses[messageId]
    }

    /// Snapshot of all recorded statuses — used by the chat-level
    /// summary chip to count how many bubbles in the current
    /// conversation are downlevel. Returns a copy so the caller
    /// can't mutate actor state.
    func allStatuses() -> [String: MessageEncryptionStatus] {
        statuses
    }

    func record(_ status: MessageEncryptionStatus, for messageId: String) async {
        guard !messageId.isEmpty else { return }
        // Don't downgrade a sealed verdict on a duplicate write —
        // helps prevent a re-sync of an old RVNP1 row from masking a
        // recovered sealed render.
        if statuses[messageId] == .sealed && status != .sealed { return }
        statuses[messageId] = status
        await MessageEncryptionBadgeState.shared.bump(messageId: messageId)
    }
}

// MARK: - Outbound seal verdict bridge

/// Tiny convenience used by every server-bound send path so the
/// sender's own bubble carries the same lock badge the receiver
/// sees. The mapping from `SealReason` → `MessageEncryptionStatus`
/// is the canonical translation between the sealer's internal
/// labels and the user-facing chat verdict.
///
/// Round 15.
extension MessageContentSealer {
    static func recordSealVerdict(_ reason: SealedContent.SealReason, for messageId: String) async {
        let verdict: MessageEncryptionStatus
        switch reason {
        case .noiseTransport, .atsamHybrid:
            // 🔴 ROUND 71 phase 3 follow-up #5 (2026-05-24) —
            // Task #59. Both Noise + ATSAM produce the strongest
            // E2EE verdict from the user's POV. The lock badge
            // doesn't currently differentiate the two — a future
            // round can add a separate "PQC-protected" variant.
            verdict = .sealed
        case .noSession:
            // We had the recipient's pubkey but no live Noise
            // session — the body went up as RVNP1 explicit
            // plaintext.
            verdict = .plaintextExplicit
        case .noRecipientKey:
            // We couldn't even resolve a recipient pubkey, so the
            // body went up as RVNP1 with "no recipient key" as the
            // reason. From the bubble's POV this looks legacy-
            // grade — show the strongest warning.
            verdict = .plaintextLegacy
        }
        await MessageEncryptionStatusStore.shared.record(verdict, for: messageId)
    }
}

/// SwiftUI-observable bridge — same shape as PeerProtocolBannerState.
@MainActor
@Observable
final class MessageEncryptionBadgeState {
    static let shared = MessageEncryptionBadgeState()
    private(set) var bumps: [String: Int] = [:]
    private init() {}
    func bump(messageId: String) {
        bumps[messageId, default: 0] &+= 1
    }
}

/// Tiny capsule that reads the side-table and renders a lock /
/// open-lock / red lock per-bubble. Designed to be slotted into the
/// bubble's metadata row (next to the timestamp). Tapping it opens
/// an explainer sheet so the user can act on the warning.
///
/// Round 15: tappable + distinguishes RVNP1 (orange) from pre-round-
/// 10 legacy (red — strongest warning), plus a sealedButFailed red
/// triangle for "we have a ciphertext but can't decrypt".
struct MessageEncryptionBadge: View {
    let messageId: String

    private let badgeState = MessageEncryptionBadgeState.shared
    @State private var status: MessageEncryptionStatus? = nil
    @State private var showSheet = false

    var body: some View {
        _ = badgeState.bumps[messageId]

        return Group {
            switch status {
            case .sealed, .none:
                // Sealed (or unknown — default to no badge clutter
                // for the common case). Hiding when sealed keeps the
                // bubble metadata uncluttered for the 99%-happy
                // path.
                EmptyView()
            case .plaintextExplicit:
                tappableCapsule(
                    icon: "lock.open.fill",
                    label: "Not E2EE",
                    tint: .orange,
                    a11y: "This message was not end-to-end encrypted."
                )
            case .plaintextLegacy:
                tappableCapsule(
                    icon: "lock.slash.fill",
                    label: "Unencrypted",
                    tint: .red,
                    a11y: "This message was sent without any encryption."
                )
            case .sealedButFailed:
                tappableCapsule(
                    icon: "lock.trianglebadge.exclamationmark",
                    label: "Decrypt failed",
                    tint: .red,
                    a11y: "This message could not be decrypted."
                )
            }
        }
        .task(id: messageId) { await refresh() }
        .task(id: badgeState.bumps[messageId] ?? 0) { await refresh() }
        .sheet(isPresented: $showSheet) {
            MessageEncryptionExplainerSheet(status: status ?? .plaintextLegacy)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func tappableCapsule(
        icon: String,
        label: String,
        tint: Color,
        a11y: String
    ) -> some View {
        Button {
            Haptics.light()
            showSheet = true
        } label: {
            Label {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
        .accessibilityHint(Text("Tap for more about this message's encryption."))
    }

    private func refresh() async {
        let next = await MessageEncryptionStatusStore.shared.status(for: messageId)
        await MainActor.run {
            self.status = next
        }
    }
}

// MARK: - Explainer sheet

/// Educational sheet shown when the user taps the per-bubble
/// encryption badge. Tells the user, in plain language:
///   • what the badge means
///   • why it appeared (cold contact / out-of-date peer / etc.)
///   • what to do next (open the Safety Number sheet to verify, or
///     wait for the next message which will likely be sealed once
///     the Noise handshake completes).
///
/// Round 15.
struct MessageEncryptionExplainerSheet: View {
    let status: MessageEncryptionStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: headerIcon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(headerTint)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(headerTint.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            // Body
            VStack(alignment: .leading, spacing: 14) {
                Text(bodyText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = actionHint {
                    Label(action, systemImage: "lightbulb.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.blue.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            // Footer
            Button {
                dismiss()
            } label: {
                Text("Got it")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.blue)
                    )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: per-status copy

    private var headerIcon: String {
        switch status {
        case .sealed: return "lock.fill"
        case .plaintextExplicit: return "lock.open.fill"
        case .plaintextLegacy: return "lock.slash.fill"
        case .sealedButFailed: return "lock.trianglebadge.exclamationmark"
        }
    }
    private var headerTint: Color {
        switch status {
        case .sealed: return .green
        case .plaintextExplicit: return .orange
        case .plaintextLegacy, .sealedButFailed: return .red
        }
    }
    private var title: String {
        switch status {
        case .sealed: return "End-to-end encrypted"
        case .plaintextExplicit: return "Not end-to-end encrypted"
        case .plaintextLegacy: return "Sent unencrypted"
        case .sealedButFailed: return "Couldn't decrypt this message"
        }
    }
    private var subtitle: String {
        switch status {
        case .sealed: return "Only you and the recipient can read it."
        case .plaintextExplicit: return "The server could read this message."
        case .plaintextLegacy: return "No encryption was applied."
        case .sealedButFailed: return "The session keys may have rotated."
        }
    }
    private var bodyText: String {
        switch status {
        case .sealed:
            return "RAVEN wrapped this message with a Noise transport key that only your device and the recipient's device hold. The server stored opaque bytes."
        case .plaintextExplicit:
            return "Your device couldn't find a live encryption session with the recipient yet, so the body was sent inside a special envelope that's clearly marked as unencrypted. Once the two devices exchange keys (usually within seconds of the first contact), every following message will be sealed."
        case .plaintextLegacy:
            return "This message arrived with no encryption envelope at all — most often that means the sender is running an older RAVEN build that pre-dates the v1.7 encryption update. Treat its contents as if they were sent over plain SMS."
        case .sealedButFailed:
            return "RAVEN got a properly-sealed message, but the keys on your device couldn't decrypt it. The peer likely rotated their identity since you last spoke. Open the Safety Number sheet to re-verify and the next message should arrive readable."
        }
    }
    private var actionHint: String? {
        switch status {
        case .sealed: return nil
        case .plaintextExplicit:
            return "Tip: wait for the next message — it should arrive sealed."
        case .plaintextLegacy:
            return "Ask the sender to update RAVEN to the latest version."
        case .sealedButFailed:
            return "Open this peer's Safety Number sheet to re-verify their keys."
        }
    }
}
