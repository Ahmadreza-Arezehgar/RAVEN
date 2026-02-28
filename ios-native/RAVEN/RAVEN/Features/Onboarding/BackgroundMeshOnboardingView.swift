//
//  BackgroundMeshOnboardingView.swift
//  RAVEN
//
//  One-time onboarding prompt explaining the background mesh feature
//  and asking for location permission to enable it.
//

import SwiftUI
import CoreLocation

struct BackgroundMeshOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var backgroundManager = BackgroundMeshManager.shared
    
    @State private var currentStep = 0
    @State private var isRequestingPermission = false
    
    private let steps = [
        OnboardingStep(
            icon: "antenna.radiowaves.left.and.right.circle.fill",
            title: "Mesh Network",
            description: "RAVEN can send messages between nearby devices using Bluetooth, even without internet."
        ),
        OnboardingStep(
            icon: "arrow.triangle.2.circlepath.circle.fill",
            title: "Help Others Communicate",
            description: "Your device can relay messages for other users, helping everyone stay connected even in areas with poor coverage."
        ),
        OnboardingStep(
            icon: "moon.stars.circle.fill",
            title: "Works in Background",
            description: "Enable background relay to keep the mesh active even when the app is closed. Messages will reach their destination faster."
        )
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button {
                    skipOnboarding()
                } label: {
                    Text("Skip")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            
            Spacer()
            
            // Step content
            VStack(spacing: 24) {
                // Icon
                Image(systemName: steps[currentStep].icon)
                    .font(.system(size: 80))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolRenderingMode(.hierarchical)
                
                // Title
                Text(steps[currentStep].title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                // Description
                Text(steps[currentStep].description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .animation(.easeInOut(duration: 0.3), value: currentStep)
            
            Spacer()
            
            // Page indicators
            HStack(spacing: 8) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 32)
            
            // Buttons
            VStack(spacing: 12) {
                if currentStep < steps.count - 1 {
                    // Next button
                    Button {
                        withAnimation {
                            currentStep += 1
                        }
                    } label: {
                        Text("Next")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(14)
                    }
                } else {
                    // Enable button
                    Button {
                        enableBackgroundMesh()
                    } label: {
                        HStack {
                            if isRequestingPermission {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "bolt.fill")
                                Text("Enable Background Relay")
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(14)
                    }
                    .disabled(isRequestingPermission)
                    
                    // Maybe later button
                    Button {
                        skipOnboarding()
                    } label: {
                        Text("Maybe Later")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Check if permission was granted after returning from Settings
            if isRequestingPermission {
                checkPermissionAndComplete()
            }
        }
    }
    
    private func enableBackgroundMesh() {
        isRequestingPermission = true
        
        let status = backgroundManager.locationAuthorizationStatus
        
        switch status {
        case .notDetermined:
            backgroundManager.requestLocationPermission()
            // Wait for permission response
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                checkPermissionAndComplete()
            }
            
        case .authorizedAlways:
            backgroundManager.startBackgroundLocationAnchor()
            completeOnboarding(enabled: true)
            
        case .authorizedWhenInUse:
            // Need Always permission - show settings prompt
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            
        case .denied, .restricted:
            // Permission denied - complete without enabling
            completeOnboarding(enabled: false)
            
        @unknown default:
            completeOnboarding(enabled: false)
        }
    }
    
    private func checkPermissionAndComplete() {
        let status = backgroundManager.locationAuthorizationStatus
        
        if status == .authorizedAlways {
            backgroundManager.startBackgroundLocationAnchor()
            completeOnboarding(enabled: true)
        } else if status == .authorizedWhenInUse {
            // Partial permission - still enable what we can
            completeOnboarding(enabled: false)
        } else if status == .denied || status == .restricted {
            completeOnboarding(enabled: false)
        }
        // If still notDetermined, wait for callback
    }
    
    private func skipOnboarding() {
        completeOnboarding(enabled: false)
    }
    
    private func completeOnboarding(enabled: Bool) {
        // Mark as shown
        UserDefaults.standard.set(true, forKey: "mesh.onboarding.shown")
        UserDefaults.standard.set(enabled, forKey: "mesh.background.userEnabled")
        
        isRequestingPermission = false
        dismiss()
    }
}

// MARK: - Onboarding Step Model

private struct OnboardingStep {
    let icon: String
    let title: String
    let description: String
}

// MARK: - Onboarding Modifier

struct BackgroundMeshOnboardingModifier: ViewModifier {
    @State private var showOnboarding = false
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                checkIfShouldShowOnboarding()
            }
            .sheet(isPresented: $showOnboarding) {
                BackgroundMeshOnboardingView()
                    .interactiveDismissDisabled(false)
            }
    }
    
    private func checkIfShouldShowOnboarding() {
        Task {
            // Only show once
            let hasShown = UserDefaults.standard.bool(forKey: "mesh.onboarding.shown")
            
            // Only show after user has logged in (check for userId)
            let hasUserId = await KeychainService.shared.getUserId() != nil
            
            if !hasShown && hasUserId {
                // Small delay to let the main UI load first
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showOnboarding = true
                }
            }
        }
    }
}

extension View {
    func withBackgroundMeshOnboarding() -> some View {
        modifier(BackgroundMeshOnboardingModifier())
    }
}

// MARK: - Preview

#Preview {
    BackgroundMeshOnboardingView()
}
