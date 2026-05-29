package app.raven.feature.auth.state

/**
 * One-shot UI events. ViewModels expose these via a SharedFlow so the
 * UI can react to navigation pushes / error toasts without losing
 * events on configuration change. Equivalent to iOS's
 * `try await authService.login(...)` + thrown errors.
 */
sealed interface AuthFlowEvent {
    /** Generic error — surface as a toast / inline error. */
    data class Error(val message: String) : AuthFlowEvent

    /** Sign-in completed; navigation graph should switch shells. */
    data object SignedIn : AuthFlowEvent

    /** OAuth completed but server says "no username yet" — navigate
     *  to UsernameSelectionScreen with this short-lived token. */
    data class UsernameRequired(val tempToken: String) : AuthFlowEvent

    /** Email signup completed; navigate to OTPVerificationScreen
     *  with the email pre-populated. */
    data class OtpSent(val email: String) : AuthFlowEvent
}
