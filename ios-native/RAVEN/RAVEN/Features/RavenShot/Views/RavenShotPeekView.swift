//
//  RavenShotPeekView.swift
//  RAVEN
//
//  Interactive peek preview shown during the left-edge drag gesture.
//  Reveals a blurred map preview strip as the user swipes right.
//

import SwiftUI
import MapKit

// MARK: - Raven Shot Peek View

struct RavenShotPeekView: View {
    let progress: CGFloat // 0.0 → 1.0
    
    var body: some View {
        ZStack {
            // Blurred map background
            Map {
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .realistic))
            .disabled(true)
            .blur(radius: max(0, 8 - progress * 12))
            
            // Glass overlay with icon
            VStack(spacing: 12) {
                Spacer()
                
                // Raven Shot icon
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: "map.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: .blue.opacity(0.3), radius: 12, y: 4)
                .scaleEffect(0.7 + progress * 0.3)
                .opacity(0.5 + progress * 0.5)
                
                Text("Raven Shot")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(progress > 0.3 ? min(1, (progress - 0.3) * 3) : 0)
                
                Spacer()
            }
            
            // Right edge highlight strip
            HStack {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.4), .cyan.opacity(0.2), .clear],
                            startPoint: .trailing,
                            endPoint: .leading
                        )
                    )
                    .frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 5)
        .ignoresSafeArea()
    }
}
