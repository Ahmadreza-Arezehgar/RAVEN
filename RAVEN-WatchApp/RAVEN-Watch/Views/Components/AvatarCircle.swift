// AvatarCircle.swift
//
// The Watch never downloads avatar images directly — it would burn
// bandwidth and battery for thumbnails the user sees for half a second.
// Instead the phone projects a single initial char into the snapshot
// and we render a tinted circle with that letter inside. Good enough
// at 41–49mm screen sizes.

import SwiftUI

struct AvatarCircle: View {
    let initial: String
    let isGroup: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
            } else {
                Text(initial.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var gradientColors: [Color] {
        // Deterministic two-tone based on the first character; gives
        // the same person a stable color across sessions without us
        // having to store anything.
        let scalars = initial.unicodeScalars
        let seed = Int(scalars.first?.value ?? 65)
        let palette: [(Color, Color)] = [
            (.purple, .pink), (.blue, .cyan), (.orange, .red),
            (.green, .mint), (.indigo, .purple), (.yellow, .orange)
        ]
        let pair = palette[seed % palette.count]
        return [pair.0, pair.1]
    }
}
