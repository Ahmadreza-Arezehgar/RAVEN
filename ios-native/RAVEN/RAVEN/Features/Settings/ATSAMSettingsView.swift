//
//  ATSAMSettingsView.swift
//  RAVEN
//
//  Settings panel for the ATSAM feature flags. This view surfaces
//  `FeatureFlag.atsam`, `.proximaVault`, and `.proximaVaultStealth`
//  with their human-readable metadata, lets the user toggle each,
//  and links to the public ATSAM overview.
//
//  `.atsam` (the core protocol) defaults ON for every install —
//  it is Raven's production security protocol since v1.7. Users
//  can still toggle it off here if they want to fall back to the
//  pre-ATSAM Noise IK path for new pairs.
//
//  `.proximaVault` and `.proximaVaultStealth` default OFF and are
//  optional content-layer primitives — flipping them on enables
//  the matching cryptographic primitives but does NOT by itself
//  send PV-encrypted traffic; that requires conversation-level
//  opt-in in a separate UI.
//

import SwiftUI

struct ATSAMSettingsView: View {

    /// Flags we render in this panel. Keep narrow + ordered so the
    /// UI reads as "foundation, content, metadata".
    private let flagsInOrder: [FeatureFlag] = [
        .atsam,            // Stage 1: pairing root
        .proximaVault,     // PV v3.1.2 content layer
        .proximaVaultStealth, // PV-Stealth (rotating tags, Stage 9)
    ]

    @State private var refreshTrigger: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                // Top status pill — at-a-glance "ATSAM is on/off"
                // so users don't have to interpret the toggle row.
                HStack(spacing: 10) {
                    Circle()
                        .fill(FeatureFlag.isATSAMEnabled ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(FeatureFlag.isATSAMEnabled
                         ? "ATSAM is on — your messages use post-quantum hybrid pairing."
                         : "ATSAM is off — new pairs fall back to Noise IK.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((FeatureFlag.isATSAMEnabled ? Color.green : Color.gray).opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder((FeatureFlag.isATSAMEnabled ? Color.green : Color.gray).opacity(0.30), lineWidth: 1)
                )
                .id(refreshTrigger) // re-evaluates colour/text when toggle flips

                // Header explanation
                VStack(alignment: .leading, spacing: 8) {
                    Text("ATSAM is Raven's production security protocol. The core layer (hybrid pairing + key tree) is on by default. The two content-layer add-ons below are optional and ship off — turn them on only if you are actively testing them.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://raven-messager.com/atsam")!) {
                        HStack(spacing: 6) {
                            Text("Read the public ATSAM overview")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.22), lineWidth: 1)
                )

                // Per-flag rows
                VStack(spacing: 8) {
                    ForEach(Array(flagsInOrder.enumerated()), id: \.element.rawValue) { _, flag in
                        ATSAMFlagRow(flag: flag, refreshTrigger: $refreshTrigger)
                    }
                }

                // Honest scope footer
                VStack(alignment: .leading, spacing: 6) {
                    Label("Honest scope", systemImage: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("The ATSAM core layer is on by default — Raven uses it for new pair handshakes automatically. Toggling it off falls back to the pre-ATSAM Noise IK path for new pairs (existing sessions keep working). The two PV add-ons enable extra content-layer primitives; they do not by themselves send PV-encrypted traffic — that requires conversation-level opt-in in a separate UI.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }
            .padding(16)
        }
        .navigationTitle("ATSAM")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Single row

private struct ATSAMFlagRow: View {
    let flag: FeatureFlag
    @Binding var refreshTrigger: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: flag.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.purple)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(Color.purple.opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(flag.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { flag.isEnabled },
                set: { newValue in
                    flag.setEnabled(newValue)
                    // Force a redraw — feature flags persist via
                    // UserDefaults, which isn't @Published.
                    refreshTrigger &+= 1
                }
            ))
            .labelsHidden()
            .tint(.purple)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ATSAMSettingsView()
    }
    .preferredColorScheme(.dark)
}
#endif
