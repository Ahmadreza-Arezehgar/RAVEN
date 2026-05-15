import SwiftUI
import AuthenticationServices

// MARK: - Auth Landing View (Professional 4-CTA)
// OAuth buttons prominent at top, Email actions below

struct AuthLandingView: View {
    @State private var authService = AuthService.shared
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    // OAuth Coordinators (held in state to survive async flow)
    @State private var googleSignInCoordinator: GoogleSignInCoordinator?
    @State private var appleSignInCoordinator: AppleSignInCoordinator?
    
    // Navigation states
    @State private var showEmailSignup = false
    @State private var showEmailLogin = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                
                // MARK: - Logo Section
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue.opacity(0.2), .purple.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 140, height: 140)
                            .blur(radius: 2)
                        
                        Image("RavenLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 90, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    
                    VStack(spacing: 8) {
                        Text("RAVEN")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Secure messaging with or without internet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                
                Spacer()
                
                // MARK: - Features
                VStack(spacing: 12) {
                    FeatureRow(icon: "lock.shield", title: "Secure & private messaging")
                    FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "Works offline via mesh")
                    FeatureRow(icon: "bolt.fill", title: "Fast and reliable")
                }
                .padding(.horizontal, 48)
                
                Spacer()
                
                // MARK: - OAuth Buttons (Top Priority)
                VStack(spacing: 12) {
                    // Continue with Google
                    SocialSignInButton(provider: .google) {
                        signInWithGoogle()
                    }
                    .disabled(isLoading)
                    
                    // Continue with Apple (Official Apple button — required by Guideline 4.8)
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleAppleSignInResult(result)
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .disabled(isLoading)
                }
                .padding(.horizontal, 24)
                
                // MARK: - Divider
                HStack {
                    Rectangle()
                        .fill(.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    Rectangle()
                        .fill(.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
                
                // MARK: - Email Buttons (Secondary)
                VStack(spacing: 12) {
                    // Create account (Email)
                    Button {
                        showEmailSignup = true
                    } label: {
                        Text("Create account (Email)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(
                                    colors: [.blue, .blue.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isLoading)
                    
                    // Login (Email)
                    Button {
                        showEmailLogin = true
                    } label: {
                        Text("Login (Email)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .disabled(isLoading)
                }
                .padding(.horizontal, 24)
                
                // MARK: - Error Message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }
                
                // MARK: - Loading Indicator
                if isLoading {
                    ProgressView()
                        .padding(.top, 12)
                }
                
                Spacer()
                    .frame(height: 48)
            }
            .navigationDestination(isPresented: $showEmailSignup) {
                SignUpView()
            }
            .navigationDestination(isPresented: $showEmailLogin) {
                LoginView()
            }
        }
    }
    
    // MARK: - Google Sign In
    
    private func signInWithGoogle() {
        #if DEBUG
        print("🔵 [AuthLanding] Google Sign In tapped")
        #endif
        isLoading = true
        errorMessage = nil
        
        googleSignInCoordinator = GoogleSignInCoordinator { result in
            Task { @MainActor in
                switch result {
                case .success(let credential):
                    await handleGoogleCredential(credential)
                case .failure(let error):
                    isLoading = false
                    if case GoogleSignInError.cancelled = error {
                        // User cancelled - no error message
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        googleSignInCoordinator?.startSignIn()
    }
    
    private func handleGoogleCredential(_ credential: GoogleSignInCoordinator.GoogleCredential) async {
        do {
            let requiresUsername = try await authService.googleSignIn(idToken: credential.idToken)
            isLoading = false
            
            if requiresUsername {
                // AuthGate will automatically show UsernameSelectionView
                #if DEBUG
                print("✅ [AuthLanding] Google OAuth complete - needs username")
                #endif
            } else {
                // AuthGate will automatically show MainTabView
                #if DEBUG
                print("✅ [AuthLanding] Google OAuth complete - existing user")
                #endif
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Apple Sign In (Official SignInWithAppleButton result handler)
    
    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  let authCodeData = appleIDCredential.authorizationCode,
                  let authorizationCode = String(data: authCodeData, encoding: .utf8) else {
                errorMessage = "Failed to get Apple credentials"
                return
            }
            
            isLoading = true
            errorMessage = nil
            
            // Convert PersonNameComponents to String (same logic as AppleSignInCoordinator)
            var fullName: String? = nil
            if let nameComponents = appleIDCredential.fullName {
                let firstName = nameComponents.givenName ?? ""
                let lastName = nameComponents.familyName ?? ""
                if !firstName.isEmpty || !lastName.isEmpty {
                    fullName = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
                }
            }
            let email = appleIDCredential.email
            
            let credential = AppleSignInCoordinator.AppleCredential(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                fullName: fullName,
                email: email
            )
            
            Task { @MainActor in
                await handleAppleCredential(credential)
            }
            
        case .failure(let error):
            // ASAuthorizationError.canceled = user tapped cancel
            if (error as? ASAuthorizationError)?.code == .canceled {
                // User cancelled - no error message
                #if DEBUG
                print("🍎 [AuthLanding] Apple Sign In cancelled by user")
                #endif
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func handleAppleCredential(_ credential: AppleSignInCoordinator.AppleCredential) async {
        do {
            let requiresUsername = try await authService.appleSignIn(
                identityToken: credential.identityToken,
                authorizationCode: credential.authorizationCode,
                fullName: credential.fullName,
                email: credential.email
            )
            isLoading = false
            
            if requiresUsername {
                // AuthGate will automatically show UsernameSelectionView
                #if DEBUG
                print("✅ [AuthLanding] Apple OAuth complete - needs username")
                #endif
            } else {
                // AuthGate will automatically show MainTabView
                #if DEBUG
                print("✅ [AuthLanding] Apple OAuth complete - existing user")
                #endif
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

// Note: FeatureRow is defined in AuthGateView.swift

#Preview {
    AuthLandingView()
}
