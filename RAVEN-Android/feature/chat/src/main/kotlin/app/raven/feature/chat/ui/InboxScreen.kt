package app.raven.feature.chat.ui

import androidx.compose.foundation.background
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing
import app.raven.core.design.ravenScreenBackground
import app.raven.feature.chat.data.Conversation
import app.raven.feature.chat.state.InboxFilter
import app.raven.feature.chat.state.InboxViewModel
import app.raven.feature.chat.ui.components.ConversationRow

/**
 * Inbox screen. Mirror of iOS `InboxView`:
 *   • Header bar with title + new-chat button (new-chat sheet in
 *     Phase 2b — placeholder click here)
 *   • Search bar
 *   • All / Unread filter chips
 *   • LazyColumn of [ConversationRow] cards, 8dp gap
 *   • Loading / error / empty states (same content the iOS app shows)
 */
@Composable
fun InboxScreen(
    onConversationClick: (Conversation) -> Unit,
    onNewGroup: () -> Unit,
    viewModel: InboxViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .ravenScreenBackground()
            .padding(horizontal = Spacing.md),
    ) {
        Spacer(Modifier.height(Spacing.md))

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Inbox",
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onNewGroup) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = "New group",
                    tint = MaterialTheme.colorScheme.onBackground,
                )
            }
        }

        Spacer(Modifier.height(Spacing.sm))

        // Search field
        OutlinedTextField(
            value = state.searchQuery,
            onValueChange = viewModel::setSearchQuery,
            placeholder = { Text("Search conversations") },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Filled.Search,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            singleLine = true,
            shape = RavenShapes.pill,
            modifier = Modifier.fillMaxWidth(),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = MaterialTheme.colorScheme.outline,
                unfocusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f),
            ),
        )

        Spacer(Modifier.height(Spacing.sm))

        // Filter chips
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            InboxFilter.values().forEach { f ->
                FilterChip(
                    selected = state.filter == f,
                    onClick = { viewModel.setFilter(f) },
                    label = { Text(f.label) },
                    shape = RavenShapes.pill,
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.18f),
                        selectedLabelColor = MaterialTheme.colorScheme.primary,
                    ),
                )
            }
        }

        Spacer(Modifier.height(Spacing.sm))

        Box(modifier = Modifier.fillMaxSize()) {
            when {
                state.isLoading && state.conversations.isEmpty() -> {
                    CircularProgressIndicator(
                        modifier = Modifier.align(Alignment.Center),
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                state.errorMessage != null && state.conversations.isEmpty() -> {
                    EmptyInboxLabel(
                        title = "Couldn't load",
                        subtitle = state.errorMessage ?: "",
                    )
                }
                state.isEmpty -> {
                    EmptyInboxLabel(
                        title = "No conversations yet",
                        subtitle = "Tap a friend's profile to start your first chat.",
                    )
                }
                else -> {
                    LazyColumn(
                        contentPadding = PaddingValues(vertical = Spacing.xs),
                        verticalArrangement = Arrangement.spacedBy(Spacing.xs),
                    ) {
                        items(state.visibleConversations, key = { it.roomId }) { c ->
                            ConversationRow(conversation = c, onClick = { onConversationClick(c) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyInboxLabel(title: String, subtitle: String) {
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
