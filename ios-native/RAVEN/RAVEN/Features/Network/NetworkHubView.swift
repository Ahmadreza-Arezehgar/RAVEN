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
                    Text("Network")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 8)

                    identityCard
                    bluetoothCard
                    lanCard
                    bridgeCard
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
                    Text("Identity")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let name = authService.currentUser?.displayName, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                Spacer()
                Button {
                    Haptics.light()
                    showMyQR = true
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(DS.violet.opacity(0.35)))
                }
                .accessibilityLabel("Show my QR code")
            }

            if localRavenAddress.isEmpty {
                Text("Serverless identity not initialized")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("rvn1 address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(localRavenAddress)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.primary)
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Bluetooth mesh card

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isBluetoothActive ? DS.accentSuccess : Color.gray)
                    .frame(width: 8, height: 8)
                Text("Bluetooth mesh")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(bluetoothStateText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
            Text("\(bleEngine.discoveredPeers.count) nearby device\(bleEngine.discoveredPeers.count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20))
    }

    private var isBluetoothActive: Bool {
        bleEngine.bluetoothState == .poweredOn && bleEngine.isScanning
    }

    private var bluetoothStateText: String {
        switch bleEngine.bluetoothState {
        case .poweredOn:
            return bleEngine.isScanning ? "Powered on · scanning" : "Powered on"
        case .poweredOff:
            return "Powered off"
        case .unauthorized:
            return "Not authorized"
        case .unsupported:
            return "Not supported on this device"
        case .resetting:
            return "Resetting"
        case .unknown:
            fallthrough
        @unknown default:
            return "Unknown"
        }
    }

    // MARK: - Serverless node (LAN) card

    private var lanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Serverless node (LAN)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(lanStatusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)

            NavigationLink("Configure") {
                RavenServerlessLanSettingsView()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.violetSoft)
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20))
    }

    private var lanStatusText: String {
        guard ravenFlagOn else { return "Flag off — LAN path idle" }
        if let lanHostPort {
            return "Flag on · \(lanHostPort)"
        }
        return "Flag on · no peer configured"
    }

    // MARK: - Internet bridge card

    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Internet bridge")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(bridgeStatusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
            Text(internetBridgeFlagOn ? "Feature flag: Enabled" : "Feature flag: Disabled")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20))
    }

    private var bridgeStatusText: String {
        guard internetBridgeFlagOn else { return "Disabled" }
        return bridgeConnected ? "Connected" : "Not connected"
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
