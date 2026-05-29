//
//  EchoBubblePin.swift
//  RAVEN
//
//  Map annotation bubble for echoes — text content with
//  emoji summary and fade opacity based on time remaining.
//

import SwiftUI

struct EchoBubblePin: View {
    let echo: Echo
    let responseSummary: EchoResponseSummary?
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            // Text bubble
            Text(echo.content)
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlass(cornerRadius: 16)
            
            // Emoji + response count bar
            HStack(spacing: 4) {
                ForEach(topEmojis, id: \.self) { emoji in
                    Text(emoji)
                        .font(.caption2)
                }
                
                Text("\(totalResponses)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .liquidCapsule()
            
            // Arrow/pointer
            Triangle()
                .fill(.ultraThinMaterial)
                .frame(width: 12, height: 6)
        }
        .frame(maxWidth: 180)
        .opacity(echo.fadeOpacity)
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(RavenAnimation.snappy, value: isSelected)
    }
    
    private var topEmojis: [String] {
        guard let summary = responseSummary else { return [] }
        return summary.sortedCounts.prefix(3).map { $0.emoji.rawValue }
    }
    
    private var totalResponses: Int {
        responseSummary?.totalCount ?? 0
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}
