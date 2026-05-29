//
//  VaultLockSheet.swift
//  RAVEN
//
//  Bottom sheet for attaching a vault lock to a post or message.
//  Shows in post composer and chat composer.
//

import SwiftUI

struct VaultLockSheet: View {
    @Binding var vaultLock: VaultLock?
    @Environment(\.dismiss) private var dismiss
    
    @State private var resolution: Int = 7
    @State private var unlockDistance: Int = 1200
    @State private var hasTTL: Bool = false
    @State private var ttlHours: Int = 24
    @State private var isBurnable: Bool = false
    @State private var hasLocation: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                // Location status
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: hasLocation ? "location.fill" : "location.slash")
                            .foregroundStyle(hasLocation ? .green : .red)
                        
                        VStack(alignment: .leading) {
                            Text(hasLocation ? "Location detected" : "Location unavailable")
                                .font(.subheadline.weight(.medium))
                            Text("Content is only visible near your current location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                // Precision
                Section("Location Precision") {
                    Picker("Resolution", selection: $resolution) {
                        Text("City (~5km)").tag(5)
                        Text("Neighborhood (~1.2km)").tag(7)
                        Text("Street (~150m)").tag(9)
                    }
                    .pickerStyle(.segmented)
                }
                
                // TTL
                Section("Lock Duration") {
                    Toggle("Temporary Lock", isOn: $hasTTL)
                    
                    if hasTTL {
                        Picker("Duration", selection: $ttlHours) {
                            Text("1 hour").tag(1)
                            Text("6 hours").tag(6)
                            Text("24 hours").tag(24)
                            Text("7 days").tag(168)
                        }
                        .pickerStyle(.segmented)
                        
                        Text("After this period, the content will be visible to everyone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Burnable
                Section {
                    Toggle(isOn: $isBurnable) {
                        HStack {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text("One-Time View")
                                    .font(.subheadline)
                                Text("Content will be deleted after first unlock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                // Remove lock
                if vaultLock != nil {
                    Section {
                        Button(role: .destructive) {
                            vaultLock = nil
                            dismiss()
                        } label: {
                            Label("Remove Location Lock", systemImage: "lock.open")
                        }
                    }
                }
            }
            .navigationTitle("Location Lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyLock()
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasLocation)
                }
            }
            .task {
                hasLocation = LocationPrivacyService.shared.currentH3Cell(resolution: resolution) != nil
            }
        }
    }
    
    private func applyLock() {
        let expiresAt: Date? = hasTTL
            ? Date().addingTimeInterval(TimeInterval(ttlHours * 3600))
            : nil
        
        vaultLock = VaultLock.atCurrentLocation(
            resolution: resolution,
            unlockDistanceMeters: unlockDistance,
            expiresAt: expiresAt,
            isBurnable: isBurnable
        )
        dismiss()
    }
}
