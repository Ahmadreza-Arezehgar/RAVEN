package app.raven.feature.discover.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.RavenBrandGradient
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing
import app.raven.core.design.ravenScreenBackground
import app.raven.feature.discover.data.DiscoverUser
import app.raven.feature.discover.state.DiscoverViewModel
import app.raven.feature.discover.state.SearchMode
import app.raven.feature.discover.ui.components.DiscoverSearchBar
import app.raven.feature.discover.ui.components.DiscoverUserRow
import app.raven.feature.feed.data.Post
import app.raven.feature.feed.ui.components.PostCard

/**
 * The Discover tab — a glass search bar; idle shows friend
 * suggestions, and a search runs across People + Posts (toggled).
 */
@Composable
fun DiscoverScreen(
    viewModel: DiscoverViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .ravenScreenBackground(),
    ) {
        DiscoverSearchBar(
            query = state.query,
            onQueryChange = viewModel::setQuery,
            onClear = viewModel::clearQuery,
        )

        if (state.isSearching) {
            SearchModeToggle(selected = state.searchMode, onSelected = viewModel::setSearchMode)
        }

        Box(modifier = Modifier.fillMaxSize()) {
            when {
                !state.isSearching -> when {
                    state.isLoadingSuggested && state.suggested.isEmpty() -> Spinner()
                    state.suggested.isEmpty() && state.errorMessage != null ->
                        Notice("Couldn't load suggestions", state.errorMessage ?: "")
                    state.suggested.isEmpty() ->
                        Notice("No suggestions yet", "People you may know will show up here.")
                    else -> UserList(
                        users = state.suggested,
                        header = "Suggested for you",
                        sentIds = state.sentRequestIds,
                        onAdd = viewModel::sendFriendRequest,
                    )
                }

                state.searchMode == SearchMode.People -> when {
                    state.isLoadingResults && state.results.isEmpty() -> Spinner()
                    state.results.isEmpty() && state.errorMessage != null ->
                        Notice("Something went wrong", state.errorMessage ?: "")
                    state.results.isEmpty() -> Notice("No people found", "Try a different name.")
                    else -> UserList(
                        users = state.results,
                        header = null,
                        sentIds = state.sentRequestIds,
                        onAdd = viewModel::sendFriendRequest,
                    )
                }

                else -> when {
                    state.isLoadingPosts && state.postResults.isEmpty() -> Spinner()
                    state.postResults.isEmpty() && state.postErrorMessage != null ->
                        Notice("Something went wrong", state.postErrorMessage ?: "")
                    state.postResults.isEmpty() -> Notice("No posts found", "Try a different search.")
                    else -> PostList(
                        posts = state.postResults,
                        onLike = viewModel::toggleLike,
                        onRepost = viewModel::toggleRepost,
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchModeToggle(selected: SearchMode, onSelected: (SearchMode) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Spacing.md, vertical = Spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
    ) {
        SearchMode.values().forEach { mode ->
            val isSelected = mode == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RavenShapes.pill)
                    .then(
                        if (isSelected) {
                            Modifier.background(RavenBrandGradient)
                        } else {
                            Modifier.background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                        }
                    )
                    .clickable { onSelected(mode) }
                    .padding(vertical = 9.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = mode.label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                    color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun UserList(
    users: List<DiscoverUser>,
    header: String?,
    sentIds: Set<String>,
    onAdd: (DiscoverUser) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = Spacing.md, end = Spacing.md, bottom = Spacing.xl),
        verticalArrangement = Arrangement.spacedBy(Spacing.xs),
    ) {
        if (header != null) {
            item {
                Text(
                    text = header,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = Spacing.xs),
                )
            }
        }
        items(users, key = { it.id }) { user ->
            DiscoverUserRow(
                user = user,
                isRequestSent = user.id in sentIds,
                onAdd = { onAdd(user) },
            )
        }
    }
}

@Composable
private fun PostList(
    posts: List<Post>,
    onLike: (Post) -> Unit,
    onRepost: (Post) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = Spacing.xl),
    ) {
        items(posts, key = { it.id }) { post ->
            PostCard(
                post = post,
                onLike = { onLike(post) },
                onComment = {},
                onRepost = { onRepost(post) },
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)),
            )
        }
    }
}

@Composable
private fun Spinner() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun Notice(title: String, subtitle: String) {
    Column(
        modifier = Modifier
            .fillMaxSize()
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
