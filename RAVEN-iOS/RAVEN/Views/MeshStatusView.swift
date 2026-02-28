// RAVEN - Mesh Status View
// Converted from Flutter mesh_status_screen.dart, nearby_people_portal.dart

import SwiftUI

struct MeshStatusView: View {
    @ObservedObject var meshService = MeshService.shared
    @ObservedObject var networkMonitor = NetworkMonitor.shared
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Status Card
                    statusCard
                    
                    // Nearby Peers
                    nearbyPeersSection
                    
                    // Statistics
                    statisticsSection
                }
                .padding()
            }
            .navigationTitle("Mesh Network")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Toggle("", isOn: Binding(
                        get: { meshService.isEnabled },
                        set: { newValue in
                            if newValue {
                                meshService.start()
                            } else {
                                meshService.stop()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(.ravenPrimary)
                }
            }
        }
    }
    
    // MARK: - Status Card
    var statusCard: some View {
        VStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(meshService.isEnabled ? Color.green.opacity(0.2) : Color(UIColor.systemGray5))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32))
                    .foregroundColor(meshService.isEnabled ? .green : .secondary)
            }
            
            // Status text
            VStack(spacing: 4) {
                Text(meshService.isEnabled ? "Mesh Active" : "Mesh Disabled")
                    .font(.headline)
                
                Text(meshService.isEnabled ? "Broadcasting and scanning for nearby peers" : "Enable to connect with nearby devices")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Connection info
            HStack(spacing: 24) {
                statusItem(value: "\(meshService.nearbyPeers.count)", label: "Nearby")
                Divider().frame(height: 30)
                statusItem(value: "\(meshService.connectedPeers.count)", label: "Connected")
                Divider().frame(height: 30)
                statusItem(value: networkMonitor.isConnected ? "Online" : "Offline", label: "Internet")
            }
        }
        .padding()
        .glassBackground()
    }
    
    @ViewBuilder
    func statusItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Nearby Peers
    var nearbyPeersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Nearby Peers")
                    .font(.headline)
                
                Spacer()
                
                if meshService.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if meshService.nearbyPeers.isEmpty {
                EmptyStateView(
                    icon: "person.2.wave.2",
                    title: "No Peers Found",
                    message: "Make sure other RAVEN users are nearby with mesh enabled"
                )
                .frame(height: 150)
            } else {
                ForEach(meshService.nearbyPeers) { peer in
                    peerRow(peer)
                }
            }
        }
    }
    
    @ViewBuilder
    func peerRow(_ peer: MeshPeer) -> some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.ravenPrimary.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "person.fill")
                    .foregroundColor(.ravenPrimary)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.subheadline.bold())
                
                HStack(spacing: 8) {
                    // Signal strength
                    signalBars(rssi: peer.rssi)
                    
                    Text(peer.lastSeen.timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Connection status
            if meshService.connectedPeers.contains(where: { $0.id == peer.id }) {
                BadgeCapsule(text: "Connected", color: .green, size: .small)
            } else {
                Button {
                    // Connect
                } label: {
                    Text("Connect")
                        .font(.caption.bold())
                        .foregroundColor(.ravenPrimary)
                }
            }
        }
        .padding()
        .glassBackground()
    }
    
    @ViewBuilder
    func signalBars(rssi: Int) -> some View {
        let strength = min(4, max(1, (rssi + 100) / 20))
        
        HStack(spacing: 2) {
            ForEach(1..<5) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= strength ? Color.ravenPrimary : Color(UIColor.systemGray4))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
    
    // MARK: - Statistics
    var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Statistics")
                .font(.headline)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(icon: "arrow.up.message", label: "Sent via Mesh", value: "0")
                statCard(icon: "arrow.down.message", label: "Received via Mesh", value: "0")
                statCard(icon: "arrow.triangle.swap", label: "Relayed", value: "0")
                statCard(icon: "clock", label: "Uptime", value: "0m")
            }
        }
    }
    
    @ViewBuilder
    func statCard(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.ravenPrimary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassBackground()
    }
}

// MARK: - Network Mode Toggle
struct NetworkModeToggle: View {
    @ObservedObject var meshService = MeshService.shared
    @ObservedObject var networkMonitor = NetworkMonitor.shared
    
    var body: some View {
        HStack(spacing: 12) {
            // Internet status
            HStack(spacing: 6) {
                Image(systemName: networkMonitor.statusIcon)
                    .foregroundColor(networkMonitor.isConnected ? .green : .red)
                
                Text(networkMonitor.isConnected ? "Online" : "Offline")
                    .font(.caption)
            }
            
            Divider().frame(height: 16)
            
            // Mesh status
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(meshService.isEnabled ? .ravenPrimary : .secondary)
                
                Text(meshService.isEnabled ? "Mesh On" : "Mesh Off")
                    .font(.caption)
            }
            
            if meshService.connectedPeers.count > 0 {
                BadgeCapsule(text: "\(meshService.connectedPeers.count)", color: .ravenPrimary, size: .small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackground(cornerRadius: 20)
    }
}

#Preview {
    MeshStatusView()
        .preferredColorScheme(.dark)
}
