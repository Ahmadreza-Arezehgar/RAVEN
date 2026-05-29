package app.raven.feature.auth.state

/**
 * Top-level routing state for the auth gate. Mirror of iOS
 * `AppBootState` + `AuthService.{requiresUsernameSetup,
 * needsPhoneNumber, isAuthenticated, isEmailVerified}` rolled
 * into one sealed type. The `AuthGate` composable matches on
 * this and renders one screen at a time.
 */
sealed interface AuthGateState {

    /** Initial — TokenStore is still being read from disk. Render
     *  the splash so we never flash the wrong screen. */
    data object Checking : AuthGateState

    /** First-launch user, hasn't seen the welcome carousel. */
    data object Onboarding : AuthGateState

    /** No stored tokens / refresh failed. Render the auth landing. */
    data object Unauthenticated : AuthGateState

    /** OAuth user signed in but hasn't picked a handle. Carries the
     *  short-lived `temp_token` used to call `/set-username`. */
    data class UsernameRequired(val tempToken: String) : AuthGateState

    /** Email user signed in but hasn't verified their email yet.
     *  Carries the email so the OTP screen can re-send + display. */
    data class EmailVerificationRequired(val email: String) : AuthGateState

    /** OAuth user has no phone yet AND the prompt hasn't been
     *  dismissed once. Lets us show the optional phone-collection
     *  screen without re-prompting forever. */
    data object PhoneCollectionOptional : AuthGateState

    /** Done. Show the main shell. */
    data object SignedIn : AuthGateState
}
