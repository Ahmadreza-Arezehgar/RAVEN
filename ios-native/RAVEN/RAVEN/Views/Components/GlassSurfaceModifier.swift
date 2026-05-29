//
//  GlassSurfaceModifier.swift
//  RAVEN
//
//  `.glassSurface(in: <Shape>)` was a design-system modifier from the
//  Phase-4 commit that the revert removed. `FeedVideoPlayer` (chrome
//  buttons + nav pills) and a few other callers still use it. Stub
//  it as `.ultraThinMaterial` + a thin white stroke so the chrome
//  reads as "frosted glass over media" even without the original
//  multi-layer blur tint pipeline.
//

import SwiftUI

extension View {
    /// Frosted-glass background clipped to the given shape.
    /// Stub for the Phase-4 design-system modifier.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
