//
//  MeshPostTypes.swift
//  RAVEN
//
//  Shared types for Mesh Post feature
//

import Foundation

// MARK: - Mesh Post Status

/// Status of a post in the mesh broadcast lifecycle
enum MeshPostStatus: String {
    case queuedMesh = "queued_mesh"       // Ready to broadcast via mesh
    case broadcasting = "broadcasting"     // Currently being broadcast
    case synced = "synced"                 // Successfully synced to server
    case syncFailed = "sync_failed"        // Permanently failed to sync (400/422) — excluded from retry queue
}
