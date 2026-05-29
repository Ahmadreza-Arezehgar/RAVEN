package app.raven.feature.auth.ui

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
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenSecondaryButton
import kotlinx.coroutines.launch

/**
 * 3-card welcome carousel. Mirror of iOS `OnboardingView`.
 *  - Page 0: Secure & private (lock icon)
 *  - Page 1: Works offline via mesh (wifi/antenna icon)
 *  - Page 2: Fast & reliable (bolt icon)
 *
 * Bottom CTAs:
 *  - "Get Started" (advances pages 0 → 1 → 2 → invokes [onFinish])
 *  - "Skip" on every page except the last
 *
 * The carousel auto-paginates by user swipe; we leave auto-rotation
 * off so users with motion sensitivity aren't surprised.
 */
private data class OnboardingPage(
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
)

private val pages = listOf(
    OnboardingPage(
        title = "Secure & private",
        subtitle = "End-to-end encrypted by default. Your conversations stay yours.",
        icon = Icons.Filled.Lock,
    ),
    OnboardingPage(
        title = "Works offline",
        subtitle = "Bluetooth mesh routing keeps you connected when there's no signal.",
        icon = Icons.Filled.Wifi,
    ),
    OnboardingPage(
        title = "Fast & reliable",
        subtitle = "Direct relay paths and post-quantum crypto, with the speed of a chat app.",
        icon = Icons.Filled.Bolt,
    ),
)

@Composable
fun OnboardingScreen(onFinish: () -> Unit) {
    val pagerState = rememberPagerState(pageCount = { pages.size })
    val scope = rememberCoroutineScope()

    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))

        // Pager
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .height(420.dp),
        ) { page ->
            OnboardingCard(pages[page])
        }

        Spacer(Modifier.height(Spacing.lg))

        // Dots
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = Spacing.sm),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            repeat(pages.size) { i ->
                val isActive = i == pagerState.currentPage
                Box(
                    modifier = Modifier
                        .size(width = if (isActive) 24.dp else 8.dp, height = 8.dp)
                        .padding(horizontal = 2.dp)
                        .clip(CircleShape)
                        .background(
                            if (isActive) RavenPalette.Purple
                            else MaterialTheme.colorScheme.outline,
                        )
                )
            }
        }

        Spacer(Modifier.height(Spacing.lg))

        // CTA
        val isLast = pagerState.currentPage == pages.size - 1
        RavenPrimaryButton(
            text = if (isLast) "Get Started" else "Continue",
            onClick = {
                if (isLast) onFinish()
                else scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
            },
        )

        if (!isLast) {
            Spacer(Modifier.height(Spacing.sm))
            RavenSecondaryButton(text = "Skip", onClick = onFinish)
        }

        Spacer(Modifier.height(Spacing.lg))
    }
}

@Composable
private fun OnboardingCard(page: OnboardingPage) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(160.dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            RavenPalette.Purple.copy(alpha = 0.35f),
                            RavenPalette.Purple.copy(alpha = 0.05f),
                        )
                    )
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = page.icon,
                contentDescription = null,
                tint = RavenPalette.Purple,
                modifier = Modifier.size(72.dp),
            )
        }
        Spacer(Modifier.height(Spacing.xl))
        Text(
            text = page.title,
            style = MaterialTheme.typography.displaySmall,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(Spacing.md))
        Text(
            text = page.subtitle,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = Spacing.lg),
        )
    }
}
