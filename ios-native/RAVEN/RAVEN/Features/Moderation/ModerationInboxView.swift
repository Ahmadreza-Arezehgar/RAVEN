import SwiftUI

// MARK: - Moderation Inbox View
/// Displays moderation decisions affecting the user with appeal capability.
/// Liquid Glass cards showing Statement of Reasons (DSA Article 17).
struct ModerationInboxView: View {
    @State private var moderationService = ModerationService.shared
    @State private var selectedDecision: ModerationDecision?
    @State private var showAppealSheet = false
    @State private var appealText = ""
    @State private var isSubmittingAppeal = false
    @State private var showAppealSuccess = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if moderationService.myActions.isEmpty {
                    emptyState
                } else {
                    ForEach(moderationService.myActions) { action in
                        DecisionCard(decision: action) {
                            selectedDecision = action
                            appealText = ""
                            showAppealSheet = true
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Moderation Inbox")
        .task {
            await moderationService.fetchMyActions()
        }
        .sheet(isPresented: $showAppealSheet) {
            appealSheet
        }
        .overlay {
            if showAppealSuccess {
                appealSuccessToast
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green.gradient)
            
            Text("All Clear")
                .font(.title2.bold())
            
            Text("No moderation actions on your account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
    
    // MARK: - Appeal Sheet
    
    private var appealSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                // Decision summary
                if let decision = selectedDecision {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(decision.decisionLabel, systemImage: decision.decisionIcon)
                            .font(.headline)
                            .foregroundStyle(decision.decisionColor)
                        
                        if let reason = decision.decisionReason {
                            Text(reason)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        
                        Text("Reason: \(decision.reason.replacingOccurrences(of: "_", with: " ").capitalized)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Divider()
                    
                    // Appeal input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Appeal")
                            .font(.headline)
                        
                        Text("Explain why you believe this decision should be reconsidered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        TextEditor(text: $appealText)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.separator, lineWidth: 0.5)
                            )
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Submit Appeal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAppealSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task { await submitAppeal() }
                    }
                    .disabled(appealText.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 || isSubmittingAppeal)
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    // MARK: - Submit Appeal
    
    private func submitAppeal() async {
        guard let decision = selectedDecision else { return }
        
        isSubmittingAppeal = true
        defer { isSubmittingAppeal = false }
        
        do {
            try await moderationService.submitAppeal(
                reportId: decision.id,
                text: appealText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            showAppealSheet = false
            
            // Show success toast
            withAnimation(.spring(response: 0.4)) {
                showAppealSuccess = true
            }
            
            // Auto-dismiss toast
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation { showAppealSuccess = false }
            }
        } catch {
            #if DEBUG
            print("❌ [Appeal] Submission failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Success Toast
    
    private var appealSuccessToast: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Appeal submitted successfully")
                    .font(.subheadline.bold())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
            .padding(.bottom, 30)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}


// MARK: - Decision Card

struct DecisionCard: View {
    let decision: ModerationDecision
    let onAppeal: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: decision.decisionIcon)
                    .font(.title3.bold())
                    .foregroundStyle(decision.decisionColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.decisionLabel)
                        .font(.headline)
                    
                    if let date = decision.decidedAt {
                        Text(date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
                
                // Appeal badge
                if decision.appealStatus != "none" {
                    Text(decision.appealLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(appealBadgeColor.opacity(0.15))
                        .foregroundStyle(appealBadgeColor)
                        .clipShape(Capsule())
                }
            }
            
            // Reason
            if let reason = decision.decisionReason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            
            // Target info
            HStack(spacing: 6) {
                Image(systemName: targetIcon)
                    .font(.caption)
                Text("\(decision.targetType.capitalized)")
                    .font(.caption)
                
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
                Text("Reported for: \(decision.reason.replacingOccurrences(of: "_", with: " "))")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            
            // Appeal button
            if decision.canAppeal {
                Button(action: onAppeal) {
                    Label("Appeal This Decision", systemImage: "hand.raised.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(decision.decisionColor)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(decision.decisionColor.opacity(0.2), lineWidth: 1)
        )
    }
    
    private var targetIcon: String {
        switch decision.targetType {
        case "post": return "text.bubble"
        case "comment": return "bubble.left"
        case "message": return "envelope"
        case "user": return "person"
        case "group", "room": return "person.3"
        case "story": return "circle.dashed"
        default: return "doc"
        }
    }
    
    private var appealBadgeColor: Color {
        switch decision.appealStatus {
        case "pending": return .orange
        case "accepted": return .green
        case "rejected": return .red
        default: return .gray
        }
    }
}
