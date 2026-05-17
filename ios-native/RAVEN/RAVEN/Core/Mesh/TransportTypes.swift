//
//  TransportTypes.swift
//  RAVEN
//
//  Spec V1 — Unified naming for transport layer
//

import Foundation

// MARK: - 1.1 Transport Modes

/// How the app routes messages based on connectivity
enum TransportMode: String, Codable {
    case internetOnly = "INTERNET_ONLY"
    case meshOnly     = "MESH_ONLY"
    case hybrid       = "HYBRID"
}

// MARK: - 1.2 Connectivity State

/// Unified network state derived from NWPath + server probe + flaky detection
enum NetState: String, Codable {
    case online   = "ONLINE"    // NWPath satisfied + server reachable + stable
    case offline  = "OFFLINE"   // NWPath unsatisfied or no connectivity
    case degraded = "DEGRADED"  // Connected but server unreachable or flaky
}

// MARK: - 1.3 Routes (For UI Labels)

/// How a message was delivered — computed from deliveryAuthority + hopCount
enum Route: String, Codable {
    case server      = "SERVER"        // Delivered via internet
    case directMesh  = "DIRECT_MESH"   // Direct BLE neighbor (hopCount == 0)
    case meshBridge  = "MESH_BRIDGE"   // Relayed through intermediate nodes
}

// MARK: - 1.4 Delivery State (State Machine)

/// Lifecycle of a message from creation to final delivery
enum DeliveryState: String, Codable {
    case created              = "CREATED"
    case sentServer           = "SENT_SERVER"
    case sentMesh             = "SENT_MESH"
    case deliveredToRecipient = "DELIVERED_TO_RECIPIENT"
    case ackedByServer        = "ACKED_BY_SERVER"
    case expired              = "EXPIRED"
    case failed               = "FAILED"
}

// MARK: - 1.5 Mesh Message Kind

/// Identifies the type of mesh message for handler dispatch.
/// New features register handlers for their specific kinds via
/// `BLEMeshEngine.register(handler:for:)`.
enum MeshMessageKind: String, Codable {
    // Existing (dispatched via legacy path)
    case chat           = "chat"
    case post           = "post"
    case ack            = "ack"
    
    // Club Mode
    case clubPing      = "club_ping"
    case clubJoin      = "club_join"
    case clubLeave     = "club_leave"
    
    // Echo
    case echoBroadcast  = "echo_broadcast"
    case echoResponse   = "echo_response"
    
    // Vault (location-locked content)
    case vaultContent = "vault_content"
    
    // MARK: - Backward Compatibility
    
    /// Accepts legacy Flock raw values from older peers:
    /// "flockPing" → .clubPing, "flockJoin" → .clubJoin, etc.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        
        // Try standard init first
        if let kind = MeshMessageKind(rawValue: raw) {
            self = kind
            return
        }
        
        // Legacy mapping
        switch raw {
        case "flockPing", "flock_ping":     self = .clubPing
        case "flockJoin", "flock_join":     self = .clubJoin
        case "flockLeave", "flock_leave":   self = .clubLeave
        case "proximity_content":           self = .vaultContent
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "Unknown MeshMessageKind: \(raw)")
            )
        }
    }
}
