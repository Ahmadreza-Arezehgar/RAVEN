//
//  ATSAMMismatchBanner.swift
//  RAVEN
//
//  2026-05-16 — round 12 first cut.
//  2026-05-16 — ROUND 26 (rebranded "LegacyPeerBanner") —
//    user-requested redesign:
//      • Apple Liquid Glass capsule (`ravenGlass(in: Capsule())`)
//        instead of the older `.ultraThinMaterial` shim, so it
//        morphs with the chrome underneath.
//      • Friendly user-facing copy that explains WHAT the user
//        gives up when the peer is on the older RAVEN, not just
//        the protocol acronym ("ATSAM not active" → "این فرد
//        RAVEN قدیمی دارد").
//      • Auto-dismiss bumped from 8s to 10s per spec, with a
//        manual ✕ that suppresses for the rest of the session.
//
//  Visible at the top-right of a 1:1 conversation when the peer
//  is detected as a legacy / non-round-26 client. Detection sits
//  in three receive paths:
//    1. Server DM unseal — RVNP1 (admitted plaintext) or no magic
//       at all → `PeerProtocolCapabilityStore.record(.legacyClient)`
//    2. Mesh receive — `envelope.protocolVersion < 17`
//       (round 26 wires this up in `RAVENApp.handleMeshMessage`).
//    3. Mesh receive — incoming envelope's body unseals as
//       `.explicitPlaintext` / `.legacy` (same RVNP1 check, but
//       triggered by the mesh path's own unseal call).
//
//  The banner clears itself as soon as we receive a single sealed
//  message from the peer — i.e. they updated the app between
//  launches and the next ciphertext drops the warning.
//

import SwiftUI

struct ATSAMMismatchBanner: View {

    let peerUserId: String
    let peerDisplayName: String

    /// Read state lazily; the view observes `PeerProtocolBannerState`
    /// for per-peer change notifications.
    @State private var visible: Bool = false
    @State private var autoDismissTask: Task<Void, Never>? = nil

    // Observed once at view init; SwiftUI keeps the dependency
    // automatically because we read `bumps[peerUserId]` in body.
    private let bannerState = PeerProtocolBannerState.shared

    /// Auto-dismiss after this many seconds of being visible. Picked
    /// to be long enough that the user sees + reads it on first open
    /// of the conversation, short enough not to linger and crowd the
    /// message list.
    ///
    /// 🔴 ROUND 26 — user spec'd 10s exactly.
    private let autoDismissAfter: TimeInterval = 10

    var body: some View {
        // Touching this expression keeps `bannerState.bumps` in the
        // SwiftUI dependency graph so per-peer mutations re-render.
        _ = bannerState.bumps[peerUserId]

        return Group {
            if visible {
                capsule
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.45, dampingFraction: 0.82)),
                            removal: .opacity.animation(.easeOut(duration: 0.2))
                        )
                    )
            }
        }
        .task(id: peerUserId) {
            await refresh()
        }
        .task(id: bannerState.bumps[peerUserId] ?? 0) {
            await refresh()
        }
    }

    // MARK: - Capsule body

    /// Round-26 liquid-glass capsule. Layout reads left-to-right:
    ///
    ///   [⚠︎] [Title          ] [✕]
    ///       [Sub-text         ]
    ///
    /// The icon is a soft orange "older version" glyph. The X tap
    /// records a per-session dismissal so we don't badger the user.
    private var capsule: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.20))
                    .frame(width: 24, height: 24)
                Image(systemName: "arrow.up.circle.badge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Older RAVEN")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(peerDisplayName) hasn't updated — some E2EE features off")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Button {
                Haptics.light()
                dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .ravenGlass(in: Capsule(style: .continuous))
        // Hairline orange border so the warning still reads at a
        // glance against busy chat chrome under the glass.
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.orange.opacity(0.40), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 4)
        .frame(maxWidth: 260, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(peerDisplayName) is on an older RAVEN version. Some end-to-end encryption features are unavailable."))
        .accessibilityHint(Text("Auto-dismisses in \(Int(autoDismissAfter)) seconds. Double-tap the X to dismiss now."))
    }

    // MARK: - State sync

    private func refresh() async {
        let show = await PeerProtocolCapabilityStore.shared.shouldShowBanner(for: peerUserId)
        await MainActor.run {
            if show != visible {
                withAnimation { visible = show }
                if show {
                    scheduleAutoDismiss()
                } else {
                    autoDismissTask?.cancel()
                    autoDismissTask = nil
                }
            }
        }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        let after = autoDismissAfter
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation { visible = false }
            }
        }
    }

    private func dismissBanner() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        withAnimation { visible = false }
        Task.detached {
            await PeerProtocolCapabilityStore.shared.markDismissed(peerUserId)
        }
    }
}
