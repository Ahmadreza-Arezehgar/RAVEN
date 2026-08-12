//
//  RavenServerlessLanSettingsView.swift
//  RAVEN — minimal Debug UI for serverless LAN ↔ raven-node.
//
//  Gated by FeatureFlag.ravenEnvelopeV1. Stores only host / port / peer
//  public-key hex (never seeds or private keys). Status lines show
//  address/fingerprint fragments only.
//

import SwiftUI

struct RavenServerlessLanSettingsView: View {
    @State private var flagEnabled = FeatureFlag.ravenEnvelopeV1.isEnabled
    @State private var host: String = ""
    @State private var portText: String = "7420"
    @State private var listenPortText: String = "0"
    @State private var peerPubHex: String = ""
    @State private var statusMessage: String?
    @State private var localFingerprint: String = ""
    @State private var localPubHex: String = ""
    @State private var copiedLocalPub = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $flagEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FeatureFlag.ravenEnvelopeV1.displayName)
                            .font(.body.weight(.semibold))
                        Text(FeatureFlag.ravenEnvelopeV1.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.blue)
                .onChange(of: flagEnabled) { _, newValue in
                    FeatureFlag.ravenEnvelopeV1.setEnabled(newValue)
                    if newValue {
                        RavenEnvelopeBridgeService.shared.start()
                        RavenEnvelopeChatWire.shared.start()
                    } else {
                        RavenEnvelopeBridgeService.shared.stop()
                        RavenEnvelopeChatWire.shared.stop()
                    }
                    statusMessage = newValue
                        ? "Flag on — MeshEnvelope path stays active; LAN is parallel."
                        : "Flag off — LAN path idle; MeshEnvelope only."
                }
            } header: {
                Text("Feature flag")
            } footer: {
                Text("Default OFF. Turn ON for Discover + paste ash whoami / rvn1…. When on, MessageRouter may also TCP-frame sealed bytes to the peer below. Chat BLE/server paths are unchanged.\n\nبرای Discover و چسباندن whoami این فلگ را روشن کنید.")
            }

            Section {
                LabeledContent("Fingerprint") {
                    Text(localFingerprint.isEmpty ? "—" : localFingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !localPubHex.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ed25519 pub (hex) — paste into raven-node --peer-pub-hex")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(localPubHex)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            SecurePasteboard.copy(localPubHex)
                            copiedLocalPub = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedLocalPub = false
                            }
                        } label: {
                            Label(
                                copiedLocalPub ? "Copied" : "Copy pub hex",
                                systemImage: copiedLocalPub ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                        }
                    }
                }
            } header: {
                Text("This device (public only)")
            } footer: {
                Text("Never share seeds or private keys. Terminal demos need only this pub hex and the node’s pub_hex.")
            }

            Section {
                TextField("Host (LAN IP or 127.0.0.1)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                TextField("Port", text: $portText)
                    .keyboardType(.numberPad)
                TextField("Listen port (0=off, LAN→BLE reverse)", text: $listenPortText)
                    .keyboardType(.numberPad)
                TextField("Peer pub hex (64 chars)", text: $peerPubHex)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                if let fp = Self.fingerprint(ofPubHex: peerPubHex) {
                    LabeledContent("Peer fingerprint") {
                        Text(fp)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("raven-node endpoint")
            } footer: {
                Text("Peer pub is the node’s public Ed25519 from `raven-node init` (pub_hex=…). Host is the Mac’s LAN IP when testing a physical phone.")
            }

            Section {
                Button("Save LAN config") {
                    saveConfig()
                }
                .disabled(!canSave)

                if RavenServerlessLanConfig.stored != nil {
                    Button("Clear LAN config", role: .destructive) {
                        RavenServerlessLanConfig.clear()
                        host = ""
                        portText = "7420"
                        listenPortText = "0"
                        peerPubHex = ""
                        statusMessage = "Cleared. LAN path will not attempt sends."
                        RavenEnvelopeBridgeService.shared.stop()
                        if FeatureFlag.isRavenEnvelopeV1Enabled {
                            RavenEnvelopeBridgeService.shared.start()
                            RavenEnvelopeChatWire.shared.start()
                        } else {
                            RavenEnvelopeChatWire.shared.stop()
                        }
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Ready when: flag ON + valid host/port/peer pub saved. Send any chat message — Mesh jobs still run; LAN is best-effort ACK from raven-node.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Smoke checklist")
            }
        }
        .navigationTitle("Serverless LAN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        guard flagEnabled else { return false }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              let port = UInt16(portText), port > 0,
              Self.isValidPubHex(peerPubHex) else { return false }
        return true
    }

    private func load() {
        flagEnabled = FeatureFlag.ravenEnvelopeV1.isEnabled
        if let stored = RavenServerlessLanConfig.stored {
            host = stored.host
            portText = String(stored.port)
            listenPortText = String(stored.listenPort)
            peerPubHex = stored.peerPubHex
        }
        localFingerprint = DeviceIdentityService.shared.fingerprint ?? ""
        if let pub = DeviceIdentityService.shared.publicKeyData {
            localPubHex = pub.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func saveConfig() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = peerPubHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let port = UInt16(portText), port > 0, Self.isValidPubHex(hex) else {
            statusMessage = "Invalid host, port, or peer pub hex."
            return
        }
        let listenPort = UInt16(listenPortText) ?? 0
        let cfg = RavenServerlessLanConfig(
            host: trimmedHost,
            port: port,
            peerPubHex: hex,
            listenPort: listenPort
        )
        cfg.save()
        peerPubHex = hex
        let peerFp = Self.fingerprint(ofPubHex: hex) ?? "—"
        statusMessage = "Saved \(trimmedHost):\(port) listen=\(listenPort) · peer \(peerFp). No secrets stored."
        RavenEnvelopeBridgeService.shared.stop()
        RavenEnvelopeBridgeService.shared.start()
        if FeatureFlag.isRavenEnvelopeV1Enabled {
            RavenEnvelopeChatWire.shared.start()
        }
    }

    static func isValidPubHex(_ hex: String) -> Bool {
        let t = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count == 64 else { return false }
        return t.allSatisfy { $0.isHexDigit }
    }

    /// Public-only short fingerprint (same family as DeviceIdentityService).
    static func fingerprint(ofPubHex hex: String) -> String? {
        guard isValidPubHex(hex),
              let data = Self.data(fromHex: hex) else {
            return nil
        }
        return DeviceIdentityService.deriveFingerprint(from: data)
    }

    static func data(fromHex hex: String) -> Data? {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RavenServerlessLanSettingsView()
    }
}
#endif
