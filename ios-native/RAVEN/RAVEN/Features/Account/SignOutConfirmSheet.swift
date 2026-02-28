import SwiftUI

// MARK: - Sign Out Confirmation Sheet
/// Professional confirmation sheet for signing out.
/// Calls authService.logout() which clears keychain, DB, caches, and in-memory stores.
struct SignOutConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authService = AuthService.shared
    @State private var isSigningOut = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
            
            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 72, height: 72)
                    
                    Circle()
                        .fill(Color.orange.opacity(0.06))
                        .frame(width: 72, height: 72)
                        .blur(radius: 8)
                    
                    Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 8)
                
                // Title + body
                VStack(spacing: 10) {
                    Text("Sign out?")
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                    
                    Text("You'll need to sign in again to access your account. All local data will be cleared from this device.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                
                // Buttons
                VStack(spacing: 12) {
                    // Sign Out button
                    Button {
                        Task { await performSignOut() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSigningOut {
                                ProgressView()
                                    .tint(.white)
                                Text("Signing out...")
                            } else {
                                Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                                Text("Sign Out")
                            }
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isSigningOut ? Color.orange.opacity(0.6) : Color.orange)
                        )
                        .shadow(color: .orange.opacity(0.25), radius: 8, x: 0, y: 4)
                    }
                    .disabled(isSigningOut)
                    
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
                    .disabled(isSigningOut)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .padding(.top, 16)
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(isSigningOut)
    }
    
    // MARK: - Sign Out Logic
    
    private func performSignOut() async {
        isSigningOut = true
        
        // Warning haptic
        Haptics.warning()
        
        // 1. Dismiss sheet first to avoid dangling presentation crash
        await MainActor.run { dismiss() }
        
        // 2. Wait for dismiss animation to complete
        try? await Task.sleep(nanoseconds: 300_000_000)
        
        // 3. Now safely logout — AuthGateView will redirect to login
        try? await authService.logout()
    }
}
