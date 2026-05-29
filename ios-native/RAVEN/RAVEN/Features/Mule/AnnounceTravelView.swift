//
//  AnnounceTravelView.swift
//  RAVEN
//
//  Full-screen form for announcing a travel intent (Data Mules).
//  Liquid Glass design with city pickers, date/time, and capacity selector.
//

import SwiftUI

// MARK: - Announce Travel View

struct AnnounceTravelView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var locationService = LocationPrivacyService.shared
    @StateObject private var muleService = MuleService.shared
    
    @State private var fromCity: String = ""
    @State private var toCity: String = ""
    @State private var departureDate: Date = Date().addingTimeInterval(3600)
    @State private var arrivalDate: Date = Date().addingTimeInterval(3600 * 6)
    @State private var selectedCapacity: Int = 50
    @State private var isSubmitting = false
    @State private var showSuccess = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header icon
                    CapsuleIcon(
                        systemImage: "airplane",
                        tint: FeatureColor.dataMules.primary,
                        size: 48
                    )
                    .padding(.top, 16)
                    
                    Text(String(localized: "اعلام سفر", comment: "Announce Travel"))
                        .font(.title2.bold())
                    
                    Text(String(localized: "با اعلام سفر، دستگاه شما پیام‌های مرتبط را حمل می‌کند", comment: "Travel description"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    // Route section
                    FeatureGlassCard {
                        VStack(spacing: 16) {
                            // From
                            VStack(alignment: .leading, spacing: 6) {
                                Label {
                                    Text(String(localized: "مبدأ", comment: "From"))
                                } icon: {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(FeatureColor.dataMules.primary)
                                }
                                .font(.caption.bold())
                                
                                TextField(String(localized: "شهر مبدأ", comment: "Origin city"), text: $fromCity)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusInner))
                            }
                            
                            // Arrow
                            Image(systemName: "arrow.down")
                                .font(.title3.bold())
                                .foregroundStyle(FeatureColor.dataMules.primary)
                            
                            // To
                            VStack(alignment: .leading, spacing: 6) {
                                Label {
                                    Text(String(localized: "مقصد", comment: "To"))
                                } icon: {
                                    Image(systemName: "mappin.and.ellipse")
                                        .foregroundStyle(FeatureColor.dataMules.primary)
                                }
                                .font(.caption.bold())
                                
                                TextField(String(localized: "شهر مقصد", comment: "Destination city"), text: $toCity)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusInner))
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Date/Time section
                    FeatureGlassCard {
                        VStack(spacing: 16) {
                            DatePicker(
                                String(localized: "زمان حرکت", comment: "Departure time"),
                                selection: $departureDate,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .tint(FeatureColor.dataMules.primary)
                            
                            DatePicker(
                                String(localized: "زمان تقریبی رسیدن", comment: "Estimated arrival"),
                                selection: $arrivalDate,
                                in: departureDate...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .tint(FeatureColor.dataMules.primary)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Capacity selector
                    FeatureGlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text(String(localized: "ظرفیت حمل", comment: "Carry capacity"))
                            } icon: {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(FeatureColor.dataMules.primary)
                            }
                            .font(.subheadline.bold())
                            
                            HStack(spacing: 12) {
                                ForEach(TravelIntent.capacityOptions, id: \.self) { cap in
                                    Button {
                                        let impact = UIImpactFeedbackGenerator(style: .light)
                                        impact.impactOccurred()
                                        selectedCapacity = cap
                                    } label: {
                                        Text("\(cap) MB")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(selectedCapacity == cap ? .white : .primary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background {
                                                if selectedCapacity == cap {
                                                    Capsule()
                                                        .fill(FeatureColor.dataMules.primary.gradient)
                                                } else {
                                                    Capsule()
                                                        .fill(.ultraThinMaterial)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Info notice
                    PrivacyNotice(
                        icon: "clock.fill",
                        text: String(localized: "اعلام شما ۲ ساعت قبل از حرکت به کاربران نزدیک پخش می‌شود", comment: "Broadcast timing notice"),
                        tint: FeatureColor.dataMules.primary
                    )
                    .padding(.horizontal)
                    
                    // Submit button
                    Button {
                        submitTravel()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text(String(localized: "اعلام سفر", comment: "Submit travel"))
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            (fromCity.isEmpty || toCity.isEmpty)
                            ? Color.gray.gradient
                            : FeatureColor.dataMules.primary.gradient,
                            in: Capsule()
                        )
                    }
                    .disabled(fromCity.isEmpty || toCity.isEmpty || isSubmitting)
                    .padding(.horizontal)
                    
                    Spacer(minLength: DS.bottomTabClearance)
                }
            }
            .navigationTitle(String(localized: "سفر جدید", comment: "New Travel"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "انصراف", comment: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .alert(
                String(localized: "سفر ثبت شد!", comment: "Travel registered"),
                isPresented: $showSuccess
            ) {
                Button("OK") { dismiss() }
            } message: {
                Text(String(localized: "اعلام شما ۲ ساعت قبل از حرکت فعال می‌شود", comment: "Will activate 2h before departure"))
            }
        }
    }
    
    // MARK: - Submit
    
    private func submitTravel() {
        guard !fromCity.isEmpty, !toCity.isEmpty else { return }
        isSubmitting = true
        
        // Use current location as fromRegion, or a hash-based fallback
        let fromCell = locationService.currentH3Cell ?? GeoFence.latLngToCell(lat: 35.69, lng: 51.39)  // Tehran fallback
        let toCell = GeoFence.latLngToCell(lat: 32.65, lng: 51.67)  // Isfahan fallback (will be dynamic)
        
        let intent = TravelIntent.create(
            fromRegion: fromCell,
            toRegion: toCell,
            departureTime: departureDate,
            estimatedArrivalTime: arrivalDate,
            capacityMB: selectedCapacity
        )
        
        muleService.announceTravel(intent)
        
        isSubmitting = false
        showSuccess = true
    }
}

// MARK: - Preview

#Preview("Announce Travel") {
    AnnounceTravelView()
}
