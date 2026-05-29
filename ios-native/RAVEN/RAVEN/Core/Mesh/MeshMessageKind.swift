//
//  MeshMessageKind.swift
//  RAVEN
//
//  Mesh message kind discriminator used by `MeshMessageFrame`. Was
//  previously defined alongside the Phase-4 transport types that got
//  reverted out of the working tree (81848e2). The feature services
//  (`ClubService`, `EchoService`, `MeshFeaturesContainerView`, …) and
//  `BLEMeshEngine.register(for:handler:)` all still expect this enum,
//  so we re-introduce it standalone here.
//
//  Raw values stay short for BLE-payload efficiency — every frame
//  carries `mk: "cp"` instead of `mk: "clubPing"`.
//

import Foundation

enum MeshMessageKind: String, Codable, Hashable {
    // Club (rooms / channels) ─────────────────────────────────────
    case clubPing          = "cp"
    case clubJoin          = "cj"
    case clubLeave         = "cl"
    case clubMemberDropped = "cmd"

    // Echo (proximity ping replies) ───────────────────────────────
    case echoBroadcast       = "eb"
    case echoResponse        = "er"

    // Vault content drops ─────────────────────────────────────────
    case vaultContent = "vc"

    // Generic chat / posts (legacy) ───────────────────────────────
    case chat = "chat"
    case post = "post"
    case ack  = "ack"
}
