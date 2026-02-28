import SwiftUI
import Observation

// MARK: - Moderation Service
/// Fetches moderation decisions affecting the current user and handles appeals.
@Observable
final class ModerationService {
    static let shared = ModerationService()
    
    /// Decisions affecting the current user (Statement of Reasons)
    private(set) var myActions: [ModerationDecision] = []
    
    /// Number of unread/new decisions
    var unreadCount: Int {
        myActions.filter { $0.canAppeal }.count
    }
    
    private(set) var isLoading = false
    
    private init() {}
    
    /// Clear all cached moderation data (used on logout)
    func clearActions() {
        myActions = []
    }
    
    // MARK: - Fetch My Actions
    
    /// Fetch moderation decisions that affect the current user.
    func fetchMyActions() async {
        do {
            let actions: [ModerationDecision] = try await NetworkService.shared.get(
                path: "/api/reports/my-actions"
            )
            await MainActor.run {
                self.myActions = actions
            }
            #if DEBUG
            print("⚖️ [ModerationService] Fetched \(actions.count) decisions")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [ModerationService] Failed to fetch actions: \(error)")
            #endif
        }
    }
    
    // MARK: - Submit Appeal
    
    /// Submit an appeal for a moderation decision.
    func submitAppeal(reportId: String, text: String) async throws {
        let body = AppealRequest(text: text)
        let _: AppealResponse = try await NetworkService.shared.post(
            path: "/api/reports/\(reportId)/appeal",
            body: body
        )
        
        // Update local state
        await MainActor.run {
            if let idx = myActions.firstIndex(where: { $0.id == reportId }) {
                myActions[idx].appealStatus = "pending"
                myActions[idx].canAppeal = false
            }
        }
        
        Haptics.success()
        #if DEBUG
        print("📝 [ModerationService] Appeal submitted for \(reportId)")
        #endif
    }
}

// MARK: - Models

struct ModerationDecision: Codable, Identifiable {
    let id: String
    let targetType: String
    let targetId: String
    let reason: String
    let decision: String
    let decisionReason: String?
    let decidedAt: String?
    var appealStatus: String
    var canAppeal: Bool
    
    enum CodingKeys: String, CodingKey {
        case id
        case targetType = "target_type"
        case targetId = "target_id"
        case reason
        case decision
        case decisionReason = "decision_reason"
        case decidedAt = "decided_at"
        case appealStatus = "appeal_status"
        case canAppeal = "can_appeal"
    }
    
    /// Human-readable decision label
    var decisionLabel: String {
        switch decision {
        case "warn": return "Warning Issued"
        case "remove_content": return "Content Removed"
        case "restrict": return "Account Restricted"
        case "tempban": return "Temporary Suspension"
        case "ban": return "Account Banned"
        case "mute": return "Account Muted"
        case "shadowban": return "Visibility Reduced"
        default: return "Action Taken"
        }
    }
    
    /// Icon for decision type
    var decisionIcon: String {
        switch decision {
        case "warn": return "exclamationmark.triangle.fill"
        case "remove_content": return "trash.fill"
        case "restrict": return "lock.fill"
        case "tempban": return "clock.badge.xmark"
        case "ban": return "nosign"
        case "mute": return "speaker.slash.fill"
        case "shadowban": return "eye.slash.fill"
        default: return "gavel.fill"
        }
    }
    
    /// Color for decision severity
    var decisionColor: Color {
        switch decision {
        case "warn": return .orange
        case "remove_content": return .red
        case "restrict", "mute", "shadowban": return .purple
        case "tempban": return .red
        case "ban": return .red
        default: return .gray
        }
    }
    
    /// Human-readable appeal status
    var appealLabel: String {
        switch appealStatus {
        case "pending": return "Appeal Under Review"
        case "accepted": return "Appeal Accepted"
        case "rejected": return "Appeal Rejected"
        default: return ""
        }
    }
}

private struct AppealRequest: Encodable {
    let text: String
}

private struct AppealResponse: Decodable {
    let message: String?
    let appeal_status: String?
}
