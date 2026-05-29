package app.raven.feature.feed.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.raven.core.design.RavenBrandGradient
import app.raven.core.design.RavenPalette
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing
import app.raven.core.design.liquidGlass
import app.raven.feature.feed.state.FeedTab

/**
 * The home-feed header:
 *   [ RAVEN logo ]      [ Local | Friends ]      [ bell ]
 *
 * The logo is the real raven-R brand mark; the Local/Friends pill is
 * a futuristic panel with a brand-gradient selected segment.
 */
@Composable
fun FeedHeader(
    selectedTab: FeedTab,
    onTabSelected: (FeedTab) -> Unit,
    onBellClick: () -> Unit,
    modifier: Modifier = Modifier,
    unreadNotifications: Int = 0,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Spacing.md, vertical = Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RavenLogoBadge()
        Spacer(Modifier.weight(1f))
        FeedTabSelector(selected = selectedTab, onSelected = onTabSelected)
        Spacer(Modifier.weight(1f))
        HeaderCircleButton(
            icon = Icons.Outlined.Notifications,
            contentDescription = "Notifications",
            onClick = onBellClick,
            badgeCount = unreadNotifications,
        )
    }
}

@Composable
private fun RavenLogoBadge() {
    Image(
        painter = painterResource(id = app.raven.core.design.R.drawable.raven_logo),
        contentDescription = "RAVEN",
        modifier = Modifier
            .size(42.dp)
            .clip(RoundedCornerShape(12.dp))
            .border(
                width = 1.dp,
                color = RavenPalette.Purple.copy(alpha = 0.55f),
                shape = RoundedCornerShape(12.dp),
            ),
    )
}

@Composable
private fun HeaderCircleButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    badgeCount: Int = 0,
) {
    Box {
        Box(
            modifier = Modifier
                .size(42.dp)
                .liquidGlass(shape = CircleShape, elevation = 3.dp)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = contentDescription,
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(20.dp),
            )
        }
        if (badgeCount > 0) {
            NotificationBadge(
                count = badgeCount,
                modifier = Modifier.align(Alignment.TopEnd),
            )
        }
    }
}

/**
 * Unread-count badge that rides the top-right of the bell. A dark
 * ring "cuts" it out from the icon so the count stays legible.
 */
@Composable
private fun NotificationBadge(count: Int, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .offset(x = 4.dp, y = (-4).dp)
            .defaultMinSize(minWidth = 18.dp, minHeight = 18.dp)
            .clip(CircleShape)
            .background(RavenAccentRed)
            .border(2.dp, RavenPalette.SurfaceBase, CircleShape)
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = if (count > 9) "9+" else count.toString(),
            color = Color.White,
            fontSize = 10.sp,
            lineHeight = 10.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

/** Notification-badge red — vivid enough to read against the bell. */
private val RavenAccentRed = Color(0xFFFF3366)

@Composable
private fun FeedTabSelector(
    selected: FeedTab,
    onSelected: (FeedTab) -> Unit,
) {
    Row(
        modifier = Modifier
            .liquidGlass(shape = RavenShapes.pill, elevation = 2.dp)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        FeedTab.values().forEach { tab ->
            val isSelected = tab == selected
            Box(
                modifier = Modifier
                    .clip(RavenShapes.pill)
                    .then(if (isSelected) Modifier.background(RavenBrandGradient) else Modifier)
                    .clickable { onSelected(tab) }
                    .padding(horizontal = Spacing.md, vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = tab.label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                    color = if (isSelected) {
                        Color.White
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
        }
    }
}
