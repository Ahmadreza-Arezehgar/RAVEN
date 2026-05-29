//
//  OfflineCachedAvatar.swift
//  RAVEN
//
//  Drop-in replacement for `AsyncImage` whose backing store is
//  `AvatarCacheService` — i.e. it survives offline cold launch
//  because the bytes live in `Documents/avatars/` rather than the
//  HTTP-cache-controlled `URLCache.shared`.
//
//  Use this anywhere the app shows another user's photo:
//
//      OfflineCachedAvatar(url: peer.avatarURL,
//                          size: 36,
//                          fallbackInitial: peer.displayName.first)
//
//  When the URL is nil the view renders the initials fallback.
//  When the URL is non-nil but the bytes haven't loaded yet (and
//  the disk cache misses) the view renders the initials placeholder
//  while the network fetch is in flight, then crossfades to the
//  real image. There is no spinner — that would just stack noise on
//  every avatar in a conversation list.
//

import SwiftUI

struct OfflineCachedAvatar: View {
    let url: URL?
    let size: CGFloat
    /// Single-letter / single-emoji fallback to draw inside the
    /// gradient circle when no image is available. nil → render a
    /// generic person glyph.
    let fallbackInitial: Character?
    /// Tint used for the initials gradient. Defaults to a stable
    /// per-URL hue so different peers render visibly different.
    let tint: Color?

    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?

    init(url: URL?, size: CGFloat, fallbackInitial: Character? = nil, tint: Color? = nil) {
        self.url = url
        self.size = size
        self.fallbackInitial = fallbackInitial
        self.tint = tint
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .transition(.opacity)
            } else {
                initialsCircle
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            // Cancel any in-flight load when the URL changes
            // (cell reuse in a list, etc.).
            loadTask?.cancel()
            guard let url else { image = nil; return }
            loadTask = Task { @MainActor in
                let img = await AvatarCacheService.shared.image(for: url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.image = img
                }
            }
        }
        .onDisappear { loadTask?.cancel() }
    }

    private var initialsCircle: some View {
        Circle()
            .fill(LinearGradient(
                colors: [resolvedTint.opacity(0.7), resolvedTint.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Group {
                    if let ch = fallbackInitial {
                        Text(String(ch).uppercased())
                            .font(.system(size: max(11, size * 0.42),
                                          weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: max(10, size * 0.45)))
                            .foregroundStyle(.white)
                    }
                }
            )
    }

    /// Stable, deterministic per-URL hue — same URL always produces
    /// the same colour so a peer's avatar identity-circle is
    /// recognisable across screens.
    private var resolvedTint: Color {
        if let tint { return tint }
        guard let url else { return Color.gray }
        // Trivial hash → hue. Good enough for visual distinguishability.
        let hue = Double(abs(url.absoluteString.hashValue) % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}
