package app.raven.core.design

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

/**
 * Color tokens — faithful to the canonical iOS RAVEN app.
 *
 * The iOS app is an "Apple liquid glass" app: translucent frosted
 * surfaces, **white** content, a hairline white rim, on a true-black
 * background. Its chrome has no dominant coloured accent — the iOS
 * `DS` palette is deliberately "limited to 3" (purple, blue, gray)
 * and a solid tint is used only sparingly. The brand-adjacent tint
 * is the iOS `Color.purple` (systemPurple).
 *
 * Naming note: the accent symbol is still called [RavenPalette.Purple]
 * for call-site compatibility across the feature modules.
 */
object RavenPalette {
    // ── Accent (used sparingly — most chrome is glass + white) ───────
    /** iOS `Color.purple` / systemPurple `#AF52DE` — the one solid tint. */
    val Purple = Color(0xFFAF52DE)
    /** Pressed / dim accent. */
    val PurpleDim = Color(0xFF8E3FB8)
    /** 20% accent halo. */
    val PurpleGlow = Color(0x33AF52DE)
    /** iOS system orange `#FF9500` — premium chips + status. */
    val Orange = Color(0xFFFF9500)
    val OrangeDim = Color(0xFFC76E00)

    /** Premium / vault gold. */
    val Gold = Color(0xFFD9B259)

    /** iOS system green `#34C759` — status dots, mesh / online. */
    val Emerald = Color(0xFF34C759)
    val EmeraldDim = Color(0xFF248A3D)

    // ── Surfaces (dark) — iOS system semantic colors ────────────────
    /** iOS `systemBackground` (dark) — true black for OLED. */
    val SurfaceBase = Color(0xFF000000)
    /** iOS `systemGray6` (dark) — opaque fallback for non-glass fills. */
    val SurfaceRaised = Color(0xFF1C1C1E)
    /** Grouped surface at 85% alpha. */
    val SurfaceCard = Color(0xD91C1C1E)
    /** iOS `systemGray5` (dark) — raised fills, modals. */
    val SurfaceModal = Color(0xFF2C2C2E)

    // ── Strokes / dividers — iOS hairline separators ────────────────
    /** White ~16% — the iOS separator in dark mode. */
    val GlassBorder = Color(0x29FFFFFF)
    val GlassBorderLight = Color(0x14000000)

    // ── Text — iOS label colors ─────────────────────────────────────
    val TextPrimary = Color(0xFFFFFFFF)
    /** iOS `secondaryLabel` (dark) — `#EBEBF5` @ 60%. */
    val TextSecondary = Color(0x99EBEBF5)
    /** iOS `tertiaryLabel` (dark) — `#EBEBF5` @ 30%. */
    val TextMuted = Color(0x4DEBEBF5)

    // ── Status — iOS system colors ──────────────────────────────────
    val MemberActive = Color(0xFF34C759)
    val MemberStale = Color(0xFFFF9500)
    val MemberDropped = Color(0xFFFF3B30)
}

/**
 * Material3 dark ColorScheme — true-black background, white content,
 * the systemPurple tint reserved for the few coloured accents.
 */
val ravenDarkColorScheme: ColorScheme = darkColorScheme(
    primary = RavenPalette.Purple,
    onPrimary = Color.White,
    primaryContainer = RavenPalette.PurpleDim,
    onPrimaryContainer = Color.White,
    secondary = RavenPalette.Orange,
    onSecondary = Color.White,
    tertiary = RavenPalette.Emerald,
    onTertiary = Color.Black,
    background = RavenPalette.SurfaceBase,
    onBackground = RavenPalette.TextPrimary,
    surface = RavenPalette.SurfaceRaised,
    onSurface = RavenPalette.TextPrimary,
    surfaceVariant = RavenPalette.SurfaceModal,
    onSurfaceVariant = RavenPalette.TextSecondary,
    outline = RavenPalette.GlassBorder,
    outlineVariant = RavenPalette.GlassBorderLight,
    error = RavenPalette.MemberDropped,
    onError = Color.White,
)

/** Material3 light ColorScheme — iOS light mode. */
val ravenLightColorScheme: ColorScheme = lightColorScheme(
    primary = RavenPalette.Purple,
    onPrimary = Color.White,
    secondary = RavenPalette.Orange,
    onSecondary = Color.White,
    tertiary = RavenPalette.Emerald,
    background = Color(0xFFFFFFFF),
    onBackground = Color(0xFF000000),
    surface = Color(0xFFF2F2F7),
    onSurface = Color(0xFF000000),
    surfaceVariant = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF3C3C43),
    outline = Color(0x33000000),
)
