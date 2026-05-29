package app.raven.feature.auth.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.Spacing
import app.raven.feature.auth.state.AuthViewModel
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenTextField

/**
 * Email login. Mirror of `LoginView.swift`.
 * Two fields, one CTA, plus "Forgot password?" link.
 */
@Composable
fun LoginScreen(
    onForgotPassword: () -> Unit,
    onBack: () -> Unit,
    viewModel: AuthViewModel = hiltViewModel(),
) {
    var usernameOrEmail by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    val isWorking by viewModel.isWorking.collectAsState()

    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))

        Text(
            text = "Welcome back",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = "Sign in to continue",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(Spacing.xl))

        RavenTextField(
            value = usernameOrEmail,
            onValueChange = { usernameOrEmail = it },
            label = "Username or email",
            keyboardType = KeyboardType.Email,
            imeAction = ImeAction.Next,
            enabled = !isWorking,
        )

        Spacer(Modifier.height(Spacing.md))

        RavenTextField(
            value = password,
            onValueChange = { password = it },
            label = "Password",
            isPassword = true,
            imeAction = ImeAction.Done,
            enabled = !isWorking,
        )

        Spacer(Modifier.height(Spacing.sm))

        Text(
            text = "Forgot password?",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            textDecoration = TextDecoration.Underline,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = !isWorking, onClick = onForgotPassword),
            textAlign = TextAlign.End,
        )

        Spacer(Modifier.height(Spacing.xl))

        RavenPrimaryButton(
            text = "Log in",
            loading = isWorking,
            enabled = usernameOrEmail.isNotBlank() && password.isNotBlank() && !isWorking,
            onClick = { viewModel.login(usernameOrEmail, password) },
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
