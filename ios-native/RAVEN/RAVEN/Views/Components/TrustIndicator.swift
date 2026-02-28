import SwiftUI

// MARK: - Trust Level

/// Trust levels for users - completely local, no fake verification
enum TrustLevel: String, Codable, CaseIterable {
    case unknown        // No connection
    case mutualRooms    // Share common rooms
    case knownViaContacts  // In phone contacts
    case verified       // Verified contact (phone match + mutual)
    
    var icon: String {
        switch self {
        case .unknown: return ""
        case .mutualRooms: return "person.2"
        case .knownViaContacts: return "person.text.rectangle"
        case .verified: return "checkmark.seal"
        }
    }
    
    var label: String {
        switch self {
        case .unknown: return ""
        case .mutualRooms: return "Mutual Rooms"
        case .knownViaContacts: return "Known via Contacts"
        case .verified: return "Verified Contact"
        }
    }
    
    var color: Color {
        switch self {
        case .unknown: return .clear
        case .mutualRooms: return .secondary
        case .knownViaContacts: return .blue.opacity(0.8)
        case .verified: return .green.opacity(0.9)
        }
    }
}

// MARK: - Trust Indicator (Subtle Badge)

/// A subtle trust indicator badge - no fake blue ticks
struct TrustIndicator: View {
    let level: TrustLevel
    var showLabel: Bool = false
    var size: CGFloat = 12
    
    var body: some View {
        if level != .unknown {
            HStack(spacing: 4) {
                Image(systemName: level.icon)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(level.color)
                
                if showLabel {
                    Text(level.label)
                        .font(.caption2)
                        .foregroundStyle(level.color)
                }
            }
        }
    }
}

// MARK: - Trust Indicator Pill (Expanded Version)

/// A glass-style pill showing trust level with label
struct TrustIndicatorPill: View {
    let level: TrustLevel
    
    var body: some View {
        if level != .unknown {
            HStack(spacing: 5) {
                Image(systemName: level.icon)
                    .font(.system(size: 11, weight: .semibold))
                
                Text(level.label)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(level.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(level.color.opacity(0.3), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Trust Level Calculator

/// Calculates trust level based on local data only - no server calls
struct TrustCalculator {
    
    /// Calculate trust level for a user
    /// - Parameters:
    ///   - isInContacts: User exists in phone contacts
    ///   - mutualRoomCount: Number of shared rooms/groups
    ///   - isPhoneVerified: Phone number was verified to match contacts
    static func calculate(
        isInContacts: Bool,
        mutualRoomCount: Int,
        isPhoneVerified: Bool = false
    ) -> TrustLevel {
        // Highest trust: verified contact (in contacts + verified phone)
        if isInContacts && isPhoneVerified {
            return .verified
        }
        
        // Medium: known via contacts
        if isInContacts {
            return .knownViaContacts
        }
        
        // Low: share mutual rooms
        if mutualRoomCount > 0 {
            return .mutualRooms
        }
        
        return .unknown
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 24) {
        Text("Trust Indicators")
            .font(.headline)
        
        // Icon only
        HStack(spacing: 16) {
            TrustIndicator(level: .verified)
            TrustIndicator(level: .knownViaContacts)
            TrustIndicator(level: .mutualRooms)
        }
        
        // With labels
        VStack(alignment: .leading, spacing: 8) {
            TrustIndicator(level: .verified, showLabel: true)
            TrustIndicator(level: .knownViaContacts, showLabel: true)
            TrustIndicator(level: .mutualRooms, showLabel: true)
        }
        
        // Pills
        VStack(spacing: 8) {
            TrustIndicatorPill(level: .verified)
            TrustIndicatorPill(level: .knownViaContacts)
            TrustIndicatorPill(level: .mutualRooms)
        }
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
