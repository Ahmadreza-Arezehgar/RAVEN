//
//  RavenServerlessLanSettingsView.swift
//  RAVEN — minimal Debug UI for serverless LAN ↔ raven-node.
//
//  Gated by FeatureFlag.ravenEnvelopeV1. Stores only host / port / peer
//  public-key hex (never seeds or private keys). Status lines show
//  address/fingerprint fragments only.
//

import SwiftUI
import Darwin
import UIKit

struct RavenServerlessLanSettingsView: View {
    @State private var flagEnabled = FeatureFlag.ravenEnvelopeV1.isEnabled
    @State private var host: String = ""
    @State private var portText: String = "7420"
    @State private var listenPortText: String = "7421"
    @State private var peerPubHex: String = ""
    @State private var statusMessage: String?
    @State private var localFingerprint: String = ""
    @State private var localPubHex: String = ""
    @State private var localRavenAddress: String = ""
    @State private var copiedLocalPub = false
    @State private var copiedWhoami = false

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
                .disabled(!FeatureFlag.canEnableRavenEnvelopeV1)
                .onChange(of: flagEnabled) { _, newValue in
                    FeatureFlag.ravenEnvelopeV1.setEnabled(newValue)
                    if FeatureFlag.isRavenEnvelopeV1Enabled {
                        RavenEnvelopeBridgeService.shared.start()
                        RavenEnvelopeChatWire.shared.start()
                        ATSAMLabEndpointHost.shared.start()
                    } else {
                        RavenEnvelopeBridgeService.shared.stop()
                        RavenEnvelopeChatWire.shared.stop()
                        ATSAMLabEndpointHost.shared.stop()
                    }
                    statusMessage = newValue
                        ? "Flag on — MeshEnvelope path stays active; LAN is parallel."
                        : "Flag off — LAN path idle; MeshEnvelope only."
                }
            } header: {
                Text("Feature flag")
            } footer: {
                Text(FeatureFlag.canEnableRavenEnvelopeV1
                    ? "Debug lab only. New sends are accepted only when the body is already authenticated ciphertext; plaintext and interim-demo bodies are refused."
                    : "Security hold: unavailable in production until indexed ATSAM sessions, private routing tags, and encrypted ACKs interoperate.")
            }

            Section {
                LabeledContent("Fingerprint") {
                    Text(localFingerprint.isEmpty ? "—" : localFingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !localRavenAddress.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Raven address (rvn1…)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(localRavenAddress)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if !localPubHex.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ed25519 pub (hex) — paste into raven-node --peer-pub-hex")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(localPubHex)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
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
                            if !localRavenAddress.isEmpty {
                                Button {
                                    SecurePasteboard.copy(ashWhoamiBlock)
                                    copiedWhoami = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        copiedWhoami = false
                                    }
                                } label: {
                                    Label(
                                        copiedWhoami ? "Copied" : "Copy whoami for ash",
                                        systemImage: copiedWhoami ? "checkmark.circle.fill" : "terminal"
                                    )
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("This device (public only)")
            } footer: {
                Text("Never share seeds or private keys. For Mac Terminal: Copy whoami for ash, then in ash menu 3 → a paste that block (not cargo / cd).\n\nTo receive Mac→phone messages: leave Raven open with this Host/Port saved — the app pulls the Mac queue over Wi‑Fi.")
            }

            Section {
                TextField("Host = Mac Wi‑Fi IP (e.g. 192.168.100.209)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                TextField("Port (Mac listen, usually 7420)", text: $portText)
                    .keyboardType(.numberPad)
                TextField("Listen port (7421=Mac can dial this phone)", text: $listenPortText)
                    .keyboardType(.numberPad)
                if let wifi = Self.wifiIPv4() {
                    LabeledContent("This iPhone Wi‑Fi IP") {
                        Text(wifi)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("On Mac ash after WAITING: paste \(wifi):7421 as LAN dial (or when prompted).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                TextField("Peer pub hex = Mac pub_hex from ash whoami", text: $peerPubHex)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                Button {
                    pasteMacEndpointFromClipboard()
                } label: {
                    Label("Paste Mac whoami / pub into Peer", systemImage: "doc.on.clipboard")
                }

                if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !Self.isValidPubHex(peerPubHex) {
                    Text("⚠️ Host and Peer pub are required — Save stays disabled until both are filled. Pull will not run.\nFA: Host = آی‌پی مک + Peer pub = pub_hex مک را پر کن و Save بزن.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let fp = Self.fingerprint(ofPubHex: peerPubHex) {
                    LabeledContent("Peer fingerprint") {
                        Text(fp)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Mac endpoint (required for Pull)")
            } footer: {
                Text("Host = Mac LAN IP. Peer pub = Mac `pub_hex` from ash whoami (not this phone’s pub). Listen 7421 lets Mac dial you if Pull fails.")
            }

            #if DEBUG
            Section {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "raven.lab.test_a") },
                    set: { UserDefaults.standard.set($0, forKey: "raven.lab.test_a") }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lab Test A unlock")
                            .font(.body.weight(.semibold))
                        Text("DEBUG only. Enables PairInit / indexed session path (same as RAVEN_LAB_TEST_A=1). Release stays fail-closed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)

                Button("Ensure lab cert + prekey") {
                    do {
                        _ = try ATSAMLabTrustStore.ensureLocalMaterial()
                        statusMessage = "Lab cert + prekey ready (Keychain)."
                    } catch {
                        statusMessage = "Lab material failed: \(error.localizedDescription)"
                    }
                }
                Button("Copy my lab cert JSON") {
                    do {
                        let json = try ATSAMLabTrustStore.exportLocalCertJSON()
                        SecurePasteboard.copy(json)
                        statusMessage = "Copied cert JSON — paste into Mac: ash lab import-peer-cert"
                    } catch {
                        statusMessage = "Export cert failed: \(error.localizedDescription)"
                    }
                }
                Button("Copy my lab prekey JSON") {
                    do {
                        let json = try ATSAMLabTrustStore.exportLocalPrekeyJSON()
                        SecurePasteboard.copy(json)
                        statusMessage = "Copied prekey JSON — paste into Mac: ash lab import-peer-prekey / prekey fetch --file"
                    } catch {
                        statusMessage = "Export prekey failed: \(error.localizedDescription)"
                    }
                }
                Button("Paste Mac cert JSON from clipboard") {
                    let clip = UIPasteboard.general.string ?? ""
                    do {
                        try ATSAMLabTrustStore.importPeerCertJSON(clip)
                        statusMessage = "Imported Mac device cert."
                    } catch {
                        statusMessage = "Import cert failed: \(error.localizedDescription)"
                    }
                }
            } header: {
                Text("Test A trust OOB (paste)")
            } footer: {
                Text("Exchange public cert + prekey JSON over the same Wi‑Fi lab only. Never paste private keys. After Accept, PairResponse uplinks to Mac:7420 automatically.")
            }
            #endif

            Section {
                Button("Save LAN config") {
                    saveConfig()
                }
                .disabled(!canSave)

                if RavenServerlessLanConfig.stored != nil {
                    Button {
                        Task {
                            let n = await RavenEnvelopeBridgeService.shared.pullMacQueueNow()
                            statusMessage = n > 0
                                ? "Pulled \(n) message(s) from Mac queue."
                                : "Pull done — 0 messages. Check: flag ON, Local Network Allow, Host=\(host) Port=\(portText), same Wi‑Fi. If iOS asked for Local Network — Allow."
                        }
                    } label: {
                        Label("Pull from Mac now", systemImage: "arrow.down.circle")
                    }

                    Button("Clear LAN config", role: .destructive) {
                        RavenServerlessLanConfig.clear()
                        host = ""
                        portText = "7420"
                        listenPortText = "7421"
                        peerPubHex = ""
                        statusMessage = "Cleared. LAN path will not attempt sends."
                        RavenEnvelopeBridgeService.shared.stop()
                        if FeatureFlag.isRavenEnvelopeV1Enabled {
                            RavenEnvelopeBridgeService.shared.start()
                            RavenEnvelopeChatWire.shared.start()
                            ATSAMLabEndpointHost.shared.start()
                        } else {
                            RavenEnvelopeChatWire.shared.stop()
                            ATSAMLabEndpointHost.shared.stop()
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

    /// ash-compatible public identity block (never a seed).
    private var ashWhoamiBlock: String {
        """
        address     \(localRavenAddress)
        fingerprint \(localFingerprint)
        pub_hex     \(localPubHex)
        """
    }

    private func load() {
        flagEnabled = FeatureFlag.ravenEnvelopeV1.isEnabled
        if let stored = RavenServerlessLanConfig.stored {
            host = stored.host
            portText = String(stored.port)
            listenPortText = stored.listenPort > 0 ? String(stored.listenPort) : "7421"
            peerPubHex = stored.peerPubHex
        } else {
            listenPortText = "7421"
        }
        localFingerprint = DeviceIdentityService.shared.fingerprint ?? ""
        if let pub = DeviceIdentityService.shared.publicKeyData {
            localPubHex = pub.map { String(format: "%02x", $0) }.joined()
            localRavenAddress = RavenAddressV1.encode(ed25519PublicKey: pub) ?? ""
        } else {
            localPubHex = ""
            localRavenAddress = ""
        }
    }

    private func saveConfig() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = peerPubHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let port = UInt16(portText), port > 0, Self.isValidPubHex(hex) else {
            statusMessage = "Invalid host, port, or peer pub hex."
            return
        }
        var listenPort = UInt16(listenPortText) ?? 0
        if listenPort == 0 { listenPort = 7421 }
        listenPortText = String(listenPort)
        let cfg = RavenServerlessLanConfig(
            host: trimmedHost,
            port: port,
            peerPubHex: hex,
            listenPort: listenPort
        )
        cfg.save()
        peerPubHex = hex
        let peerFp = Self.fingerprint(ofPubHex: hex) ?? "—"
        let phoneIp = Self.wifiIPv4() ?? "?"
        statusMessage = "Saved Mac \(trimmedHost):\(port) · phone listens :\(listenPort) · this IP \(phoneIp) · peer \(peerFp). Allow Local Network if asked."
        RavenEnvelopeBridgeService.shared.stop()
        RavenEnvelopeBridgeService.shared.start()
        if FeatureFlag.isRavenEnvelopeV1Enabled {
            RavenEnvelopeChatWire.shared.start()
        }
    }

    private func pasteMacEndpointFromClipboard() {
        let raw = UIPasteboard.general.string ?? ""
        let lower = raw.lowercased()
        // Prefer labeled pub_hex=… / pub_hex     …
        if let r = lower.range(of: #"pub_hex\s*[:=]?\s*([0-9a-f]{64})"#, options: .regularExpression) {
            let m = String(lower[r])
            if let hex = m.split(whereSeparator: { !$0.isHexDigit }).first(where: { $0.count == 64 }) {
                peerPubHex = String(hex)
            }
        } else if let hex = lower.split(whereSeparator: { !$0.isHexDigit }).first(where: { $0.count == 64 }) {
            peerPubHex = String(hex)
        }
        // Optional host from "192.168.x.x:7420"
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let hr = raw.range(of: #"\b(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?\b"#, options: .regularExpression) {
            let token = String(raw[hr])
            host = token.split(separator: ":").first.map(String.init) ?? token
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            host = "192.168.100.209"
        }
        if portText.isEmpty { portText = "7420" }
        statusMessage = Self.isValidPubHex(peerPubHex)
            ? "Pasted Peer pub. Confirm Host=\(host) Port=\(portText), then Save."
            : "Clipboard had no 64-char pub_hex. Copy Mac ash whoami first."
    }

    /// Best-effort Wi‑Fi IPv4 for Mac dial instructions (en0-style).
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("wlan") else { continue }
            let ret = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if ret == 0 {
                let ip = String(cString: hostname)
                if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                    return ip
                }
            }
        }
        return nil
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
