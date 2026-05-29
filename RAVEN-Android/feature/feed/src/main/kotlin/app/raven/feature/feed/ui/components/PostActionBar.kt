package app.raven.feature.feed.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing

/**
 * The like / comment / repost / share row under a post — mirror of
 * the iOS `PostCard` action bar. Counts hide when zero; the active
 * state recolours the icon (red heart when liked, emerald repeat
 * when reposted).
 */
@Composable
fun PostActionBar(
    likeCount: Int,
    isLiked: Boolean,
    commentCount: Int,
    repostCount: Int,
    isReposted: Boolean,
    isBookmarked: Boolean,
    onLike: () -> Unit,
    onComment: () -> Unit,
    onRepost: () -> Unit,
    onBookmark: () -> Unit,
    onShare: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.lg),
    ) {
        ActionButton(
            icon = if (isLiked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder,
            label = countLabel(likeCount),
            tint = if (isLiked) RavenPalette.MemberDropped else MaterialTheme.colorScheme.onSurfaceVariant,
            onClick = onLike,
        )
        ActionButton(
            icon = Icons.Outlined.ChatBubbleOutline,
            label = countLabel(commentCount),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            onClick = onComment,
        )
        ActionButton(
            icon = Icons.Outlined.Repeat,
            label = countLabel(repostCount),
            tint = if (isReposted) RavenPalette.Emerald else MaterialTheme.colorScheme.onSurfaceVariant,
            onClick = onRepost,
        )
        ActionButton(
            icon = if (isBookmarked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder,
            label = null,
            tint = if (isBookmarked) RavenPalette.Gold else MaterialTheme.colorScheme.onSurfaceVariant,
            onClick = onBookmark,
        )
        Spacer(Modifier.weight(1f))
        ActionButton(
            icon = Icons.Outlined.Share,
            label = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            onClick = onShare,
        )
    }
}

@Composable
private fun ActionButton(
    icon: ImageVector,
    label: String?,
    tint: Color,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .clip(RavenShapes.pill)
            .clickable(onClick = onClick)
            .padding(vertical = 4.dp, horizontal = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.xxs),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(18.dp),
        )
        if (!label.isNullOrEmpty()) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = tint,
            )
        }
    }
}

/** Abbreviate counts (1200 → "1.2K"); null hides the label entirely. */
private fun countLabel(count: Int): String? = when {
    count <= 0 -> null
    count < 1_000 -> count.toString()
    count < 1_000_000 -> "%.1f".format(count / 1_000.0) + "K"
    else -> "%.1f".format(count / 1_000_000.0) + "M"
}
