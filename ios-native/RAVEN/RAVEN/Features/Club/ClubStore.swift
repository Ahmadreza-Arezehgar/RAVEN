//
//  ClubStore.swift
//  RAVEN
//
//  Observable view model for Club Mode.
//  Manages active club, members, drop detection, and alerts.
//

import Foundation
import Combine

// MARK: - Club Store

@MainActor @Observable
final class ClubStore {
    static let shared = ClubStore()
    
    /// Active flocks the user can see (created/joined).
    var clubs: [Club] = []
    
    /// Active flock the user is currently in.
    var activeClub: Club?
    
    /// Members of the active club.
    var members: [ClubMember] = []
    
    /// Members who have been dropped (> 60s stale).
    var droppedMembers: [ClubMember] {
        members.filter { $0.status == .dropped && !$0.isMe }
    }
    
    /// Whether the user has an active club session.
    var hasActiveSession: Bool { activeClub != nil }
    
    /// Loading state.
    var isLoading: Bool = false
    
    /// Error message.
    var errorMessage: String?
    
    /// Join code input.
    var joinCode: String = ""
    
    /// Alert for dropped members.
    var showDropAlert: Bool = false
    var droppedMemberName: String = ""
    
    /// Track members we've already alerted about (prevent re-fire).
    private var alertedDropIds: Set<String> = []
    private var dropCheckTimer: Timer?
    
    private init() {
        startDropDetection()
    }
    
    // NOTE: deinit removed — ClubStore is a singleton (shared) so the timer
    // lives for the app lifetime. Additionally, deinit runs nonisolated and
    // cannot safely access @MainActor-isolated properties like dropCheckTimer.
    
    // MARK: - Public API
    
    func loadClubs() async {
        isLoading = true
        defer { isLoading = false }
        
        clubs = (try? await ClubRepository.shared.getActiveClubs()) ?? []
        
        // Restore active session if any
        await ClubService.shared.restoreActiveSession()
        syncFromService()
    }
    
    func createClub(
        name: String,
        durationHours: Int,
        dropThresholdMeters: Int,
        clubDescription: String? = nil,
        contactEmail: String? = nil,
        externalLink: String? = nil,
        locationPrecision: Club.LocationPrecision = .exact,
        locationSource: Club.LocationSource = .meshOnly
    ) async -> String? {
        guard let club = await ClubService.shared.createClub(
            name: name,
            durationHours: durationHours,
            dropThresholdMeters: dropThresholdMeters,
            clubDescription: clubDescription,
            contactEmail: contactEmail,
            externalLink: externalLink,
            locationPrecision: locationPrecision,
            locationSource: locationSource
        ) else {
            errorMessage = "Failed to create club"
            return nil
        }
        syncFromService()
        return club.inviteCode
    }
    
    func joinClub() async -> Bool {
        let code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6 else {
            errorMessage = "Invite code must be 6 characters"
            return false
        }
        
        let success = await ClubService.shared.joinClub(inviteCode: code)
        if !success {
            errorMessage = "Club not found or expired"
        }
        syncFromService()
        return success
    }
    
    func leaveClub() async {
        await ClubService.shared.leaveClub()
        alertedDropIds.removeAll()
        syncFromService()
    }
    
    /// Sync stored properties from ClubService
    private func syncFromService() {
        activeClub = ClubService.shared.activeClub
        members = ClubService.shared.members
    }
    
    /// Dismiss drop alert and auto-clear the alerted member after recovery window.
    func dismissDropAlert() {
        showDropAlert = false
        droppedMemberName = ""
    }
    
    // MARK: - Drop Detection
    
    private func startDropDetection() {
        dropCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForDrops()
            }
        }
    }
    
    private func checkForDrops() {
        guard activeClub != nil else { return }
        
        // Clear alerted IDs for members who recovered (back to active/stale)
        let recoveredIds = alertedDropIds.filter { alertedId in
            members.first(where: { $0.userId == alertedId })?.status != .dropped
        }
        alertedDropIds.subtract(recoveredIds)
        
        // Find newly-dropped members we haven't alerted about yet
        for member in members where !member.isMe {
            if member.status == .dropped && !alertedDropIds.contains(member.userId) {
                droppedMemberName = member.displayName
                showDropAlert = true
                alertedDropIds.insert(member.userId)
                
                // Post notification for sound/haptic
                NotificationCenter.default.post(
                    name: .clubMemberDropped,
                    object: nil,
                    userInfo: ["name": member.displayName, "userId": member.userId]
                )
                
                // Auto-dismiss after 10 seconds
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    if self?.showDropAlert == true {
                        self?.dismissDropAlert()
                    }
                }
                
                break // One alert at a time
            }
        }
    }
}
