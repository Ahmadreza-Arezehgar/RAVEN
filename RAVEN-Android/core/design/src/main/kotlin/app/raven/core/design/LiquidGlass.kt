package app.raven.core.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * RAVEN surface treatment — faithful to the iOS app's "liquid glass"
 * design system (the `LiquidGlass` enum in the iOS code).
 *
 * Every iOS surface — bars, pills, cards, sheet headers, buttons — is
 * a translucent frosted pane: an `.ultraThinMaterial` fill, a hairline
 * white rim that is bright at the top-leading edge and fades out, and
 * a soft drop shadow. Content on it is white. The chrome carries no
 * coloured "accent".
 *
 * Android can't do a true backdrop blur in an offline build, so the
 * material is approximated with a low-alpha white fill over the black
 * background — together with the white rim and shadow it still reads
 * as a floating glass pane.
 *
 * (Function/val names are kept so existing call sites don't churn.)
 */

/** A liquid-glass surface: translucent frosted fill + hairline white rim. */
fun Modifier.liquidGlass(
    shape: Shape = RavenShapes.card,
    elevation: Dp = 6.dp,
): Modifier = this
    .shadow(
        elevation = elevation,
        shape = shape,
        ambientColor = Color.Black.copy(alpha = 0.30f),
        spotColor = Color.Black.copy(alpha = 0.40f),
    )
    .clip(shape)
    .background(Color.White.copy(alpha = 0.12f))
    .border(width = 0.8.dp, brush = GlassSheenBorder, shape = shape)

/** Pill-shaped liquid-glass surface. */
fun Modifier.liquidCapsule(elevation: Dp = 3.dp): Modifier =
    liquidGlass(shape = RavenShapes.pill, elevation = elevation)

/**
 * Screen background — iOS `systemBackground`: a flat true black. The
 * glass surfaces float on top of it.
 */
fun Modifier.ravenScreenBackground(): Modifier =
    this.background(RavenPalette.SurfaceBase)

/**
 * Accent fill — the compose FAB, primary buttons, selected segmented
 * controls. The iOS chrome is glass; where a solid tint is genuinely
 * needed the app uses its systemPurple accent.
 */
val RavenBrandGradient: Brush = Brush.verticalGradient(
    listOf(
        RavenPalette.Purple,
        RavenPalette.PurpleDim,
    )
)

/**
 * The liquid-glass rim — a hairline stroke, bright at the top-leading
 * edge and fading to almost nothing. Mirror of iOS
 * `LiquidGlass.edgeStroke`.
 */
val GlassSheenBorder: Brush = Brush.linearGradient(
    listOf(
        Color.White.copy(alpha = 0.22f),
        Color.White.copy(alpha = 0.06f),
        Color.White.copy(alpha = 0.02f),
    )
)
