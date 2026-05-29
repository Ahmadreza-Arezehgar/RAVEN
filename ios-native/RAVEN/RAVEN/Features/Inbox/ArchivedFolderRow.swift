//
//  ArchivedFolderRow.swift
//  RAVEN
//
//  The capsule-pill at the top of the Inbox that opens the archive
//  folder — Telegram-style entry point, refit to Apple's liquid
//  glass aesthetic.
//
//  Visual layout
//  ─────────────
//   ┌──────────────────────────────────────────────────────┐
//   │  ┌────┐                                          ⌃   │
//   │  │ 📥 │   Archived Chats              7   │        │
//   │  └────┘                                              │
//   └──────────────────────────────────────────────────────┘
//
//  • The whole row is one tappable capsule with `.ultraThinMaterial`
//    fill so it floats on top of whatever wallpaper / background the
//    inbox is rendering.
//  • The icon sits in a smaller indigo-tinted rounded square — same
//    palette as the Archive swipe action, so users connect the two
//    affordances.
//  • Count badge appears only when > 0 (an empty archive shouldn't
//    advertise itself).
//
//  Renders nothing when `count == 0` so the inbox stays clean for
//  users who never archive anything.
//

import SwiftUI

struct ArchivedFolderRow: View {

    let count: Int
    let onTap: () -> Void

    var body: some View {
        if count > 0 {
            Button {
                Haptics.light()
                onTap()
            } label: {
                contentView
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var contentView: some View {
        HStack(spacing: 12) {
            // Indigo-tinted square — same accent as the Archive
            // swipe action, so the visual relationship is obvious.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.indigo, Color.indigo.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Archived Chats")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(count == 1 ? "1 conversation" : "\(count) conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Tiny count chip + chevron — the chip mirrors the
            // unread-badge style used in normal conversation rows so
            // archived rows feel like a first-class part of the list.
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.indigo.opacity(0.85))
                )

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        )
    }
}

// MARK: - Preview helper (not compiled into release)

#if DEBUG
#Preview("ArchivedFolderRow") {
    VStack(spacing: 12) {
        ArchivedFolderRow(count: 3) { print("tap") }
        ArchivedFolderRow(count: 1) { print("tap") }
        ArchivedFolderRow(count: 27) { print("tap") }
        ArchivedFolderRow(count: 0) { print("tap") } // hidden
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
#endif
