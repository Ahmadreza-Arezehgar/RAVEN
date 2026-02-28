//
//  BackgroundMeshSettingsView.swift
//  RAVEN
//
//  Settings UI for managing background mesh relay functionality.
//

import SwiftUI
import CoreLocation

struct BackgroundMeshSettingsView: View {
    @ObservedObject private var backgroundManager = BackgroundMeshManager.shared
    @ObservedObject private var bleEngine = BLEMeshEngine.shared
    
    @State private var showLocationPermissionAlert = false
    
    var body: some View {
        List {
            // MARK: - Status Section
            Section {
                HStack {
                    Image(systemName: backgroundManager.isBackgroundEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(backgroundManager.isBackgroundEnabled ? .green : .red)
                    Text("Background Relay")
                    Spacer()
                    Text(backgroundManager.isBackgroundEnabled ? "Active" : "Inactive")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("BLE Status")
                    Spacer()
                    Text(bleEngine.isScanning && bleEngine.isAdvertising ? "Active" : "Inactive")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Image(systemName: "person.2.fill")
                    Text("Connected Peers")
                    Spacer()
                    Text("\(bleEngine.connectedPeers.count)")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Current Status")
            }
            
            // MARK: - Enable Section
            Section {
                Toggle(isOn: Binding(
                    get: { backgroundManager.isBackgroundEnabled },
                    set: { newValue in
                        if newValue {
                            enableBackgroundRelay()
                        } else {
                            backgroundManager.stopBackgroundLocationAnchor()
                        }
                    }
                )) {
                    HStack {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundColor(.blue)
                        Text("Background Relay")
                    }
                }
                .tint(.blue)
            } header: {
                Text("Background Mode")
            } footer: {
                Text("When enabled, your device can relay messages for other RAVEN users even when the app is closed. This helps messages reach their destination faster.")
            }
            
            // MARK: - Statistics Section
            Section {
                HStack {
                    Text("Total Background Wakes")
                    Spacer()
                    Text("\(backgroundManager.totalBackgroundWakes)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Last Wake Reason")
                    Spacer()
                    Text(backgroundManager.lastWakeReason.rawValue.replacingOccurrences(of: "_", with: " "))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                
                if let lastWake = backgroundManager.lastWakeTime {
                    HStack {
                        Text("Last Wake Time")
                        Spacer()
                        Text(lastWake, style: .relative)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Statistics")
            }
            
            // MARK: - Info Section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(
                        icon: "battery.25",
                        title: "Battery Impact",
                        description: "Low (~2-5% per day)"
                    )
                    
                    InfoRow(
                        icon: "location.fill",
                        title: "Location Usage",
                        description: "Powers Live Location sharing and offline mesh relay"
                    )
                    
                    InfoRow(
                        icon: "lock.shield.fill",
                        title: "Privacy",
                        description: "No personal data is shared with other devices"
                    )
                }
                .padding(.vertical, 8)
            } header: {
                Text("About Background Relay")
            }
        }
        .navigationTitle("Background Mesh")
        .alert("Location Permission Required", isPresented: $showLocationPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Background relay requires 'Always' location permission. Please enable it in Settings.")
        }
    }
    
    private func enableBackgroundRelay() {
        let status = backgroundManager.locationAuthorizationStatus
        
        switch status {
        case .notDetermined:
            backgroundManager.requestLocationPermission()
            
        case .authorizedWhenInUse:
            // Need to upgrade to Always
            showLocationPermissionAlert = true
            
        case .authorizedAlways:
            backgroundManager.startBackgroundLocationAnchor()
            
        case .denied, .restricted:
            showLocationPermissionAlert = true
            
        @unknown default:
            break
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationView {
        BackgroundMeshSettingsView()
    }
}
