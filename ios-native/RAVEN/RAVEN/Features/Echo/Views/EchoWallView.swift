//
//  EchoWallView.swift
//  RAVEN
//
//  Main Echo feed — displays received echoes with emoji reactions.
//  Liquid Glass design with animated response buttons.
//

import SwiftUI

// MARK: - Echo Wall View

struct EchoWallView: View {
    @State private var store = EchoStore.shared
    @State private var showComposer = false
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if store.isLoading && store.receivedEchoes.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in
                                shimmerCard
                            }
                        } else if displayedEchoes.isEmpty {
                            emptyState
                        } else {
                            ForEach(displayedEchoes) { echo in
                                EchoCard(
                                    echo: echo,
                                    summary: store.summary(for: echo.id),
                                    hasResponded: store.hasResponded(to: echo.id),
                                    onRespond: { emoji in
                                        Task { await store.respond(to: echo.id, with: emoji) }
                                    }
                                )
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
                .refreshable {
                    await store.loadEchoes()
                }
                
                // FAB - Create Echo
                Button {
                    showComposer = true
                } label: {
                    Image(systemName: "megaphone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            LinearGradient(
                                colors: [.purple, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: .purple.opacity(0.4), radius: 12, y: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("Echo Wall")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("", selection: $selectedTab) {
                        Text("All").tag(0)
                        Text("Mine").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
            .sheet(isPresented: $showComposer) {
                EchoComposerView()
            }
            .task {
                await store.loadEchoes()
            }
        }
    }
    
    private var displayedEchoes: [Echo] {
        selectedTab == 0 ? store.receivedEchoes : store.myEchoes
    }
    
    // MARK: - Shimmer Placeholder
    
    private var shimmerCard: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(height: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "megaphone")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("No Echoes yet")
                .font(.title3.weight(.medium))
            
            Text("Send an anonymous question and see who\nin your mesh network responds!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }
}

// MARK: - Echo Card

struct EchoCard: View {
    let echo: Echo
    let summary: EchoResponseSummary
    let hasResponded: Bool
    let onRespond: (EchoEmoji) -> Void
    
    @State private var selectedEmoji: EchoEmoji?
    @State private var bounceEmoji: EchoEmoji?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                // Pseudonym avatar
                Circle()
                    .fill(pseudonymColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String(echo.authorPseudonym.prefix(2)))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    if echo.isMine {
                        Text("Your Echo")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    } else {
                        Text("#\(echo.authorPseudonym)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    
                    if echo.h3Cell != nil {
                        HStack(spacing: 2) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 8))
                            Text("Nearby")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
                
                // Time
                Text(echo.timeRemaining)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            
            // Content
            Text(echo.content)
                .font(.body)
                .lineLimit(5)
                .padding(.vertical, 4)
            
            // Emoji Response Bar
            HStack(spacing: 8) {
                ForEach(EchoEmoji.allCases, id: \.self) { emoji in
                    emojiButton(emoji)
                }
                
                Spacer()
                
                // Total count
                if summary.totalCount > 0 {
                    Text("\(summary.totalCount)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    echo.isMine ?
                        AnyShapeStyle(LinearGradient(colors: [.purple.opacity(0.4), .indigo.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                        AnyShapeStyle(.white.opacity(0.08)),
                    lineWidth: 1
                )
        )
    }
    
    // MARK: - Emoji Button
    
    @ViewBuilder
    private func emojiButton(_ emoji: EchoEmoji) -> some View {
        let count = summary.counts[emoji] ?? 0
        let isSelected = selectedEmoji == emoji
        
        Button {
            guard !hasResponded else { return }
            selectedEmoji = emoji
            bounceEmoji = emoji
            onRespond(emoji)
            
            // Reset bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                bounceEmoji = nil
            }
        } label: {
            HStack(spacing: 3) {
                Text(emoji.rawValue)
                    .font(.system(size: 18))
                    .scaleEffect(bounceEmoji == emoji ? 1.4 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: bounceEmoji)
                
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ?
                    AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)) :
                    AnyShapeStyle(.ultraThinMaterial)
            )
            .clipShape(Capsule())
        }
        .disabled(hasResponded && !isSelected)
        .opacity(hasResponded && !isSelected ? 0.5 : 1.0)
    }
    
    // MARK: - Pseudonym Color
    
    private var pseudonymColor: Color {
        let hash = echo.authorPseudonym.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }
}

// MARK: - Preview

#Preview {
    EchoWallView()
}
