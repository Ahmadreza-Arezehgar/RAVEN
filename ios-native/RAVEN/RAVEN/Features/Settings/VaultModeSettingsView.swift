//
//  VaultModeSettingsView.swift
//  RAVEN
//
//  Settings panel for PROXIMA-VAULT (PV) Vault Mode. Surfaces:
//   • The on/off toggle (via `FeatureFlag.proximaVault`).
//   • The PV-Stealth toggle (rotating envelope tags, Stage 9).
//   • A `PVPadUsageWarning` for each active pad-pair, so the user
//     gets visible advance notice when they need to re-pair.
//
//  Pad-cursor reads are currently driven by an in-memory sample
//  set. Once the pad store lands in the production pipeline, swap
//  `sampleCursors` for a real `PVPadStore.activeDirectionalCursors`
//  call.
//

import SwiftUI

struct VaultModeSettingsView: View {

    /// Placeholder cursors shown when no real pads are loaded. The
    /// view is intentionally tolerant of being rendered before any
    /// real pad has been provisioned so QA can sanity-check the UI
    /// in isolation.
    @State private var sampleCursors: [SamplePadCursor] = [
        SamplePadCursor(peer: "Alice (sample)", consumed: 12_000, capacity: 65_536),
        SamplePadCursor(peer: "Bob (sample)",   consumed: 54_500, capacity: 65_536),
        SamplePadCursor(peer: "Carol (sample)", consumed: 63_900, capacity: 65_536),
    ]

    /// Re-render trigger when toggles change.
    @State private var refreshTrigger: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Intro
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vault Mode")
                        .font(.system(size: 22, weight: .bold))
                    Text("One-time-pad protection for selected high-sensitivity text messages. Information-theoretic secrecy when strict pad conditions are met. Not intended for media or large attachments.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Toggles
                VaultToggleRow(
                    flag: .proximaVault,
                    refreshTrigger: $refreshTrigger
                )
                VaultToggleRow(
                    flag: .proximaVaultStealth,
                    refreshTrigger: $refreshTrigger
                )

                // Pad usage section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pad usage")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Each pad has a finite per-direction budget. When usage approaches the cap, plan an in-person re-pair before Vault Mode runs out.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(sampleCursors, id: \.peer) { sample in
                        PVPadUsageWarning(
                            consumed: sample.consumed,
                            capacity: sample.capacity,
                            peerLabel: sample.peer,
                            onPlanRepair: {
                                // Wired by a future pair-flow coordinator.
                            }
                        )
                    }
                }

                // Honest scope footer
                VStack(alignment: .leading, spacing: 6) {
                    Label("Honest scope", systemImage: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Vault Mode is for small text messages. It does not protect media. It does not hide that two devices are talking. Metadata unlinkability requires the PV-Stealth toggle above.")
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

                Spacer(minLength: 12)
            }
            .padding(16)
        }
        .navigationTitle("Vault Mode")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

private struct SamplePadCursor: Hashable {
    let peer: String
    let consumed: Int
    let capacity: Int
}

private struct VaultToggleRow: View {
    let flag: FeatureFlag
    @Binding var refreshTrigger: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: flag.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.purple)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.purple.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(flag.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { flag.isEnabled },
                set: { newValue in
                    flag.setEnabled(newValue)
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
        VaultModeSettingsView()
    }
    .preferredColorScheme(.dark)
}
#endif
