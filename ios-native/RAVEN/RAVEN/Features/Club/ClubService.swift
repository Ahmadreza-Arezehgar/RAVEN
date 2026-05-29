//
//  ClubService.swift
//  RAVEN
//
//  Core service for Club Mode — handles creation, join/leave,
//  mesh broadcast/receive, and handler registration.
//

import Foundation
import UIKit

// MARK: - Club Service

@MainActor
final class ClubService: ObservableObject {
    static let shared = ClubService()
    
    /// Currently active club (user can be in at most one at a time).
    @Published private(set) var activeClub: Club?
    @Published private(set) var members: [ClubMember] = []
    
    private init() {}
    
    // MARK: - Registration
    
    /// Register mesh handlers for Club messages.
    /// Call this once at app launch.
    func registerMeshHandlers() {
        guard FeatureFlag.isClubModeEnabled else { return }
        
        BLEMeshEngine.shared.register(for: .clubPing) { [weak self] data, deviceId in
            await self?.handlePing(data: data, from: deviceId)
        }
        
        BLEMeshEngine.shared.register(for: .clubJoin) { [weak self] data, deviceId in
            await self?.handleJoin(data: data, from: deviceId)
        }
        
        BLEMeshEngine.shared.register(for: .clubLeave) { [weak self] data, deviceId in
            await self?.handleLeave(data: data, from: deviceId)
        }
        
        #if DEBUG
        print("🐦 [Club] Mesh handlers registered")
        #endif
    }
    
    // MARK: - Create Club
    
    /// Create a new club and start the ticker.
    func createClub(
        name: String,
        durationHours: Int = 6,
        dropThresholdMeters: Int = 200,
        clubDescription: String? = nil,
        contactEmail: String? = nil,
        externalLink: String? = nil,
        locationPrecision: Club.LocationPrecision = .exact,
        locationSource: Club.LocationSource = .meshOnly
    ) async -> Club? {
        guard FeatureFlag.isClubModeEnabled else { return nil }
        guard activeClub == nil else { return nil } // Only one club at a time

        guard let userId = await KeychainService.shared.getUserId(), !userId.isEmpty,
              let displayName = currentDisplayName() else {
            #if DEBUG
            print("🐦 [Club] Cannot create — user identity not ready")
            #endif
            return nil
        }

        let now = Date()
        let club = Club(
            id: UUID().uuidString,
            name: String(name.prefix(40)),
            inviteCode: Club.generateInviteCode(),
            creatorId: userId,
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(durationHours * 3600)),
            dropThresholdMeters: max(50, min(500, dropThresholdMeters)),
            maxMembers: 20,
            clubDescription: clubDescription.map { String($0.prefix(200)) },
            contactEmail: contactEmail,
            externalLink: externalLink,
            locationPrecision: locationPrecision,
            locationSource: locationSource
        )

        // Persist
        do {
            try await ClubRepository.shared.upsertClub(club)
        } catch {
            #if DEBUG
            print("🐦 [Club] Failed to persist club \(club.id.prefix(8)): \(error)")
            #endif
            return nil
        }

        // Add self as first member
        let myMember = ClubMember(
            id: UUID().uuidString,
            clubId: club.id,
            userId: userId,
            displayName: displayName,
            avatarURL: AuthService.shared.currentUser?.avatarPath,
            h3Cell: LocationPrivacyService.shared.currentH3Cell(resolution: 9),
            lastSeenAt: now,
            isMe: true
        )
        do {
            try await ClubRepository.shared.upsertMember(myMember)
        } catch {
            #if DEBUG
            print("🐦 [Club] Failed to persist creator membership: \(error)")
            #endif
            // Roll back the club row so we don't leave an orphan club without its creator.
            try? await ClubRepository.shared.deleteClub(id: club.id)
            return nil
        }

        activeClub = club
        members = [myMember]

        // Start ticker
        ClubTickerService.shared.start(for: club)

        // Broadcast join to mesh
        await broadcastJoin(club: club, userId: userId, displayName: displayName)
        
        #if DEBUG
        print("🐦 [Club] Created: \(club.name) | code=\(club.inviteCode)")
        #endif
        
        return club
    }
    
    // MARK: - Join Club
    
    /// Join a club by invite code.
    func joinClub(inviteCode: String) async -> Bool {
        guard FeatureFlag.isClubModeEnabled else { return false }
        guard activeClub == nil else { return false }

        // Look up by invite code (local DB first, then mesh discovery)
        let lookup: Club?
        do {
            lookup = try await ClubRepository.shared.getClubByCode(inviteCode)
        } catch {
            #if DEBUG
            print("🐦 [Club] Lookup failed for code \(inviteCode): \(error)")
            #endif
            return false
        }
        guard let club = lookup else {
            #if DEBUG
            print("🐦 [Club] No club found for code: \(inviteCode)")
            #endif
            return false
        }

        guard club.isActive else { return false }

        guard let userId = await KeychainService.shared.getUserId(), !userId.isEmpty,
              let displayName = currentDisplayName() else {
            #if DEBUG
            print("🐦 [Club] Cannot join — user identity not ready")
            #endif
            return false
        }

        let myMember = ClubMember(
            id: UUID().uuidString,
            clubId: club.id,
            userId: userId,
            displayName: displayName,
            avatarURL: AuthService.shared.currentUser?.avatarPath,
            h3Cell: LocationPrivacyService.shared.currentH3Cell(resolution: 9),
            lastSeenAt: Date(),
            isMe: true
        )

        // Atomic count-and-insert inside the repository actor — prevents two
        // concurrent joins from both observing `count < limit` and slipping past it.
        let inserted: Bool
        do {
            inserted = try await ClubRepository.shared.joinIfUnderLimit(myMember, maxMembers: club.maxMembers)
        } catch {
            #if DEBUG
            print("🐦 [Club] Join insert failed: \(error)")
            #endif
            return false
        }
        guard inserted else {
            #if DEBUG
            print("🐦 [Club] Member limit reached (\(club.maxMembers))")
            #endif
            return false
        }

        activeClub = club
        do {
            members = try await ClubRepository.shared.getMembers(clubId: club.id)
        } catch {
            #if DEBUG
            print("🐦 [Club] getMembers failed: \(error)")
            #endif
            members = [myMember]
        }

        // Start ticker
        ClubTickerService.shared.start(for: club)

        // Broadcast join
        await broadcastJoin(club: club, userId: userId, displayName: displayName)

        #if DEBUG
        print("🐦 [Club] Joined: \(club.name) | code=\(club.inviteCode)")
        #endif

        return true
    }
    
    // MARK: - Leave Club
    
    /// Leave the active club.
    func leaveClub() async {
        guard let club = activeClub else { return }

        let userId = await KeychainService.shared.getUserId() ?? ""

        // Broadcast leave
        let payload = ClubLeavePayload(
            clubId: club.id,
            userId: userId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )

        var frame = MeshMessageFrame(
            kind: .clubLeave,
            payload: payload,
            senderId: userId,
            hopLimit: 3,
            sprayCounter: 20,
            ttlSeconds: 300
        )
        frame.sign()

        // FIX: Broadcast actual frame data (same fix as Echo/Vault).
        if let data = frame.toData() {
            await BLEMeshEngine.shared.broadcastPostData(data)
        }

        // Cleanup
        do {
            try await ClubRepository.shared.removeMember(clubId: club.id, userId: userId)
        } catch {
            #if DEBUG
            print("🐦 [Club] removeMember failed on leave: \(error)")
            #endif
        }
        ClubTickerService.shared.stop()

        activeClub = nil
        members = []
        
        #if DEBUG
        print("🐦 [Club] Left club: \(club.name)")
        #endif
    }
    
    // MARK: - Refresh
    
    /// Reload members from database.
    func refreshMembers() async {
        guard let club = activeClub else { return }
        do {
            members = try await ClubRepository.shared.getMembers(clubId: club.id)
        } catch {
            #if DEBUG
            print("🐦 [Club] refreshMembers failed: \(error)")
            #endif
        }
    }

    /// Restore active club on app launch.
    func restoreActiveSession() async {
        guard FeatureFlag.isClubModeEnabled else { return }
        let clubs: [Club]
        do {
            clubs = try await ClubRepository.shared.getActiveClubs()
        } catch {
            #if DEBUG
            print("🐦 [Club] restoreActiveSession getActiveClubs failed: \(error)")
            #endif
            return
        }

        // Find club where we're a member
        for club in clubs {
            let restoredMembers: [ClubMember]
            do {
                restoredMembers = try await ClubRepository.shared.getMembers(clubId: club.id)
            } catch {
                #if DEBUG
                print("🐦 [Club] restoreActiveSession getMembers failed for \(club.id.prefix(8)): \(error)")
                #endif
                continue
            }
            if restoredMembers.contains(where: { $0.isMe }) {
                self.activeClub = club
                self.members = restoredMembers
                ClubTickerService.shared.start(for: club)

                #if DEBUG
                print("🐦 [Club] Restored session: \(club.name)")
                #endif
                return
            }
        }
    }
    
    // MARK: - Incoming Handlers
    
    private func handlePing(data: Data, from deviceId: String) async {
        guard FeatureFlag.isClubModeEnabled else { return }
        
        // 🔐 Verify Ed25519 signature before processing
        let sig = MeshSignatureVerifier.extractSignatureFields(from: data)
        guard MeshSignatureVerifier.verify(data: data, signature: sig.signature, signerPublicKey: sig.signerPublicKey) else { return }
        
        guard let frame = try? JSONDecoder().decode(
            MeshMessageFrame<ClubPingPayload>.self,
            from: data
        ) else { return }
        
        let payload = frame.payload

        // Only process pings for our active club
        guard let club = await MainActor.run(body: { self.activeClub }),
              club.id == payload.clubId else { return }

        // Update member location (with precise coords if sent)
        do {
            try await ClubRepository.shared.updateMemberLocation(
                clubId: payload.clubId,
                userId: payload.userId,
                h3Cell: payload.h3Cell,
                preciseLat: payload.preciseLat,
                preciseLng: payload.preciseLng
            )
        } catch {
            #if DEBUG
            print("🐦 [Club] updateMemberLocation failed: \(error)")
            #endif
            return
        }
        
        // Refresh UI
        await MainActor.run {
            if let idx = self.members.firstIndex(where: { $0.userId == payload.userId }) {
                self.members[idx].h3Cell = payload.h3Cell
                self.members[idx].preciseLat = payload.preciseLat
                self.members[idx].preciseLng = payload.preciseLng
                self.members[idx].lastSeenAt = Date()
            }
        }
    }
    
    private func handleJoin(data: Data, from deviceId: String) async {
        guard FeatureFlag.isClubModeEnabled else { return }
        
        // 🔐 Verify Ed25519 signature
        let sig = MeshSignatureVerifier.extractSignatureFields(from: data)
        guard MeshSignatureVerifier.verify(data: data, signature: sig.signature, signerPublicKey: sig.signerPublicKey) else { return }
        
        guard let frame = try? JSONDecoder().decode(
            MeshMessageFrame<ClubJoinPayload>.self,
            from: data
        ) else { return }
        
        let payload = frame.payload
        
        // If we're in the same club, add the member
        if let club = await MainActor.run(body: { self.activeClub }),
           club.id == payload.clubId {
            let member = ClubMember(
                id: UUID().uuidString,
                clubId: payload.clubId,
                userId: payload.userId,
                displayName: payload.displayName,
                h3Cell: nil,
                lastSeenAt: Date(),
                isMe: false
            )
            do {
                try await ClubRepository.shared.upsertMember(member)
            } catch {
                #if DEBUG
                print("🐦 [Club] upsertMember on join failed: \(error)")
                #endif
                return
            }
            await MainActor.run {
                if !self.members.contains(where: { $0.userId == payload.userId }) {
                    self.members.append(member)
                }
            }

            #if DEBUG
            await MainActor.run {
                print("🐦 [Club] \(payload.displayName) joined club")
            }
            #endif
        } else {
            // Not our club — but store the club info for future join by code
            // (Club metadata propagates via mesh)
            let club = Club(
                id: payload.clubId,
                name: "", // We don't know the name from a join payload
                inviteCode: payload.inviteCode,
                creatorId: "",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(21600), // Assume 6h default
                dropThresholdMeters: 200,
                maxMembers: 20,
                locationPrecision: .exact,
                locationSource: .meshOnly
            )
            do {
                try await ClubRepository.shared.upsertClub(club)
            } catch {
                #if DEBUG
                print("🐦 [Club] upsertClub from mesh discovery failed: \(error)")
                #endif
            }
        }
    }
    
    private func handleLeave(data: Data, from deviceId: String) async {
        guard FeatureFlag.isClubModeEnabled else { return }
        
        // 🔐 Verify Ed25519 signature
        let sig = MeshSignatureVerifier.extractSignatureFields(from: data)
        guard MeshSignatureVerifier.verify(data: data, signature: sig.signature, signerPublicKey: sig.signerPublicKey) else { return }
        
        guard let frame = try? JSONDecoder().decode(
            MeshMessageFrame<ClubLeavePayload>.self,
            from: data
        ) else { return }
        
        let payload = frame.payload
        
        guard let club = await MainActor.run(body: { self.activeClub }),
              club.id == payload.clubId else { return }

        do {
            try await ClubRepository.shared.removeMember(
                clubId: payload.clubId,
                userId: payload.userId
            )
        } catch {
            #if DEBUG
            print("🐦 [Club] removeMember on leave-mesh failed: \(error)")
            #endif
        }

        await MainActor.run {
            self.members.removeAll { $0.userId == payload.userId }
        }
    }
    
    // MARK: - Broadcast Helpers
    
    private func broadcastJoin(club: Club, userId: String, displayName: String) async {
        let payload = ClubJoinPayload(
            clubId: club.id,
            userId: userId,
            displayName: displayName,
            inviteCode: club.inviteCode,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )

        var frame = MeshMessageFrame(
            kind: .clubJoin,
            payload: payload,
            senderId: userId,
            hopLimit: 3,
            sprayCounter: 30,
            ttlSeconds: 600
        )
        frame.sign()

        // FIX: Broadcast actual frame data (same fix as Echo/Vault).
        if let data = frame.toData() {
            await BLEMeshEngine.shared.broadcastPostData(data)
        }
    }

    /// Look up the user's display name from AuthService, returning nil
    /// instead of broadcasting a placeholder like "Unknown" — a missing name
    /// usually means identity isn't set up yet, and we'd rather skip the
    /// broadcast than poison every peer's member list.
    ///
    /// FIX: Was reading from UserDefaults key "currentUsername" which is never
    /// written anywhere in the codebase, causing ALL Club operations to silently
    /// fail with "user identity not ready". Now reads from AuthService.
    @MainActor
    private func currentDisplayName() -> String? {
        guard let user = AuthService.shared.currentUser else { return nil }
        guard let name = user.firstName ?? user.username else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    // NOTE: createControlEnvelope removed — was producing empty MeshEnvelope
    // wrappers (text: nil) that discarded the actual frame data. Club now
    // broadcasts signed MeshMessageFrame data directly via broadcastPostData.
}

// MARK: - Notification Names

extension Notification.Name {
    static let clubMemberDropped = Notification.Name("raven.club.member.dropped")
}
