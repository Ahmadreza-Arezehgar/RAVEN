// RAVEN - Location Permission Banner
// Contextual banner for requesting location permission

import SwiftUI
import CoreLocation

/// A banner that prompts users to enable location services
/// Use this in Home/Local feed when location is needed
struct LocationPermissionBanner: View {
    @ObservedObject var locationService: LocationService
    var onLocationGranted: (() -> Void)?
    
    var body: some View {
        Group {
            if !locationService.isAuthorized {
                bannerContent
            }
        }
    }
    
    private var bannerContent: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.ravenPrimary.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: locationService.shouldShowSettingsPrompt
                      ? "location.slash.fill"
                      : "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.ravenPrimary)
            }
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(locationService.shouldShowSettingsPrompt
                     ? "Location Access Denied"
                     : "Enable Location")
                    .font(.subheadline.weight(.semibold))
                
                Text(locationService.shouldShowSettingsPrompt
                     ? "Open Settings to allow location access"
                     : "See posts and people near you")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action Button
            Button {
                handleButtonTap()
            } label: {
                Text(locationService.shouldShowSettingsPrompt ? "Settings" : "Enable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.ravenPrimary)
                    .clipShape(Capsule())
            }
        }
        .padding()
        // Apple Native Liquid Glass Effect (iOS 26+)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .padding(.horizontal)
        .onChange(of: locationService.isAuthorized) { _, isAuthorized in
            if isAuthorized {
                onLocationGranted?()
            }
        }
    }
    
    private func handleButtonTap() {
        if locationService.shouldShowSettingsPrompt {
            locationService.openSettings()
        } else {
            locationService.requestPermission()
        }
    }
}

// MARK: - Compact Inline Banner (for tight spaces)
struct LocationPermissionInlineBanner: View {
    @ObservedObject var locationService: LocationService
    
    var body: some View {
        if !locationService.isAuthorized {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundColor(.ravenPrimary)
                
                Text("Enable location for nearby content")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button {
                    if locationService.shouldShowSettingsPrompt {
                        locationService.openSettings()
                    } else {
                        locationService.requestPermission()
                    }
                } label: {
                    Text(locationService.shouldShowSettingsPrompt ? "Settings" : "Enable")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.ravenPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(UIColor.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }
}

// MARK: - Preview
#Preview("Not Determined") {
    VStack(spacing: 20) {
        LocationPermissionBanner(locationService: .shared)
        LocationPermissionInlineBanner(locationService: .shared)
    }
    .padding()
}
