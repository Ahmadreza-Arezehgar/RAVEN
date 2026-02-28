import SwiftUI

// MARK: - Conversation Search Capsule (Morphing Glass Input)
/// Floats above bottom bar when Messages tab is active.
/// Tap to expand into search input, or shows "Search chats" when inactive.
struct ConversationSearchCapsule: View {
    @Binding var query: String
    @Binding var isActive: Bool
    var isFocused: FocusState<Bool>.Binding
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
            
            if isActive {
                // Active: show text field
                TextField("Search conversations...", text: $query)
                    .font(.system(size: 16))
                    .focused(isFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        if query.isEmpty {
                            closeSearch()
                        }
                    }
                
                // Clear/Close button
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        closeSearch()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
            } else {
                // Inactive: pill label
                Text("Search chats")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: isActive ? .infinity : nil)
        // Apple Native Liquid Glass Effect with fallback
        .liquidGlassCapsule()
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        .onTapGesture {
            if !isActive {
                activateSearch()
            }
        }
        .accessibilityLabel("Search conversations")
        .accessibilityHint(isActive ? "Type to search" : "Double tap to search")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isActive)
    }
    
    private func activateSearch() {
        Haptics.light()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isActive = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFocused.wrappedValue = true
        }
    }
    
    private func closeSearch() {
        Haptics.light()
        isFocused.wrappedValue = false
        query = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isActive = false
        }
    }
}

// MARK: - Search Pill (Simple Tap Button - Legacy) 
/// Only visible when Messages tab is active - floats ABOVE the TabBar
struct SearchPill: View {
    let onTap: () -> Void
    
    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                Text("Search chats")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        // Apple Native Liquid Glass Effect with fallback
        .liquidGlassCapsule()
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }
}

// MARK: - Liquid Tab Bar (Apple Native Liquid Glass)
/// Uses Apple's native material API for authentic iOS styling
struct LiquidTabBar: View {
    @Binding var tab: AppTab
    
    private var isMessages: Bool { tab == .messages }
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { t in
                tabItem(t, t.icon)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isMessages ? 10 : 14)
        // Apple Native Liquid Glass Effect with fallback
        .liquidGlassCapsule()
        .scaleEffect(isMessages ? 0.92 : 1.0)
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: isMessages)
    }
    
    @ViewBuilder
    private func tabItem(_ t: AppTab, _ icon: String) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                tab = t
            }
        } label: {
            ZStack {
                // Selection indicator using native glass
                if tab == t {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.15))
                        .frame(width: 52, height: 36)
                }
                
                Image(systemName: icon)
                    .font(.system(size: 22, weight: tab == t ? .medium : .regular))
                    .foregroundStyle(
                        tab == t 
                            ? Color.primary 
                            : Color.secondary
                    )
                    .symbolEffect(.bounce, value: tab == t)
            }
            .frame(width: 56, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.accessibilityName)
        .accessibilityAddTraits(tab == t ? .isSelected : [])
    }
}

// MARK: - Preview
#Preview {
    @Previewable @State var tab: AppTab = .home
    
    ZStack {
        Color.black
            .ignoresSafeArea()
        
        VStack {
            Spacer()
            
            // Search Pill - only when Messages
            if tab == .messages {
                SearchPill {
                    print("Search tapped")
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .padding(.bottom, 8)
            }
            
            LiquidTabBar(tab: $tab)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tab)
    }
}
