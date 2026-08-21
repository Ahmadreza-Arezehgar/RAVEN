//
//  GlassSurfaceModifier.swift
//  RAVEN
//
//  TERMINAL REDESIGN (2026-08): the old liquid-glass surface is repointed
//  onto the console language — an opaque near-black panel with a phosphor
//  hairline stroke. `FeedVideoPlayer` chrome, nav pills and every other
//  caller re-skin through this single modifier.
//

import SwiftUI

extension View {
    /// Console-panel background clipped to the given shape.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(shape.fill(DS.inkElevated.opacity(0.94)))
            .overlay(shape.strokeBorder(DS.hairline, lineWidth: 1))
    }
}
