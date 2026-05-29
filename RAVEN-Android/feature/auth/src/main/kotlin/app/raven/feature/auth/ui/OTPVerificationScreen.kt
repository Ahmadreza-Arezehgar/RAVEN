package app.raven.feature.auth.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import app.raven.core.design.Spacing
import app.raven.feature.auth.state.AuthViewModel
import app.raven.feature.auth.ui.components.AuthScaffold
import app.raven.feature.auth.ui.components.RavenPrimaryButton

/**
 * 6-digit OTP entry. Mirror of `OTPVerificationView.swift`.
 *
 * One masked text field that captures the digits; 6 visual cells
 * driven from that string. iOS uses the SwiftUI auto-fill for
 * one-time-codes via `.textContentType(.oneTimeCode)`; we get the
 * equivalent for free on Android because `KeyboardType.Number`
 * + autofill picks up SMS one-time codes via the SMS Retriever
 * pipeline when configured.
 */
@Composable
fun OTPVerificationScreen(
    email: String,
    purpose: String = "register",
    onBack: () -> Unit,
    viewModel: AuthViewModel = hiltViewModel(),
) {
    var code by rememberSaveable { mutableStateOf("") }
    val isWorking by viewModel.isWorking.collectAsState()
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    AuthScaffold {
        Spacer(Modifier.height(Spacing.xl))
        Text(
            text = "Enter your code",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(Spacing.sm))
        Text(
            text = "We sent a 6-digit code to $email",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(Spacing.xl))

        // Invisible BasicTextField for keyboard + autofill —
        // visual rendering is the 6 boxes below.
        BasicTextField(
            value = code,
            onValueChange = { v ->
                code = v.filter(Char::isDigit).take(6)
            },
            singleLine = true,
            modifier = Modifier
                .focusRequester(focusRequester)
                .size(1.dp),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Number,
                imeAction = ImeAction.Done,
            ),
            textStyle = TextStyle(color = androidx.compose.ui.graphics.Color.Transparent),
            cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Transparent),
        )

        // Visual 6-cell row, clickable to refocus.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = !isWorking) { focusRequester.requestFocus() },
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            repeat(6) { i ->
                val ch = code.getOrNull(i)?.toString() ?: ""
                Box(
                    modifier = Modifier
                        .size(width = 48.dp, height = 56.dp)
                        .background(
                            color = MaterialTheme.colorScheme.surface,
                            shape = RoundedCornerShape(12.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = ch,
                        style = MaterialTheme.typography.displaySmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        Spacer(Modifier.height(Spacing.xl))

        RavenPrimaryButton(
            text = "Verify",
            loading = isWorking,
            enabled = code.length == 6 && !isWorking,
            onClick = { viewModel.verifyOtp(email = email, code = code, purpose = purpose) },
        )

        Spacer(Modifier.height(Spacing.sm))

        Text(
            text = "Resend code",
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = !isWorking) {
                    viewModel.sendOtp(email = email, purpose = purpose)
                },
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.primary,
            style = MaterialTheme.typography.labelLarge,
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
