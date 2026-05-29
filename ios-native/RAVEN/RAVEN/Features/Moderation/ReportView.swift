import SwiftUI

// MARK: - Report Target Type
enum ReportTargetType: String, CaseIterable {
    case post = "post"
    case user = "user"
    case message = "message"
    case comment = "comment"
    case group = "group"
    case room = "room"
    case story = "story"
    case media = "media"
}

// MARK: - Report Reason (from server)
struct ReportReasonItem: Identifiable, Decodable {
    let code: String
    let label: String
    let icon: String
    
    var id: String { code }
}

// MARK: - Report View
struct ReportView: View {
    let targetType: ReportTargetType
    let targetId: String
    var targetName: String? = nil
    var reportedUserId: String? = nil  // Owner of the content
    var context: [String: String]? = nil  // Extra context (conversation_id, etc.)
    
    @Environment(\.dismiss) private var dismiss
    @State private var reasons: [ReportReasonItem] = []
    @State private var selectedReason: ReportReasonItem?
    @State private var additionalNote: String = ""
    @State private var isSubmitting = false
    @State private var isLoadingReasons = true
    @State private var showSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showBlockPrompt = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        
                        Text("Report \(targetType.rawValue.capitalized)")
                            .font(.system(size: 20, weight: .bold))
                        
                        if let name = targetName {
                            Text(name)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        
                        Text("Help us understand what's wrong")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 20)
                    
                    // Reason Selection (dynamic from server)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Why are you reporting this?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        
                        if isLoadingReasons {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(reasons) { reason in
                                    ReportReasonRow(
                                        reason: reason,
                                        isSelected: selectedReason?.code == reason.code,
                                        onTap: {
                                            Haptics.selection()
                                            withAnimation(.spring(response: 0.3)) {
                                                selectedReason = reason
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Additional Note
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Additional details (optional)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        
                        TextEditor(text: $additionalNote)
                            .font(.system(size: 15))
                            .frame(minHeight: 80)
                            .padding(12)
                            .scrollContentBackground(.hidden)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 16)
                    
                    // Submit Button
                    Button {
                        Task { await submitReport() }
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Submit Report")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedReason == nil ? Color.gray : Color.red)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(selectedReason == nil || isSubmitting)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    
                    // Info Text
                    Text("Reports are reviewed by our team. False reports may result in action against your account.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 20)
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadReasons()
            }
            .alert("Report Submitted", isPresented: $showSuccess) {
                if reportedUserId != nil {
                    Button("Block User") {
                        showBlockPrompt = true
                    }
                    Button("Done") {
                        dismiss()
                    }
                } else {
                    Button("OK") { dismiss() }
                }
            } message: {
                if reportedUserId != nil {
                    Text("Thank you. Would you also like to block this user?")
                } else {
                    Text("Thank you for helping keep RAVEN safe.")
                }
            }
            .alert("Block User?", isPresented: $showBlockPrompt) {
                Button("Block", role: .destructive) {
                    Task { await blockAfterReport() }
                }
                Button("No Thanks", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("They won't be able to see your profile, posts, or message you.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    // MARK: - Load Dynamic Reasons
    private func loadReasons() async {
        do {
            let items: [ReportReasonItem] = try await NetworkService.shared.get(
                path: "/api/reports/reasons",
                queryItems: [URLQueryItem(name: "object_type", value: targetType.rawValue)]
            )
            await MainActor.run {
                reasons = items
                isLoadingReasons = false
            }
        } catch {
            // Fallback to static reasons
            await MainActor.run {
                reasons = Self.fallbackReasons
                isLoadingReasons = false
            }
        }
    }
    
    // MARK: - Submit Report
    private func submitReport() async {
        guard let reason = selectedReason else { return }

        // 🔴 ROUND 26 — unified user-action telemetry (haptic + bg server log).
        UserActionTelemetry.shared.record(
            .report,
            targetId: targetId,
            targetType: UserActionTarget(rawValue: targetType.rawValue),
            metadata: ["reason": reason.code]
        )

        // ⚡ Optimistic: show success immediately
        Haptics.success()
        showSuccess = true
        
        do {
            let payload = ReportPayload(
                target_type: targetType.rawValue,
                target_id: targetId,
                reported_user_id: reportedUserId,
                reason: reason.code,
                note: additionalNote.isEmpty ? nil : additionalNote,
                context: context
            )
            
            let _: ReportAPIResponse = try await NetworkService.shared.post(
                path: "/api/reports",
                body: payload
            )
            // Server confirmed — success alert already showing
        } catch {
            // Rollback: hide success and show error
            await MainActor.run {
                showSuccess = false
                errorMessage = "Failed to submit report. Please try again."
                showError = true
                Haptics.error()
            }
        }
    }
    
    // MARK: - Block After Report
    private func blockAfterReport() async {
        guard let userId = reportedUserId else { dismiss(); return }
        
        do {
            _ = try await BlockService.shared.blockUser(userId: userId)
        } catch {
            #if DEBUG
            print("⚠️ Block after report failed: \(error)")
            #endif
        }
        
        await MainActor.run { dismiss() }
    }
    
    // MARK: - Fallback Reasons
    static let fallbackReasons: [ReportReasonItem] = [
        .init(code: "spam", label: "Spam / Scam", icon: "envelope.badge.fill"),
        .init(code: "harassment", label: "Harassment / Bullying", icon: "person.fill.xmark"),
        .init(code: "hate_speech", label: "Hate Speech", icon: "exclamationmark.bubble.fill"),
        .init(code: "violence", label: "Violence / Dangerous Content", icon: "flame.fill"),
        .init(code: "nudity", label: "Nudity / Sexual Content", icon: "eye.slash.fill"),
        .init(code: "illegal", label: "Illegal Content", icon: "hand.raised.fill"),
        .init(code: "impersonation", label: "Impersonation", icon: "person.2.fill"),
        .init(code: "privacy", label: "Privacy Violation", icon: "lock.slash.fill"),
        .init(code: "self_harm", label: "Self-harm / Suicide", icon: "heart.slash.fill"),
        .init(code: "false_info", label: "False Information", icon: "xmark.seal.fill"),
        .init(code: "other", label: "Other", icon: "ellipsis.circle.fill"),
    ]
}

// MARK: - Report Reason Row
struct ReportReasonRow: View {
    let reason: ReportReasonItem
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: reason.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 36, height: 36)
                    .background(isSelected ? Color.red : Color.secondary.opacity(0.15))
                    .clipShape(Circle())
                
                Text(reason.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.red.opacity(0.5) : Color.white.opacity(0.15), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Report Payload
private struct ReportPayload: Encodable {
    let target_type: String
    let target_id: String
    let reported_user_id: String?
    let reason: String
    let note: String?
    let context: [String: String]?
}

// MARK: - Report Response
private struct ReportAPIResponse: Decodable {
    let id: String?
    let success: Bool?
}

// MARK: - Preview
#Preview {
    ReportView(targetType: .post, targetId: "123", targetName: "Example Post", reportedUserId: "user-456")
}
