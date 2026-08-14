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
//   6. Display a 30-digit Safety Number derived from the root +
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
                                Text("Compare these 30 digits with the peer over an out-of-band channel (phone, video, in person). If they match on both sides, no man-in-the-middle is possible — even if Raven's server tried to substitute keys.")
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

    /// Local user id, bound into the pairing transcript.
    ///
    /// 🔴 2026-07-18 — this previously read `UserDefaults` key
    /// `"currentUserId"`, which NOTHING in the app ever writes, so it
    /// always evaluated to the literal `"me"`. Because
    /// `ATSAMTranscript` binds both user ids (round 26) and each side
    /// supplies them swapped, both peers hashed a transcript
    /// containing `"me"` in *their own* slot:
    ///
    ///   initiator → (userIdInitiator: "me",    userIdResponder: bob)
    ///   responder → (userIdInitiator: alice,   userIdResponder: "me")
    ///
    /// Different transcripts → different roots → every ATSAM message
    /// failed to decrypt. The manual pair path was dead on arrival.
    ///
    /// The bound id MUST be the same identity the messaging layer
    /// stamps as `senderId`, because `seal`/`unseal` look the root up
    /// by that id (`ATSAMMessageSealer.seal(senderUserId:…)`).
    /// `MessageService.currentUserId()` resolves it via
    /// `KeychainService`, so we read exactly that source and no other
    /// — a second fallback source could silently reintroduce the same
    /// divergence. Returns nil rather than a placeholder so callers
    /// fail closed.
    private func localUserId() async -> String? {
        guard let id = await KeychainService.shared.getUserId(),
              !id.isEmpty else { return nil }
        return id
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
        case identityKeyMismatch
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
        // 🔴 2026-07-18 — pin `signedBy` to the identity we ALREADY
        // trust for this peer.
        //
        // Without this the round-66 verification below is
        // self-referential: `signingPub` is built from `bundle.signedBy`
        // — a value the SERVER supplied in the same response — so a
        // malicious server simply mints its own Ed25519 key, signs a
        // payload binding the correct userId to ITS x25519/ML-KEM keys,
        // and every existing guard passes. The safety number is the
        // only backstop, and round 66's stated goal was precisely not
        // to depend on users comparing it.
        //
        // `PeerKeyDirectory` already persists a per-peer identity pin
        // and rejects rotation (`applyFetchedBundle`); this path just
        // never consulted it. No pin (genuine first contact) still
        // falls back to TOFU + safety number.
        if let pinned = await PeerKeyDirectory.shared.identityKey(for: userId),
           pinned != bundle.signedBy {
            throw OnlinePairError.identityKeyMismatch
        }
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
        // Resolve the identity BEFORE generating keys. `self.localKeys`
        // is what `runOnlinePair` / `acceptPairInit` subsequently pair
        // with, so rotating it and then bailing out would leave an
        // UNPUBLISHED keypair armed: we would pair with keys the peer
        // cannot fetch, while the peer binds our previously-published
        // public keys into the transcript — divergent roots, i.e. the
        // exact failure this fix exists to remove.
        guard let myId = await localUserId() else {
            publishStatus = "Publish failed: no local identity yet — finish sign-in first."
            return
        }
        do {
            let keys = try ATSAMPairingKeys.generate()

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
            //
            // 🔴 2026-07-18 — this bound the `"me"` placeholder (see
            // `localUserId()`), which made the manual publish path
            // actively destructive, not merely broken: a peer
            // verifying our bundle rebuilds this payload with our
            // REAL id (`fetchVerifiedBundle` above deliberately uses
            // the requested id, never the server echo), so the
            // signature could never verify — and because the server
            // returns the most-recently-updated row, publishing here
            // SHADOWED the correct bundle that
            // `ATSAMPrekeyService.autoPublishIfNeeded` had already
            // published under the real id. Resolve from the same
            // source auto-publish uses (see the guard at the top of
            // this function), and skip rather than publish an
            // unverifiable bundle.
            let toSign = PeerKeyDirectory.strongSignedPayload(
                userId: myId,
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
            // Arm the keypair for pairing ONLY once its public half is
            // actually published, so `runOnlinePair` / `acceptPairInit`
            // can never pair with keys the peer is unable to fetch.
            self.localKeys = keys
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
        // Fail closed: pairing under a placeholder identity derives a
        // root the peer can never reproduce. See `localUserId()`.
        guard let myId = await localUserId() else {
            lastPairOutcome = PairOutcome(
                succeeded: false,
                statusText: "No local identity yet — finish sign-in before pairing.",
                safetyNumber: nil
            )
            return
        }
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
                pairingNonce: nil,
                selfUserId: myId,
                peerUserId: peerId
            )

            // Deposit the pair-init for the peer.
            let initId = try await ATSAMPrekeyService.submitPairInit(
                toUserId: peerId,
                local: local,
                outgoingCiphertext: result.outgoingCiphertext,
                pairingNonce: result.transcript.pairingNonce,
                context: "raven-online-v1"
            )

            // 🔑 Persist the derived root so the ATSAM message sealer
            // actually activates for this peer. Without this the root is
            // discarded and `ATSAMMessageSealer.seal` always returns nil,
            // so every message silently falls back to the legacy path —
            // ATSAM never protects a live message. Keyed by the PEER's
            // userId, matching seal (root(for: recipientUserId)) and
            // unseal (root(for: senderUserId)).
            try await ATSAMRootStorage.shared.setRoot(
                result.root, transcript: result.transcript, for: peerId
            )
            // Register the peer for mesh identity resolution. Round-70+
            // senders ship `senderIdHash` with `senderId = ""`, and the
            // receiver recovers the id via `MeshIdentityResolver`. Its
            // map is otherwise populated only from our own sends, the
            // friends list, and self — so a peer paired here that we
            // have not yet messaged would resolve to "" and every
            // inbound ATSAM mesh message would fail with `.noSenderKey`
            // despite a perfectly correct root.
            await MeshIdentityResolver.shared.register(userId: peerId)

            // Derive the safety number from the root + sorted
            // user-id pair. Both sides compute the same value.
            let safetyNumber = computeSafetyNumber(
                root: result.root,
                userA: myId,
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
        // Fail closed: see `localUserId()`. The initiator binds our
        // real id in their transcript, so binding a placeholder here
        // guarantees a root mismatch.
        guard let myId = await localUserId() else {
            lastPairOutcome = PairOutcome(
                succeeded: false,
                statusText: "No local identity yet — finish sign-in before accepting a pair.",
                safetyNumber: nil
            )
            return
        }
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
            // 🔴 2026-07-18 — the ML-KEM half was NOT checked here.
            // `strongSignedPayload(userId:xPub:pqPub:)` covers `pqPub`
            // with the same Ed25519 signature we just verified, so a
            // server that swaps `ml_kem_pub` inside the relayed
            // pair-init was previously accepted. The transcript binds
            // pkAPQ, so a swap already fails closed via root
            // divergence — but only AFTER we decapsulate toward the
            // substituted key, which hands the attacker Z_PQ and
            // voids the harvest-now-decrypt-later guarantee that is
            // the entire point of the PQ half. Reject up front, and
            // report a precise error instead of a silent dead pair.
            guard peerPQPub == initiatorBundle.pqPub else {
                throw OnlinePairError.pairInitKeyMismatch
            }

            let result = try ATSAMHybridPairing.pairAsResponder(
                local: local,
                peerXPub: peerXPub,
                peerPQPub: peerPQPub,
                incomingCiphertext: incomingCT,
                context: Data(init_.context.utf8),
                pairingNonce: nonce,
                selfUserId: myId,
                peerUserId: init_.fromUser
            )
            let safetyNumber = computeSafetyNumber(
                root: result.root,
                userA: myId,
                userB: init_.fromUser
            )

            // 🔑 Persist the derived root so the ATSAM sealer activates
            // for this peer. Keyed by the PEER's userId (init_.fromUser)
            // so unseal (root(for: senderUserId)) finds it on receive and
            // seal (root(for: recipientUserId)) finds it on reply.
            try await ATSAMRootStorage.shared.setRoot(
                result.root, transcript: result.transcript, for: init_.fromUser
            )
            // See the initiator path: without this the peer's
            // `senderIdHash` cannot be resolved on inbound mesh frames.
            await MeshIdentityResolver.shared.register(userId: init_.fromUser)

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

    /// 30-digit decimal fingerprint: SIX groups of five, space-separated.
    ///
    /// 🔴 2026-07-19 — this comment said "60-digit / 12 groups" and was WRONG.
    /// The loop below is `stride(from: 0, to: 30, by: 5)`, i.e. six iterations
    /// consuming five bytes each. The stale figure had already propagated to
    /// the Settings row subtitle and to the public protocol page; both are now
    /// corrected to 30. Note this is a DIFFERENT fingerprint from
    /// `Core/Security/E2EE/SafetyNumbers` (groupCount = 12), which really is
    /// 60 digits — do not "unify" the two comments without changing the code.
    ///
    /// Derived from `K_root` (via the key tree, so the root bytes never enter
    /// the hash) and the sorted pair of user-ids. Symmetric: both sides
    /// compute the same string. Roughly 100 bits against second-preimage.
    private func computeSafetyNumber(root: ATSAMRootKey,
                                     userA: String,
                                     userB: String) -> String {
        // SHA-512 over (rootProbe || sorted user-ids); the first 30 bytes
        // become SIX groups of five decimal digits (30 digits total).
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
