import SwiftUI

// MARK: - Login View (Liquid Glass Design)
struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showForgotPassword = false
    
    @State private var authService = AuthService.shared
    @FocusState private var focusedField: Field?
    
    @Environment(\.dismiss) private var dismiss
    
    enum Field {
        case username, password
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 70))
                        .foregroundStyle(.blue)
                        .padding(.bottom, 8)
                    
                    Text("Welcome Back")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Sign in to continue messaging")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                
                // Form
                VStack(spacing: 16) {
                    LiquidGlassTextField(
                        icon: "person",
                        placeholder: "Username or Email",
                        text: $username
                    )
                    .focused($focusedField, equals: .username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    
                    LiquidGlassTextField(
                        icon: "lock",
                        placeholder: "Password",
                        text: $password,
                        isSecure: true
                    )
                    .focused($focusedField, equals: .password)
                    
                    // Forgot Password
                    HStack {
                        Spacer()
                        Button("Forgot Password?") {
                            showForgotPassword = true
                        }
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 24)
                
                // Error
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                
                // Sign In Button
                Button {
                    signIn()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Sign In")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isFormValid ? Color.blue : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isFormValid || isLoading)
                .padding(.horizontal, 24)
                
                // Don't have an account?
                HStack {
                    Text("Don't have an account?")
                        .foregroundStyle(.secondary)
                    Button("Sign Up") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                .font(.subheadline)
                .padding(.top, 8)
                
                Spacer(minLength: 60)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView()
        }
        .onTapGesture {
            focusedField = nil
            hideKeyboard()
        }
    }
    
    // MARK: - Validation
    
    var isFormValid: Bool {
        !username.isEmpty && password.count >= 6
    }
    
    // MARK: - Sign In
    
    private func signIn() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                try await authService.login(
                    username: username.lowercased(),
                    password: password
                )
                
                // AuthGate will handle navigation
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Forgot Password View (3-Step Flow)
struct ForgotPasswordView: View {
    enum Step {
        case enterEmail
        case enterCode
        case newPassword
        case success
    }
    
    @State private var step: Step = .enterEmail
    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icon
                Image(systemName: stepIcon)
                    .font(.system(size: 50))
                    .foregroundStyle(stepColor)
                    .padding(.top, 40)
                
                Text(stepTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(stepSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                // Step-specific content
                switch step {
                case .enterEmail:
                    emailStepView
                case .enterCode:
                    codeStepView
                case .newPassword:
                    passwordStepView
                case .success:
                    successStepView
                }
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                // Action button (not shown on success)
                if step != .success {
                    Button {
                        performAction()
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(buttonTitle)
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isButtonEnabled ? Color.blue : Color.gray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!isButtonEnabled || isLoading)
                    .padding(.horizontal, 24)
                }
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: step)
        }
    }
    
    // MARK: - Step Views
    
    private var emailStepView: some View {
        LiquidGlassTextField(
            icon: "envelope",
            placeholder: "Email",
            text: $email
        )
        .textInputAutocapitalization(.never)
        .keyboardType(.emailAddress)
        .padding(.horizontal, 24)
    }
    
    private var codeStepView: some View {
        VStack(spacing: 12) {
            LiquidGlassTextField(
                icon: "number",
                placeholder: "6-digit code",
                text: $code
            )
            .keyboardType(.numberPad)
            .padding(.horizontal, 24)
            
            Button("Resend Code") {
                resendCode()
            }
            .font(.subheadline)
            .foregroundStyle(.blue)
        }
    }
    
    private var passwordStepView: some View {
        VStack(spacing: 12) {
            LiquidGlassTextField(
                icon: "lock",
                placeholder: "New Password",
                text: $newPassword,
                isSecure: true
            )
            .padding(.horizontal, 24)
            
            LiquidGlassTextField(
                icon: "lock.fill",
                placeholder: "Confirm Password",
                text: $confirmPassword,
                isSecure: true
            )
            .padding(.horizontal, 24)
            
            if !newPassword.isEmpty && newPassword.count < 6 {
                Text("Password must be at least 6 characters")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
    
    private var successStepView: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Password reset successfully!")
            }
            .font(.subheadline)
            
            Button("Return to Login") {
                dismiss()
            }
            .fontWeight(.semibold)
            .foregroundStyle(.blue)
        }
    }
    
    // MARK: - Computed Properties
    
    private var stepIcon: String {
        switch step {
        case .enterEmail: return "key.fill"
        case .enterCode: return "envelope.badge.shield.half.filled"
        case .newPassword: return "lock.rotation"
        case .success: return "checkmark.seal.fill"
        }
    }
    
    private var stepColor: Color {
        switch step {
        case .enterEmail: return .orange
        case .enterCode: return .blue
        case .newPassword: return .purple
        case .success: return .green
        }
    }
    
    private var stepTitle: String {
        switch step {
        case .enterEmail: return "Reset Password"
        case .enterCode: return "Enter Code"
        case .newPassword: return "New Password"
        case .success: return "All Done!"
        }
    }
    
    private var stepSubtitle: String {
        switch step {
        case .enterEmail: return "Enter your email to receive a password reset code"
        case .enterCode: return "We sent a 6-digit code to \(email)"
        case .newPassword: return "Choose a new password for your account"
        case .success: return "Your password has been updated"
        }
    }
    
    private var buttonTitle: String {
        switch step {
        case .enterEmail: return "Send Reset Code"
        case .enterCode: return "Verify Code"
        case .newPassword: return "Set New Password"
        case .success: return ""
        }
    }
    
    private var isButtonEnabled: Bool {
        switch step {
        case .enterEmail: return email.contains("@")
        case .enterCode: return code.count >= 4
        case .newPassword: return newPassword.count >= 6 && newPassword == confirmPassword
        case .success: return false
        }
    }
    
    // MARK: - Actions
    
    private func performAction() {
        switch step {
        case .enterEmail: sendResetCode()
        case .enterCode: verifyCode()
        case .newPassword: resetPassword()
        case .success: break
        }
    }
    
    private func sendResetCode() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                _ = try await AuthService.shared.sendVerificationCode(
                    email: email.lowercased(),
                    purpose: "reset_password"
                )
                await MainActor.run {
                    isLoading = false
                    step = .enterCode
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func resendCode() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                _ = try await AuthService.shared.sendVerificationCode(
                    email: email.lowercased(),
                    purpose: "reset_password"
                )
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func verifyCode() {
        isLoading = true
        errorMessage = nil
        
        // Move to password step (actual code validation happens on final submit)
        Task { @MainActor in
            isLoading = false
            step = .newPassword
        }
    }
    
    private func resetPassword() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                try await AuthService.shared.resetPassword(
                    email: email.lowercased(),
                    code: code,
                    newPassword: newPassword
                )
                await MainActor.run {
                    isLoading = false
                    step = .success
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LoginView()
    }
}
