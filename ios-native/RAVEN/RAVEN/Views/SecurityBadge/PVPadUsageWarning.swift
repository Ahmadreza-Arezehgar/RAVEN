//
//  PVPadUsageWarning.swift
//  RAVEN — ATSAM Stage 10 UI policy
//
//  Surfaces a clear, honest warning when a PROXIMA-VAULT pad is
//  running low. Vault Mode's whole guarantee depends on pad
//  conditions being met — one of those conditions is "pad slice
//  must be at least as long as the message" (per ATSAM §3.5).
//  If the user keeps sending vault messages until the pad is
//  exhausted, encryption falls back to standard AEAD silently,
//  which is a worse outcome than telling the user "your pad is
//  72% used, plan a re-pair soon".
//
//  This view is purely presentational. It does not modify the
//  pad cursor, the pad-store, or transport. It only reads a
//  usage ratio from the caller and renders the right level of
//  alarm.
//
//  Thresholds:
//    0–60%     hidden (no view rendered)
//    60–80%    info — quiet reminder
//    80–95%    warning — recommend re-pair on next encounter
//    95–100%   urgent — Vault Mode about to disable
//

import SwiftUI

/// Severity tiers for the pad-usage indicator.
enum PVPadUsageLevel: Sendable, Equatable {
    case quiet
    case info
    case warning
    case urgent

    /// Classify a (consumed / capacity) ratio in `[0.0, 1.0]`.
    static func from(ratio: Double) -> PVPadUsageLevel {
        switch ratio {
        case ..<0.60:  return .quiet
        case ..<0.80:  return .info
        case ..<0.95:  return .warning
        default:       return .urgent
        }
    }

    var accent: Color {
        switch self {
        case .quiet, .info: return Color(red: 0.36, green: 0.55, blue: 0.95)
        case .warning:      return Color(red: 0.95, green: 0.62, blue: 0.20)
        case .urgent:       return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }

    var systemImage: String {
        switch self {
        case .quiet, .info: return "info.circle.fill"
        case .warning:      return "exclamationmark.triangle.fill"
        case .urgent:       return "xmark.octagon.fill"
        }
    }

    var headline: String {
        switch self {
        case .quiet, .info: return "Vault pad usage"
        case .warning:      return "Vault pad running low"
        case .urgent:       return "Vault pad nearly exhausted"
        }
    }
}

/// Compact banner that surfaces pad usage with honest copy.
///
/// `consumed` and `capacity` are the raw counters maintained by
/// the pad cursor (number of messages already sent vs. the
/// per-direction message budget). The view computes the ratio and
/// picks the right severity tier.
struct PVPadUsageWarning: View {
    /// Number of messages already sent in this direction.
    let consumed: Int

    /// Per-direction message budget for the pad.
    let capacity: Int

    /// Optional human label for *which* pad this is, e.g. the
    /// peer's display name. Shown subtly under the headline.
    var peerLabel: String? = nil

    /// Caller-provided closure invoked when the user taps the
    /// "Plan re-pair" CTA. We intentionally do not embed
    /// navigation here — it depends on the host app's
    /// coordinator. Defaults to no-op.
    var onPlanRepair: () -> Void = {}

    private var ratio: Double {
        guard capacity > 0 else { return 0 }
        return Double(consumed) / Double(capacity)
    }

    private var level: PVPadUsageLevel {
        PVPadUsageLevel.from(ratio: ratio)
    }

    var body: some View {
        if level != .quiet {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: level.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(level.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(level.headline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(body(forLevel: level))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PVPadUsageBar(ratio: ratio, accent: level.accent)
                        .frame(height: 4)
                        .padding(.top, 4)
                    HStack(spacing: 8) {
                        Text("\(consumed) of \(capacity) messages")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        if let peerLabel = peerLabel {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text(peerLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                if level == .warning || level == .urgent {
                    Button(action: onPlanRepair) {
                        Text("Plan re-pair")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(level.accent.opacity(0.20))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(level.accent.opacity(0.45), lineWidth: 1)
                            )
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(level.accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(level.accent.opacity(0.30), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(level.headline). \(Int(ratio * 100)) percent of pad consumed."))
        }
    }

    private func body(forLevel level: PVPadUsageLevel) -> String {
        switch level {
        case .info:
            return "Vault pad has crossed 60% usage. Plenty of headroom for now."
        case .warning:
            return "Plan to re-pair in person before Vault Mode runs out. New pad material is exchanged side-by-side."
        case .urgent:
            return "Vault Mode will disable once the pad is exhausted. Schedule an in-person re-pair as soon as possible."
        case .quiet:
            return ""
        }
    }
}

/// Slim progress bar with a tinted fill. Pure SwiftUI; no
/// animation hooks so we don't accidentally consume CPU on
/// every cursor update.
struct PVPadUsageBar: View {
    let ratio: Double
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.15))
                Capsule()
                    .fill(accent.opacity(0.85))
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
            }
        }
    }
}

#if DEBUG
#Preview("Pad usage warnings") {
    VStack(spacing: 12) {
        PVPadUsageWarning(consumed: 40_000, capacity: 65_536, peerLabel: "Alice")
        PVPadUsageWarning(consumed: 55_000, capacity: 65_536, peerLabel: "Bob")
        PVPadUsageWarning(consumed: 64_000, capacity: 65_536, peerLabel: "Carol")
        // Quiet — renders nothing because ratio < 0.60.
        PVPadUsageWarning(consumed: 100, capacity: 65_536, peerLabel: "Dave")
    }
    .padding()
    .preferredColorScheme(.dark)
}
#endif
