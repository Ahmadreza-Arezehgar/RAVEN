import SwiftUI

// MARK: - OTP Verification View
struct OTPVerificationView: View {
    let email: String
    let onVerified: () -> Void
    
    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expirationDate = Date().addingTimeInterval(300)  // 5 minutes (matches server)
    @State private var canResend = true  // Enable resend from start
    @State private var resendCooldownEnd = Date.distantPast
    
    // ✅ @State vars that drive the UI — updated every tick for live countdown
    @State private var displaySeconds: Int = 300
    @State private var displayResendCooldown: Int = 0
    
    @State private var authService = AuthService.shared
    @State private var showChangeEmail = false
    @State private var showLogoutConfirm = false
    
    @Environment(\.dismiss) private var dismiss
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Header
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.blue.opacity(0.1))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                }
                
                Text("Verify Your Email")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("We sent a 6-digit code to")
                    .foregroundStyle(.secondary)
                
                Text(email)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
            }
            
            // OTP Input
            OTPInputView(code: $code)
                .onChange(of: code) { _, newValue in
                    if newValue.count == 6 {
                        verify()
                    }
                }
            
            // Timer
            VStack(spacing: 8) {
                if displaySeconds > 0 {
                    Text("Code expires in \(formattedTime)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Code expired — request a new one")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            
            // Error
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal)
            }
            
            // Verify Button
            Button {
                verify()
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Verify")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(code.count == 6 && displaySeconds > 0 ? Color.blue : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(code.count != 6 || isLoading || displaySeconds == 0)
            .padding(.horizontal, 24)
            
            // Resend
            HStack {
                Text("Didn't receive code?")
                    .foregroundStyle(.secondary)
                
                if displayResendCooldown > 0 {
                    Text("Resend in \(displayResendCooldown)s")
                        .foregroundStyle(.gray)
                } else {
                    Button("Resend") {
                        resendCode()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canResend)
                }
            }
            .font(.subheadline)
            
            Spacer()
            
            // Escape routes
            VStack(spacing: 12) {
                Button("Use different email") {
                    showChangeEmail = true
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                Button("Log out and start over") {
                    showLogoutConfirm = true
                }
                .font(.caption)
                .foregroundStyle(.red.opacity(0.7))
            }
            .padding(.bottom, 32)
        }
        .padding()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    showLogoutConfirm = true
                }
            }
        }
        .onReceive(timer) { _ in
            // ✅ Update @State vars every tick — drives live UI countdown
            displaySeconds = max(0, Int(expirationDate.timeIntervalSinceNow))
            displayResendCooldown = max(0, Int(resendCooldownEnd.timeIntervalSinceNow))
            if !canResend && displayResendCooldown == 0 {
                canResend = true
            }
        }
        .alert("Log Out?", isPresented: $showLogoutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                logout()
            }
        } message: {
            Text("You'll need to create a new account or sign in again.")
        }
        .onTapGesture { hideKeyboard() }
        .sheet(isPresented: $showChangeEmail) {
            ChangeEmailSheet(currentEmail: email) { newEmail in
                // Resend to new email
                Task {
                    _ = try? await authService.sendVerificationCode(email: newEmail)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    var formattedTime: String {
        let minutes = displaySeconds / 60
        let secs = displaySeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
    
    // MARK: - Verify
    
    private func verify() {
        guard code.count == 6, displaySeconds > 0 else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                try await authService.verifyCode(email: email, code: code)
                
                await MainActor.run {
                    isLoading = false
                    onVerified()
                }
            } catch let error as APIError {
                await MainActor.run {
                    isLoading = false
                    errorMessage = friendlyError(error)
                    code = ""
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    code = ""
                }
            }
        }
    }
    
    private func friendlyError(_ error: APIError) -> String {
        switch error {
        case .badRequest(let msg):
            if msg.lowercased().contains("expired") {
                return "Code expired. Please request a new one."
            } else if msg.lowercased().contains("invalid") {
                return "Invalid code. Please check and try again."
            }
            return msg
        case .rateLimited:
            return "Too many attempts. Please wait a moment."
        default:
            return error.localizedDescription
        }
    }
    
    // MARK: - Resend
    
    private func resendCode() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                _ = try await authService.sendVerificationCode(email: email)
                
                await MainActor.run {
                    isLoading = false
                    expirationDate = Date().addingTimeInterval(300)
                    resendCooldownEnd = Date().addingTimeInterval(60)  // 60s cooldown before next resend
                    canResend = false
                    code = ""
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    // MARK: - Logout
    
    private func logout() {
        Task {
            try? await authService.logout()
        }
    }
}

// MARK: - Change Email Sheet
struct ChangeEmailSheet: View {
    let currentEmail: String
    let onSubmit: (String) -> Void
    
    @State private var newEmail = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Enter your new email address")
                    .font(.headline)
                    .padding(.top, 32)
                
                LiquidGlassTextField(
                    icon: "envelope",
                    placeholder: "New email",
                    text: $newEmail
                )
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .padding(.horizontal)
                
                Button {
                    onSubmit(newEmail.lowercased())
                    dismiss()
                } label: {
                    Text("Send Code to New Email")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(newEmail.contains("@") ? Color.blue : Color.gray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!newEmail.contains("@"))
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Change Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        OTPVerificationView(email: "user@example.com") {
            print("Verified!")
        }
    }
}
