package app.raven.feature.chat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import coil.compose.AsyncImage

/**
 * Avatar composable — pixel-equivalent of iOS `GlassAvatar`.
 *
 *   • Circular crop
 *   • Liquid-glass gradient ring around the image (purple + orange
 *     at 25 % / 10 % alpha — matches the landing-screen halo)
 *   • Optional bottom-trailing presence dot (green) when
 *     [showOnlineIndicator] is true
 *   • Initials fallback when [path] is null/empty
 */
@Composable
fun GlassAvatar(
    name: String,
    path: String?,
    size: Dp = 50.dp,
    showOnlineIndicator: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier.size(size)) {
        val ring = Brush.linearGradient(
            colors = listOf(
                RavenPalette.Purple.copy(alpha = 0.25f),
                RavenPalette.Orange.copy(alpha = 0.10f),
            )
        )
        Box(
            modifier = Modifier
                .matchParentSize()
                .clip(CircleShape)
                .background(ring)
                .border(width = 1.dp, color = MaterialTheme.colorScheme.outline, shape = CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (!path.isNullOrBlank()) {
                AsyncImage(
                    model = path,
                    contentDescription = name,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .matchParentSize()
                        .clip(CircleShape),
                )
            } else {
                Text(
                    text = name.initials(),
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = RavenPalette.Purple,
                )
            }
        }

        if (showOnlineIndicator) {
            // Bottom-trailing dot — 12dp circle with 2dp border in
            // the surface colour so it reads on both light and dark.
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(12.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF34C759))
                    .border(2.dp, MaterialTheme.colorScheme.background, CircleShape),
            )
        }
    }
}

private fun String.initials(): String {
    val parts = trim().split(' ').filter { it.isNotBlank() }
    return when {
        parts.isEmpty() -> "?"
        parts.size == 1 -> parts[0].take(2).uppercase()
        else -> (parts[0].first().toString() + parts[1].first().toString()).uppercase()
    }
}
