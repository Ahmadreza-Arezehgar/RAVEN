// Brand tokens — sourced from `RAVEN-iOS/RAVEN/Utils/Extensions.swift`,
// matched to the macOS Flutter app's `RavenColors` so the two builds
// look identical.

import SwiftUI

enum RavenColors {
    static let primary = Color(red: 0x66 / 255.0, green: 0x44 / 255.0, blue: 0xFF / 255.0) // #6644FF
    static let secondary = Color(red: 0x00 / 255.0, green: 0xCC / 255.0, blue: 0xCC / 255.0) // #00CCCC
    static let accent = Color(red: 0xFF / 255.0, green: 0x66 / 255.0, blue: 0x99 / 255.0) // #FF6699

    // Sampled from the actual RavenLogo asset (azure → violet, softer
    // than the brand purple). Used for avatars and the wordmark gradient.
    static let logoStart = Color(red: 0x5B / 255.0, green: 0xA0 / 255.0, blue: 0xE8 / 255.0) // #5BA0E8
    static let logoEnd = Color(red: 0x9F / 255.0, green: 0x7D / 255.0, blue: 0xE8 / 255.0)   // #9F7DE8
}

extension LinearGradient {
    static let ravenBrand = LinearGradient(
        colors: [RavenColors.primary, RavenColors.secondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let ravenLogo = LinearGradient(
        colors: [RavenColors.logoStart, RavenColors.logoEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
