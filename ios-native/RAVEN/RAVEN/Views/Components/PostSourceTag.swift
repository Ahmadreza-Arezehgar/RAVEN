import SwiftUI

// MARK: - Location Prompt Capsule
/// Shown when GPS is disabled, prompting user to enable location
struct LocationPromptCapsule: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.orange)
            
            Text("Enable location to show nearby posts")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
            
            Spacer(minLength: 0)
            
            Button {
                openSettings()
            } label: {
                Text("Enable")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.gradient)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Post Source Tag
/// Subtle glass tag showing post source: "For You" or "Nearby • 2.3km"
struct PostSourceTag: View {
    let source: PostSource
    let distance: String?
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source == .forYou ? "sparkles" : "mappin")
                .font(.system(size: 10, weight: .medium))
            
            Text(tagText)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.8))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
    
    private var tagText: String {
        if source == .forYou { return "For You" }
        if let d = distance { return "Nearby • \(d)" }
        return "Nearby"
    }
}

#Preview("Location Prompt") {
    VStack {
        LocationPromptCapsule()
            .padding()
        
        PostSourceTag(source: .forYou, distance: nil)
        PostSourceTag(source: .nearby, distance: "2.3km")
    }
}
