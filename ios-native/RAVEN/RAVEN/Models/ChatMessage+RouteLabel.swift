//
//  ChatMessage+RouteLabel.swift
//  RAVEN
//
//  Spec V1 §8 — UI labels for delivery route
//

import Foundation

// MARK: - ChatMessage Route Labels

extension ChatMessage {
    /// Compute the delivery route from deliveryAuthority + hopCount (Spec V1 §6/§8)
    var deliveryRoute: Route {
        if deliveryAuthority == .server {
            return .server
        }
        // Mesh delivery: hopCount == 0 means direct neighbor
        if hopCount == 0 {
            return .directMesh
        }
        return .meshBridge
    }
    
    /// Human-readable label for chat bubble badges (Spec V1 §8)
    var uiRouteLabel: String {
        switch deliveryRoute {
        case .server:     return "Sent via Internet"
        case .directMesh: return "Sent via Direct Mesh"
        case .meshBridge: return "Sent via Mesh Bridge"
        }
    }
    
    /// SF Symbol name for route indicator
    var routeIcon: String {
        switch deliveryRoute {
        case .server:     return "antenna.radiowaves.left.and.right"
        case .directMesh: return "dot.radiowaves.left.and.right"
        case .meshBridge: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Post Route Labels

extension Post {
    /// Badge label for posts initially sent via mesh (Spec V1 §7.1)
    var uiBadgeLabel: String? {
        if initialSend == "mesh" {
            return "Initial Send by Mesh"
        }
        return nil
    }
}
