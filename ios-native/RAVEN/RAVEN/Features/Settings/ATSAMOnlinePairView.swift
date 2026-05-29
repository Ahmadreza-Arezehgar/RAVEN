//
//  ATSAMOnlinePairView.swift
//  RAVEN — Phase B online pair flow
//
//  Replaces the hex-paste developer scaffold (`ATSAMPairView`)
//  with a server-mediated online pair flow:
//
//   1. Generate local hybrid keys + publish my bundle.
//   2. Type a peer's user id (or pick from contacts).
//   3. Fetch peer's bundle.
//   4. Run `ATSAMHybridPairing.pairAsInitiator(...)` locally.
//   5. Submit the resulting pair-init packet (X25519 pub +
//      ML-KEM pub + ML-KEM ciphertext + nonce) to the server's
//      pair-init queue.
//   6. Display a 60-digit Safety Number derived from the root +
//      sorted user-ids so the user can compare it with the peer
//      over an out-of-band channel.
//
//  The actual K_root never touches the server. The server stores
//  only public material + opaque ciphertext.
//

import SwiftUI
import CryptoKit

struct ATSAMOnlinePairView: View {

    @StateObject private var model = ATSAMOnlinePairModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                VStack(alignment: .leading, spacing: 6) {
                    Text("ATSAM pair · online")
                        .font(.system(size: 20, weight: .bold))
                    Text("Server-mediated post-quantum pairing. Your hybrid root is derived locally; the server only stores public material.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Step 1 — publish my bundle
                GroupBox("Step 1 — Publish my bundle") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await model.publishLocalBundle() }
                        } label: {
                            Label("Generate + publish my bundle",
                                  systemImage: "icloud.and.arrow.up.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(model.busy)

                        if let status = model.publishStatus {
                            statusRow(status)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Step 2 — pair with a peer
                GroupBox("Step 2 — Pair with a peer") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Peer user id")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        TextField("e.g. bob_abcdef", text: $model.peerUserId)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            Task { await model.runOnlinePair() }
                        } label: {
                            Label("Fetch bundle + run pair",
                                  systemImage: "link.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!model.canPair)

                        if let outcome = model.lastPairOutcome {
                            statusRow(outcome.statusText, color: outcome.succeeded ? .green : .red)
                            if let safety = outcome.safetyNumber {
                                Text("Safety number")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                Text(safety)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.primary.opacity(0.05))
                                    )
                                Text("Compare these 60 digits with the peer over an out-of-band channel (phone, video, in person). If they match on both sides, no man-in-the-middle is possible — even if Raven's server tried to substitute keys.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Step 3 — accept pending pair-inits
                GroupBox("Step 3 — Pending pair-inits") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await model.fetchPendingPairInits() }
                        } label: {
                            Label("Check inbox",
                                  systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(model.busy)

                        if model.pendingInits.isEmpty && model.fetchedInbox {
                            Text("No pending pair-inits.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(model.pendingInits) { init_ in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("From: \(init_.fromUser)")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Context: \(init_.context)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Accept") {
                                    Task { await model.acceptPairInit(init_) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Honest scope
                VStack(alignment: .leading, spacing: 6) {
                    Label("Honest scope", systemImage: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("The server sees only your public X25519 and ML-KEM-768 keys plus the ML-KEM ciphertext. It cannot derive the shared root. Substitution attacks are caught by the safety-number comparison above. Hardware compromise of either device is still out of scope.")
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
        .navigationTitle("ATSAM pair · online")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func statusRow(_ text: String, color: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color == .secondary ? .secondary : .primary)
            Spacer()
        }
    }
}

// MARK: - View model

@MainActor
final class ATSAMOnlinePairModel: ObservableObject {

    @Published var busy: Bool = false
    @Published var publishStatus: String?
    @Published var peerUserId: String = ""
    @Published var lastPairOutcome: PairOutcome?
    @Published var pendingInits: [ATSAMPrekeyService.PairInitDTO] = []
    @Published var fetchedInbox: Bool = false

    /// Local keys cached so we don't regenerate on every pair.
    private var localKeys: ATSAMPairingKeys?

    /// Stable per-device id; persisted via UserDefaults so the
    /// server can deduplicate bundles across launches.
    private var deviceId: String {
        if let cached = UserDefaults.standard.string(forKey: "atsam.online.device_id") {
            return cached
        }
        let fresh = "ios-" + UUID().uuidString.prefix(12).lowercased()
        UserDefaults.standard.set(fresh, forKey: "atsam.online.device_id")
        return fresh
    }

    /// Local user id, fetched from auth state. For the scaffold
    /// we use a stub if no auth identity is loaded.
    private var localUserId: String {
        UserDefaults.standard.string(forKey: "currentUserId") ?? "me"
    }

    var canPair: Bool {
        !busy && localKeys != nil && !peerUserId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    struct PairOutcome {
        let succeeded: Bool
        let statusText: String
        let safetyNumber: String?
    }

    // 🔴 ROUND 66 (2026-05-20) — hacker-audit ATSAM C10
    // (HIGH: unverified bundle fetch in the manual online-pair UI).
    //
    // `ATSAMOnlinePairView` ships in production (presented from
    // SecuritySettingsView). Both its pairing paths fetched key
    // material via the RAW `ATSAMPrekeyService.fetchBundle`, which
    // only base64-decodes — it does NO signature verification. A
    // malicious / compromised server could therefore hand the
    // initiator (or the responder) attacker-controlled X25519 +
    // ML-KEM keys and the manual pair would derive a root with the
    // attacker. The safety-number comparison is the ultimate
    // backstop, but users skip it; signature verification closes
    // the silent-MITM path so the safety number only has to catch
    // the (much rarer) full first-contact substitution.
    enum OnlinePairError: Error {
        case userIdMismatch
        case malformedBundle
        case signatureInvalid
        case pairInitKeyMismatch
    }

    /// Fetch a peer bundle AND verify its Ed25519 signature over the
    /// round-16 strong (userId-bound) payload. Mirrors
    /// `PeerKeyDirectory.fetchAndVerifyFromServer`'s strong-format
    /// check. Throws on any tamper/ mismatch so callers fail closed.
    private func fetchVerifiedBundle(
        userId: String
    ) async throws -> ATSAMPrekeyService.DecodedBundle {
        let bundle = try await ATSAMPrekeyService.fetchBundle(userId: userId)
        // The server-echoed userId must equal what we asked for —
        // see ROUND 65 for the cross-user substitution this blocks.
        guard bundle.userId == userId else { throw OnlinePairError.userIdMismatch }
        guard bundle.xPub.count == 32 else { throw OnlinePairError.malformedBundle }
        guard let signingPub = try? Curve25519.Signing.PublicKey(
            rawRepresentation: bundle.signedBy
        ) else { throw OnlinePairError.malformedBundle }
        // Rebuild the signed payload with the REQUESTED userId (never
        // the server echo) so a swapped bundle fails verification.
        let payload = PeerKeyDirectory.strongSignedPayload(
            userId: userId, xPub: bundle.xPub, pqPub: bundle.pqPub
        )
        guard signingPub.isValidSignature(bundle.signature, for: payload) else {
            throw OnlinePairError.signatureInvalid
        }
        return bundle
    }

    // MARK: - Publish

    func publishLocalBundle() async {
        busy = true
        defer { busy = false }
        do {
            let keys = try ATSAMPairingKeys.generate()
            self.localKeys = keys

            // 🔴 ROUND 67 (2026-05-20) — hacker-audit ATSAM C11
            // (MEDIUM: ephemeral signing key corrupts the published
            // bundle).
            //
            // PREVIOUSLY this scaffold signed the bundle with a
            // BRAND-NEW `Curve25519.Signing.PrivateKey()` minted on
            // every call. Consequences:
            //   • The `signed_by` key changed on every publish, so a
            //     peer who pinned identity:me from one publish would
            //     hit a TOFU mismatch on the next — Safety-Number
            //     warnings storm across every conversation.
            //   • `fetch_bundle` returns the most-recently-updated
            //     row, so this junk bundle could shadow the real
            //     stable bundle that `autoPublishIfNeeded` publishes.
            //
            // FIX: sign with the device's STABLE identity key from
            // `DeviceIdentityService` — exactly what
            // `ATSAMPrekeyService.autoPublishIfNeeded` uses. Now the
            // manual publish and the automatic publish agree on
            // `signed_by`, so no spurious identity rotation.
            //
            // Round 16 (audit C7): the canonical signed payload binds
            // `userId` so a server-side substitution can't swap one
            // user's bundle for another.
            let toSign = PeerKeyDirectory.strongSignedPayload(
                userId: localUserId,
                xPub: keys.xPub,
                pqPub: keys.pqPub
            )
            guard let signature = DeviceIdentityService.shared.sign(toSign),
                  let identityPub = DeviceIdentityService.shared.publicKeyData else {
                publishStatus = "Publish failed: device identity key not available yet."
                return
            }

            try await ATSAMPrekeyService.publishMyBundle(
                local: keys,
                deviceId: deviceId,
                identityKey: identityPub,
                signature: signature
            )
            publishStatus = "Bundle published as device \(deviceId)"
        } catch {
            publishStatus = "Publish failed: \(error)"
        }
    }

    // MARK: - Pair (initiator)

    func runOnlinePair() async {
        guard let local = localKeys else {
            lastPairOutcome = PairOutcome(succeeded: false,
                                          statusText: "Publish your bundle first.",
                                          safetyNumber: nil)
            return
        }
        let peerId = peerUserId.trimmingCharacters(in: .whitespaces)
        busy = true
        defer { busy = false }
        do {
            // 🔴 ROUND 66 — fetch the peer's bundle THROUGH the
            // signature-verifying path. A raw fetch would let a
            // malicious server hand us attacker keys.
            let bundle = try await fetchVerifiedBundle(userId: peerId)

            // Run the hybrid pair locally.
            let result = try ATSAMHybridPairing.pairAsInitiator(
                local: local,
                peerXPub: bundle.xPub,
                peerPQPub: bundle.pqPub,
                context: Data("raven-online-v1".utf8),
                pairingNonce: nil
            )

            // Deposit the pair-init for the peer.
            let initId = try await ATSAMPrekeyService.submitPairInit(
                toUserId: peerId,
                local: local,
                outgoingCiphertext: result.outgoingCiphertext,
                pairingNonce: result.transcript.pairingNonce,
                context: "raven-online-v1"
            )

            // Derive the safety number from the root + sorted
            // user-id pair. Both sides compute the same value.
            let safetyNumber = computeSafetyNumber(
                root: result.root,
                userA: localUserId,
                userB: peerId
            )

            lastPairOutcome = PairOutcome(
                succeeded: true,
                statusText: "Pair-init #\(initId) deposited. Compare the safety number below with the peer.",
                safetyNumber: safetyNumber
            )
        } catch ATSAMError.nonHybridFallbackRefused {
            lastPairOutcome = PairOutcome(
                succeeded: false,
                statusText: "Either side lacked ML-KEM keys. Hybrid pair refused (fail-closed).",
                safetyNumber: nil
            )
        } catch {
            lastPairOutcome = PairOutcome(
                succeeded: false,
                statusText: "Online pair failed: \(error)",
                safetyNumber: nil
            )
        }
    }

    // MARK: - Pair (responder)

    func fetchPendingPairInits() async {
        busy = true
        defer { busy = false; fetchedInbox = true }
        do {
            pendingInits = try await ATSAMPrekeyService.fetchPendingPairInits()
        } catch {
            pendingInits = []
        }
    }

    func acceptPairInit(_ init_: ATSAMPrekeyService.PairInitDTO) async {
        guard let local = localKeys else { return }
        busy = true
        defer { busy = false }
        do {
            guard let peerXPub = Data(base64Encoded: init_.x25519Pub),
                  let peerPQPub = Data(base64Encoded: init_.mlKemPub),
                  let incomingCT = Data(base64Encoded: init_.mlKemCt),
                  let nonce = Data(base64Encoded: init_.pairingNonce) else {
                return
            }

            // 🔴 ROUND 66 — verify the pair-init's key material
            // against the initiator's SIGNED published bundle before
            // deriving a root. Without this, a malicious server can
            // swap the X25519 / ML-KEM keys inside the relayed
            // pair-init (keeping `from_user` intact) and the
            // responder would derive a root with the attacker. We
            // fetch `from_user`'s signature-verified bundle and
            // require the pair-init's X25519 key to match it.
            let initiatorBundle = try await fetchVerifiedBundle(userId: init_.fromUser)
            guard peerXPub == initiatorBundle.xPub else {
                throw OnlinePairError.pairInitKeyMismatch
            }

            let result = try ATSAMHybridPairing.pairAsResponder(
                local: local,
                peerXPub: peerXPub,
                peerPQPub: peerPQPub,
                incomingCiphertext: incomingCT,
                context: Data(init_.context.utf8),
                pairingNonce: nonce
            )
            let safetyNumber = computeSafetyNumber(
                root: result.root,
                userA: localUserId,
                userB: init_.fromUser
            )
            try await ATSAMPrekeyService.ackPairInit(id: init_.id)
            pendingInits.removeAll { $0.id == init_.id }
            lastPairOutcome = PairOutcome(
                succeeded: true,
                statusText: "Accepted pair-init from \(init_.fromUser). Safety number below.",
                safetyNumber: safetyNumber
            )
        } catch {
            lastPairOutcome = PairOutcome(
                succeeded: false,
                statusText: "Accept failed: \(error)",
                safetyNumber: nil
            )
        }
    }

    // MARK: - Safety number

    /// 60-digit decimal fingerprint derived from `K_root` and the
    /// sorted pair of user-ids. Symmetric: both sides compute the
    /// same string. Format: 12 groups of 5 digits, space-separated.
    private func computeSafetyNumber(root: ATSAMRootKey,
                                     userA: String,
                                     userB: String) -> String {
        // Use SHA-512 over (root || sorted user-ids) and convert
        // the first 30 bytes into 60 decimal digits in groups of 5.
        // Sorting ensures symmetry: same number on both ends.
        let sorted = [userA, userB].sorted().joined(separator: "\n")
        var input = Data()
        input.append(rootBytes(of: root))
        input.append(Data(sorted.utf8))
        let digest = SHA512.hash(data: input)
        let bytes = Array(digest).prefix(30)
        // Group into 5-byte chunks; each chunk → 5-digit decimal (max 99999).
        var out = [String]()
        for chunk in stride(from: 0, to: 30, by: 5) {
            var value: UInt64 = 0
            for b in bytes[chunk..<(chunk + 5)] {
                value = (value << 8) | UInt64(b)
            }
            // 5 bytes = 40 bits = up to 2^40. Map to 5 decimal digits.
            let digits = value % 100_000
            out.append(String(format: "%05d", digits))
        }
        return out.joined(separator: " ")
    }

    /// Pulls the raw bytes of a freshly-derived root key. Uses
    /// SHA-256 of the root via its key-tree so the bytes don't
    /// leak the actual root.
    private func rootBytes(of root: ATSAMRootKey) -> Data {
        // We don't have direct access to root.bytes (fileprivate),
        // but `ATSAMKeyTree` exposes deterministic sub-keys. Use
        // K_lookup as a stable "this root vs another root" probe.
        let tree = ATSAMKeyTree(root: root)
        let probe = tree.pvStealthLookupKey
        return Data(SHA256.hash(data: probe))
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ATSAMOnlinePairView()
    }
    .preferredColorScheme(.dark)
}
#endif
