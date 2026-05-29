//
//  AlbumBubbleView.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — Telegram-style grouped media albums.
//
//  When the user multi-picks N photos / videos in the attachment
//  sheet, each item lands as its OWN `ChatMessage` row (so every
//  item keeps its own E2EE envelope, signed URL, upload progress,
//  ACK lifecycle, retry semantics — none of the existing round-21
//  hardening has to change). The album fields on each row
//  (`albumGroupKey`, `albumIndex`, `albumTotal`) glue them back
//  together at render time: ChatView's message-list pass collects
//  consecutive rows that share `albumGroupKey` and hands them to
//  this view as one bubble.
//
//  Layout matches Telegram / WhatsApp:
//    • 2 items  → side-by-side (1×2 split)
//    • 3 items  → big left, two stacked right (2/3 + 1/3)
//    • 4 items  → 2×2 grid
//    • 5+ items → 2×2 grid with `+N` overlay on the last tile,
//                  where N = remaining (e.g. 5 → "+1", 9 → "+5").
//                  The hidden tiles are still uploading / visible
//                  in the chat — the overlay is just a fullscreen-
//                  open affordance.
//
//  Per-tile upload progress + caption are inherited from the
//  per-row state, so a partial album (4 of 5 uploaded) renders
//  the 4 ready tiles as photos and the 5th tile with the ring
//  overlay, all inside the same bubble.
//
//  Tap on any tile opens the fullscreen viewer for that item.
//

import SwiftUI

struct AlbumBubbleView: View {

    /// Album rows in selection / send order (`albumIndex` ascending).
    /// Caller guarantees `messages.count >= 1` and all share the same
    /// `albumGroupKey`.
    let messages: [ChatMessage]

    /// Whether this album is from the local user (right-aligned, blue
    /// bubble corner) or a peer (left-aligned, secondary corner).
    let isFromMe: Bool

    /// Tapped tile callback — parent typically opens the fullscreen
    /// media viewer for that ChatMessage.
    var onTapTile: ((ChatMessage) -> Void)? = nil

    // MARK: - Layout knobs

    /// Inter-tile gap. Telegram uses ~2pt; we use 3pt so the photos
    /// don't merge visually under the Liquid Glass material.
    private let tileGap: CGFloat = 3
    /// Outer bubble corner radius — matches the round-21 single-
    /// image bubble (22pt) so the album doesn't look like a
    /// foreign element next to other media.
    private let bubbleCorner: CGFloat = 22
    /// Max album width on screen — matches ImageMessageView's cap.
    private let maxBubbleWidth: CGFloat = 280

    // MARK: - Visible tile budget

    /// We render at most 4 tiles in the grid; anything past 4
    /// becomes a "+N" overlay on the 4th tile. ChatView still
    /// shows N rows in the DB; this is purely a render cap.
    private static let visibleTileCap = 4

    private var visibleTiles: [ChatMessage] {
        Array(messages.prefix(Self.visibleTileCap))
    }

    private var overflowCount: Int {
        max(0, messages.count - Self.visibleTileCap)
    }

    // MARK: - Body

    var body: some View {
        gridForCount(visibleTiles.count)
            .frame(maxWidth: maxBubbleWidth)
            .clipShape(RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous))
            // Subtle hairline border so the album reads as one card
            // even when a tile is currently uploading (grey scrim).
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }

    // MARK: - Layouts

    @ViewBuilder
    private func gridForCount(_ n: Int) -> some View {
        switch n {
        case 1:
            // One-tile album shouldn't really happen (single-media
            // path uses the existing ImageMessageView), but render
            // gracefully in case a sibling row is mid-fetch.
            tile(messages[0], isOverflow: false)
        case 2:
            HStack(spacing: tileGap) {
                tile(messages[0], isOverflow: false)
                tile(messages[1], isOverflow: false)
            }
            .aspectRatio(2, contentMode: .fit)
        case 3:
            HStack(spacing: tileGap) {
                tile(messages[0], isOverflow: false)
                VStack(spacing: tileGap) {
                    tile(messages[1], isOverflow: false)
                    tile(messages[2], isOverflow: false)
                }
            }
            .aspectRatio(1.2, contentMode: .fit)
        default:
            // 4-or-more → 2×2 grid; the last visible tile carries
            // the +N overlay when there are siblings past the cap.
            let tiles = visibleTiles
            VStack(spacing: tileGap) {
                HStack(spacing: tileGap) {
                    tile(tiles[0], isOverflow: false)
                    tile(tiles[1], isOverflow: false)
                }
                HStack(spacing: tileGap) {
                    tile(tiles[2], isOverflow: false)
                    tile(tiles[3], isOverflow: overflowCount > 0)
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    // MARK: - Tile

    @ViewBuilder
    private func tile(_ message: ChatMessage, isOverflow: Bool) -> some View {
        Button {
            onTapTile?(message)
        } label: {
            ZStack {
                tileContent(message)

                // Per-tile upload progress ring — mirrors the
                // single-image ImageMessageView overlay so an
                // album-in-flight reads the same as a standalone
                // photo-in-flight (round 26 spec).
                tileProgressOverlay(message)

                // "+N more" affordance on the last visible tile when
                // the album has > 4 items. Tap still opens the
                // fullscreen viewer for THIS tile; the user swipes
                // through the rest in the gallery.
                if isOverflow {
                    ZStack {
                        Color.black.opacity(0.55)
                        Text("+\(overflowCount)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .accessibilityLabel(Text("\(overflowCount) more"))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What goes BEHIND the overlays — either the local thumbnail
    /// (if the row has a localPath we wrote during compress-first),
    /// or a placeholder until the upload's `attachmentUrl` lands.
    @ViewBuilder
    private func tileContent(_ message: ChatMessage) -> some View {
        if let local = message.localPath,
           !local.isEmpty,
           let img = UIImage(contentsOfFile: local) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let urlStr = message.attachmentUrl, !urlStr.isEmpty {
            // Existing media cache helper handles signed URL re-sign +
            // disk cache; AsyncImage is fine as a fallback for the
            // simple album case (the per-message ImageMessageView has
            // a fancier loader but it's out of scope for the grid).
            AsyncImage(url: AppConfig.mediaURL(from: urlStr)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color(.systemGray5)
                }
            }
        } else {
            Color(.systemGray5)
        }
    }

    @ViewBuilder
    private func tileProgressOverlay(_ message: ChatMessage) -> some View {
        if message.syncState == .uploading,
           let progress = message.uploadProgress,
           progress < 1.0 {
            ZStack {
                Color.black.opacity(0.40)
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 3)
                            .frame(width: 32, height: 32)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.02, progress)))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 32, height: 32)
                            .animation(.easeOut(duration: 0.2), value: progress)
                    }
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
        } else if message.syncState == .failed {
            // Failure overlay — small retry-affordance glyph so
            // the user can long-press the tile (parent wires the
            // retry action).
            ZStack {
                Color.black.opacity(0.55)
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(Text("Upload failed — tap to retry"))
        } else if message.type == .video {
            // Standard video play-glyph + duration pill, similar to
            // the picker's video badge.
            ZStack {
                Color.black.opacity(0.20)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}
