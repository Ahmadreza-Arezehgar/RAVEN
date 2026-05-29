package app.raven.feature.auth.ui

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.Spacing
import app.raven.feature.auth.state.AuthViewModel
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenTextField
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Set-username screen for OAuth users (Google / Apple sign-in
 * doesn't carry a RAVEN handle). Mirror of
 * `UsernameSelectionView.swift`.
 *
 * Debounce-checks availability via [AuthApi.checkUsername] as the
 * user types — the field turns green when available, shows a hint
 * when taken.
 */
@Composable
fun UsernameSelectionScreen(
    tempToken: String,
    viewModel: AuthViewModel = hiltViewModel(),
) {
    var username by rememberSaveable { mutableStateOf("") }
    var availability by remember { mutableStateOf<Boolean?>(null) }
    val isWorking by viewModel.isWorking.collectAsState()

    // 400ms debounce on the availability check.
    LaunchedEffect(username) {
        availability = null
        if (username.length >= 3) {
            delay(400)
            viewModel.checkUsername(username) { ok -> availability = ok }
        }
    }

    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))
        Text(
            text = "Pick a handle",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = "This is how others find and mention you on RAVEN.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(Spacing.xl))

        val hint = when {
            username.length in 1 until 3 -> "At least 3 characters"
            availability == true -> "✓ Available"
            availability == false -> "Username is taken"
            else -> null
        }

        RavenTextField(
            value = username,
            onValueChange = { v -> username = v.lowercase().filter { it.isLetterOrDigit() || it == '_' } },
            label = "Username",
            supportingText = hint,
            errorText = if (availability == false) hint else null,
            enabled = !isWorking,
        )

        Spacer(Modifier.height(Spacing.xl))

        RavenPrimaryButton(
            text = "Continue",
            loading = isWorking,
            enabled = availability == true && !isWorking,
            onClick = { viewModel.setUsername(username = username, tempToken = tempToken) },
        )

        Spacer(Modifier.height(Spacing.xl))
    }
}
