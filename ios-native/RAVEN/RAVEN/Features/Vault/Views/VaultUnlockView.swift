//
//  VaultUnlockView.swift
//  RAVEN
//
//  Overlay shown when a post/message has a vault lock.
//  Shows lock status and allows unlock attempt.
//

import SwiftUI

struct VaultUnlockView: View {
    let vaultLock: VaultLock
    let onUnlock: () async -> Bool
    
    @State private var isUnlocking = false
    @State private var unlockFailed = false
    
    var body: some View {
        if vaultLock.isContentVisible {
            // Content visible — show nothing (caller shows actual content)
            EmptyView()
        } else {
            // Locked state
            VStack(spacing: 16) {
                // Lock icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.teal.opacity(0.3), .blue.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: "lock.fill")
                        .font(.title)
                        .foregroundStyle(.teal)
                }
                
                Text("Location-Locked Content")
                    .font(.subheadline.weight(.semibold))
                
                Text("You need to be near a specific location to view this content")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                // Distance info
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                    Text("Required distance: ~\(vaultLock.unlockDistanceMeters)m")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                
                // Expiry info
                if let expires = vaultLock.expiresAt {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Unlocks: \(expires.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                
                // Burnable badge
                if vaultLock.isBurnable {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("View once only")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                
                // Unlock button
                Button {
                    Task { await attemptUnlock() }
                } label: {
                    HStack(spacing: 8) {
                        if isUnlocking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "location.viewfinder")
                        }
                        Text("Try to Unlock")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.teal, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .disabled(isUnlocking)
                
                if unlockFailed {
                    Text("🔒 Still locked — get closer to the target location")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
            }
            .padding(20)
            .liquidGlass(cornerRadius: 20)
            .animation(RavenAnimation.smooth, value: unlockFailed)
        }
    }
    
    private func attemptUnlock() async {
        isUnlocking = true
        unlockFailed = false
        
        let success = await onUnlock()
        
        isUnlocking = false
        if !success {
            unlockFailed = true
        }
    }
}
