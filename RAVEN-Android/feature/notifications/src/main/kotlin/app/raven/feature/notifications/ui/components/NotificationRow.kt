package app.raven.feature.notifications.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.liquidGlass
import app.raven.feature.notifications.data.AppNotification
import app.raven.feature.notifications.data.NotificationKind
import java.time.Duration
import java.time.Instant

/**
 * One notification — a futuristic panel row: a kind-coloured icon
 * chip, the resolved text, a relative time, and an unread dot.
 */
@Composable
fun NotificationRow(
    notification: AppNotification,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = notification.kind.accent()
    Row(
        modifier = modifier
            .fillMaxWidth()
            .liquidGlass()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = notification.kind.icon(),
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(20.dp),
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = notification.text,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (notification.isRead) FontWeight.Normal else FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = timeAgo(notification.timestamp),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (!notification.isRead) {
            Box(
                modifier = Modifier
                    .size(9.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary),
            )
        }
    }
}

private fun NotificationKind.icon(): ImageVector = when (this) {
    NotificationKind.Like -> Icons.Filled.Favorite
    NotificationKind.Comment -> Icons.Outlined.ChatBubbleOutline
    NotificationKind.Friend -> Icons.Filled.Person
    NotificationKind.Repost -> Icons.Outlined.Repeat
    NotificationKind.Mention -> Icons.Filled.Notifications
    NotificationKind.Security -> Icons.Filled.Lock
    NotificationKind.Post -> Icons.Filled.Notifications
    NotificationKind.Other -> Icons.Filled.Notifications
}

private fun NotificationKind.accent(): Color = when (this) {
    NotificationKind.Like -> RavenPalette.MemberDropped
    NotificationKind.Comment -> RavenPalette.Purple
    NotificationKind.Friend -> RavenPalette.Emerald
    NotificationKind.Repost -> RavenPalette.Emerald
    NotificationKind.Mention -> RavenPalette.Purple
    NotificationKind.Security -> RavenPalette.Orange
    NotificationKind.Post -> RavenPalette.Purple
    NotificationKind.Other -> RavenPalette.Purple
}

private fun timeAgo(ts: Instant): String {
    val seconds = Duration.between(ts, Instant.now()).seconds.coerceAtLeast(0)
    return when {
        seconds < 60 -> "now"
        seconds < 3_600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3_600}h ago"
        seconds < 7 * 86_400 -> "${seconds / 86_400}d ago"
        else -> "${seconds / (7 * 86_400)}w ago"
    }
}
