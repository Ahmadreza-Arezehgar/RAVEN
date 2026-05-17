import SwiftUI

// MARK: - Sign Up View (Liquid Glass Design)
struct SignUpView: View {
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var birthYear = ""
    @State private var agreedToTerms = false
    
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var emailError: String?        // Inline email-specific error
    @State private var isCheckingEmail = false     // Spinner on email field
    @State private var emailIsAvailable: Bool?     // nil = unchecked, true/false = result
    @State private var showOTPView = false
    @State private var showTerms = false
    @State private var showPrivacy = false
    
    @State private var authService = AuthService.shared
    @FocusState private var focusedField: Field?
    
    // Debounce email check
    @State private var emailCheckTask: Task<Void, Never>?
    
    @Environment(\.dismiss) private var dismiss
    
    enum Field {
        case firstName, lastName, username, email, password, confirm, birthYear
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue.opacity(0.2), .purple.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 100, height: 100)
                            .blur(radius: 2)

                        Image("RavenLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.bottom, 2)

                    Text("Create Account")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Join the secure messaging network")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                
                // Form
                VStack(spacing: 16) {
                    // Name Row
                    HStack(spacing: 12) {
                        LiquidGlassTextField(
                            icon: "person",
                            placeholder: "First Name",
                            text: $firstName
                        )
                        .focused($focusedField, equals: .firstName)
                        
                        LiquidGlassTextField(
                            icon: "person",
                            placeholder: "Last Name",
                            text: $lastName
                        )
                        .focused($focusedField, equals: .lastName)
                    }
                    
                    LiquidGlassTextField(
                        icon: "at",
                        placeholder: "Username",
                        text: $username
                    )
                    .focused($focusedField, equals: .username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    
                    // Email field + inline error
                    VStack(spacing: 6) {
                        LiquidGlassTextField(
                            icon: "envelope",
                            placeholder: "Email",
                            text: $email
                        )
                        .focused($focusedField, equals: .email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .overlay(alignment: .trailing) {
                            if isCheckingEmail {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 12)
                            } else if emailIsAvailable == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .padding(.trailing, 12)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .onChange(of: email) { _, newValue in
                            onEmailChanged(newValue)
                        }
                        
                        // Liquid glass capsule error banner
                        if let emailErr = emailError {
                            EmailErrorBanner(message: emailErr)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.9).combined(with: .opacity).combined(with: .move(edge: .top)),
                                    removal: .opacity
                                ))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: emailError)
                    
                    LiquidGlassTextField(
                        icon: "lock",
                        placeholder: "Password (min 10 chars)",
                        text: $password,
                        isSecure: true
                    )
                    .focused($focusedField, equals: .password)
                    
                    LiquidGlassTextField(
                        icon: "lock.fill",
                        placeholder: "Confirm Password",
                        text: $confirmPassword,
                        isSecure: true
                    )
                    .focused($focusedField, equals: .confirm)
                    
                    LiquidGlassTextField(
                        icon: "calendar",
                        placeholder: "Birth Year (e.g. 1995)",
                        text: $birthYear
                    )
                    .focused($focusedField, equals: .birthYear)
                    .keyboardType(.numberPad)
                    
                    // Password Requirements
                    PasswordRequirementsView(password: password)
                }
                .padding(.horizontal, 24)
                
                // Error
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                
                // Terms Agreement
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        agreedToTerms.toggle()
                    } label: {
                        Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                            .foregroundStyle(agreedToTerms ? .blue : .secondary)
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    
                    HStack(spacing: 0) {
                        Text("I agree to the ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button { showTerms = true } label: {
                            Text("Terms of Service")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        
                        Text(" and ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button { showPrivacy = true } label: {
                            Text("Privacy Policy")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                
                // Sign Up Button
                Button {
                    signUp()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Create Account")
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
                
                // Already have account
                HStack {
                    Text("Already have an account?")
                        .foregroundStyle(.secondary)
                    Button("Sign In") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                .font(.subheadline)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showOTPView) {
            NavigationStack {
                OTPVerificationView(email: email, purpose: "registration") {
                    // Verified - dismiss and AuthGate will handle navigation
                    showOTPView = false
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showOTPView = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showTerms) {
            TermsOfServiceSheet()
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                PrivacyPolicyView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPrivacy = false }
                        }
                    }
            }
        }
        .onTapGesture {
            focusedField = nil
            hideKeyboard()
        }
    }
    
    // MARK: - Validation
    
    var isFormValid: Bool {
        !firstName.isEmpty &&
        !lastName.isEmpty &&
        username.count >= 3 &&
        email.contains("@") &&
        password.count >= 10 &&
        password == confirmPassword &&
        birthYear.count == 4 &&
        agreedToTerms &&
        emailError == nil &&       // No email error
        emailIsAvailable != false  // Email must not be taken
    }
    
    // MARK: - Email Check (Debounced)
    
    private func onEmailChanged(_ newEmail: String) {
        // Reset state
        emailError = nil
        emailIsAvailable = nil
        emailCheckTask?.cancel()
        
        let trimmed = newEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only check if it looks like a valid email
        guard trimmed.contains("@"), trimmed.contains("."), trimmed.count >= 5 else {
            return
        }
        
        // Debounce 0.8s
        emailCheckTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            
            await MainActor.run { isCheckingEmail = true }
            
            do {
                let result = try await authService.checkEmailAndSendCode(email: trimmed)
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    isCheckingEmail = false
                    if result.available {
                        emailIsAvailable = true
                        emailError = nil
                    } else {
                        emailIsAvailable = false
                        emailError = result.message
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isCheckingEmail = false
                    // Network error — don't block the user, just clear status
                    emailIsAvailable = nil
                    emailError = nil
                }
            }
        }
    }
    
    // MARK: - Sign Up
    
    private func signUp() {
        guard let year = Int(birthYear) else {
            errorMessage = "Invalid birth year"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // Step 1: If email wasn't already checked (or check expired), verify now
                if emailIsAvailable != true {
                    let result = try await authService.checkEmailAndSendCode(email: email.lowercased())
                    if !result.available {
                        await MainActor.run {
                            isLoading = false
                            emailError = result.message
                            emailIsAvailable = false
                        }
                        return
                    }
                }
                
                // Step 2: Register the user
                try await authService.register(
                    username: username.lowercased(),
                    password: password,
                    firstName: firstName,
                    lastName: lastName,
                    birthYear: year,
                    email: email.lowercased()
                )
                
                // Step 3: Verification code was already sent in Step 1
                // Go straight to OTP screen
                await MainActor.run {
                    isLoading = false
                    showOTPView = true
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

// MARK: - Email Error Banner (Liquid Glass Capsule)
struct EmailErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
            
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: Capsule())
        .overlay(
            Capsule().strokeBorder(.red.opacity(0.30), lineWidth: 0.6) // error tint on top of unified surface
        )
        .padding(.horizontal, 4)
    }
}

// MARK: - Password Requirements View
struct PasswordRequirementsView: View {
    let password: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RequirementRow(met: password.count >= 10, text: "At least 10 characters")
            RequirementRow(met: password.contains(where: \.isUppercase), text: "One uppercase letter")
            RequirementRow(met: password.contains(where: \.isLowercase), text: "One lowercase letter")
            RequirementRow(met: password.contains(where: \.isNumber), text: "One number")
            RequirementRow(met: password.contains(where: { "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains($0) }), text: "One special character")
        }
        .font(.caption)
    }
}

struct RequirementRow: View {
    let met: Bool
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? .green : .secondary)
                .font(.caption)
            Text(text)
                .foregroundStyle(met ? .primary : .secondary)
        }
    }
}

// MARK: - Terms of Service Sheet
struct TermsOfServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    private let sections: [(icon: String, title: String, body: String)] = [
        ("person.crop.circle", "Account",
         "You must be at least 13 years old to create an account. You are responsible for keeping your credentials secure and for all activity under your account."),
        ("bubble.left.and.text.bubble.right", "Content & Conduct",
         "You retain ownership of content you create. You may not use RAVEN to send spam, harass others, distribute illegal content, or impersonate someone else. We may remove content that violates these rules."),
        ("nosign", "Zero Tolerance Policy",
         "RAVEN has a zero-tolerance policy for objectionable content or abusive behavior. Any user who posts offensive, hateful, or inappropriate content, or engages in bullying, harassment, or threats, will have their account terminated immediately. You can report or block any user or content directly within the app."),
        ("lock.shield", "Security & Privacy",
         "Messages are encrypted in transit and at rest. We do not sell your data or show ads. See the Privacy Policy for full details on data collection and retention."),
        ("antenna.radiowaves.left.and.right", "Mesh Networking",
         "When mesh mode is enabled, your device may relay encrypted messages for nearby users. You cannot read relayed content — it is end-to-end encrypted."),
        ("exclamationmark.triangle", "Termination",
         "We may suspend or terminate accounts that violate these terms. You can delete your account at any time — all personal data is permanently removed within 30 days."),
        ("hand.raised", "Disclaimer",
         "RAVEN is provided \"as is\" without warranty. We are not liable for message delivery failures, data loss, or service interruptions. Use at your own risk."),
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)
                        
                        Text("Terms of Service")
                            .font(.title2.bold())
                        
                        Text("Last updated: February 10, 2025")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    
                    // Sections
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: section.icon)
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                            
                            Text(section.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    
                    // Contact
                    Text("Questions? Email privacy@raven-messager.com")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("Terms of Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SignUpView()
    }
}
