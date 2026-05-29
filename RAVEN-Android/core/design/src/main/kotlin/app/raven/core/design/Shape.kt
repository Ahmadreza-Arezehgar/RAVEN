package app.raven.core.design

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/**
 * Corner-radius tokens — exact translation of iOS `DS.radiusCard`,
 * `DS.radiusInner`, `DS.radiusPill`.
 *
 *   radiusCard  = 22  → cards, sheets, glass containers
 *   radiusInner = 12  → images inside cards, chips, text fields
 *   radiusPill  = 100 → capsules / pills (overflows to fully rounded)
 *
 * These plug into Material3's [Shapes] system: `MaterialTheme.shapes.medium`
 * maps to card radius, `.small` to inner, `.extraLarge` to pill.
 */
object RavenShapes {
    val card = RoundedCornerShape(22.dp)
    val inner = RoundedCornerShape(12.dp)
    val pill = RoundedCornerShape(100.dp)

    /**
     * Top-only rounded sheet (matches `liquidTopBar` in iOS — top corners
     * 24dp, bottom flat). Use this for bottom sheets that slide up from
     * the bottom edge of the screen.
     */
    val topSheet = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)
}

val ravenShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RavenShapes.inner,
    medium = RavenShapes.card,
    large = RavenShapes.card,
    extraLarge = RavenShapes.pill,
)
