package app.raven.feature.shell

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.raven.core.design.GlassSheenBorder
import app.raven.core.design.RavenPalette
import app.raven.core.design.RavenShapes
import app.raven.core.design.Spacing
import app.raven.core.design.liquidCapsule
import app.raven.core.design.ravenScreenBackground
import app.raven.feature.chat.data.Conversation
import app.raven.feature.chat.ui.InboxScreen
import app.raven.feature.discover.ui.DiscoverScreen
import app.raven.feature.feed.ui.HomeFeedScreen
import app.raven.feature.profile.ui.ProfileScreen

/**
 * Main app shell — the post-auth screen the user lives in. Mirror of
 * iOS `MainShellView` + `HapticTabBar`: a content area plus a floating
 * liquid-glass capsule tab bar (Home / Discover / Inbox / Profile).
 *
 * The active glass pill morphs/slides between cells with a spring —
 * the iOS `matchedGeometryEffect` behaviour — while each cell's
 * icon ⇄ label content cross-fades.
 */
enum class AppTab(
    val label: String,
    val outline: ImageVector,
    val filled: ImageVector,
) {
    // Icons matched to the iOS tab bar's SF Symbols: house,
    // magnifyingglass, bubble.left.and.bubble.right (→ Forum, the
    // two-bubble icon) and person.circle (→ AccountCircle).
    Home("Home", Icons.Outlined.Home, Icons.Filled.Home),
    Discover("Discover", Icons.Outlined.Search, Icons.Filled.Search),
    Inbox("Inbox", Icons.Outlined.Forum, Icons.Filled.Forum),
    Profile("Profile", Icons.Outlined.AccountCircle, Icons.Filled.AccountCircle),
}

@Composable
fun MainShell(
    onOpenConversation: (Conversation) -> Unit,
    onNewGroup: () -> Unit,
) {
    var selected by rememberSaveable { mutableStateOf(AppTab.Inbox) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            RavenTabBar(selected = selected, onSelect = { selected = it })
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .ravenScreenBackground(),
        ) {
            when (selected) {
                AppTab.Home -> HomeFeedScreen()
                AppTab.Discover -> DiscoverScreen()
                AppTab.Inbox -> InboxScreen(
                    onConversationClick = onOpenConversation,
                    onNewGroup = onNewGroup,
                )
                AppTab.Profile -> ProfileScreen()
            }
        }
    }
}

/** Floating liquid-glass capsule tab bar with a spring-morphing pill. */
@Composable
private fun RavenTabBar(selected: AppTab, onSelect: (AppTab) -> Unit) {
    val tabs = AppTab.values()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = Spacing.md, vertical = Spacing.sm)
            .liquidCapsule(elevation = 12.dp)
            .padding(6.dp),
    ) {
        // The morphing active pill — slides between the equal-width
        // cells with a spring, mirroring the iOS matchedGeometryEffect.
        val targetBias = -1f + 2f * selected.ordinal / (tabs.size - 1)
        val bias by animateFloatAsState(
            targetValue = targetBias,
            animationSpec = spring(
                dampingRatio = 0.82f,
                stiffness = Spring.StiffnessMediumLow,
            ),
            label = "tabPill",
        )
        Box(
            modifier = Modifier
                .align(BiasAlignment(horizontalBias = bias, verticalBias = 0f))
                .fillMaxWidth(1f / tabs.size)
                .height(46.dp)
                .padding(3.dp)
                .clip(RavenShapes.pill)
                .background(Color.White.copy(alpha = 0.14f))
                .border(0.8.dp, GlassSheenBorder, RavenShapes.pill),
        )

        Row(modifier = Modifier.fillMaxWidth()) {
            tabs.forEach { tab ->
                TabCell(
                    tab = tab,
                    selected = tab == selected,
                    onClick = { onSelect(tab) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** One equal-width cell — its content cross-fades between a dim icon
 *  (inactive) and a white label + green dot (active). */
@Composable
private fun TabCell(
    tab: AppTab,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .height(46.dp)
            .clip(RavenShapes.pill)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Crossfade(targetState = selected, label = "tabContent") { isActive ->
            if (isActive) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(
                        text = tab.label,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                        maxLines = 1,
                    )
                    Box(
                        modifier = Modifier
                            .size(5.dp)
                            .clip(CircleShape)
                            .background(RavenPalette.Emerald),
                    )
                }
            } else {
                Icon(
                    imageVector = tab.outline,
                    contentDescription = tab.label,
                    tint = Color.White.copy(alpha = 0.55f),
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}
