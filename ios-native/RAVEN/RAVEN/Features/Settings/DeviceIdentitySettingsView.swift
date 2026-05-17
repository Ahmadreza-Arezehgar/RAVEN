//
//  DeviceIdentitySettingsView.swift
//  RAVEN
//
//  Settings view for device identity and trusted devices
//

import SwiftUI

struct DeviceIdentitySettingsView: View {
    @State private var fingerprint: String = ""
    @State private var trustedDevices: [FriendDevice] = []
    @State private var showingPairing = false
    @State private var isLoading = true
    @State private var isCopied = false
    
    var body: some View {
        List {
            // Local Identity
            localIdentitySection
            
            // Pairing
            pairingSection
            
            // Trusted Devices
            trustedDevicesSection
        }
        .navigationTitle("Device Identity")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPairing) {
            PairingView()
        }
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
    }
    
    // MARK: - Local Identity Section
    
    private var localIdentitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Fingerprint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if !fingerprint.isEmpty {
                    Text(fingerprint)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                } else {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
            
            if !fingerprint.isEmpty {
                Button {
                    UIPasteboard.general.string = fingerprint
                    Haptics.success()
                    
                    withAnimation { isCopied = true }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { isCopied = false }
                    }
                } label: {
                    Label(
                        isCopied ? "Copied!" : "Copy Fingerprint",
                        systemImage: isCopied ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .foregroundStyle(isCopied ? .green : .blue)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Your Device")
        } footer: {
            Text("This fingerprint uniquely identifies your device for secure mesh messaging. Share it with friends to enable offline communication.")
        }
    }
    
    // MARK: - Pairing Section
    
    private var pairingSection: some View {
        Section {
            Button {
                showingPairing = true
            } label: {
                Label("Pair with Friend", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Offline Pairing")
        } footer: {
            Text("Pair devices via Bluetooth to exchange messages without internet.")
        }
    }
    
    // MARK: - Trusted Devices Section
    
    private var trustedDevicesSection: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if trustedDevices.isEmpty {
                ContentUnavailableView(
                    "No Trusted Devices",
                    systemImage: "person.2.slash",
                    description: Text("Pair with friends to add trusted devices")
                )
            } else {
                ForEach(trustedDevices) { device in
                    trustedDeviceRow(device)
                }
                .onDelete(perform: deleteDevices)
            }
        } header: {
            Text("Trusted Devices (\(trustedDevices.count))")
        }
    }
    
    // MARK: - Device Row
    
    private func trustedDeviceRow(_ device: FriendDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceName ?? "Unknown Device")
                    .font(.headline)
                
                Text(device.fingerprint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if let verifiedAt = device.verifiedAt {
                    Text("Verified \(verifiedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            trustStateIndicator(device.trustState)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task {
                    try? await FriendDeviceRepository.shared.revokeDevice(device.fingerprint)
                    await loadData()
                }
            } label: {
                Label("Revoke", systemImage: "xmark.shield")
            }
        }
    }
    
    // MARK: - Trust State Indicator
    
    @ViewBuilder
    private func trustStateIndicator(_ state: TrustState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        case .unverified:
            // 2026-05-10: TOFU first-seen — yellow exclamation so the
            // user knows they should verify via Safety Number.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .trusted:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
        case .revoked:
            Image(systemName: "xmark.shield.fill")
                .foregroundStyle(.red)
        }
    }
    
    // MARK: - Actions
    
    private func loadData() async {
        fingerprint = DeviceIdentityService.shared.fingerprint ?? ""
        trustedDevices = await FriendDeviceRepository.shared.getAllTrustedDevices()
        isLoading = false
    }
    
    private func deleteDevices(at offsets: IndexSet) {
        // Capture devices synchronously to prevent index-out-of-bounds in async Task
        let devicesToDelete = offsets.map { trustedDevices[$0] }
        
        Task {
            for device in devicesToDelete {
                try? await FriendDeviceRepository.shared.deleteDevice(device.fingerprint)
            }
            await loadData()
        }
    }
}

#Preview {
    NavigationStack {
        DeviceIdentitySettingsView()
    }
}
