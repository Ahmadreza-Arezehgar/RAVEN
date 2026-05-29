package app.raven.feature.feed.ui

import android.content.Context
import android.content.Intent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.GlassSheenBorder
import app.raven.core.design.RavenBrandGradient
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing
import app.raven.core.design.ravenScreenBackground
import app.raven.feature.feed.data.Post
import app.raven.feature.feed.state.FeedViewModel
import app.raven.feature.feed.ui.components.CommentSheet
import app.raven.feature.feed.ui.components.ComposeSheet
import app.raven.feature.feed.ui.components.FeedHeader
import app.raven.feature.feed.ui.components.FeedSkeletonList
import app.raven.feature.feed.ui.components.PostCard
import app.raven.feature.notifications.state.NotificationsViewModel
import app.raven.feature.notifications.ui.NotificationsScreen

/**
 * The Home tab — the RAVEN social feed ("Echo Wall"). Mirror of the
 * iOS `FeedView`: a glass header with a Local/Friends segmented
 * control, a scrolling list of [PostCard]s, pull-to-refresh, a
 * compose FAB, and the comments / new-post bottom sheets.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeFeedScreen(
    viewModel: FeedViewModel = hiltViewModel(),
) {
    // Shared with the NotificationsScreen overlay (same ViewModelStore
    // owner) so the bell badge and the list stay in sync. Kept a
    // body-local — it's an internal detail, not part of the contract.
    val notificationsViewModel: NotificationsViewModel = hiltViewModel()
    val state by viewModel.state.collectAsState()
    val notificationsState by notificationsViewModel.state.collectAsState()
    var showNotifications by remember { mutableStateOf(false) }
    var browserUrl by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    // Real backdrop blur — when the Activity overlay opens, the feed
    // behind it picks up a RenderEffect GPU blur (API 31+). Below 31
    // `Modifier.blur` is a no-op and the overlay's translucent scrim
    // still dims the feed.
    val feedBlur by animateDpAsState(
        targetValue = if (showNotifications) 28.dp else 0.dp,
        label = "feedBlur",
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .ravenScreenBackground(),
    ) {
        Column(modifier = Modifier.fillMaxSize().blur(feedBlur)) {
            FeedHeader(
                selectedTab = state.tab,
                onTabSelected = viewModel::selectTab,
                onBellClick = { showNotifications = true },
                unreadNotifications = notificationsState.unreadCount,
            )

            PullToRefreshBox(
                isRefreshing = state.isRefreshing,
                onRefresh = {
                    viewModel.refresh()
                    notificationsViewModel.load()
                },
                modifier = Modifier.fillMaxSize(),
            ) {
                when {
                    state.isLoading -> FeedSkeletonList()

                    state.errorMessage != null && state.posts.isEmpty() ->
                        FeedNotice(
                            title = "Couldn't load the feed",
                            subtitle = state.errorMessage ?: "",
                        )

                    state.isEmpty ->
                        FeedNotice(
                            title = "Nothing here yet",
                            subtitle = "New posts will show up here as people share them.",
                        )

                    else -> LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(bottom = 96.dp),
                    ) {
                        items(state.posts, key = { it.id }) { post ->
                            PostCard(
                                post = post,
                                onLike = { viewModel.toggleLike(post) },
                                onComment = { viewModel.openComments(post) },
                                onRepost = { viewModel.toggleRepost(post) },
                                isBookmarked = post.id in state.bookmarkedIds,
                                onBookmark = { viewModel.toggleBookmark(post) },
                                onShare = { sharePost(context, post) },
                                onLinkClick = { browserUrl = it },
                            )
                            PostSeparator()
                        }
                    }
                }
            }
        }

        ComposeFab(
            onClick = viewModel::openComposer,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(Spacing.md)
                .blur(feedBlur),
        )

        state.comments?.let { sheet ->
            CommentSheet(
                state = sheet,
                onDismiss = viewModel::closeComments,
                onDraftChange = viewModel::setCommentDraft,
                onSubmit = viewModel::submitComment,
            )
        }

        state.composer?.let { composer ->
            ComposeSheet(
                state = composer,
                onDismiss = viewModel::closeComposer,
                onDraftChange = viewModel::setComposerDraft,
                onSubmit = viewModel::submitPost,
            )
        }

        if (showNotifications) {
            NotificationsScreen(onClose = { showNotifications = false })
        }

        browserUrl?.let { url ->
            InAppBrowserScreen(url = url, onClose = { browserUrl = null })
        }
    }
}

/** Share a post's text through the Android system share sheet. */
private fun sharePost(context: Context, post: Post) {
    val text = "@${post.authorUsername} on RAVEN:\n\n${post.content}"
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(send, "Share post"))
}

/** Glossy brand-gradient compose button with a glass sheen. */
@Composable
private fun ComposeFab(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(58.dp)
            .shadow(
                elevation = 16.dp,
                shape = CircleShape,
                ambientColor = RavenPalette.Purple.copy(alpha = 0.5f),
                spotColor = RavenPalette.Purple.copy(alpha = 0.7f),
            )
            .clip(CircleShape)
            .background(RavenBrandGradient)
            .border(1.dp, GlassSheenBorder, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Edit,
            contentDescription = "New post",
            tint = Color.White,
            modifier = Modifier.size(24.dp),
        )
    }
}

@Composable
private fun PostSeparator() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.5f)),
    )
}

@Composable
private fun FeedNotice(title: String, subtitle: String) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(Spacing.lg),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = subtitle,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
