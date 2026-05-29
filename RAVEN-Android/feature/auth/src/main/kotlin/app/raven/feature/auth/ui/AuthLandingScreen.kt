package app.raven.feature.auth.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.Image
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import app.raven.feature.auth.R
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenSecondaryButton
import app.raven.feature.auth.ui.components.SocialSignInButton

/**
 * Top-level auth landing. Mirror of `AuthLandingView.swift`:
 *   • Logo halo + RAVEN wordmark + tagline
 *   • 3 feature rows (lock / antenna / bolt)
 *   • Google + Apple OAuth pills (primary placement)
 *   • "or" divider
 *   • Create account (Email) + Log in (Email) secondary CTAs
 *
 * OAuth handlers are STUBS for Phase 1 — they show a toast-equivalent
 * error explaining the SDK isn't wired yet. Phase 1a adds Google
 * (`play-services-auth`) and Phase 1b adds Apple (webview-based).
 * The button shells stay so the visual parity holds.
 */
@Composable
fun AuthLandingScreen(
    onCreateAccount: () -> Unit,
    onLogin: () -> Unit,
    onGoogleClick: () -> Unit,
    onAppleClick: () -> Unit,
    isLoading: Boolean,
) {
    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))

        // ── Logo halo ────────────────────────────────────────────
        Box(
            modifier = Modifier
                .size(140.dp)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            RavenPalette.Purple.copy(alpha = 0.25f),
                            RavenPalette.Orange.copy(alpha = 0.10f),
                        )
                    )
                )
                .padding(Spacing.md)
                .align(Alignment.CenterHorizontally),
            contentAlignment = Alignment.Center,
        ) {
            // Real RAVEN bitmap — same 1024×1024 PNG iOS ships in
            // Assets.xcassets/RavenLogo.imageset/. Copied into
            // res/drawable-nodpi/ so the image stays pixel-identical
            // across densities (Compose-Image scales it down).
            Image(
                painter = painterResource(R.drawable.raven_logo),
                contentDescription = "RAVEN logo",
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .size(96.dp)
                    .clip(CircleShape),
            )
        }

        Spacer(Modifier.height(Spacing.lg))

        Text(
            text = "RAVEN",
            style = MaterialTheme.typography.displayLarge,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier
                .fillMaxWidth(),
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = "Secure messaging with or without internet",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(Spacing.xl))

        // ── Feature rows ────────────────────────────────────────
        FeatureRow(Icons.Filled.Lock, "Secure & private messaging")
        Spacer(Modifier.height(Spacing.sm))
        FeatureRow(Icons.Filled.Wifi, "Works offline via mesh")
        Spacer(Modifier.height(Spacing.sm))
        FeatureRow(Icons.Filled.Bolt, "Fast and reliable")

        Spacer(Modifier.height(Spacing.xl))

        // ── OAuth primary CTAs ──────────────────────────────────
        SocialSignInButton(
            text = "Continue with Google",
            onClick = onGoogleClick,
            enabled = !isLoading,
        )
        Spacer(Modifier.height(Spacing.sm))
        SocialSignInButton(
            text = "Continue with Apple",
            backgroundColor = Color.Black,
            contentColor = Color.White,
            border = null,
            onClick = onAppleClick,
            enabled = !isLoading,
        )

        Spacer(Modifier.height(Spacing.lg))

        // ── "or" divider ────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Divider(
                modifier = Modifier.weight(1f),
                color = MaterialTheme.colorScheme.outline.copy(alpha = 0.4f),
            )
            Text(
                text = "or",
                modifier = Modifier.padding(horizontal = Spacing.sm),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
            Divider(
                modifier = Modifier.weight(1f),
                color = MaterialTheme.colorScheme.outline.copy(alpha = 0.4f),
            )
        }

        Spacer(Modifier.height(Spacing.lg))

        // ── Email CTAs ─────────────────────────────────────────
        RavenPrimaryButton(
            text = "Create account (Email)",
            onClick = onCreateAccount,
            enabled = !isLoading,
        )
        Spacer(Modifier.height(Spacing.sm))
        RavenSecondaryButton(
            text = "Log in (Email)",
            onClick = onLogin,
            enabled = !isLoading,
        )

        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
private fun FeatureRow(icon: ImageVector, label: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Start,
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(RavenPalette.Purple.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = RavenPalette.Purple,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.size(Spacing.md))
        Text(
            text = label,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
    }
}
