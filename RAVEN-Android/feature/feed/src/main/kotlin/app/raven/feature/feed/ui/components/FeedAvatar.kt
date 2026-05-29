package app.raven.feature.feed.ui.components

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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import coil.compose.AsyncImage

/**
 * Circular author avatar — pixel-equivalent of the iOS `GlassAvatar`:
 * a purple→orange glass ring, a circular crop of the photo, and an
 * initials fallback when no avatar URL is available.
 */
@Composable
fun FeedAvatar(
    name: String,
    path: String?,
    size: Dp = 44.dp,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    listOf(
                        RavenPalette.Purple.copy(alpha = 0.25f),
                        RavenPalette.Orange.copy(alpha = 0.10f),
                    )
                )
            )
            .border(1.dp, MaterialTheme.colorScheme.outline, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        if (!path.isNullOrBlank()) {
            AsyncImage(
                model = path,
                contentDescription = name,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(size)
                    .clip(CircleShape),
            )
        } else {
            Text(
                text = initialsOf(name),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = RavenPalette.Purple,
            )
        }
    }
}

private fun initialsOf(name: String): String {
    val parts = name.trim().split(' ', '_', '.').filter { it.isNotBlank() }
    return when {
        parts.isEmpty() -> "?"
        parts.size == 1 -> parts[0].take(2).uppercase()
        else -> (parts[0].first().toString() + parts[1].first().toString()).uppercase()
    }
}
