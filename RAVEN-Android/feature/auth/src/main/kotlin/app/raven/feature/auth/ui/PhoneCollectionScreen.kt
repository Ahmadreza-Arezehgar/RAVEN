package app.raven.feature.auth.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import app.raven.core.design.Spacing
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenTextField

/**
 * Optional phone-collection screen for OAuth users. Mirror of
 * `PhoneCollectionView.swift`. Server endpoint that consumes this
 * (PATCH /api/users/me with phone field) is wired in Phase 2 when
 * the profile module lands; for now we just collect the number and
 * call [onComplete] so the flow advances past this gate.
 */
@Composable
fun PhoneCollectionScreen(
    onComplete: (phone: String) -> Unit,
    onSkip: () -> Unit,
) {
    var phone by rememberSaveable { mutableStateOf("") }

    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))
        Text(
            text = "Add your phone number",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = "Optional. Friends can find you by phone when you turn discovery on.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(Spacing.xl))

        RavenTextField(
            value = phone,
            onValueChange = { v -> phone = v.trim() },
            label = "Phone (e.g. +14155551234)",
            keyboardType = KeyboardType.Phone,
        )

        Spacer(Modifier.height(Spacing.xl))

        RavenPrimaryButton(
            text = "Continue",
            enabled = phone.length >= 7,
            onClick = { onComplete(phone) },
        )

        Spacer(Modifier.height(Spacing.sm))

        Text(
            text = "Skip for now",
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onSkip),
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelLarge,
        )

        Spacer(Modifier.height(Spacing.xl))
    }
}
