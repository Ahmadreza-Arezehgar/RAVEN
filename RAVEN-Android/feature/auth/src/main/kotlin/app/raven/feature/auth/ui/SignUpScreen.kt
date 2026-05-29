package app.raven.feature.auth.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.Spacing
import app.raven.feature.auth.state.AuthViewModel
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenTextField

/**
 * Email signup form. Mirror of `SignUpView.swift`.
 * Collects: username, email, password, first name, last name, birth
 * year, optional phone. On submit → AuthViewModel.register; on
 * success the AuthFlowEvent.OtpSent kicks the user to OTP screen.
 *
 * Validation is intentionally light here — server-side rules are
 * the source of truth; we only block obvious local issues
 * (empty + short username + non-digit birth year) so the user
 * doesn't pay a round-trip for typos.
 */
@Composable
fun SignUpScreen(
    onBack: () -> Unit,
    viewModel: AuthViewModel = hiltViewModel(),
) {
    var username by rememberSaveable { mutableStateOf("") }
    var firstName by rememberSaveable { mutableStateOf("") }
    var lastName by rememberSaveable { mutableStateOf("") }
    var email by rememberSaveable { mutableStateOf("") }
    var phone by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var birthYearText by rememberSaveable { mutableStateOf("") }
    val isWorking by viewModel.isWorking.collectAsState()

    val birthYear = birthYearText.toIntOrNull()
    val canSubmit = username.length >= 3 &&
        firstName.isNotBlank() &&
        email.contains("@") &&
        password.length >= 8 &&
        birthYear != null && birthYear in 1900..2100 &&
        !isWorking

    AuthScaffold {
        Spacer(Modifier.height(Spacing.lg))

        Text(
            text = "Create account",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = "Join the RAVEN mesh",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(Spacing.lg))

        RavenTextField(
            value = username,
            onValueChange = { username = it.trim() },
            label = "Username",
            supportingText = "At least 3 characters",
            enabled = !isWorking,
        )
        Spacer(Modifier.height(Spacing.sm))

        RavenTextField(
            value = firstName,
            onValueChange = { firstName = it },
            label = "First name",
            autoCapitalization = KeyboardCapitalization.Words,
            enabled = !isWorking,
        )
        Spacer(Modifier.height(Spacing.sm))

        RavenTextField(
            value = lastName,
            onValueChange = { lastName = it },
            label = "Last name (optional)",
            autoCapitalization = KeyboardCapitalization.Words,
            enabled = !isWorking,
        )
        Spacer(Modifier.height(Spacing.sm))

        RavenTextField(
            value = email,
            onValueChange = { email = it.trim() },
            label = "Email",
            keyboardType = KeyboardType.Email,
            enabled = !isWorking,
        )
        Spacer(Modifier.height(Spacing.sm))

        RavenTextField(
            value = phone,
            onValueChange = { phone = it.trim() },
            label = "Phone (optional, e.g. +14155551234)",
            keyboardType = KeyboardType.Phone,
            enabled = !isWorking,
        )
        Spacer(Modifier.height(Spacing.sm))

        RavenTextField(
            value = birthYearText,
            onValueChange = { v -> birthYearText = v.filter(Char::isDigit).take(4) },
            label = "Year of birth",
            keyboardType = KeyboardType.Number,
            supportingText = "Four digits",
            enabled = !isWorking,
        )
        Spacer(Modifier.height(Spacing.sm))

        RavenTextField(
            value = password,
            onValueChange = { password = it },
            label = "Password",
            isPassword = true,
            supportingText = "Minimum 8 characters",
            imeAction = ImeAction.Done,
            enabled = !isWorking,
        )

        Spacer(Modifier.height(Spacing.lg))

        RavenPrimaryButton(
            text = "Create account",
            loading = isWorking,
            enabled = canSubmit,
            onClick = {
                viewModel.register(
                    username = username,
                    password = password,
                    firstName = firstName,
                    lastName = lastName,
                    birthYear = birthYear ?: 0,
                    email = email,
                    phone = phone.takeIf { it.isNotBlank() },
                )
            },
        )

        Spacer(Modifier.height(Spacing.sm))

        Text(
            text = "Back",
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = !isWorking, onClick = onBack),
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelLarge,
        )

        Spacer(Modifier.height(Spacing.xl))
    }
}
