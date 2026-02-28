//
//  LocationAttachSheet.swift
//  RAVEN
//
//  Liquid Glass sheet for choosing Current or Live location sharing
//

import SwiftUI
import CoreLocation

struct LocationAttachSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var locationManager = LocationManager.shared
    
    let onSendCurrent: (CLLocation) -> Void
    let onStartLive: (TimeInterval, CLLocation) -> Void
    
    @State private var selectedDuration: TimeInterval = 3600  // 1 hour default
    @State private var isLoadingCurrent = false
    @State private var isStartingLive = false
    @State private var showPermissionAlert = false
    
    private let durations: [(String, TimeInterval)] = [
        ("15 min", 15 * 60),
        ("1 hour", 60 * 60),
        ("8 hours", 8 * 60 * 60),
        ("24 hours", 24 * 60 * 60)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(.primary.opacity(0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 16)
            
            headerSection
            currentLocationButton
            dividerLine
            liveLocationSection
            
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background { glassBackground }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .onAppear {
            if !locationManager.hasLocationPermission {
                locationManager.requestWhenInUse()
            }
        }
        .alert("Location Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable location access in Settings to share your location.")
        }
    }
    
    // MARK: - Extracted Sub-Views
    
    private var headerSection: some View {
        HStack {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("Share Location")
                .font(.system(size: 18, weight: .bold))
        }
        .padding(.bottom, 20)
    }
    
    private var currentLocationButton: some View {
        Button {
            sendCurrentLocation()
        } label: {
            locationRow(
                icon: "location.fill",
                iconColor: .blue,
                title: "Send Current Location",
                subtitle: "Share your location right now",
                isLoading: isLoadingCurrent
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoadingCurrent || isStartingLive)
    }
    
    private var dividerLine: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 14)
    }
    
    private var liveLocationSection: some View {
        VStack(spacing: 14) {
            locationRow(
                icon: "location.north.circle.fill",
                iconColor: .green,
                title: "Share Live Location",
                subtitle: "Share for up to 24 hours",
                isLoading: false
            )
            .allowsHitTesting(false)
            
            durationPicker
            startLiveButton
        }
    }
    
    private var durationPicker: some View {
        HStack(spacing: 8) {
            ForEach(durations, id: \.1) { duration in
                Button {
                    Haptics.light()
                    selectedDuration = duration.1
                } label: {
                    Text(duration.0)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selectedDuration == duration.1 ? Color.primary : Color.primary.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            if selectedDuration == duration.1 {
                                Capsule()
                                    .fill(.cyan.opacity(0.4))
                            } else {
                                Capsule()
                                    .fill(.primary.opacity(0.1))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var startLiveButton: some View {
        Button {
            startLiveLocation()
        } label: {
            HStack(spacing: 8) {
                if isStartingLive {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                }
                Text("Start Live Location")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                LinearGradient(
                    colors: [.green.opacity(0.6), .cyan.opacity(0.5)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoadingCurrent || isStartingLive)
    }
    
    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.primary.opacity(0.3), .primary.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
    
    // MARK: - Actions
    
    private func sendCurrentLocation() {
        guard checkPermission() else { return }
        
        isLoadingCurrent = true
        Haptics.light()
        
        Task {
            do {
                let location = try await locationManager.getCurrentLocation()
                await MainActor.run {
                    isLoadingCurrent = false
                    onSendCurrent(location)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isLoadingCurrent = false
                    #if DEBUG
                    print("📍 [Location] Failed to get current: \(error)")
                    #endif
                }
            }
        }
    }
    
    private func startLiveLocation() {
        guard checkPermission() else { return }
        
        isStartingLive = true
        Haptics.medium()
        
        Task {
            do {
                let location = try await locationManager.getCurrentLocation()
                await MainActor.run {
                    isStartingLive = false
                    onStartLive(selectedDuration, location)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isStartingLive = false
                    #if DEBUG
                    print("📍 [Location] Failed to start live: \(error)")
                    #endif
                }
            }
        }
    }
    
    private func checkPermission() -> Bool {
        switch locationManager.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .notDetermined:
            locationManager.requestWhenInUse()
            return false
        case .denied, .restricted:
            showPermissionAlert = true
            return false
        @unknown default:
            return false
        }
    }
    
    // MARK: - Row Component
    
    private func locationRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(iconColor)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            
            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.primary.opacity(0.08))
        }
    }
}

#Preview {
    Color.black
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            LocationAttachSheet(
                onSendCurrent: { _ in },
                onStartLive: { _, _ in }
            )
        }
}
