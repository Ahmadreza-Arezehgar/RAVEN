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
