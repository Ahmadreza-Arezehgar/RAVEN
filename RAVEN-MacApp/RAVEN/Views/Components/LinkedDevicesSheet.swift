// LinkedDevicesSheet — list of devices paired to the account, with a
// revoke action so the user can sign out a phone / tablet remotely.

import SwiftUI

struct LinkedDevicesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [LinkedDevice] = []
    @State private var loading = true
    @State private var error: String?
    @State private var revoking: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Linked devices").font(.title3.weight(.bold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                if loading {
                    ProgressView().padding(40).frame(maxWidth: .infinity)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else if devices.isEmpty {
                    Text("No other devices linked.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(devices) { d in
                            DeviceRow(
                                device: d,
                                revoking: revoking.contains(d.id),
                                onRevoke: { Task { await revoke(d) } }
                            )
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 520)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do {
            devices = try await NetworkService.shared.linkedDevices()
        } catch {
            self.error = "Couldn't load linked devices."
            print("📱 [devices] load failed: \(error)")
        }
        loading = false
    }

    @MainActor
    private func revoke(_ device: LinkedDevice) async {
        revoking.insert(device.id)
        defer { revoking.remove(device.id) }
        do {
            try await NetworkService.shared.revokeLinkedDevice(deviceId: device.id)
            devices.removeAll { $0.id == device.id }
        } catch {
            print("📱 [devices] revoke failed: \(error)")
        }
    }
}

private struct DeviceRow: View {
    let device: LinkedDevice
    let revoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: glyph)
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .foregroundStyle(RavenColors.logoStart)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.deviceName ?? device.deviceModel ?? "Unknown device")
                        .font(.system(size: 14, weight: .semibold))
                    if device.isThisDevice {
                        Text("This device")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RavenColors.accent.opacity(0.25))
                            .foregroundStyle(RavenColors.accent)
                            .clipShape(Capsule())
                    }
                }
                if let os = device.deviceOs {
                    Text(os)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("Last seen \(relativeTime(device.lastSeenAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if !device.isThisDevice {
                Button(action: onRevoke) {
                    Text(revoking ? "…" : "Revoke")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(revoking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var glyph: String {
        let os = (device.deviceOs ?? "").lowercased()
        if os.contains("ios") || os.contains("iphone") { return "iphone" }
        if os.contains("ipad") { return "ipad" }
        if os.contains("mac") { return "laptopcomputer" }
        if os.contains("windows") { return "pc" }
        if os.contains("android") { return "candybarphone" }
        return "display"
    }

    private func relativeTime(_ d: Date) -> String {
        let diff = Date().timeIntervalSince(d)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        if diff < 604800 { return "\(Int(diff / 86400))d ago" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: d)
    }
}
