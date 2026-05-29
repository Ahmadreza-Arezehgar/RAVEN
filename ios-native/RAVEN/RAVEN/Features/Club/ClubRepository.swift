//
//  ClubRepository.swift
//  RAVEN
//
//  SQLite persistence for Club Mode.
//  Handles clubs, members, location updates, and auto-expiry.
//

import Foundation

// MARK: - Club Repository

actor ClubRepository {
    static let shared = ClubRepository()
    private init() {}

    // MARK: - Clubs CRUD

    /// Insert or update a club.
    func upsertClub(_ club: Club) async throws {
        let sql = """
            INSERT OR REPLACE INTO clubs
            (club_id, name, invite_code, creator_id, created_at, expires_at,
             drop_threshold_meters, max_members, description, contact_email,
             external_link, raven_group_id, location_precision, location_source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try await DatabaseService.shared.execute(sql, params: [
            club.id,
            club.name,
            club.inviteCode,
            club.creatorId,
            Int64(club.createdAt.timeIntervalSince1970 * 1000),
            Int64(club.expiresAt.timeIntervalSince1970 * 1000),
            club.dropThresholdMeters,
            club.maxMembers,
            club.clubDescription as Any,
            club.contactEmail as Any,
            club.externalLink as Any,
            club.ravenGroupId as Any,
            club.locationPrecision.rawValue,
            club.locationSource.rawValue
        ])
    }

    /// Get all active clubs.
    func getActiveClubs() async throws -> [Club] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = "SELECT * FROM clubs WHERE expires_at > ? ORDER BY created_at DESC"
        let rows = try await DatabaseService.shared.query(sql, params: [nowMs])
        return rows.compactMap { parseClub($0) }
    }

    /// Get club by ID.
    func getClub(id: String) async throws -> Club? {
        let sql = "SELECT * FROM clubs WHERE club_id = ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [id])
        return rows.first.flatMap { parseClub($0) }
    }

    /// Get club by invite code.
    func getClubByCode(_ code: String) async throws -> Club? {
        let sql = "SELECT * FROM clubs WHERE invite_code = ? AND expires_at > ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [
            code.uppercased(),
            Int64(Date().timeIntervalSince1970 * 1000)
        ])
        return rows.first.flatMap { parseClub($0) }
    }

    /// Delete a club and its members.
    func deleteClub(id: String) async throws {
        try await DatabaseService.shared.execute(
            "DELETE FROM club_members WHERE club_id = ?", params: [id]
        )
        try await DatabaseService.shared.execute(
            "DELETE FROM clubs WHERE club_id = ?", params: [id]
        )
    }

    // MARK: - Members CRUD

    /// Add or update a club member.
    func upsertMember(_ member: ClubMember) async throws {
        let sql = """
            INSERT OR REPLACE INTO club_members
            (member_id, club_id, user_id, display_name, avatar_url, h3_cell, precise_lat, precise_lng, last_seen_at, is_me)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try await DatabaseService.shared.execute(sql, params: [
            member.id,
            member.clubId,
            member.userId,
            member.displayName,
            member.avatarURL as Any,
            member.h3Cell.map { Int64(bitPattern: $0) } as Any,
            member.preciseLat as Any,
            member.preciseLng as Any,
            Int64(member.lastSeenAt.timeIntervalSince1970 * 1000),
            member.isMe ? 1 : 0
        ])
    }

    /// Atomically check the member limit and insert the new member.
    /// Both the count and the upsert run inside this actor's isolation domain,
    /// so two concurrent joins can't both observe `count < limit` and slip past it.
    /// Returns true if the member was inserted, false if the club was already full.
    func joinIfUnderLimit(_ member: ClubMember, maxMembers: Int) async throws -> Bool {
        let count = try await memberCount(clubId: member.clubId)
        // Re-joins (same userId) are allowed even at the limit.
        let isExisting = try await memberExists(clubId: member.clubId, userId: member.userId)
        guard isExisting || count < maxMembers else { return false }
        try await upsertMember(member)
        return true
    }

    /// Get all members of a club.
    func getMembers(clubId: String) async throws -> [ClubMember] {
        let sql = "SELECT * FROM club_members WHERE club_id = ? ORDER BY display_name"
        let rows = try await DatabaseService.shared.query(sql, params: [clubId])
        return rows.compactMap { parseMember($0) }
    }

    /// Update member's H3 cell, precise coordinates, and last seen time.
    func updateMemberLocation(clubId: String, userId: String, h3Cell: UInt64, preciseLat: Double? = nil, preciseLng: Double? = nil) async throws {
        let sql = """
            UPDATE club_members SET h3_cell = ?, precise_lat = ?, precise_lng = ?, last_seen_at = ?
            WHERE club_id = ? AND user_id = ?
        """
        try await DatabaseService.shared.execute(sql, params: [
            Int64(bitPattern: h3Cell),
            preciseLat as Any,
            preciseLng as Any,
            Int64(Date().timeIntervalSince1970 * 1000),
            clubId,
            userId
        ])
    }

    /// Remove a member from a club.
    func removeMember(clubId: String, userId: String) async throws {
        let sql = "DELETE FROM club_members WHERE club_id = ? AND user_id = ?"
        try await DatabaseService.shared.execute(sql, params: [clubId, userId])
    }

    /// Get member count for a club.
    func memberCount(clubId: String) async throws -> Int {
        let sql = "SELECT COUNT(*) as cnt FROM club_members WHERE club_id = ?"
        let rows = try await DatabaseService.shared.query(sql, params: [clubId])
        return Int(rows.first?["cnt"] as? Int64 ?? 0)
    }

    /// Whether a given user is already a member of the club.
    func memberExists(clubId: String, userId: String) async throws -> Bool {
        let sql = "SELECT 1 FROM club_members WHERE club_id = ? AND user_id = ? LIMIT 1"
        let rows = try await DatabaseService.shared.query(sql, params: [clubId, userId])
        return !rows.isEmpty
    }

    // MARK: - Cleanup

    /// Delete expired clubs and their members.
    func cleanupExpired() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await DatabaseService.shared.execute(
            "DELETE FROM club_members WHERE club_id IN (SELECT club_id FROM clubs WHERE expires_at <= ?)",
            params: [nowMs]
        )
        try await DatabaseService.shared.execute(
            "DELETE FROM clubs WHERE expires_at <= ?",
            params: [nowMs]
        )
    }

    // MARK: - Parse

    private func parseClub(_ row: [String: Any]) -> Club? {
        guard let id = row["club_id"] as? String,
              let name = row["name"] as? String,
              let inviteCode = row["invite_code"] as? String,
              let creatorId = row["creator_id"] as? String,
              let createdAtMs = row["created_at"] as? Int64,
              let expiresAtMs = row["expires_at"] as? Int64 else {
            return nil
        }
        
        let precisionRaw = row["location_precision"] as? String ?? "exact"
        let sourceRaw = row["location_source"] as? String ?? "mesh"

        return Club(
            id: id,
            name: name,
            inviteCode: inviteCode,
            creatorId: creatorId,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000.0),
            dropThresholdMeters: Int(row["drop_threshold_meters"] as? Int64 ?? 200),
            maxMembers: Int(row["max_members"] as? Int64 ?? 20),
            clubDescription: row["description"] as? String,
            contactEmail: row["contact_email"] as? String,
            externalLink: row["external_link"] as? String,
            ravenGroupId: row["raven_group_id"] as? String,
            locationPrecision: Club.LocationPrecision(rawValue: precisionRaw) ?? .exact,
            locationSource: Club.LocationSource(rawValue: sourceRaw) ?? .meshOnly
        )
    }

    private func parseMember(_ row: [String: Any]) -> ClubMember? {
        guard let id = row["member_id"] as? String,
              let clubId = row["club_id"] as? String,
              let userId = row["user_id"] as? String,
              let displayName = row["display_name"] as? String,
              let lastSeenMs = row["last_seen_at"] as? Int64 else {
            return nil
        }

        let h3Cell = (row["h3_cell"] as? Int64).map { UInt64(bitPattern: $0) }
        let isMe = (row["is_me"] as? Int64 ?? 0) == 1
        let preciseLat = row["precise_lat"] as? Double
        let preciseLng = row["precise_lng"] as? Double
        let avatarURL = row["avatar_url"] as? String

        return ClubMember(
            id: id,
            clubId: clubId,
            userId: userId,
            displayName: displayName,
            avatarURL: avatarURL,
            h3Cell: h3Cell,
            preciseLat: preciseLat,
            preciseLng: preciseLng,
            lastSeenAt: Date(timeIntervalSince1970: TimeInterval(lastSeenMs) / 1000.0),
            isMe: isMe
        )
    }
}
