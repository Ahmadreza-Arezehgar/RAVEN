//
//  TravelListView.swift
//  RAVEN
//
//  "My Travels" view — entry point for Data Mules.
//  Shows active travel card and "Announce New Travel" button.
//

import SwiftUI

// MARK: - Travel List View

struct TravelListView: View {
    @StateObject private var muleService = MuleService.shared
    @State private var showAnnounceSheet = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    CapsuleIcon(
                        systemImage: "airplane",
                        tint: FeatureColor.dataMules.primary,
                        size: 56
                    )
                    
                    Text(String(localized: "سفرهای من", comment: "My Travels"))
                        .font(.title.bold())
                    
                    Text(String(localized: "با سفرتان پیام‌های کاربران آفلاین را حمل کنید", comment: "Carry messages for offline users"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                
                // Active intent card
                if let intent = muleService.activeIntent {
                    ActiveIntentCard(intent: intent)
                        .padding(.horizontal)
                        .transition(.glassMorph)
                }
                
                // Empty state (no active travel)
                if muleService.activeIntent == nil {
                    FeatureGlassCard {
                        VStack(spacing: 16) {
                            Image(systemName: "airplane.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            
                            Text(String(localized: "سفر فعالی ندارید", comment: "No active travel"))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            Text(String(localized: "با اعلام سفر بعدی، به شبکه RAVEN کمک کنید", comment: "Help RAVEN network"))
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                    .padding(.horizontal)
                }
                
                // Announce new travel button
                if muleService.activeIntent == nil {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        showAnnounceSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(String(localized: "اعلام سفر جدید", comment: "Announce New Travel"))
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(FeatureColor.dataMules.primary.gradient, in: Capsule())
                    }
                    .padding(.horizontal)
                }
                
                // How it works section
                FeatureGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "چگونه کار می‌کند؟", comment: "How it works"))
                            .font(.headline)
                        
                        howItWorksRow(
                            number: "1",
                            icon: "mappin.and.ellipse",
                            text: String(localized: "مبدأ و مقصد سفرتان را وارد کنید", comment: "Enter origin and destination")
                        )
                        howItWorksRow(
                            number: "2",
                            icon: "antenna.radiowaves.left.and.right",
                            text: String(localized: "۲ ساعت قبل از حرکت، به کاربران نزدیک اعلام می‌شود", comment: "Announced 2h before departure")
                        )
                        howItWorksRow(
                            number: "3",
                            icon: "envelope.fill",
                            text: String(localized: "دستگاه شما پیام‌های مرتبط را حمل می‌کند", comment: "Your device carries relevant messages")
                        )
                        howItWorksRow(
                            number: "4",
                            icon: "checkmark.circle.fill",
                            text: String(localized: "در مقصد به کاربران آفلاین تحویل داده می‌شود", comment: "Delivered at destination")
                        )
                    }
                }
                .padding(.horizontal)
                
                Spacer(minLength: DS.bottomTabClearance)
            }
        }
        .navigationTitle(String(localized: "سفرها", comment: "Travels"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAnnounceSheet) {
            AnnounceTravelView()
        }
    }
    
    // MARK: - How It Works Row
    
    private func howItWorksRow(number: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(FeatureColor.dataMules.primary.gradient, in: Circle())
            
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(FeatureColor.dataMules.primary)
                    .frame(width: 20)
                
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview("Travel List") {
    NavigationStack {
        TravelListView()
    }
}
