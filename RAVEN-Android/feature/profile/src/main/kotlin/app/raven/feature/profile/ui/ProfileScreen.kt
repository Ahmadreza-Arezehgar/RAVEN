package app.raven.feature.profile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing
import app.raven.core.design.liquidGlass
import app.raven.core.design.ravenScreenBackground
import app.raven.feature.feed.data.Post
import app.raven.feature.feed.ui.components.PostCard
import app.raven.feature.profile.data.UserProfile
import app.raven.feature.profile.state.ProfileUiState
import app.raven.feature.profile.state.ProfileViewModel
import app.raven.feature.profile.ui.components.EditProfileSheet
import app.raven.feature.profile.ui.components.ProfileAvatar
import app.raven.feature.profile.ui.components.ProfileSettingsSheet
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The Profile tab — the signed-in user's own profile: a futuristic
 * header (avatar, name, badges, bio), a stats panel, and the user's
 * own posts. A gear opens settings (Edit profile / Sign out).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(
    viewModel: ProfileViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .ravenScreenBackground(),
    ) {
        when {
            state.isLoading && state.profile == null ->
                CircularProgressIndicator(
                    modifier = Modifier.align(Alignment.Center),
                    color = MaterialTheme.colorScheme.primary,
                )

            state.profile == null ->
                ProfileNotice(
                    title = "Couldn't load your profile",
                    subtitle = state.errorMessage ?: "",
                )

            else -> ProfileContent(
                state = state,
                onSettings = viewModel::openSettings,
                onLike = viewModel::toggleLike,
                onRepost = viewModel::toggleRepost,
            )
        }

        if (state.settingsOpen) {
            ProfileSettingsSheet(
                onDismiss = viewModel::closeSettings,
                onEditProfile = viewModel::openEditor,
                onSignOut = viewModel::signOut,
            )
        }

        state.editor?.let { editor ->
            EditProfileSheet(
                state = editor,
                avatarUrl = state.profile?.avatarUrl,
                avatarName = state.profile?.displayName ?: "",
                onDismiss = viewModel::closeEditor,
                onNameChange = viewModel::setEditorName,
                onBioChange = viewModel::setEditorBio,
                onPickAvatar = viewModel::updateAvatar,
                onSave = viewModel::saveProfile,
            )
        }
    }
}

@Composable
private fun ProfileContent(
    state: ProfileUiState,
    onSettings: () -> Unit,
    onLike: (Post) -> Unit,
    onRepost: (Post) -> Unit,
) {
    val profile = state.profile ?: return

    LazyColumn(modifier = Modifier.fillMaxSize()) {
        item {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Spacing.xs, vertical = Spacing.xs),
                horizontalArrangement = Arrangement.End,
            ) {
                IconButton(onClick = onSettings) {
                    Icon(
                        imageVector = Icons.Outlined.Settings,
                        contentDescription = "Settings",
                        tint = MaterialTheme.colorScheme.onBackground,
                    )
                }
            }
        }

        item { ProfileHeaderBlock(profile) }

        item {
            Spacer(Modifier.height(Spacing.lg))
            StatsCard(postsCount = profile.postsCount, friendsCount = profile.friendsCount)
            Spacer(Modifier.height(Spacing.lg))
        }

        item {
            Text(
                text = "Posts",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = Spacing.md, vertical = Spacing.xs),
            )
        }

        when {
            state.isLoadingPosts && state.posts.isEmpty() -> item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(Spacing.lg),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                }
            }

            state.posts.isEmpty() -> item {
                Text(
                    text = "No posts yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(Spacing.lg),
                )
            }

            else -> items(state.posts, key = { it.id }) { post ->
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

        item { Spacer(Modifier.height(Spacing.xl)) }
    }
}

@Composable
private fun ProfileHeaderBlock(profile: UserProfile) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Spacing.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ProfileAvatar(name = profile.displayName, path = profile.avatarUrl, size = 96.dp)

        Spacer(Modifier.height(Spacing.sm))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = profile.displayName,
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onBackground,
            )
            if (profile.isVerified) {
                Spacer(Modifier.width(4.dp))
                Icon(
                    imageVector = Icons.Filled.Verified,
                    contentDescription = "Verified",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp),
                )
            }
            if (profile.isPremium) {
                Spacer(Modifier.width(4.dp))
                Icon(
                    imageVector = Icons.Filled.WorkspacePremium,
                    contentDescription = "Premium",
                    tint = RavenPalette.Gold,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        Spacer(Modifier.height(2.dp))
        Text(
            text = "@${profile.username}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        profile.joinedAt?.let { joined ->
            Spacer(Modifier.height(2.dp))
            Text(
                text = joinedLabel(joined),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (profile.bio.isNotBlank()) {
            Spacer(Modifier.height(Spacing.sm))
            Text(
                text = profile.bio,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onBackground,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun StatsCard(postsCount: Int, friendsCount: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Spacing.md)
            .liquidGlass()
            .padding(vertical = Spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatColumn(value = postsCount, label = "Posts", modifier = Modifier.weight(1f))
        Box(
            modifier = Modifier
                .width(0.5.dp)
                .height(32.dp)
                .background(MaterialTheme.colorScheme.outline),
        )
        StatColumn(value = friendsCount, label = "Friends", modifier = Modifier.weight(1f))
    }
}

@Composable
private fun StatColumn(value: Int, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = value.toString(),
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ProfileNotice(title: String, subtitle: String) {
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

private val joinedFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("MMMM yyyy").withZone(ZoneId.systemDefault())

private fun joinedLabel(joined: Instant): String = "Joined ${joinedFormatter.format(joined)}"
