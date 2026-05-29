//
//  MeshCapabilities.swift
//  RAVEN
//
//  Capability bitmap for BLE advertisement / peer discovery.
//  Allows nodes to advertise what they can do (relay, gateway, LoRa, etc.).
//

import Foundation
import UIKit

// MARK: - Mesh Capabilities

struct MeshCapabilities: OptionSet, Codable, Sendable {
    let rawValue: UInt16
    
    /// Basic relay capability (default for all nodes)
    static let relaysMessages = MeshCapabilities(rawValue: 1 << 0)
    
    /// Device has internet connectivity (Wi-Fi or cellular)
    static let hasInternet = MeshCapabilities(rawValue: 1 << 1)
    
    /// Device has stable Wi-Fi (not just cellular)
    static let wifiStable = MeshCapabilities(rawValue: 1 << 2)
    
    /// User has opted into gateway mode
    static let gatewayEnabled = MeshCapabilities(rawValue: 1 << 3)
    
    /// Battery level > 30%
    static let batteryHigh = MeshCapabilities(rawValue: 1 << 4)
    
    /// Device supports LoRa (future)
    static let hasLoRa = MeshCapabilities(rawValue: 1 << 5)
    
    /// Device has active travel intent (Data Mules)
    static let hasTravelIntent = MeshCapabilities(rawValue: 1 << 6)
    
    // MARK: - Derived Properties
    
    /// Whether this device can act as an internet bridge right now.
    var isActiveGateway: Bool {
        contains([.hasInternet, .gatewayEnabled, .batteryHigh])
    }
    
    /// Whether this device is a traveling mule with active intent.
    var isActiveMule: Bool {
        contains([.relaysMessages, .hasTravelIntent])
    }
    
    /// Human-readable list of active capabilities.
    var displayLabels: [String] {
        var labels: [String] = []
        if contains(.relaysMessages) { labels.append("Relay") }
        if contains(.hasInternet) { labels.append("Internet") }
        if contains(.wifiStable) { labels.append("Wi-Fi") }
        if contains(.gatewayEnabled) { labels.append("Gateway") }
        if contains(.batteryHigh) { labels.append("Battery OK") }
        if contains(.hasLoRa) { labels.append("LoRa") }
        if contains(.hasTravelIntent) { labels.append("Mule") }
        return labels
    }
    
    // MARK: - BLE Advertisement
    
    /// Encode to 2 bytes for BLE advertisement data.
    var bleData: Data {
        withUnsafeBytes(of: rawValue.littleEndian) { Data($0) }
    }
    
    /// Decode from BLE advertisement data (2 bytes).
    static func from(bleData data: Data) -> MeshCapabilities? {
        guard data.count >= 2 else { return nil }
        let value = data.withUnsafeBytes { $0.load(as: UInt16.self) }
        return MeshCapabilities(rawValue: UInt16(littleEndian: value))
    }
    
    // MARK: - Current Device Capabilities
    
    /// Compute current device capabilities dynamically.
    @MainActor
    static func current() -> MeshCapabilities {
        var caps: MeshCapabilities = [.relaysMessages]
        
        if NetworkMonitor.shared.isOnline {
            caps.insert(.hasInternet)
        }
        
        // Check Wi-Fi stability
        if NetworkMonitor.shared.connectionType == .wifi {
            caps.insert(.wifiStable)
        }
        
        // Check user gateway preference
        if UserDefaults.standard.bool(forKey: "raven.gateway_enabled") {
            caps.insert(.gatewayEnabled)
        }
        
        // Battery check
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 || batteryLevel > 0.30 {  // -1 means unknown → assume OK
            caps.insert(.batteryHigh)
        }
        
        // Travel intent check
        if UserDefaults.standard.bool(forKey: "raven.has_active_travel_intent") {
            caps.insert(.hasTravelIntent)
        }
        
        return caps
    }
}
