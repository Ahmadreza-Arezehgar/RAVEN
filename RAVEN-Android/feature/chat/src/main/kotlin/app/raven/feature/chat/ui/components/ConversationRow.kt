package app.raven.feature.chat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing
import app.raven.core.design.liquidGlass
import app.raven.feature.chat.data.Conversation
import java.time.Duration
import java.time.Instant

/**
 * One row in the inbox list. Mirror of iOS `ConversationRowView`:
 *   [Avatar 50] [name (bold if unread) ✓ 🔕  ⋯  relative-time]
 *               [• preview text                ⋯  unread badge]
 *
 *   • 14dp horizontal / 12dp vertical row padding
 *   • Rounded card background (DS.radiusCard = 22dp)
 *   • Subtle 0.85 opacity dim when no unread
 *   • Tappable surface — caller passes a click handler
 */
@Composable
fun ConversationRow(
    conversation: Conversation,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val hasUnread = conversation.unreadCount > 0
    Row(
        modifier = modifier
            .fillMaxWidth()
            .liquidGlass()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box {
            GlassAvatar(
                name = conversation.title,
                path = conversation.peer.avatarUrl ?: conversation.groupAvatarUrl,
                size = 50.dp,
            )
            if (conversation.isPinned) {
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .size(18.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.PushPin,
                        contentDescription = "Pinned",
                        modifier = Modifier.size(12.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // ── Header row: title + verified + muted + spacer + time ──
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = conversation.title,
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = if (hasUnread) FontWeight.Bold else FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (!conversation.isGroup && conversation.peer.isVerified) {
                    Spacer(Modifier.size(4.dp))
                    Icon(
                        imageVector = Icons.Filled.Verified,
                        contentDescription = "Verified",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(14.dp),
                    )
                }
                if (conversation.isMuted) {
                    Spacer(Modifier.size(4.dp))
                    Icon(
                        imageVector = Icons.Filled.NotificationsOff,
                        contentDescription = "Muted",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                conversation.lastMessageTimestamp?.let { ts ->
                    Text(
                        text = relativeTime(ts),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // ── Subhead row: dot + preview + spacer + unread badge ──
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (conversation.lastMessagePreview != null) {
                    Box(
                        modifier = Modifier
                            .size(5.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.7f)),
                    )
                    Spacer(Modifier.size(4.dp))
                    Text(
                        text = conversation.lastMessagePreview,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (hasUnread) {
                            MaterialTheme.colorScheme.onSurface
                        } else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
                UnreadBadge(count = conversation.unreadCount, isMuted = conversation.isMuted)
            }
        }
    }
}

/** Tight relative-time formatter, matching iOS `.relative` style. */
private fun relativeTime(ts: Instant): String {
    val now = Instant.now()
    val d = Duration.between(ts, now)
    val seconds = d.seconds.coerceAtLeast(0)
    return when {
        seconds < 60 -> "now"
        seconds < 3600 -> "${seconds / 60}m"
        seconds < 86_400 -> "${seconds / 3600}h"
        seconds < 7 * 86_400 -> "${seconds / 86_400}d"
        else -> "${seconds / (7 * 86_400)}w"
    }
}
