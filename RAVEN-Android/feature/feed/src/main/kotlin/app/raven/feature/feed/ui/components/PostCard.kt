package app.raven.feature.feed.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing
import app.raven.feature.feed.data.Post
import java.time.Duration
import java.time.Instant

/**
 * One post in the home feed — mirror of the iOS `PostCard`:
 *
 *   [ avatar 44 ]  username ✓ ♛ · 2h            ⋯
 *                  body text …
 *                  [ media ]
 *                  ♡ 12   💬 4   ⟳ 1            ↗
 */
@Composable
fun PostCard(
    post: Post,
    onLike: () -> Unit,
    onComment: () -> Unit,
    onRepost: () -> Unit,
    modifier: Modifier = Modifier,
    isBookmarked: Boolean = false,
    onBookmark: () -> Unit = {},
    onShare: () -> Unit = {},
    onLinkClick: (String) -> Unit = {},
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = Spacing.md, vertical = Spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(Spacing.sm),
    ) {
        FeedAvatar(name = post.authorUsername, path = post.authorAvatar, size = 44.dp)

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            PostHeader(post)

            if (post.content.isNotBlank()) {
                Text(
                    text = postContentWithLinks(
                        content = post.content,
                        linkColor = MaterialTheme.colorScheme.primary,
                        onLinkClick = onLinkClick,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onBackground,
                )
                firstUrl(post.content)?.let { url ->
                    LinkPreviewChip(url = url, onClick = { onLinkClick(url) })
                }
            }

            if (post.voiceUrl != null) {
                VoicePostPlayer(url = post.voiceUrl, durationSec = post.voiceDurationSec)
            }

            if (post.media.isNotEmpty()) {
                PostMediaContent(media = post.media)
            }

            PostActionBar(
                likeCount = post.likeCount,
                isLiked = post.isLiked,
                commentCount = post.commentCount,
                repostCount = post.repostCount,
                isReposted = post.isReposted,
                isBookmarked = isBookmarked,
                onLike = onLike,
                onComment = onComment,
                onRepost = onRepost,
                onBookmark = onBookmark,
                onShare = onShare,
            )
        }
    }
}

@Composable
private fun PostHeader(post: Post) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = post.authorUsername,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (post.isVerified) {
            Spacer(Modifier.width(3.dp))
            Icon(
                imageVector = Icons.Filled.Verified,
                contentDescription = "Verified",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(14.dp),
            )
        }
        if (post.isPremium) {
            Spacer(Modifier.width(3.dp))
            Icon(
                imageVector = Icons.Filled.WorkspacePremium,
                contentDescription = "Premium",
                tint = RavenPalette.Gold,
                modifier = Modifier.size(13.dp),
            )
        }
        Spacer(Modifier.width(6.dp))
        Text(
            text = "· ${timeAgo(post.timestamp)}",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
        if (post.isEdited) {
            Spacer(Modifier.width(4.dp))
            Text(
                text = "edited",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        Spacer(Modifier.weight(1f))
        Icon(
            imageVector = Icons.Filled.MoreHoriz,
            contentDescription = "More",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** Tight relative-time formatter, matching the iOS `.timeAgo` style. */
private fun timeAgo(ts: Instant): String {
    val seconds = Duration.between(ts, Instant.now()).seconds.coerceAtLeast(0)
    return when {
        seconds < 60 -> "now"
        seconds < 3_600 -> "${seconds / 60}m"
        seconds < 86_400 -> "${seconds / 3_600}h"
        seconds < 7 * 86_400 -> "${seconds / 86_400}d"
        else -> "${seconds / (7 * 86_400)}w"
    }
}

/** `http(s)` URLs in post text — opened by the in-app browser. */
private val urlRegex = Regex("""https?://[^\s]+""")

/** First http(s) URL in [content], or null. */
private fun firstUrl(content: String): String? = urlRegex.find(content)?.value

/**
 * A tappable preview chip for a post link — guaranteed-tappable
 * alternative / supplement to the inline link annotation, mirroring
 * the iOS `LinkPreviewCard`. Tapping it opens the in-app browser.
 */
@Composable
private fun LinkPreviewChip(url: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.Link,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = url.substringAfter("://").substringBefore("/").removePrefix("www."),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * Render post text with any URLs as tappable links that open the
 * in-app browser via [onLinkClick] — mirror of the iOS link tap.
 */
private fun postContentWithLinks(
    content: String,
    linkColor: Color,
    onLinkClick: (String) -> Unit,
): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    for (match in urlRegex.findAll(content)) {
        append(content.substring(cursor, match.range.first))
        val url = match.value
        withLink(
            LinkAnnotation.Url(
                url = url,
                styles = TextLinkStyles(style = SpanStyle(color = linkColor)),
                linkInteractionListener = { onLinkClick(url) },
            ),
        ) {
            append(url)
        }
        cursor = match.range.last + 1
    }
    append(content.substring(cursor))
}
