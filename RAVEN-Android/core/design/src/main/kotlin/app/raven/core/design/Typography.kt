package app.raven.core.design

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Typography — mapped to Apple's HIG type ramp because the iOS app
 * uses [`Font.system(.title)`, `.body`, etc.] everywhere.
 *
 *   SF Pro on iOS  ↔  SF-equivalent on Android
 *
 * Android doesn't have SF Pro bundled. We fall through to
 * `FontFamily.SansSerif`, which on most modern devices resolves to a
 * geometric sans (Roboto on stock, Samsung Sans on Samsung, etc.).
 * For a closer match we can ship Inter or SF-Pro-equivalent later via
 * `googleFontsProvider` — left as a follow-up so the foundation
 * doesn't pull a 2 MB asset on day one.
 *
 * Size table is taken from Apple's "Large (Default)" Dynamic Type
 * ramp so users on stock Dynamic Type see the same visual size as on
 * iOS. Letter spacing matches SF Pro's tracking table from Apple's
 * Typography reference.
 */
private val defaultFontFamily = FontFamily.SansSerif

val ravenTypography: Typography = Typography(
    // .largeTitle ≈ 34pt / 41 line / -0.4 tracking
    displayLarge = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Bold,
        fontStyle = FontStyle.Normal,
        fontSize = 34.sp,
        lineHeight = 41.sp,
        letterSpacing = (-0.4).sp,
    ),
    // .title ≈ 28pt / 34 line
    displayMedium = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.SemiBold,
        fontSize = 28.sp,
        lineHeight = 34.sp,
        letterSpacing = (-0.3).sp,
    ),
    // .title2 ≈ 22pt / 28 line
    displaySmall = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.SemiBold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = (-0.2).sp,
    ),
    // .title3 ≈ 20pt / 25 line
    headlineLarge = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 25.sp,
        letterSpacing = (-0.1).sp,
    ),
    // .headline ≈ 17pt semibold / 22 line
    headlineMedium = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.SemiBold,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        letterSpacing = (-0.1).sp,
    ),
    // .body ≈ 17pt regular / 22 line
    bodyLarge = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Normal,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        letterSpacing = (-0.1).sp,
    ),
    // .callout ≈ 16pt / 21 line
    bodyMedium = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 21.sp,
        letterSpacing = 0.sp,
    ),
    // .subheadline ≈ 15pt / 20 line
    bodySmall = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Normal,
        fontSize = 15.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp,
    ),
    // .footnote ≈ 13pt / 18 line
    labelLarge = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Medium,
        fontSize = 13.sp,
        lineHeight = 18.sp,
        letterSpacing = 0.1.sp,
    ),
    // .caption ≈ 12pt / 16 line
    labelMedium = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.2.sp,
    ),
    // .caption2 ≈ 11pt / 13 line
    labelSmall = TextStyle(
        fontFamily = defaultFontFamily,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 13.sp,
        letterSpacing = 0.3.sp,
    ),
)
