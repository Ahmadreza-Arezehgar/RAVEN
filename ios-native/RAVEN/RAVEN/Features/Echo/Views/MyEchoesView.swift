//
//  MyEchoesView.swift
//  RAVEN
//
//  List of echoes authored by this user with live response counts.
//

import SwiftUI

// MARK: - My Echoes View

struct MyEchoesView: View {
    @State private var store = EchoStore.shared
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if store.myEchoes.isEmpty {
                    emptyState
                } else {
                    ForEach(store.myEchoes) { echo in
                        MyEchoCard(
                            echo: echo,
                            summary: store.summary(for: echo.id)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle("My Echoes")
        .task {
            await store.loadEchoes()
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("You haven't sent any echoes yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 80)
    }
}

// MARK: - My Echo Card

struct MyEchoCard: View {
    let echo: Echo
    let summary: EchoResponseSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Content
            Text(echo.content)
                .font(.body)
                .lineLimit(4)
            
            // Stats bar
            HStack(spacing: 16) {
                // Total responses
                Label("\(summary.totalCount) responses", systemImage: "bubble.right.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
                
                Spacer()
                
                // Time remaining
                HStack(spacing: 4) {
                    Image(systemName: echo.isExpired ? "clock.badge.xmark" : "clock")
                        .font(.caption2)
                    Text(echo.timeRemaining)
                        .font(.caption2)
                }
                .foregroundStyle(echo.isExpired ? .red : .secondary)
            }
            
            // Emoji breakdown
            if summary.totalCount > 0 {
                HStack(spacing: 10) {
                    ForEach(summary.sortedCounts, id: \.emoji) { item in
                        HStack(spacing: 3) {
                            Text(item.emoji.rawValue)
                                .font(.system(size: 16))
                            Text("\(item.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.purple.opacity(0.3), .indigo.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

#Preview {
    NavigationStack {
        MyEchoesView()
    }
}
