//
//  SecurityBadge.swift
//  RAVEN — ATSAM Stage 10 UI policy
//
//  A small, opinionated SwiftUI view that surfaces *which* ATSAM
//  security mode protects the current view / message. The five
//  modes mirror the public ATSAM overview (PDF §29):
//
//      Mode                    Suggested badge      Honest description
//      ────────────────────────────────────────────────────────────────────
//      Normal secure chat      Lock                 End-to-end encryption.
//      GhostLink discovery     Invisible signal     Finds trusted nearby
//                                                   devices without
//                                                   broadcasting username
//                                                   or phone number.
//      PV-RAW Vault            Diamond              One-time-pad protection
//                                                   when vault pad is
//                                                   available.
//      PV-Stealth              Ghost diamond        Rotating envelope tags
//                                                   that reduce metadata
//                                                   linkability.
//      Fallback                Shield               Strong computational
//                                                   encryption when the
//                                                   vault pad is not
//                                                   available.
//
//  The component reads the right copy + icon for each mode
//  directly from `SecurityBadgeMode`. Callers pass the mode they
//  determined upstream; this view does NOT decide policy itself.
//
//  This file is PURELY presentational. It does not modify any
//  cryptographic state, does not invoke the transport layer, and
//  does not log telemetry. Embedding `SecurityBadge` somewhere
//  cannot accidentally change Raven's security behaviour.
//

import SwiftUI

/// The five badge modes documented in the public ATSAM overview.
/// Naming is product-visible — each rawValue is what the in-app
/// localised string-table key resolves to.
enum SecurityBadgeMode: String, Sendable, CaseIterable, Identifiable {
    case lock
    case invisibleSignal
    case diamond
    case ghostDiamond
    case shield

    var id: String { rawValue }

    /// Short label that fits inside the badge capsule.
    var label: String {
        switch self {
        case .lock:            return "End-to-end"
        case .invisibleSignal: return "GhostLink"
        case .diamond:         return "Vault"
        case .ghostDiamond:    return "Vault · Stealth"
        case .shield:          return "Fallback"
        }
    }

    /// Honest, user-facing one-sentence description. Mirrors the
    /// "Suggested user-facing description" column of the public
    /// overview document. Localise via NSLocalizedString once the
    /// in-app string table catches up.
    var description: String {
        switch self {
        case .lock:
            return "End-to-end encrypted with modern computational cryptography."
        case .invisibleSignal:
            return "Finds trusted nearby devices without broadcasting your username or phone number."
        case .diamond:
            return "One-time-pad protection for selected text messages when a vault pad is available."
        case .ghostDiamond:
            return "Rotating envelope tags reduce metadata linkability across messages."
        case .shield:
            return "Strong computational encryption while a vault pad is unavailable."
        }
    }

    /// SF Symbol that renders inside the capsule. Picked to match
    /// the public badge naming without literally drawing a
    /// "diamond" (SF Symbols' diamond glyphs are inconsistent
    /// across iOS versions).
    var systemImage: String {
        switch self {
        case .lock:            return "lock.fill"
        case .invisibleSignal: return "antenna.radiowaves.left.and.right.slash"
        case .diamond:         return "rhombus.fill"
        case .ghostDiamond:    return "eye.slash.fill"
        case .shield:          return "shield.lefthalf.filled"
        }
    }

    /// Accent tint for the badge. The colour itself is not a
    /// security claim — the LABEL is. Colour is for at-a-glance
    /// recognition.
    var accent: Color {
        switch self {
        case .lock:            return Color(red: 0.30, green: 0.65, blue: 0.40)   // calm green
        case .invisibleSignal: return Color(red: 0.36, green: 0.55, blue: 0.95)   // calm blue
        case .diamond:         return Color(red: 0.65, green: 0.45, blue: 0.95)   // purple
        case .ghostDiamond:    return Color(red: 0.85, green: 0.55, blue: 0.95)   // pink-purple
        case .shield:          return Color(red: 0.85, green: 0.65, blue: 0.30)   // amber
        }
    }
}

/// Capsule-style badge used in chat headers and message bubbles
/// to show *which* protection class a given message belongs to.
struct SecurityBadge: View {
    let mode: SecurityBadgeMode

    /// Compact mode hides the trailing label and only shows the
    /// icon. Use for inline rendering inside message bubbles.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mode.accent)
            if !compact {
                Text(mode.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(mode.accent.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(mode.accent.opacity(0.40), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(mode.label) security mode"))
        .accessibilityHint(Text(mode.description))
    }
}

#if DEBUG
#Preview("Security badges") {
    VStack(alignment: .leading, spacing: 14) {
        ForEach(SecurityBadgeMode.allCases) { mode in
            HStack(spacing: 12) {
                SecurityBadge(mode: mode)
                SecurityBadge(mode: mode, compact: true)
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(20)
    .preferredColorScheme(.dark)
}
#endif
