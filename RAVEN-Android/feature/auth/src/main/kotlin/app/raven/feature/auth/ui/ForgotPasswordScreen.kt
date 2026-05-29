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
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.Spacing
import app.raven.feature.auth.data.AuthRepository
import app.raven.feature.auth.state.AuthViewModel
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton
import app.raven.feature.auth.ui.components.RavenTextField
import kotlinx.coroutines.launch

/**
 * Two-step password recovery flow. Mirror of the iOS reset flow that
 * lives off `LoginView.swift → Forgot password?`.
 *
 *   Step 1 — Email entry. Hits POST /api/auth/send-code with
 *            purpose="reset". Server emails the 6-digit OTP.
 *   Step 2 — OTP + new password. Hits POST /api/auth/reset-password.
 *            On 204 the user is bounced back to the login screen
 *            (we don't auto-sign-in — same posture as iOS, makes the
 *            session-takeover threat-model cleaner).
 *
 * We use the existing [AuthRepository] directly here instead of going
 * through [AuthViewModel] because the reset flow has its own local
 * state (email + OTP + newPassword) that doesn't belong on the shared
 * VM. Errors funnel through [AuthFlowEvent.Error] via the VM's
 * SharedFlow.
 */
@Composable
fun ForgotPasswordScreen(
    onResetComplete: () -> Unit,
    onBack: () -> Unit,
    repo: AuthRepository,
    viewModel: AuthViewModel = hiltViewModel(),
) {
    var step by rememberSaveable { mutableStateOf(ForgotStep.EmailEntry) }
    var email by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var newPassword by rememberSaveable { mutableStateOf("") }
    val isWorking by viewModel.isWorking.collectAsState()
    val coroutineScope = androidx.compose.runtime.rememberCoroutineScope()

    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))

        Text(
            text = when (step) {
                ForgotStep.EmailEntry -> "Reset password"
                ForgotStep.CodeAndPassword -> "Check your email"
            },
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(Spacing.xs))
        Text(
            text = when (step) {
                ForgotStep.EmailEntry -> "We'll send you a 6-digit code to reset your password."
                ForgotStep.CodeAndPassword -> "Enter the code we sent to $email and pick a new password."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(Spacing.xl))

        when (step) {
            ForgotStep.EmailEntry -> {
                RavenTextField(
                    value = email,
                    onValueChange = { email = it.trim() },
                    label = "Email",
                    keyboardType = KeyboardType.Email,
                    imeAction = ImeAction.Done,
                    enabled = !isWorking,
                )

                Spacer(Modifier.height(Spacing.lg))

                RavenPrimaryButton(
                    text = "Send code",
                    loading = isWorking,
                    enabled = email.contains("@") && !isWorking,
                    onClick = {
                        coroutineScope.launch {
                            runCatching { repo.sendOtp(email, purpose = "reset") }
                                .onSuccess { step = ForgotStep.CodeAndPassword }
                                .onFailure { viewModel.emitError(it.message ?: "Could not send code.") }
                        }
                    },
                )
            }
            ForgotStep.CodeAndPassword -> {
                RavenTextField(
                    value = code,
                    onValueChange = { v -> code = v.filter(Char::isDigit).take(6) },
                    label = "6-digit code",
                    keyboardType = KeyboardType.Number,
                    imeAction = ImeAction.Next,
                    enabled = !isWorking,
                )
                Spacer(Modifier.height(Spacing.sm))
                RavenTextField(
                    value = newPassword,
                    onValueChange = { newPassword = it },
                    label = "New password",
                    isPassword = true,
                    supportingText = "Minimum 8 characters",
                    imeAction = ImeAction.Done,
                    enabled = !isWorking,
                )

                Spacer(Modifier.height(Spacing.lg))

                RavenPrimaryButton(
                    text = "Reset password",
                    loading = isWorking,
                    enabled = code.length == 6 && newPassword.length >= 8 && !isWorking,
                    onClick = {
                        coroutineScope.launch {
                            runCatching {
                                // Reset the password server-side, then
                                // immediately sign in with the new
                                // credentials so the user lands in the
                                // app instead of bouncing to the login
                                // screen. Mirror of the iOS reset flow.
                                repo.resetPassword(email, code, newPassword)
                                repo.login(email, newPassword)
                            }
                                .onSuccess { onResetComplete() }
                                .onFailure { viewModel.emitError(it.message ?: "Reset failed.") }
                        }
                    },
                )

                Spacer(Modifier.height(Spacing.sm))

                Text(
                    text = "Use a different email",
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !isWorking) { step = ForgotStep.EmailEntry },
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        }

        Spacer(Modifier.height(Spacing.sm))

        Text(
            text = "Back to sign-in",
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

private enum class ForgotStep { EmailEntry, CodeAndPassword }
