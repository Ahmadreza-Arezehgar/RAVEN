//
//  ATSAMPairView.swift
//  RAVEN
//
//  Minimal scaffold for the ATSAM pair-provisioning flow. Drives
//  `ATSAMHybridPairing.pairAsInitiator` / `.pairAsResponder` from
//  user-pasted hex blobs. Replaces the camera + QR pipeline that
//  will land later — the cryptographic correctness is the same;
//  only the input mechanism differs.
//
//  This view is self-contained: it neither persists keys nor wires
//  them into Noise IK / mesh transport. A successful pair just
//  surfaces "pair succeeded, root derived" to the user. The
//  follow-on coordinator (out of scope here) is what stores the
//  resulting `ATSAMKeyTree` against the peer's profile.
//

import SwiftUI
import CryptoKit

// This developer scaffold has only a DEBUG-gated entry point
// (SecuritySettingsView), so the entire file is excluded from
// Release builds.
#if DEBUG

struct ATSAMPairView: View {

    @StateObject private var model = ATSAMPairModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                VStack(alignment: .leading, spacing: 6) {
                    Text("ATSAM pair (developer scaffold)")
                        .font(.system(size: 20, weight: .bold))
                    Text("Generates a hybrid root with X25519 + ML-KEM-768. The QR / NFC handshake UI is not in this build — paste the peer's public-key payload below to test the cryptographic path end-to-end.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Local key generation
                GroupBox("Step 1 — Generate your local keys") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            model.generateLocalKeys()
                        } label: {
                            Label("Generate fresh keypair", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)

                        if let xPub = model.localXPubHex {
                            KeyDisplayRow(label: "X25519 public", value: xPub)
                        }
                        if let pqPubHash = model.localPQPubHashHex {
                            KeyDisplayRow(label: "ML-KEM pub SHA-256[:16]", value: pqPubHash)
                        } else if model.localKeysReady {
                            Text("ML-KEM keys not available on this OS — pair will fall back to degraded mode if opted in.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Peer key input
                GroupBox("Step 2 — Paste peer's X25519 public (hex, 64 chars)") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.peerXPubHex)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        Toggle("Allow degraded fallback (no ML-KEM)", isOn: $model.allowFallback)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                // Pair button
                Button {
                    model.performInitiatorPair()
                } label: {
                    HStack {
                        Image(systemName: "link")
                        Text("Run ATSAM pair as initiator")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!model.canPair)

                // Result
                if let outcome = model.lastOutcome {
                    GroupBox("Result") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(outcome.succeeded ? .green : .red)
                                Text(outcome.headline)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(outcome.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let bbeKey = outcome.bbeKeyHash {
                                KeyDisplayRow(label: "K_BBE SHA-256[:16]", value: bbeKey)
                            }
                            if let liveKey = outcome.liveKeyHash {
                                KeyDisplayRow(label: "K_live SHA-256[:16]", value: liveKey)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("ATSAM pair")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - View model

@MainActor
final class ATSAMPairModel: ObservableObject {

    @Published var localKeysReady: Bool = false
    @Published var localXPubHex: String?
    @Published var localPQPubHashHex: String?
    @Published var peerXPubHex: String = ""
    @Published var allowFallback: Bool = false
    @Published var lastOutcome: Outcome?

    private var localKeys: ATSAMPairingKeys?

    struct Outcome: Equatable {
        let succeeded: Bool
        let headline: String
        let detail: String
        let bbeKeyHash: String?
        let liveKeyHash: String?
    }

    var canPair: Bool {
        localKeysReady && peerXPubHex.replacingOccurrences(of: " ", with: "").count == 64
    }

    func generateLocalKeys() {
        do {
            let keys = try ATSAMPairingKeys.generate()
            self.localKeys = keys
            self.localXPubHex = keys.xPub.hexPretty
            if !keys.pqPub.isEmpty {
                let hash = Data(SHA256.hash(data: keys.pqPub).prefix(16))
                self.localPQPubHashHex = hash.hexPretty
            } else {
                self.localPQPubHashHex = nil
            }
            self.localKeysReady = true
        } catch {
            self.localKeysReady = false
            self.localKeys = nil
            self.lastOutcome = Outcome(
                succeeded: false,
                headline: "Keygen failed",
                detail: String(describing: error),
                bbeKeyHash: nil,
                liveKeyHash: nil
            )
        }
    }

    func performInitiatorPair() {
        guard let local = localKeys else {
            lastOutcome = Outcome(
                succeeded: false,
                headline: "Run Step 1 first",
                detail: "Generate local keys before pairing.",
                bbeKeyHash: nil,
                liveKeyHash: nil
            )
            return
        }
        let cleaned = peerXPubHex.replacingOccurrences(of: " ", with: "")
        guard let peerXPub = Data(hexString: cleaned), peerXPub.count == 32 else {
            lastOutcome = Outcome(
                succeeded: false,
                headline: "Peer key invalid",
                detail: "Expected 64 hex characters (32 raw bytes).",
                bbeKeyHash: nil,
                liveKeyHash: nil
            )
            return
        }
        do {
            // Peer's ML-KEM key is not part of this scaffold yet —
            // pass empty + rely on degraded fallback if the user
            // opted in. The pair API enforces fail-closed when
            // fallback is NOT allowed.
            let result = try ATSAMHybridPairing.pairAsInitiator(
                local: local,
                peerXPub: peerXPub,
                peerPQPub: Data(),
                context: Data("raven-atsam-pair-scaffold".utf8),
                pairingNonce: nil,
                allowNonHybridFallback: allowFallback
            )
            let tree = ATSAMKeyTree(root: result.root)
            let bbeHash = Data(SHA256.hash(data: tree.bbeDiscoveryKey).prefix(16))
            let liveHash = Data(SHA256.hash(data: tree.ghostHandshakeKey).prefix(16))
            lastOutcome = Outcome(
                succeeded: true,
                headline: "Pair complete (root derived)",
                detail: allowFallback
                    ? "Degraded mode (X25519 only). Production callers should not opt in to this — the hybrid root is what gives post-quantum protection."
                    : "Hybrid root (X25519 + ML-KEM) derived. Both halves must fall before this root can be recovered.",
                bbeKeyHash: bbeHash.hexPretty,
                liveKeyHash: liveHash.hexPretty
            )
        } catch ATSAMError.nonHybridFallbackRefused {
            lastOutcome = Outcome(
                succeeded: false,
                headline: "Hybrid pair refused",
                detail: "Either side lacked ML-KEM keys. Opt in to fallback only for development testing.",
                bbeKeyHash: nil,
                liveKeyHash: nil
            )
        } catch {
            lastOutcome = Outcome(
                succeeded: false,
                headline: "Pair failed",
                detail: String(describing: error),
                bbeKeyHash: nil,
                liveKeyHash: nil
            )
        }
    }
}

// MARK: - Visual helpers

private struct KeyDisplayRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private extension Data {
    init?(hexString: String) {
        let s = hexString.unicodeScalars.filter { $0.isASCII }
            .reduce(into: "") { acc, scalar in acc.unicodeScalars.append(scalar) }
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard next <= s.endIndex,
                  let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }

    var hexPretty: String {
        let hex = self.map { String(format: "%02x", $0) }.joined()
        // Insert a thin space every 8 chars so it wraps nicely.
        var out = ""
        var i = 0
        for ch in hex {
            if i > 0 && i % 8 == 0 { out.append(" ") }
            out.append(ch)
            i += 1
        }
        return out
    }
}

#Preview {
    NavigationStack {
        ATSAMPairView()
    }
    .preferredColorScheme(.dark)
}

#endif // DEBUG
