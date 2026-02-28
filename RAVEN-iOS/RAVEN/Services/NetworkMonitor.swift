// RAVEN - Network Monitor
// Converted from Flutter network_detector.dart

import Foundation
import Network
import Combine

/// Monitors network connectivity and type
@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published var isConnected = true
    @Published var connectionType: ConnectionType = .wifi
    @Published var isExpensive = false  // Cellular/hotspot
    @Published var isConstrained = false  // Low data mode
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    enum ConnectionType: String {
        case wifi = "wifi"
        case cellular = "cellular"
        case ethernet = "ethernet"
        case unknown = "unknown"
    }
    
    private init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateStatus(path)
            }
        }
        monitor.start(queue: queue)
    }
    
    func stopMonitoring() {
        monitor.cancel()
    }
    
    private func updateStatus(_ path: NWPath) {
        let wasConnected = isConnected
        
        isConnected = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .ethernet
        } else {
            connectionType = .unknown
        }
        
        print("📶 [Network] Status: \(isConnected ? "Connected" : "Disconnected") via \(connectionType.rawValue)")
        
        // Trigger immediate sync when connectivity is restored
        if !wasConnected && isConnected {
            print("📶 [Network] Connectivity restored — syncing pending messages...")
            Task {
                await SyncService.shared.syncAll()
            }
        }
    }
    
    var statusIcon: String {
        if !isConnected { return "wifi.slash" }
        switch connectionType {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .ethernet: return "cable.connector"
        case .unknown: return "network"
        }
    }
}
