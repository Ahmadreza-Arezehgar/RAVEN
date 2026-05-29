//
//  MeshFriendRequestBroadcaster.swift
//  RAVEN
//
//  🟦 ROUND 50 (2026-05-17) — offline QR friend-add over mesh.
//
//  When `ScanQRCodeView` decodes a friend QR, it tries to POST the
//  friend request to `/api/users/friend-request`. When the user is
//  offline (or behind a captive Wi-Fi) that POST fails with
//  `networkError(-1009)` and the friendship never lands — the user
//  reported "scan QR while offline = nothing happens".
//
//  Fix: in PARALLEL with the server POST, broadcast a mesh envelope
//  carrying a `FriendRequestMeshPayload`. The mesh DTN spray
//  delivers the envelope to nearby BLE peers (one of which is
//  hopefully the scanned device). The receiver materializes the
//  scanner as a local friend (auto-accept, since the QR was
//  out-of-band mutual consent), pins the agreement+signing keys for
//  E2EE, and shows a notification.
//
//  When connectivity returns on either side, the existing
//  `PendingFriendRequestQueue` flushes the server-side request so
//  the canonical friendship row lands too. Local-only friends keep
//  working (mesh DM) until then.
//

import Foundation

enum MeshFriendRequestBroadcaster {
    /// Build + broadcast a `friend_request` mesh envelope so a nearby
    /// BLE peer (or relay) can materialize us as a friend even when
    /// neither side has internet. Mirrors `MeshGroupBroadcaster.broadcastCreate`
    /// architecturally.
    ///
    /// Idempotent at the receiver: the receiver's
    /// `FriendDeviceRepository.upsert` is INSERT-OR-REPLACE, and the
    /// friends-cache upsert in `RAVENApp.handleFriendRequestMeshMessage`
    /// dedups by `userId`. Broadcasting on every QR scan is safe.
    ///
    /// SECURITY: the envelope is signed via the standard mesh sign
    /// path (`enqueueForBroadcast` calls `MeshCryptoService.signEnvelope`).
    /// The payload is NOT encrypted — it carries the sender's public
    /// keys + username, which are public material anyway (broadcast
    /// in the QR code itself out-of-band).
    static func broadcastFriendRequest(toUserId recipientUserId: String) async {
        guard !recipientUserId.isEmpty else { return }

        // Snapshot our own identity for the payload.
        let myId = await KeychainService.shared.getUserId() ?? ""
        guard !myId.isEmpty else {
            #if DEBUG
            print("🟦 [FriendReqBroadcaster] ABORT — userId not loaded from Keychain")
            #endif
            return
        }
        let me = await MainActor.run { AuthService.shared.currentUser }
        let myUsername = me?.username ?? ""
        let myDisplayName = me?.displayName ?? me?.username
        let myAvatar = me?.avatarPath

        // Our public keys. The agreement key (X25519) is what lets
        // the receiver seal RVNS1 to us; the signing key (Ed25519)
        // lets them pin our device fingerprint for trusted relay.
        let agreementB64 = await PeerKeyDirectory.shared.agreementKey(for: myId)?.base64EncodedString()
        let signingB64 = DeviceIdentityService.shared.publicKeyBase64

        let payload = FriendRequestMeshPayload(
            version: FriendRequestMeshPayload.currentVersion,
            senderUserId: myId,
            senderUsername: myUsername,
            senderDisplayName: myDisplayName,
            senderAvatarUrl: myAvatar,
            recipientUserId: recipientUserId,
            agreementPublicKeyB64: agreementB64,
            signingPublicKeyB64: signingB64,
            issuedAt: Date().timeIntervalSince1970
        )

        guard let payloadJSON = payload.encode() else {
            #if DEBUG
            print("🟦 [FriendReqBroadcaster] ABORT — could not encode FriendRequestMeshPayload")
            #endif
            return
        }

        let deviceId = DeviceIdentityService.shared.fingerprint ?? ""

        // Build the envelope. recipientId = the friend we're adding.
        // The receiver's mesh handler self-validates by comparing
        // `payload.recipientUserId == myUserId` so non-targets along
        // the spray path just relay without materializing.
        var envelope = MeshEnvelope(
            clientMessageId: "friendReq-\(recipientUserId.prefix(8))-\(UUID().uuidString.prefix(8))",
            roomId: recipientUserId,
            senderId: myId,
            senderName: myUsername,
            recipientId: recipientUserId,
            type: 6,                           // MessageType.system index
            text: payloadJSON,
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopCount: 0,
            hopLimit: PremiumLimits.meshHopLimit,
            routePath: [deviceId],
            originDeviceId: deviceId,
            needsForwarding: true
        )
        envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
        envelope.isGroup = false
        envelope.payloadKind = "friend_request"

        #if DEBUG
        print("🟦 [FriendReqBroadcaster] BROADCAST friend_request to=\(recipientUserId.prefix(8)) from=\(myId.prefix(8)) (@\(myUsername)) mid=\(envelope.clientMessageId.prefix(16))")
        #endif

        await BLEMeshEngine.shared.enqueueForBroadcast(envelope)
    }
}
