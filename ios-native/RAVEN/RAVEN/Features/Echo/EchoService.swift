//
//  EchoService.swift
//  RAVEN
//
//  Core service for Echo feature — handles creation, response,
//  mesh broadcast/receive, and handler registration.
//

import Foundation

// MARK: - Echo Service

@MainActor
final class EchoService: ObservableObject {
    static let shared = EchoService()
    
    /// Rate limiter for echo creation.
    private var rateLimiter = EchoRateLimiter()
    
    /// Track which echoes we've responded to (in-memory, per session).
    private(set) var respondedEchoIds: Set<String> = []
    
    private init() {}
    
    // MARK: - Registration
    
    /// Register mesh handlers for Echo messages.
    /// Call this once at app launch.
    func registerMeshHandlers() {
        guard FeatureFlag.isEchoEnabled else { return }
        
        BLEMeshEngine.shared.register(for: .echoBroadcast) { [weak self] data, deviceId in
            await self?.handleIncomingBroadcast(data: data, from: deviceId)
        }
        
        BLEMeshEngine.shared.register(for: .echoResponse) { [weak self] data, deviceId in
            await self?.handleIncomingResponse(data: data, from: deviceId)
        }
        
        #if DEBUG
        print("📣 [Echo] Mesh handlers registered")
        #endif
    }
    
    // MARK: - Create Echo
    
    /// Create and broadcast a new echo.
    ///
    /// - Parameters:
    ///   - content: Question text (max 200 chars)
    ///   - ttlMinutes: Time-to-live (60-1440 minutes)
    ///   - shareLocation: Whether to include city-level H3 cell
    /// - Returns: The created Echo, or nil if rate limited
    func createEcho(content: String, ttlMinutes: Int = 360, shareLocation: Bool = false) async -> Echo? {
        guard FeatureFlag.isEchoEnabled else { return nil }
        
        // Rate limit
        guard rateLimiter.canCreate() else {
            #if DEBUG
            print("📣 [Echo] Rate limited — cannot create")
            #endif
            return nil
        }
        
        // Validate content
        let trimmed = String(content.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let userId = await KeychainService.shared.getUserId() ?? ""
        let pseudonym = Echo.generatePseudonym(for: userId)
        
        let now = Date()
        let expiresAt = now.addingTimeInterval(TimeInterval(ttlMinutes * 60))
        
        // Location (city-level only, resolution 5)
        var h3Cell: String? = nil
        if shareLocation {
            if let cell = LocationPrivacyService.shared.currentH3Cell {
                h3Cell = H3Lite.cellToString(cell)
            }
        }
        
        let echo = Echo(
            id: UUID().uuidString,
            authorPseudonym: pseudonym,
            content: trimmed,
            h3Cell: h3Cell,
            createdAt: now,
            expiresAt: expiresAt,
            isMine: true,
            receivedAt: now
        )
        
        // Persist
        do {
            try await EchoRepository.shared.insertEcho(echo)
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to persist echo \(echo.id.prefix(8)): \(error)")
            #endif
        }
        rateLimiter.recordCreation()

        // Broadcast via mesh — frame-level Ed25519 signature is required;
        // receivers' MeshSignatureVerifier rejects unsigned frames.
        //
        // FIX: Compute payload-level Ed25519 signature so receivers can verify
        // the payload independently of the transport frame.
        let payloadSigData = "\(echo.id)|\(echo.content)|\(Int64(now.timeIntervalSince1970 * 1000))".data(using: .utf8) ?? Data()
        let payloadSig = DeviceIdentityService.shared.sign(payloadSigData)?.base64EncodedString()

        let payload = EchoBroadcastPayload(
            echoId: echo.id,
            authorPseudonym: echo.authorPseudonym,
            content: echo.content,
            h3Cell: echo.h3Cell,
            createdAt: Int64(now.timeIntervalSince1970 * 1000),
            ttlMinutes: ttlMinutes,
            signature: payloadSig
        )

        var frame = MeshMessageFrame(
            kind: .echoBroadcast,
            payload: payload,
            senderId: userId,
            hopLimit: 8,
            sprayCounter: 100,
            ttlSeconds: ttlMinutes * 60
        )
        frame.sign()

        // FIX: Broadcast the actual signed frame data directly.
        // Previously, the frame data was computed but discarded — an empty
        // MeshEnvelope (text: nil) was broadcast instead, so receivers
        // never received the Echo payload.
        if let data = frame.toData() {
            await BLEMeshEngine.shared.broadcastPostData(data)
        }
        
        #if DEBUG
        print("📣 [Echo] Created echo: \(echo.id.prefix(8)) | content=\(trimmed.prefix(30))")
        #endif
        
        return echo
    }
    
    // MARK: - Respond to Echo
    
    /// Respond to an echo with an emoji.
    /// Each user can only respond once per echo.
    ///
    /// - Parameters:
    ///   - echoId: The echo to respond to
    ///   - emoji: One of the 5 allowed emojis
    /// - Returns: True if response was sent, false if already responded
    func respond(to echoId: String, with emoji: EchoEmoji) async -> Bool {
        guard FeatureFlag.isEchoEnabled else { return false }
        guard !respondedEchoIds.contains(echoId) else { return false }
        
        let nonce = UUID().uuidString

        // Persist locally
        do {
            try await EchoRepository.shared.insertResponse(
                echoId: echoId,
                emoji: emoji.rawValue,
                nonce: nonce
            )
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to persist response for \(echoId.prefix(8)): \(error)")
            #endif
        }

        respondedEchoIds.insert(echoId)

        // Broadcast via mesh — sender ID stays empty so the response is anonymous,
        // but the frame carries an Ed25519 signature so peers know the response
        // came from a real device key.
        let payload = EchoResponsePayload(
            echoId: echoId,
            emoji: emoji.rawValue,
            responseNonce: nonce,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )

        var frame = MeshMessageFrame(
            kind: .echoResponse,
            payload: payload,
            senderId: "", // Anonymous — no sender ID!
            messageId: "er-\(nonce)",
            hopLimit: 8,
            sprayCounter: 50,
            ttlSeconds: 3600
        )
        frame.sign()

        // FIX: Broadcast actual frame data (same fix as createEcho).
        if let data = frame.toData() {
            await BLEMeshEngine.shared.broadcastPostData(data)
        }
        
        #if DEBUG
        print("📣 [Echo] Responded to \(echoId.prefix(8)) with \(emoji.rawValue)")
        #endif
        
        return true
    }
    
    // MARK: - Incoming Handlers
    
    /// Handle incoming echo broadcast from mesh.
    private func handleIncomingBroadcast(data: Data, from deviceId: String) async {
        guard FeatureFlag.isEchoEnabled else { return }
        
        // 🔐 Verify Ed25519 signature
        let sig = MeshSignatureVerifier.extractSignatureFields(from: data)
        guard MeshSignatureVerifier.verify(data: data, signature: sig.signature, signerPublicKey: sig.signerPublicKey) else { return }
        
        let frame: MeshMessageFrame<EchoBroadcastPayload>
        do {
            frame = try JSONDecoder().decode(MeshMessageFrame<EchoBroadcastPayload>.self, from: data)
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to decode broadcast frame: \(error)")
            #endif
            return
        }

        let payload = frame.payload

        // Check if already exists
        let exists: Bool
        do {
            exists = try await EchoRepository.shared.exists(echoId: payload.echoId)
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to check existence for \(payload.echoId.prefix(8)): \(error)")
            #endif
            return
        }
        guard !exists else { return }
        
        // Validate TTL
        let createdAt = Date(timeIntervalSince1970: TimeInterval(payload.createdAt) / 1000.0)
        let expiresAt = createdAt.addingTimeInterval(TimeInterval(payload.ttlMinutes * 60))
        guard expiresAt > Date() else { return }
        
        // Content length check
        guard payload.content.count <= 200 else { return }
        
        let echo = Echo(
            id: payload.echoId,
            authorPseudonym: payload.authorPseudonym,
            content: payload.content,
            h3Cell: payload.h3Cell,
            createdAt: createdAt,
            expiresAt: expiresAt,
            isMine: false,
            receivedAt: Date()
        )
        
        do {
            try await EchoRepository.shared.insertEcho(echo)
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to insert received echo \(echo.id.prefix(8)): \(error)")
            #endif
            return
        }

        // Notify UI
        await MainActor.run {
            NotificationCenter.default.post(
                name: .echoReceived,
                object: nil,
                userInfo: ["echoId": echo.id]
            )
        }
        
        #if DEBUG
        await MainActor.run {
            print("📣 [Echo] Received echo: \(echo.id.prefix(8)) from pseudo:\(echo.authorPseudonym)")
        }
        #endif
    }
    
    /// Handle incoming echo response from mesh.
    private func handleIncomingResponse(data: Data, from deviceId: String) async {
        guard FeatureFlag.isEchoEnabled else { return }
        
        // 🔐 Verify Ed25519 signature
        let sig = MeshSignatureVerifier.extractSignatureFields(from: data)
        guard MeshSignatureVerifier.verify(data: data, signature: sig.signature, signerPublicKey: sig.signerPublicKey) else { return }
        
        let frame: MeshMessageFrame<EchoResponsePayload>
        do {
            frame = try JSONDecoder().decode(MeshMessageFrame<EchoResponsePayload>.self, from: data)
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to decode response frame: \(error)")
            #endif
            return
        }

        let payload = frame.payload

        // Validate emoji
        guard EchoEmoji(rawValue: payload.emoji) != nil else { return }

        // Insert with dedup (INSERT OR IGNORE on nonce)
        do {
            try await EchoRepository.shared.insertResponse(
                echoId: payload.echoId,
                emoji: payload.emoji,
                nonce: payload.responseNonce
            )
        } catch {
            #if DEBUG
            print("📣 [Echo] Failed to insert response for \(payload.echoId.prefix(8)): \(error)")
            #endif
            return
        }
        
        // Notify UI
        await MainActor.run {
            NotificationCenter.default.post(
                name: .echoResponseReceived,
                object: nil,
                userInfo: ["echoId": payload.echoId]
            )
        }
        
        #if DEBUG
        await MainActor.run {
            print("📣 [Echo] Response for \(payload.echoId.prefix(8)): \(payload.emoji)")
        }
        #endif
    }
    
    // MARK: - Helpers
    // NOTE: createControlEnvelope removed — was producing empty MeshEnvelope
    // wrappers (text: nil) that discarded the actual frame data. Echo now
    // broadcasts signed MeshMessageFrame data directly via broadcastPostData.
}

// MARK: - Notification Names

extension Notification.Name {
    static let echoReceived = Notification.Name("raven.echo.received")
    static let echoResponseReceived = Notification.Name("raven.echo.response.received")
}
