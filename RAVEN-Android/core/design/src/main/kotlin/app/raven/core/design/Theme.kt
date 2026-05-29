package app.raven.core.design

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/**
 * Root theme wrapper.
 *
 * Defaults to **dark mode** because the iOS app uses
 * `.preferredColorScheme(.dark)` for almost every surface. Light mode
 * is supported but only kicks in when [forceDarkMode] is false AND the
 * system says light.
 *
 * Dynamic color (Material You) is **opt-in** via [useDynamicColor].
 * Default off — pixel-parity with iOS means the brand purple stays
 * constant; we don't want Android 12+ swapping our accents for a
 * wallpaper-derived palette unless the user asks.
 */
@Composable
fun RavenTheme(
    forceDarkMode: Boolean = true,
    useDynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val systemDark = isSystemInDarkTheme()
    val isDark = forceDarkMode || systemDark

    val colorScheme = when {
        useDynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (isDark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        isDark -> ravenDarkColorScheme
        else -> ravenLightColorScheme
    }

    // Tint the status bar to match the surface so the OS chrome
    // doesn't break the glass-card aesthetic the iOS app has.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            window.statusBarColor = colorScheme.background.toArgb()
            window.navigationBarColor = colorScheme.background.toArgb()
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !isDark
                isAppearanceLightNavigationBars = !isDark
            }
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = ravenTypography,
        shapes = ravenShapes,
        content = content,
    )
}
