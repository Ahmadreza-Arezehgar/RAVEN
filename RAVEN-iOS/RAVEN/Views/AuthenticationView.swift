// RAVEN - Authentication View
// Converted from Flutter sign_in_screen.dart, sign_up_screen.dart

import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject var authService: AuthService
    @State private var mode: AuthMode = .signIn
    
    // Sign In fields
    @State private var username = ""
    @State private var password = ""
    
    // Sign Up fields
    @State private var signUpUsername = ""
    @State private var signUpEmail = ""
    @State private var signUpPassword = ""
    @State private var signUpConfirmPassword = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var birthYear = Calendar.current.component(.year, from: Date()) - 18
    
    // Forgot Password
    @State private var resetEmail = ""
    
    @State private var showPassword = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    enum AuthMode {
        case signIn, signUp, forgotPassword
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Logo
                VStack(spacing: 16) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.linearGradient(colors: [.ravenPrimary, .ravenSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                    
                    Text("RAVEN")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.linearGradient(colors: [.ravenPrimary, .ravenSecondary], startPoint: .leading, endPoint: .trailing))
                    
                    Text(modeTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 60)
                
                // Form
                VStack(spacing: 16) {
                    switch mode {
                    case .signIn:
                        signInForm
                    case .signUp:
                        signUpForm
                    case .forgotPassword:
                        forgotPasswordForm
                    }
                }
                .padding(.horizontal)
                
                // Error message
                if let error = errorMessage ?? authService.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
                
                // Submit Button
                Button(action: submit) {
                    HStack {
                        if isLoading || authService.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text(submitButtonTitle)
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.ravenGradient)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isLoading || authService.isLoading)
                .padding(.horizontal)
                
                // Divider
                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal, 32)
                
                // Social login
                HStack(spacing: 16) {
                    socialButton(icon: "apple.logo", label: "Apple") {
                        // Apple Sign In
                    }
                    
                    socialButton(icon: "g.circle.fill", label: "Google") {
                        // Google Sign In
                    }
                }
                .padding(.horizontal)
                
                // Mode switch
                Button(action: toggleMode) {
                    Text(modeToggleText)
                        .font(.subheadline)
                        .foregroundColor(.ravenPrimary)
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color.black)
        .onTapGesture { hideKeyboard() }
    }
    
    // MARK: - Sign In Form
    @ViewBuilder
    var signInForm: some View {
        textField("Username", text: $username, icon: "person")
        
        HStack {
            Group {
                if showPassword {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .textContentType(.password)
            
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .glassBackground(cornerRadius: 12)
        
        HStack {
            Spacer()
            Button("Forgot Password?") {
                withAnimation { mode = .forgotPassword }
            }
            .font(.caption)
            .foregroundColor(.ravenPrimary)
        }
    }
    
    // MARK: - Sign Up Form
    @ViewBuilder
    var signUpForm: some View {
        HStack(spacing: 12) {
            textField("First Name", text: $firstName, icon: "person")
            textField("Last Name", text: $lastName, icon: "person")
        }
        
        textField("Username", text: $signUpUsername, icon: "at")
        textField("Email", text: $signUpEmail, icon: "envelope")
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
        
        // Birth Year Picker
        HStack {
            Image(systemName: "calendar")
                .foregroundColor(.secondary)
            
            Picker("Birth Year", selection: $birthYear) {
                ForEach((1920...Calendar.current.component(.year, from: Date()) - 13), id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.menu)
            
            Spacer()
        }
        .padding()
        .glassBackground(cornerRadius: 12)
        
        secureField("Password", text: $signUpPassword)
        secureField("Confirm Password", text: $signUpConfirmPassword)
    }
    
    // MARK: - Forgot Password Form
    @ViewBuilder
    var forgotPasswordForm: some View {
        Text("Enter your email and we'll send you instructions to reset your password.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        
        textField("Email", text: $resetEmail, icon: "envelope")
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
        
        Button("Back to Sign In") {
            withAnimation { mode = .signIn }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
    
    // MARK: - Helpers
    @ViewBuilder
    func textField(_ placeholder: String, text: Binding<String>, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .autocapitalization(.none)
        }
        .padding()
        .glassBackground(cornerRadius: 12)
    }
    
    @ViewBuilder
    func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Image(systemName: "lock")
                .foregroundColor(.secondary)
            SecureField(placeholder, text: text)
        }
        .padding()
        .glassBackground(cornerRadius: 12)
    }
    
    @ViewBuilder
    func socialButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(label)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .glassBackground(cornerRadius: 12)
        }
        .foregroundColor(.primary)
    }
    
    var modeTitle: String {
        switch mode {
        case .signIn: return "Sign in to continue"
        case .signUp: return "Create your account"
        case .forgotPassword: return "Reset password"
        }
    }
    
    var submitButtonTitle: String {
        switch mode {
        case .signIn: return "Sign In"
        case .signUp: return "Create Account"
        case .forgotPassword: return "Send Reset Link"
        }
    }
    
    var modeToggleText: String {
        switch mode {
        case .signIn: return "Don't have an account? Sign Up"
        case .signUp: return "Already have an account? Sign In"
        case .forgotPassword: return ""
        }
    }
    
    func toggleMode() {
        withAnimation {
            mode = mode == .signIn ? .signUp : .signIn
            errorMessage = nil
        }
    }
    
    func submit() {
        errorMessage = nil
        isLoading = true
        
        Task {
            do {
                switch mode {
                case .signIn:
                    try await authService.signIn(username: username, password: password)
                    
                case .signUp:
                    guard signUpPassword == signUpConfirmPassword else {
                        errorMessage = "Passwords don't match"
                        isLoading = false
                        return
                    }
                    try await authService.signUp(
                        username: signUpUsername,
                        password: signUpPassword,
                        firstName: firstName,
                        lastName: lastName,
                        birthYear: birthYear,
                        email: signUpEmail.isEmpty ? nil : signUpEmail
                    )
                    
                case .forgotPassword:
                    try await authService.sendVerificationCode(to: resetEmail)
                    // Show success message
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    AuthenticationView()
        .environmentObject(AuthService.shared)
        .preferredColorScheme(.dark)
}
