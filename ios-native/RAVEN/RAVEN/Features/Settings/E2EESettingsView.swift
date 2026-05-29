//
//  E2EESettingsView.swift
//  RAVEN
//
//  User-facing screen for the end-to-end encryption subsystem.
//  Owners can:
//   • flip the master kill switch (`E2EEMessageGateway.isEnabled`)
//   • see today's pre-key bundle status (signed pre-key id +
//     remaining one-time pre-key pool size)
//   • trigger a manual bundle re-publish if the server somehow lost it
//
//  Per-peer safety-number verification lives behind a chat-screen
//  link, not here — this screen is the global on/off + diagnostics.
//

import SwiftUI

struct E2EESettingsView: View {

    // MARK: - State

    @State private var isEnabled: Bool = E2EEMessageGateway.isEnabled
    @State private var spkId: UInt32? = nil
    @State private var opkRemaining: Int? = nil
    @State private var publishStatus: PublishStatus = .idle
    @State private var lastError: String? = nil

    enum PublishStatus { case idle, working, success, failure }

    // MARK: - Body

    var body: some View {
        List {
            statusSection
            atsamSection
            actionsSection
            aboutSection
        }
        .navigationTitle("End-to-End Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadStatus() }
        .refreshable { await loadStatus() }
    }

    // MARK: - ATSAM cross-link

    /// ATSAM is the layered security protocol that sits on top of
    /// E2EE. It's on by default and exposes its own toggle. This
    /// section gives users a clear path to manage it from the
    /// encryption screen so they don't have to hunt for it.
    private var atsamSection: some View {
        Section {
            NavigationLink {
                ATSAMSettingsView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "atom")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.purple)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.purple.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ATSAM Protocol")
                            .font(.system(size: 16, weight: .semibold))
                        Text(FeatureFlag.isATSAMEnabled
                             ? "On · post-quantum hybrid pairing active"
                             : "Off · new pairs fall back to Noise IK")
                            .font(.caption)
                            .foregroundStyle(FeatureFlag.isATSAMEnabled ? .green : .secondary)
                    }
                }
            }
        } header: {
            Text("ATSAM (extra layer)")
        } footer: {
            Text("ATSAM is Raven's production security protocol — post-quantum hybrid pairing on top of the Double Ratchet. It is on by default; tap above to manage or turn it off.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Encrypt 1-on-1 messages")
                        .font(.body)
                    Text(isEnabled
                         ? "Message bodies are sealed end-to-end. Even RAVEN's servers cannot read them."
                         : "Messages travel through the server in their existing protected form.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: isEnabled) { _, new in
                E2EEMessageGateway.setEnabled(new)
                Haptics.medium()
            }

            if isEnabled {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("Active — Double Ratchet (X3DH + AES-GCM)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text("End-to-end encryption only applies to 1-on-1 chats. Group chats and channels still use server-side protections.")
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            row(
                title: "Active Signed Pre-Key",
                value: spkId.map { "ID \($0)" } ?? "—"
            )
            row(
                title: "Available One-Time Pre-Keys",
                value: opkRemaining.map(String.init) ?? "—"
            )

            Button {
                Task { await republishBundle() }
            } label: {
                HStack {
                    Label(
                        publishStatus == .working ? "Re-publishing…" : "Re-publish My Bundle",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    Spacer()
                    if publishStatus == .working {
                        ProgressView().scaleEffect(0.7)
                    } else if publishStatus == .success {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if publishStatus == .failure {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(publishStatus == .working)

            if let err = lastError, publishStatus == .failure {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Bundle")
        } footer: {
            Text("Your bundle is what others use to start an encrypted conversation with you. The one-time keys are consumed as new conversations are opened — RAVEN tops them up automatically.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Protocol")
                Spacer()
                Text("X3DH + Double Ratchet")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Algorithms")
                Spacer()
                Text("X25519 / Ed25519 / AES-256-GCM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Forward Secrecy")
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack {
                Text("Post-Compromise Security")
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Implementation status: Phase 1 (messages). Identity verification (safety numbers) is available from each chat's details screen. Post-quantum hybrid is on the roadmap.")
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Data

    private func loadStatus() async {
        // Pull current pre-key bundle state. We read directly from
        // the local store rather than going to the server so the
        // screen stays useful offline.
        let store = RatchetSessionStore.shared
        let spk = try? await store.currentSignedPreKey()
        let count = (try? await store.unusedOneTimePreKeyCount()) ?? 0
        await MainActor.run {
            self.spkId = spk?.id
            self.opkRemaining = count
            self.isEnabled = E2EEMessageGateway.isEnabled
        }
    }

    private func republishBundle() async {
        await MainActor.run {
            publishStatus = .working
            lastError = nil
        }
        guard
            let userId = await KeychainService.shared.getUserId(),
            let deviceId = DeviceIdentityService.shared.fingerprint
        else {
            await MainActor.run {
                publishStatus = .failure
                lastError = "Sign-in or device identity not ready."
            }
            return
        }

        do {
            try await E2EENetworkProvider.shared.uploadOurBundle(
                userId: userId, deviceId: deviceId
            )
            await MainActor.run {
                publishStatus = .success
                Haptics.success()
            }
            await loadStatus()
        } catch {
            await MainActor.run {
                publishStatus = .failure
                lastError = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
