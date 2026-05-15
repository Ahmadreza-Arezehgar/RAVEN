//
//  RavenPlusPaywallView.swift
//  RAVEN
//
//  RAVEN+ subscription paywall — Dark glass design (Calm Blue)
//

import SwiftUI
import RevenueCat

// MARK: - Paywall Color Palette

private enum PaywallColors {
    static let accentBlue      = Color(red: 0.176, green: 0.498, blue: 0.976)  // #2D7FF9
    static let accentBlueLight = Color(red: 0.353, green: 0.663, blue: 1.0)    // #5AA9FF
    static let highlightMuted  = Color(red: 0.227, green: 0.290, blue: 0.416)  // #3A4A6A
    static let crownGold       = Color(red: 0.788, green: 0.659, blue: 0.298)  // #C9A84C
}

// MARK: - RavenPlusPaywallView

struct RavenPlusPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedPackage: Package?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var purchaseSuccess = false
    @State private var showAllFeatures = false
    
    private let subscriptionService = SubscriptionService.shared
    
    // ── Feature List ──────────────────────────────────────────────────
    
    private struct Feature {
        let icon: String
        let title: String
        let subtitle: String
    }
    
    /// Top 3 features shown by default
    private let topFeatures: [Feature] = [
        Feature(icon: "sparkles", title: "Unlimited AI", subtitle: "Unlimited transcriptions & Gemini questions"),
        Feature(icon: "antenna.radiowaves.left.and.right", title: "Mesh Superpowers", subtitle: "72h TTL, 50 hops, VIP priority routing"),
        Feature(icon: "arrow.up.doc.fill", title: "Lossless Media & 2 GB", subtitle: "Full-quality uploads up to 2 GB"),
    ]
    
    /// Extra features revealed on expand
    private let extraFeatures: [Feature] = [
        Feature(icon: "eye.slash.fill", title: "Ghost Mode", subtitle: "Read messages without sending receipts"),
        Feature(icon: "waveform", title: "10-Min Voice", subtitle: "Extended voice messages up to 10 minutes"),
        Feature(icon: "crown.fill", title: "Premium Badge", subtitle: "Stand out with a golden crown badge"),
    ]
    
    // ── Body ──────────────────────────────────────────────────────────
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main scrollable content
            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.space24) {
                    heroHeader
                        .padding(.top, 60) // room for close button
                    
                    featuresSection
                    
                    planPicker
                    
                    ctaButton
                    
                    footerSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            
            // Close button (top-left, respects safe area)
            closeButton
                .padding(.top, 12)
                .padding(.leading, 16)
        }
        // Background as modifier — .ignoresSafeArea() only affects the background,
        // not the close button or other interactive elements
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(white: 0.06),
                        Color(white: 0.04),
                        Color(white: 0.03),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [PaywallColors.accentBlue.opacity(0.06), .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 220
                        )
                    )
                    .frame(width: 440, height: 440)
                    .offset(y: -100)
                    .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .overlay {
            if purchaseSuccess {
                successOverlay
            }
        }
        // Auto-select package when offerings load asynchronously
        .onChange(of: subscriptionService.currentOffering) { _, offering in
            if selectedPackage == nil, let offering = offering {
                selectedPackage = offering.availablePackages.first { $0.packageType == .annual }
                    ?? offering.availablePackages.first
            }
        }
    }
    
    // ── Close Button ─────────────────────────────────────────────────
    
    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
    
    // ── Hero Header ──────────────────────────────────────────────────
    
    private var heroHeader: some View {
        VStack(spacing: 14) {
            // Crown with soft gold glow
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [PaywallColors.crownGold.opacity(0.10), .clear],
                            center: .center,
                            startRadius: 8,
                            endRadius: 44
                        )
                    )
                    .frame(width: 80, height: 80)
                
                Image(systemName: "crown.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [PaywallColors.crownGold, PaywallColors.crownGold.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: PaywallColors.crownGold.opacity(0.15), radius: 6)
            }
            
            Text("RAVEN+")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            
            Text("Raven+ features")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // ── Features Section (Collapsible) ───────────────────────────────
    
    private var featuresSection: some View {
        VStack(spacing: 0) {
            // Always-visible top features
            ForEach(Array(topFeatures.enumerated()), id: \.element.title) { index, feature in
                featureRow(feature)
                if index < topFeatures.count - 1 || showAllFeatures {
                    featureDivider
                }
            }
            
            // Expandable extra features
            if showAllFeatures {
                ForEach(Array(extraFeatures.enumerated()), id: \.element.title) { index, feature in
                    VStack(spacing: 0) {
                        featureRow(feature)
                        if index < extraFeatures.count - 1 {
                            featureDivider
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            
            // Toggle button
            Button {
                Haptics.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showAllFeatures.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(showAllFeatures ? "Show less" : "See all features")
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: showAllFeatures ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        // Shadow removed: prevents bleed-through on glass material
    }
    
    private func featureRow(_ feature: Feature) -> some View {
        HStack(spacing: 14) {
            // Icon — calm blue
            Image(systemName: feature.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [PaywallColors.accentBlue, PaywallColors.accentBlueLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
                .background(PaywallColors.accentBlue.opacity(0.08))
                .clipShape(Circle())
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(feature.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 16)
    }
    
    private var featureDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.06), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
            .padding(.leading, 64)
    }
    
    // ── Plan Picker ──────────────────────────────────────────────────
    
    private var planPicker: some View {
        VStack(spacing: 10) {
            if subscriptionService.isLoading {
                ProgressView()
                    .tint(.secondary)
                    .padding(32)
            } else if let offering = subscriptionService.currentOffering {
                let packages = offering.availablePackages.sorted { a, b in
                    planSortOrder(a.packageType) < planSortOrder(b.packageType)
                }
                ForEach(packages, id: \.identifier) { package in
                    PlanCard(
                        package: package,
                        isSelected: selectedPackage?.identifier == package.identifier,
                        isBestValue: package.packageType == .annual
                    ) {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedPackage = package
                        }
                    }
                }
            } else {
                // Error / empty state
                VStack(spacing: 12) {
                    Text("Unable to load plans")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    
                    Button {
                        Task { await subscriptionService.fetchOfferings() }
                    } label: {
                        Text("Retry")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PaywallColors.accentBlue)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(24)
            }
        }
        .onAppear {
            if selectedPackage == nil, let offering = subscriptionService.currentOffering {
                selectedPackage = offering.availablePackages.first { $0.packageType == .annual }
                    ?? offering.availablePackages.first
            }
        }
    }
    
    /// Sort: Yearly first, Monthly second, Lifetime third, everything else after
    private func planSortOrder(_ type: PackageType) -> Int {
        switch type {
        case .annual:   return 0
        case .monthly:  return 1
        case .lifetime: return 2
        default:        return 3
        }
    }
    
    // ── CTA Button ───────────────────────────────────────────────────
    
    private var ctaButton: some View {
        VStack(spacing: 10) {
            Button {
                Task { await handlePurchase() }
            } label: {
                ZStack {
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        VStack(spacing: 2) {
                            Text(ctaTitle)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            if let sub = ctaSubtitle {
                                Text(sub)
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.8)
                            }
                        }
                        .padding(.vertical, 14)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(
                    ZStack {
                        // Glass base
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                        
                        // Subtle blue gradient overlay
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [PaywallColors.accentBlue.opacity(0.40), PaywallColors.accentBlueLight.opacity(0.30)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                )
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [PaywallColors.accentBlue.opacity(0.4), PaywallColors.accentBlue.opacity(0.1)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
                // Shadow removed: prevents bleed-through on glass material
            }
            .disabled(selectedPackage == nil || isPurchasing)
            .opacity(selectedPackage == nil ? 0.5 : 1.0)
            
            // Free trial hint
            if let pkg = selectedPackage,
               let intro = pkg.storeProduct.introductoryDiscount,
               intro.paymentMode == .freeTrial {
                Text("Cancel anytime before your trial ends")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var ctaTitle: String {
        if let pkg = selectedPackage,
           let intro = pkg.storeProduct.introductoryDiscount,
           intro.paymentMode == .freeTrial {
            return "Start Free Trial"
        }
        return "Upgrade to Raven+"
    }
    
    private var ctaSubtitle: String? {
        guard let pkg = selectedPackage else { return nil }
        
        let period: String
        switch pkg.packageType {
        case .annual: period = " / year"
        case .monthly: period = " / month"
        case .lifetime: period = " one-time"
        default: period = ""
        }
        
        if let intro = pkg.storeProduct.introductoryDiscount,
           intro.paymentMode == .freeTrial {
            return "then \(pkg.localizedPriceString)\(period)"
        }
        
        return "\(pkg.localizedPriceString)\(period)"
    }
    
    // ── Footer ───────────────────────────────────────────────────────
    
    private var footerSection: some View {
        VStack(spacing: 12) {
            // Restore Purchases
            Button {
                Task { await handleRestore() }
            } label: {
                if isRestoring {
                    ProgressView()
                        .tint(.secondary)
                } else {
                    Text("Restore Purchases")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isRestoring)
            
            // Legal links
            HStack(spacing: 14) {
                if let termsURL = URL(string: "https://raven.social/terms") {
                    Link("Terms of Service", destination: termsURL)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                
                Text("·")
                    .foregroundStyle(.quaternary)
                
                if let privacyURL = URL(string: "https://raven.social/privacy") {
                    Link("Privacy Policy", destination: privacyURL)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            
            Text("Payment will be charged to your Apple ID account at confirmation. Subscription automatically renews unless it is canceled at least 24 hours before the end of the current period.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.top, 4)
    }
    
    // ── Success Overlay ──────────────────────────────────────────────
    
    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [PaywallColors.crownGold.opacity(0.15), .clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 50
                            )
                        )
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "crown.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [PaywallColors.crownGold, PaywallColors.crownGold.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: PaywallColors.crownGold.opacity(0.2), radius: 10)
                }
                
                Text("Welcome to Raven+")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text("All premium features are now unlocked.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                
                Button {
                    dismiss()
                } label: {
                    Text("Let's Go")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            ZStack {
                                Capsule(style: .continuous)
                                    .fill(.ultraThinMaterial)
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [PaywallColors.accentBlue.opacity(0.40), PaywallColors.accentBlueLight.opacity(0.30)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            }
                        )
                        .clipShape(Capsule(style: .continuous))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(PaywallColors.accentBlue.opacity(0.3), lineWidth: 0.5)
                        )
                }
                .padding(.top, 8)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }
    
    // ── Actions ──────────────────────────────────────────────────────
    
    private func handlePurchase() async {
        guard let package = selectedPackage else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        
        do {
            let success = try await subscriptionService.purchase(package: package)
            if success {
                Haptics.success()
                withAnimation(.spring(response: 0.4)) {
                    purchaseSuccess = true
                }
            }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func handleRestore() async {
        isRestoring = true
        defer { isRestoring = false }
        
        do {
            try await subscriptionService.restorePurchases()
            if subscriptionService.isPremium {
                Haptics.success()
                withAnimation(.spring(response: 0.4)) {
                    purchaseSuccess = true
                }
            } else {
                errorMessage = "No active subscription found."
                showError = true
            }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Plan Card
private struct PlanCard: View {
    let package: Package
    let isSelected: Bool
    let isBestValue: Bool
    let onTap: () -> Void
    
    /// Per-month price for annual packages
    private var monthlyEquivalent: String? {
        guard package.packageType == .annual else { return nil }
        
        // Use the product's own formatter to guarantee same currency as localizedPriceString
        guard let formatter = package.storeProduct.priceFormatter else { return nil }
        formatter.maximumFractionDigits = 2
        
        if let pricePerMonth = package.storeProduct.pricePerMonth {
            return formatter.string(from: pricePerMonth)
        }
        
        let price = package.storeProduct.price
        let monthly = price / Decimal(12)
        return formatter.string(from: monthly as NSDecimalNumber)
    }
    
    /// Period label for the package
    private var periodLabel: String {
        switch package.packageType {
        case .annual:   return "Yearly"
        case .monthly:  return "Monthly"
        case .lifetime: return "Lifetime"
        default:        return package.identifier
        }
    }
    
    /// Description beneath the plan name
    private var descriptionText: String {
        switch package.packageType {
        case .annual:   return "Cancel anytime"
        case .monthly:  return "Cancel anytime"
        case .lifetime: return "One-time purchase"
        default:        return ""
        }
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Selection indicator   blue
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? PaywallColors.accentBlue : Color.white.opacity(0.2),
                            lineWidth: 1.5
                        )
                        .frame(width: 22, height: 22)
                    
                    if isSelected {
                        Circle()
                            .fill(PaywallColors.accentBlue)
                            .frame(width: 12, height: 12)
                    }
                }
                
                // Plan info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(periodLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        
                        // Best value pill   glass + subtle blue
                        if isBestValue {
                            Text("Best value")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(PaywallColors.accentBlueLight)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(PaywallColors.accentBlue.opacity(0.12))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(PaywallColors.accentBlue.opacity(0.3), lineWidth: 0.5)
                                        )
                                )
                        }
                    }
                    
                    Group {
                        if let intro = package.storeProduct.introductoryDiscount,
                           intro.paymentMode == .freeTrial {
                            Text(descriptionText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            + Text("   ")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            + Text(formatTrialPeriod(intro.subscriptionPeriod))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PaywallColors.accentBlue.opacity(0.9))
                        } else {
                            Text(descriptionText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // PRICE (Apple Requirement: Billed amount MUST be the most conspicuous)
                VStack(alignment: .trailing, spacing: 2) {
                    // 1. TOTAL BILLED AMOUNT (Huge and bold)
                    Text(package.localizedPriceString)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? PaywallColors.accentBlue : .primary)
                    
                    // 2. SUBORDINATE PRICING (Small and secondary)
                    if package.packageType == .annual {
                        Text("Billed annually")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            
                        if let perMonth = monthlyEquivalent {
                            Text("Equivalent to \(perMonth)/mo")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                    } else if package.packageType == .monthly {
                        Text("Billed monthly")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? PaywallColors.accentBlue.opacity(0.5)
                            : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    private func formatTrialPeriod(_ period: SubscriptionPeriod) -> String {
        let value = period.value
        let unitString: String
        switch period.unit {
        case .day: unitString = "day"
        case .week: unitString = "week"
        case .month: unitString = "month"
        case .year: unitString = "year"
        @unknown default: unitString = "period"
        }
        return "\(value)-\(unitString) free trial"
    }
}



// MARK: - Preview

#Preview {
    RavenPlusPaywallView()
}
