//
//  RavenPlusPaywallView.swift
//  RAVEN
//
//  MESSENGER PIVOT (2026-06): RAVEN+ subscription removed — every feature is
//  free for everyone, so the paywall no longer exists. This stub remains only
//  so the (now-unreachable) `.sheet { RavenPlusPaywallView() }` call sites keep
//  compiling. With `SubscriptionService.isPremium == true` and all
//  `PremiumLimits` gates unlocked, none of those sheets are ever presented;
//  if one ever is, it shows a short notice and dismisses. No RevenueCat.
//

import SwiftUI

struct RavenPlusPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("All features included")
                .font(.title3.weight(.semibold))

            Text("Every RAVEN feature is free for everyone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(32)
        .presentationDetents([.medium])
    }
}

#Preview {
    RavenPlusPaywallView()
}
