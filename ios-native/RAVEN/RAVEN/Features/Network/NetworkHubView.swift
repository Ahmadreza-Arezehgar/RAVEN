import SwiftUI
import CoreBluetooth

// MARK: - Network Hub View (Obsidian redesign — 3rd shell tab: Network)
//
// Read-mostly "whoami + mesh status" surface for the 4-tab shell
// (Contacts · Chats · Network · Settings). Deliberately does not introduce
// any new singletons/services — it only reads state already published by
// `BLEMeshEngine.shared`, `DeviceIdentityService.shared`,
// `RavenServerlessLanConfig.stored`, and `MeshBridge.transport`, the same
// surfaces `RavenServerlessLanSettingsView` (Settings → Serverless LAN)
// already exposes. Configuration itself still lives there; this screen
// only links into it.
struct NetworkHubView: View {
    @ObservedObject private var bleEngine = BLEMeshEngine.shared
    @State private var authService = AuthService.shared

    // Identity (public-only — same source as RavenServerlessLanSettingsView.load()).
    @State private var localFingerprint: String = ""
    @State private var localRavenAddress: String = ""

    // Serverless LAN (raven-node) — read-only mirror of RavenServerlessLanConfig.stored.
    @State private var lanHostPort: String?

    // Internet bridge — best-effort read of the active BridgeTransport.
    @State private var bridgeConnected = false

    @State private var showMyQR = false
    @State private var copiedAddress = false

    private let ravenFlagOn = FeatureFlag.isRavenEnvelopeV1Enabled
    private let internetBridgeFlagOn = FeatureFlag.isInternetBridgeEnabled

    var body: some View {
        ZStack {
            RavenScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // TERMINAL REDESIGN: path title + live cursor.
                    HStack(spacing: 8) {
                        Text("raven:~/net")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.mist)
                        BlinkingCursor(height: 18)
                            .padding(.top, 6)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)

                    identityCard
                    bluetoothCard
                    lanCard
                    bridgeCard

                    // Console prompt footer.
                    HStack(spacing: 6) {
                        Text("$")
                            .font(.system(.footnote, design: .monospaced, weight: .bold))
                            .foregroundStyle(DS.phosphor)
                        BlinkingCursor(height: 13)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, DS.bottomTabClearance)
            }
        }
        .navigationBarHidden(true)
        .task {
            await MainActor.run { refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { refresh() }
            }
        }
        .sheet(isPresented: $showMyQR) {
            MyQRCodeView()
        }
    }

    // MARK: - Identity card

    @ViewBuilder
    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("$ whoami")
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(DS.phosphor.opacity(0.8))
                    if let name = authService.currentUser?.displayName, !name.isEmpty {
                        Text(name)
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                            .foregroundStyle(DS.mist)
                    }
                }
                Spacer()
                Button {
                    Haptics.light()
                    showMyQR = true
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.phosphor)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                                .fill(DS.phosphor.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                                .strokeBorder(DS.hairline, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Show my QR code")
            }

            if localRavenAddress.isEmpty {
                Text("serverless identity not initialized")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("rvn1://address")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(localRavenAddress)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(DS.mist)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            UIPasteboard.general.string = localRavenAddress
                            Haptics.light()
                            copiedAddress = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedAddress = false
                            }
                        } label: {
                            Image(systemName: copiedAddress ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(copiedAddress ? DS.accentSuccess : .secondary)
                        }
                        .accessibilityLabel("Copy address")
                    }
                    if !localFingerprint.isEmpty {
                        Text(localFingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .ravenCard(padding: 0)
    }

    // MARK: - Bluetooth mesh card

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isBluetoothActive ? DS.accentSuccess : Color.gray)
                    .frame(width: 8, height: 8)
                    .shadow(color: isBluetoothActive ? DS.accentSuccess.opacity(0.7) : .clear, radius: 4)
                Text("mesh:bluetooth")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(DS.phosphor.opacity(0.8))
                Spacer()
            }
            Text(bluetoothStateText.lowercased())
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(DS.mist)
            Text("\(bleEngine.discoveredPeers.count) nearby device\(bleEngine.discoveredPeers.count == 1 ? "" : "s")")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .ravenCard(padding: 0)
    }

    private var isBluetoothActive: Bool {
        bleEngine.bluetoothState == .poweredOn
    }

    private var bluetoothStateText: String {
        switch bleEngine.bluetoothState {
        case .poweredOn:
            return bleEngine.isScanning ? "Active · scanning" : "Active"
        case .poweredOff:
            return "Bluetooth is off"
        case .unauthorized:
            return "No Bluetooth permission"
        case .unsupported:
            return "Not supported on this device"
        case .resetting, .unknown:
            return "Starting…"
        @unknown default:
            return "Starting…"
        }
    }

    // MARK: - Serverless node (LAN) card

    private var lanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("node:lan")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(DS.phosphor.opacity(0.8))

            Text(lanStatusText.lowercased())
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(DS.mist)

            NavigationLink("[ configure ]") {
                RavenServerlessLanSettingsView()
            }
            .font(.system(.footnote, design: .monospaced, weight: .semibold))
            .foregroundStyle(DS.phosphorSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .ravenCard(padding: 0)
    }

    private var lanStatusText: String {
        guard ravenFlagOn else { return "off" }
        if let lanHostPort {
            return lanHostPort
        }
        return "on · not configured"
    }

    // MARK: - Internet bridge card

    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(bridgeConnected ? DS.pathBlue : Color.gray)
                    .frame(width: 8, height: 8)
                    .shadow(color: bridgeConnected ? DS.pathBlue.opacity(0.7) : .clear, radius: 4)
                Text("bridge:internet")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(DS.phosphor.opacity(0.8))
                Spacer()
            }
            Text(bridgeStatusText.lowercased())
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(DS.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .ravenCard(padding: 0)
    }

    private var bridgeStatusText: String {
        guard internetBridgeFlagOn else { return "off" }
        return bridgeConnected ? "connected" : "idle"
    }

    // MARK: - Refresh (non-published sources only; BLE state updates via @Published)

    private func refresh() {
        localFingerprint = DeviceIdentityService.shared.fingerprint ?? ""
        if let pub = DeviceIdentityService.shared.publicKeyData {
            localRavenAddress = RavenAddressV1.encode(ed25519PublicKey: pub) ?? ""
        } else {
            localRavenAddress = ""
        }
        if let stored = RavenServerlessLanConfig.stored {
            lanHostPort = "\(stored.host):\(stored.port)"
        } else {
            lanHostPort = nil
        }
        bridgeConnected = MeshBridge.transport.isConnected
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        NetworkHubView()
    }
}
