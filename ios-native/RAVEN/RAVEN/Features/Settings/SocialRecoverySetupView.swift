//
//  SocialRecoverySetupView.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — v1.7 NEXT: 3-of-5 social key recovery.
//
//  Discovery surface for the social recovery feature. The crypto
//  lives in `Core/Security/ShamirSecretSharing.swift` +
//  `Core/Security/SocialRecoveryService.swift`; this view is the
//  user-facing onboarding flow.
//
//  Flow (today):
//    1. Explainer screen — what social recovery is, why it matters.
//    2. "Generate sample shares" button — runs the math on a
//       fresh demo secret to demonstrate the primitive works and
//       to show what the user will be asked to share with friends.
//    3. Per-share row — index, byte count, envelope size, owner
//       fingerprint preview.
//    4. 🔴 v1.8 — "Run recovery simulation" exercises the real
//       `SocialRecoveryService.recoverVerified` VSS path end to
//       end: it unseals the shares, optionally tampers one,
//       reconstructs the key, and reports which contact (if any)
//       returned a corrupt share.
//
//  Flow (next round, gated by contact-picker work):
//    • Pick 5 trusted contacts from the friends list.
//    • Send each one their share via mesh (encrypted).
//    • Track quorum progress in `RecoveryStatusStore`.

import SwiftUI
import CryptoKit

struct SocialRecoverySetupView: View {

    // MARK: - State

    @State private var generated: [PreparedRecoveryShare] = []
    @State private var demoSecretPreview: String = ""
    @State private var lastError: String?
    @State private var isGenerating: Bool = false

    // 🔴 v1.8 — kept so the recovery simulation can unseal the
    // shares and check the reconstructed key. Demo data only: this
    // is a throwaway random secret, never the user's real key.
    @State private var demoSecret: Data = Data()
    @State private var demoContactKeys: [Curve25519.KeyAgreement.PrivateKey] = []
    @State private var tamperOneShare: Bool = true
    @State private var isRecovering: Bool = false
    @State private var recoverySim: RecoverySimResult?

    // MARK: - View

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                explainerCard
                generateButton
                if !generated.isEmpty {
                    sharesSection
                    recoverySection
                }
                if let err = lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle("Social Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Subviews

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("3-of-5 Social Recovery")
                    .font(.system(size: 18, weight: .semibold))
            }
            Text("Split your identity key into 5 encrypted shares — one per trusted contact. If you ever lose your phone AND your passphrase, any 3 of your 5 friends can help you recover. No copy of your key is ever stored on our servers.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Powered by Shamir Secret Sharing over GF(2⁸), per-contact ECIES (X25519 + HKDF + ChaChaPoly), and hash-commitment VSS — a tampered share is detected and rejected at recovery.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var generateButton: some View {
        Button {
            generateDemoShares()
        } label: {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .scaleEffect(0.85)
                        .tint(.white)
                }
                Text(isGenerating ? "Generating…" : "Generate Sample Shares")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.purple)
            )
            .foregroundStyle(.white)
        }
        .disabled(isGenerating)
    }

    private var sharesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("Sample secret hex (first 16 chars)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(demoSecretPreview)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

            Text("Each row below is ONE encrypted share. In a real setup, each row goes to a different trusted contact via mesh DM.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(Array(generated.enumerated()), id: \.offset) { idx, share in
                shareRow(index: idx + 1, prepared: share)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func shareRow(index: Int, prepared: PreparedRecoveryShare) -> some View {
        let env = prepared.envelope
        let fpHex = env.ownerFingerprint.prefix(6).map { String(format: "%02x", $0) }.joined()
        let envBytes = env.encode().count
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.18))
                Text("\(index)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.purple)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(prepared.contactUsername)
                    .font(.system(size: 14, weight: .semibold))
                Text("envelope \(envBytes) bytes · owner-fp \(fpHex)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Recovery simulation (🔴 v1.8 VSS)

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.purple)
                Text("Recovery Simulation")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("Runs the real verifiable-recovery path: unseal the shares, reconstruct the key, and check every share against its VSS commitment. A tampered share is rejected and its contact named.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Toggle(isOn: $tamperOneShare) {
                Text("Inject one tampered share (test VSS detection)")
                    .font(.system(size: 13, weight: .medium))
            }
            .tint(.purple)

            Button {
                runRecoverySimulation()
            } label: {
                HStack(spacing: 8) {
                    if isRecovering {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(.white)
                    }
                    Text(isRecovering ? "Recovering…" : "Run Recovery Simulation")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.purple.opacity(isRecovering ? 0.6 : 1))
                )
                .foregroundStyle(.white)
            }
            .disabled(isRecovering)

            if let sim = recoverySim {
                recoveryResultCard(sim)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func recoveryResultCard(_ sim: RecoverySimResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: sim.success ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(sim.success ? .green : .red)
                Text(sim.success ? "Identity Key Recovered" : "Recovery Failed")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(sim.success ? .green : .red)
            }

            if sim.success {
                resultLine(ok: true,
                           "\(sim.verifiedCount) share(s) passed VSS commitment checks")
                resultLine(ok: sim.secretMatched,
                           sim.secretMatched
                            ? "Reconstructed key matches the original"
                            : "Reconstructed key does NOT match the original")
                resultLine(ok: sim.commitmentVerified,
                           sim.commitmentVerified
                            ? "Cryptographically verified by VSS commitments"
                            : "Best-effort only — envelopes carried no commitments")
            }

            ForEach(sim.rejectedContacts, id: \.self) { name in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(name) returned a corrupt share — rejected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            Text(sim.message)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((sim.success ? Color.green : Color.red).opacity(0.08))
        )
    }

    private func resultLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func generateDemoShares() {
        isGenerating = true
        lastError = nil
        recoverySim = nil

        Task {
            do {
                // Demo secret = a fresh 32-byte random blob, the same
                // shape as a Curve25519 private key but not the user's
                // real one (we never expose the real key in this UI).
                var secret = Data(count: SocialRecoveryService.secretBytes)
                _ = secret.withUnsafeMutableBytes { buf in
                    SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
                }
                let preview = secret.prefix(8).map { String(format: "%02x", $0) }.joined()

                // Five placeholder contacts — fresh ephemeral
                // KeyAgreement pubkeys stand in for the real friends'
                // keys we'd fetch from PeerKeyDirectory in production.
                // The private keys are kept (demo only) so the recovery
                // simulation can unseal each share contact-side.
                var demoContacts: [TrustedRecoveryContact] = []
                var privKeys: [Curve25519.KeyAgreement.PrivateKey] = []
                for i in 1...5 {
                    let priv = Curve25519.KeyAgreement.PrivateKey()
                    privKeys.append(priv)
                    demoContacts.append(.init(
                        userId: "demo-user-\(i)",
                        username: "Demo Friend \(i)",
                        publicKey: priv.publicKey
                    ))
                }

                let prepared = try await SocialRecoveryService.shared.enrol(
                    secret: secret,
                    contacts: demoContacts
                )
                await MainActor.run {
                    self.demoSecret = secret
                    self.demoContactKeys = privKeys
                    self.demoSecretPreview = preview + "…"
                    self.generated = prepared
                    self.recoverySim = nil
                    self.isGenerating = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Failed: \(error.localizedDescription)"
                    self.isGenerating = false
                }
            }
        }
    }

    /// 🔴 v1.8 — exercises the production `recoverVerified` VSS path:
    /// unseal the demo shares contact-side, optionally tamper one,
    /// reconstruct the key, and report which contact (if any) returned
    /// a corrupt share.
    private func runRecoverySimulation() {
        guard !generated.isEmpty,
              demoContactKeys.count == generated.count else { return }
        isRecovering = true
        recoverySim = nil

        // Snapshot the inputs so the Task captures plain values.
        let shares = generated
        let keys = demoContactKeys
        let originalSecret = demoSecret
        let tamper = tamperOneShare

        Task {
            do {
                // 1. Contact-side: unseal each envelope with that
                //    contact's KeyAgreement private key.
                var returned: [ReturnedRecoveryShare] = []
                for (i, prep) in shares.enumerated() {
                    let share = try await SocialRecoveryService.unsealShare(
                        envelope: prep.envelope,
                        using: keys[i]
                    )
                    returned.append(ReturnedRecoveryShare(
                        share: share,
                        commitments: prep.envelope.commitments
                    ))
                }

                // 2. Optionally tamper exactly one returned share so
                //    the VSS layer has a corrupt share to catch.
                if tamper, !returned.isEmpty {
                    let t = Int.random(in: 0..<returned.count)
                    var bytes = [UInt8](returned[t].share.data)
                    bytes[0] ^= 0xFF
                    returned[t] = ReturnedRecoveryShare(
                        share: ShamirShare(
                            index: returned[t].share.index,
                            data: Data(bytes)
                        ),
                        commitments: returned[t].commitments
                    )
                }

                // 3. Run the real verified-recovery path.
                let ownerFP = shares[0].envelope.ownerFingerprint
                let outcome = try await SocialRecoveryService.shared.recoverVerified(
                    returned: returned,
                    ownerFingerprint: ownerFP,
                    k: 3
                )

                // 4. Map rejected share indices back to contact names.
                let rejectedNames: [String] = outcome.rejectedShareIndices.compactMap { idx in
                    shares.first { $0.envelope.shareIndex == idx }?.contactUsername
                }
                let matched = (outcome.secret == originalSecret)
                let verifiedCount = outcome.verifiedShareIndices.count
                let commitmentVerified = outcome.commitmentVerified

                await MainActor.run {
                    self.recoverySim = RecoverySimResult(
                        success: true,
                        secretMatched: matched,
                        commitmentVerified: commitmentVerified,
                        verifiedCount: verifiedCount,
                        rejectedContacts: rejectedNames,
                        message: matched
                            ? "Reconstructed from \(verifiedCount) verified share(s); any corrupt share was excluded automatically."
                            : "Reconstruction finished but the key did not match — investigate."
                    )
                    self.isRecovering = false
                }
            } catch {
                await MainActor.run {
                    self.recoverySim = RecoverySimResult(
                        success: false,
                        secretMatched: false,
                        commitmentVerified: false,
                        verifiedCount: 0,
                        rejectedContacts: [],
                        message: error.localizedDescription
                    )
                    self.isRecovering = false
                }
            }
        }
    }
}

/// Outcome of a `SocialRecoverySetupView` recovery simulation.
private struct RecoverySimResult {
    let success: Bool
    let secretMatched: Bool
    let commitmentVerified: Bool
    let verifiedCount: Int
    let rejectedContacts: [String]
    let message: String
}

#Preview {
    NavigationStack {
        SocialRecoverySetupView()
    }
}
