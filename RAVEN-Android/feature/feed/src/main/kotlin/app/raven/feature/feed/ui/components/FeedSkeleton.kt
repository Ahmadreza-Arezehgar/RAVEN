package app.raven.feature.feed.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing

/**
 * Placeholder cards shown while the first page of the feed loads —
 * mirror of the iOS skeleton blocks in `FeedView`.
 */
@Composable
fun FeedSkeletonList(modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxSize()) {
        repeat(4) { SkeletonPost() }
    }
}

@Composable
private fun SkeletonPost() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Spacing.md, vertical = Spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(Spacing.sm),
    ) {
        SkeletonBlock(Modifier.size(44.dp), CircleShape)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SkeletonBlock(Modifier.fillMaxWidth(0.4f).height(14.dp), RavenShapes.inner)
            SkeletonBlock(Modifier.fillMaxWidth(0.92f).height(12.dp), RavenShapes.inner)
            SkeletonBlock(Modifier.fillMaxWidth(0.7f).height(12.dp), RavenShapes.inner)
            SkeletonBlock(Modifier.fillMaxWidth().aspectRatio(4f / 3f), RavenShapes.inner)
        }
    }
}

@Composable
private fun SkeletonBlock(modifier: Modifier, shape: Shape) {
    Box(
        modifier = modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
    )
}
