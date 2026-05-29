package app.raven.feature.feed.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing
import app.raven.feature.feed.data.PostMedia
import coil.compose.AsyncImage

/**
 * Post media — a single image, or a swipeable carousel with a dot
 * indicator for multi-image posts. Mirror of the iOS `PeekCarouselView`.
 * Videos render their thumbnail with a play badge (inline playback
 * lands with the player work in a later pass).
 */
@Composable
fun PostMediaContent(
    media: List<PostMedia>,
    modifier: Modifier = Modifier,
) {
    when {
        media.isEmpty() -> Unit

        media.size == 1 -> MediaImage(item = media.first(), modifier = modifier.fillMaxWidth())

        else -> {
            val pagerState = rememberPagerState(pageCount = { media.size })
            Column(modifier = modifier.fillMaxWidth()) {
                HorizontalPager(
                    state = pagerState,
                    pageSpacing = Spacing.xs,
                ) { page ->
                    MediaImage(item = media[page], modifier = Modifier.fillMaxWidth())
                }
                Spacer(Modifier.height(Spacing.xs))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Center,
                ) {
                    repeat(media.size) { index ->
                        val active = index == pagerState.currentPage
                        Box(
                            modifier = Modifier
                                .padding(horizontal = 3.dp)
                                .size(if (active) 7.dp else 6.dp)
                                .clip(CircleShape)
                                .background(
                                    if (active) {
                                        MaterialTheme.colorScheme.primary
                                    } else {
                                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                                    }
                                ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MediaImage(
    item: PostMedia,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .aspectRatio(4f / 3f)
            .clip(RavenShapes.inner)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        AsyncImage(
            model = item.url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxWidth().aspectRatio(4f / 3f),
        )
        if (item.isVideo) {
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.55f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.PlayArrow,
                    contentDescription = "Video",
                    tint = Color.White,
                    modifier = Modifier.size(30.dp),
                )
            }
        }
    }
}
