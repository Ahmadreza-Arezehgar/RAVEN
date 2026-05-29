//
//  ChatEncryptionSummaryChip.swift
//  RAVEN
//
//  Round 15 (2026-05-16).
//
//  A small floating chip rendered at the top of a conversation when
//  any messages in the current view have arrived as RVNP1 plaintext,
//  pre-round-10 legacy, or failed-to-decrypt. Sits underneath the
//  navigation bar and slides in/out with a spring as soon as the
//  side-table picks up a non-sealed verdict.
//
//  The visible copy is intentionally short and reads as a status,
//  not a scare: "3 messages weren't encrypted" — tap to drill in.
//  Tapping opens the standard explainer sheet keyed to whichever
//  level the chip is reflecting.
//
//  Together with the per-bubble badge and the ATSAMMismatchBanner,
//  this gives the user three layers of visibility into the chat's
//  encryption health:
//
//    1. Per-bubble badge (Round 12 + 15): catches a single
//       downlevel message at the exact bubble that's affected.
//    2. ATSAM mismatch banner (Round 12): warns when the PEER
//       client is downlevel — proactive about the contact.
//    3. This summary chip (Round 15): aggregates the chat-level
//       health so the user sees "this conversation has gone
//       through 3 unencrypted messages today" at a glance.

import SwiftUI

struct ChatEncryptionSummaryChip: View {
    /// The set of message ids the chat surface is currently showing.
    /// We only count those — older messages that have rolled out of
    /// view don't bias the chip.
    let visibleMessageIds: Set<String>

    private let badgeState = MessageEncryptionBadgeState.shared
    @State private var counts = Counts()
    @State private var showSheet = false

    private struct Counts: Equatable {
        var plaintextExplicit = 0
        var plaintextLegacy = 0
        var sealedButFailed = 0
        var total: Int { plaintextExplicit + plaintextLegacy + sealedButFailed }
    }

    var body: some View {
        // Force a redraw whenever any bubble's verdict bumps.
        _ = badgeState.bumps.values.reduce(0, &+)

        return Group {
            if counts.total > 0 {
                chip
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.4, dampingFraction: 0.85))
                    )
            }
        }
        .task(id: visibleMessageIds) { await recompute() }
        .task(id: badgeState.bumps.values.reduce(0, &+)) { await recompute() }
        .sheet(isPresented: $showSheet) {
            // The sheet reflects the WORST verdict in view so the
            // copy guides the user toward the most urgent action.
            let worst: MessageEncryptionStatus = {
                if counts.sealedButFailed > 0 { return .sealedButFailed }
                if counts.plaintextLegacy > 0 { return .plaintextLegacy }
                return .plaintextExplicit
            }()
            MessageEncryptionExplainerSheet(status: worst)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var chip: some View {
        Button {
            Haptics.light()
            showSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: leadingIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.30), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        if counts.sealedButFailed > 0 || counts.plaintextLegacy > 0 { return .red }
        return .orange
    }
    private var leadingIcon: String {
        if counts.sealedButFailed > 0 { return "lock.trianglebadge.exclamationmark" }
        if counts.plaintextLegacy > 0 { return "lock.slash.fill" }
        return "lock.open.fill"
    }
    private var label: String {
        let n = counts.total
        let noun = n == 1 ? "message" : "messages"
        if counts.sealedButFailed > 0 && counts.plaintextExplicit + counts.plaintextLegacy == 0 {
            return "\(n) \(noun) couldn't be decrypted"
        }
        if counts.plaintextLegacy > 0 {
            return "\(n) \(noun) sent unencrypted"
        }
        return "\(n) \(noun) not E2EE"
    }

    private func recompute() async {
        let snapshot = await MessageEncryptionStatusStore.shared.allStatuses()
        var c = Counts()
        for id in visibleMessageIds {
            switch snapshot[id] {
            case .plaintextExplicit: c.plaintextExplicit += 1
            case .plaintextLegacy: c.plaintextLegacy += 1
            case .sealedButFailed: c.sealedButFailed += 1
            default: break
            }
        }
        await MainActor.run {
            withAnimation { self.counts = c }
        }
    }
}
