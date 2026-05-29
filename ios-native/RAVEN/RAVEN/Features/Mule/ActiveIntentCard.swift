//
//  ActiveIntentCard.swift
//  RAVEN
//
//  Glass card showing the user's active travel intent.
//  Displays route, metrics, capacity progress, and cancel button.
//

import SwiftUI

// MARK: - Active Intent Card

struct ActiveIntentCard: View {
    let intent: TravelIntent
    @ObservedObject var muleService = MuleService.shared
    @State private var showCancelAlert = false
    
    var body: some View {
        FeatureGlassCard {
            VStack(spacing: 16) {
                // Header
                HStack {
                    CapsuleIcon(
                        systemImage: "airplane",
                        tint: FeatureColor.dataMules.primary,
                        size: 28
                    )
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "سفر فعال", comment: "Active Travel"))
                            .font(.subheadline.bold())
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Status dot
                    Circle()
                        .fill(intent.isActive ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                        .shadow(color: (intent.isActive ? Color.green : Color.orange).opacity(0.5), radius: 4)
                }
                
                // Route
                HStack(spacing: 12) {
                    VStack {
                        Circle()
                            .fill(FeatureColor.dataMules.primary)
                            .frame(width: 10, height: 10)
                        Rectangle()
                            .fill(FeatureColor.dataMules.primary.opacity(0.3))
                            .frame(width: 2, height: 30)
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(FeatureColor.dataMules.primary)
                            .font(.system(size: 12))
                    }
                    
                    VStack(alignment: .leading, spacing: 30) {
                        Text(String(localized: "مبدأ", comment: "Origin"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "مقصد", comment: "Destination"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                // Metrics row
                HStack(spacing: 8) {
                    MetricCard(
                        icon: "clock.fill",
                        value: timeRemainingText,
                        label: String(localized: "باقیمانده", comment: "Remaining"),
                        tint: FeatureColor.dataMules.primary
                    )
                    MetricCard(
                        icon: "envelope.fill",
                        value: "\(muleService.stats.messagesCarried)",
                        label: String(localized: "حمل شده", comment: "Carried"),
                        tint: FeatureColor.deliveryConfidence.primary
                    )
                    MetricCard(
                        icon: "person.2.fill",
                        value: "\(muleService.stats.usersHelped)",
                        label: String(localized: "کمک‌ شده", comment: "Helped"),
                        tint: FeatureColor.internetBridge.primary
                    )
                }
                
                // Capacity progress bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "ظرفیت", comment: "Capacity"))
                            .font(.caption.bold())
                        Spacer()
                        Text("\(intent.capacityMB) MB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    GeometryReader { proxy in
                        let used = Double(muleService.stats.messagesCarried * 200) / Double(intent.capacityMB * 1_048_576)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.ultraThinMaterial)
                            Capsule()
                                .fill(FeatureColor.dataMules.primary.gradient)
                                .frame(width: proxy.size.width * min(used, 1.0))
                        }
                    }
                    .frame(height: 6)
                }
                
                // Cancel button
                Button {
                    showCancelAlert = true
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text(String(localized: "لغو سفر", comment: "Cancel Travel"))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .alert(
                    String(localized: "لغو سفر؟", comment: "Cancel travel?"),
                    isPresented: $showCancelAlert
                ) {
                    Button(String(localized: "لغو", comment: "Cancel"), role: .destructive) {
                        muleService.cancelTravel()
                    }
                    Button(String(localized: "بازگشت", comment: "Go back"), role: .cancel) {}
                }
            }
        }
    }
    
    // MARK: - Computed
    
    private var statusText: String {
        if intent.shouldBroadcast {
            return String(localized: "در حال پخش اعلام", comment: "Broadcasting")
        } else if intent.isActive {
            return String(localized: "در حال سفر", comment: "Traveling")
        } else {
            return String(localized: "برنامه‌ریزی شده", comment: "Scheduled")
        }
    }
    
    private var timeRemainingText: String {
        guard let remaining = intent.timeRemaining else {
            return String(localized: "رسیده", comment: "Arrived")
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Preview

#Preview("Active Intent") {
    let intent = TravelIntent(
        intentId: UUID().uuidString,
        userIdHashed: "test",
        fromRegion: 1,
        toRegion: 2,
        viaRegions: [],
        departureTime: Date().addingTimeInterval(-3600),
        estimatedArrivalTime: Date().addingTimeInterval(3600 * 4),
        capacityMB: 50,
        createdAt: Date().addingTimeInterval(-7200),
        signature: nil,
        signerPublicKey: nil
    )
    ActiveIntentCard(intent: intent)
        .padding()
}
