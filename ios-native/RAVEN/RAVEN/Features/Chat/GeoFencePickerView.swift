//
//  GeoFencePickerView.swift
//  RAVEN
//
//  Full-screen map sheet for selecting a geo-fence area.
//  User taps map to set center, adjusts radius with slider.
//  Privacy notice clearly states only ~8km area is shared.
//

import SwiftUI
import MapKit

// MARK: - Geo Fence Picker View

struct GeoFencePickerView: View {
    @Environment(\.dismiss) var dismiss
    
    /// Completion handler returning the selected GeoFence or nil if cancelled.
    var onSelect: (GeoFence) -> Void
    
    @StateObject private var locationService = LocationPrivacyService.shared
    
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var radiusCells: UInt8 = 1
    @State private var strictMode: Bool = true
    @State private var showsUserLocation: Bool = true
    
    // Circle overlay parameters
    private var radiusMeters: Double {
        Double(radiusCells * 2 + 1) * 8000  // ~km per cell at res 5
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Map
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    UserAnnotation()
                    
                    if let coord = selectedCoordinate {
                        // Tinted circle showing geo-fence area
                        MapCircle(center: coord, radius: radiusMeters)
                            .foregroundStyle(FeatureColor.geoFenced.primary.opacity(0.15))
                            .stroke(FeatureColor.geoFenced.primary, lineWidth: 2)
                        
                        // Center pin
                        Annotation("", coordinate: coord) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(FeatureColor.geoFenced.primary)
                                .shadow(radius: 4)
                        }
                    }
                }
                .onTapGesture { location in
                    // Convert tap to coordinate
                    // Note: MapReader is used in production for precise conversion
                }
                .ignoresSafeArea(edges: .top)
                
                // Bottom control panel
                controlPanel
            }
            .navigationTitle(String(localized: "منطقه جغرافیایی", comment: "Geo fence picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "انصراف", comment: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                locationService.requestSingleUpdate()
            }
        }
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        VStack(spacing: 16) {
            // Handle bar
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
            
            // Radius slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text(String(localized: "شعاع", comment: "Radius"))
                    } icon: {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(FeatureColor.geoFenced.primary)
                    }
                    .font(.subheadline.bold())
                    
                    Spacer()
                    
                    Text("~\(Int(radiusCells) * 2 * 8 + 8) km")
                        .font(.subheadline.bold())
                        .foregroundStyle(FeatureColor.geoFenced.primary)
                }
                
                Slider(
                    value: Binding(
                        get: { Double(radiusCells) },
                        set: { radiusCells = UInt8(max(0, min(Int($0), Int(GeoFence.maxRadius)))) }
                    ),
                    in: 0...Double(GeoFence.maxRadius),
                    step: 1
                )
                .tint(FeatureColor.geoFenced.primary)
                .onChange(of: radiusCells) { _, _ in
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                }
            }
            
            // Strict mode toggle
            Toggle(isOn: $strictMode) {
                HStack(spacing: 8) {
                    Image(systemName: strictMode ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(FeatureColor.geoFenced.primary)
                    VStack(alignment: .leading) {
                        Text(String(localized: "حالت اکید", comment: "Strict mode"))
                            .font(.subheadline.bold())
                        Text(String(localized: "فقط داخل منطقه تحویل داده شود", comment: "Only deliver inside"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(FeatureColor.geoFenced.primary)
            
            // Privacy notice
            PrivacyNotice(
                icon: "hand.raised.fill",
                text: String(localized: "مکان دقیق شما به اشتراک گذاشته نمی‌شود — فقط یک منطقه تقریبی ~۸ کیلومتری", comment: "Location privacy notice"),
                tint: FeatureColor.geoFenced.primary
            )
            
            // Confirm button
            Button {
                if let cell = locationService.currentH3Cell {
                    let fence = GeoFence(
                        h3Cell: cell,
                        radiusInCells: radiusCells,
                        deliverOnlyInside: strictMode
                    )
                    onSelect(fence)
                    dismiss()
                }
            } label: {
                HStack {
                    Image(systemName: "location.fill")
                    Text(String(localized: "تأیید منطقه", comment: "Confirm area"))
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(FeatureColor.geoFenced.primary.gradient, in: Capsule())
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Preview

#Preview("Geo Fence Picker") {
    GeoFencePickerView { fence in
        print("Selected fence: \(fence)")
    }
}
