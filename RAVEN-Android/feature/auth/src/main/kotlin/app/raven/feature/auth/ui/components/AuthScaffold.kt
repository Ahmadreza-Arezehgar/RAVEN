package app.raven.feature.auth.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.systemBars
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing

/**
 * Standard auth-screen container. Every screen sits on the dark
 * gradient background that the iOS app uses (top-down purple →
 * near-black) and gets system-bar insets + horizontal padding for
 * free. The single-column scroll handles small phones in landscape.
 */
@Composable
fun AuthScaffold(content: @Composable ColumnScope.() -> Unit) {
    val bg = Brush.verticalGradient(
        colors = listOf(
            MaterialTheme.colorScheme.background,
            RavenPalette.SurfaceRaised,
            MaterialTheme.colorScheme.background,
        )
    )
    val insets = WindowInsets.systemBars.asPaddingValues()
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bg),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(insets)
                .padding(horizontal = Spacing.lg, vertical = Spacing.lg),
        ) {
            content()
        }
    }
}
