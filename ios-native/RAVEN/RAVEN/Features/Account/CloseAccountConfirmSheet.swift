import SwiftUI

// MARK: - Close Account Confirmation Sheet
/// Professional confirmation sheet for irreversible account deletion.
/// Best-effort DELETE /api/users/me, then always performs the authoritative
/// local wipe (AuthService.logout) so the action works in the serverless build.
struct CloseAccountConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authService = AuthService.shared
    @State private var isDeleting = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
            
            VStack(spacing: 24) {
                // Danger icon
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 72, height: 72)
                    
                    Circle()
                        .fill(Color.red.opacity(0.06))
                        .frame(width: 72, height: 72)
                        .blur(radius: 8)
                    
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                }
                .padding(.top, 8)
                
                // Title + body
                VStack(spacing: 10) {
                    Text("Delete your account?")
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                    
                    Text("This will permanently delete your on-device identity, messages, contacts, and media. This action cannot be undone.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)

                // Buttons
                VStack(spacing: 12) {
                    // Delete button (destructive)
                    Button {
                        Task { await performDeletion() }
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                                    .tint(.white)
                                Text("Deleting...")
                            } else {
                                Image(systemName: "trash.fill")
                                Text("Delete Account")
                            }
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isDeleting ? Color.red.opacity(0.6) : Color.red)
                        )
                        .shadow(color: .red.opacity(0.25), radius: 8, x: 0, y: 4)
                    }
                    .disabled(isDeleting)
                    
                    // Cancel button (secondary)
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                    }
                    .disabled(isDeleting)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .padding(.top, 16)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(isDeleting)
    }
    
    // MARK: - Deletion Logic
    
    private func performDeletion() async {
        isDeleting = true

        // Best-effort server delete. The serverless build has no server, so this
        // throws .unauthorized immediately — that must NOT block the local wipe,
        // otherwise the user can never close their account. Mirrors the
        // quick-action path in MainShellView.swift:163-170.
        do {
            try await NetworkService.shared.delete(path: "/api/users/me")
        } catch {
            #if DEBUG
            print("⚠️ Account closure server DELETE failed (serverless/no-server) — wiping locally anyway: \(error)")
            #endif
        }

        // Heavy haptic to register the destructive action.
        await MainActor.run { Haptics.heavy() }

        // Brief pause so haptic registers.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Dismiss sheet first to avoid dangling presentation crash.
        await MainActor.run { dismiss() }

        // Wait for dismiss animation to complete.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Authoritative local wipe (keychain deleteAll, MeshIdentityResolver.reset,
        // ATSAMRootStorage.purgeAll, GroupKeyService.reset, DatabaseService.clearAllData,
        // mesh stop) — runs unconditionally so Close Account is reachable serverless.
        try? await authService.logout()
    }
}
