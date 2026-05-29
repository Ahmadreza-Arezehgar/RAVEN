package app.raven.feature.auth.oauth

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException

/**
 * Wraps Google's Credential Manager flow. The iOS equivalent is
 * `GoogleSignInCoordinator.swift`.
 *
 * Setup the operator has to do (one-time, NOT in source):
 *   1. Create a Web client ID in the Google Cloud Console for
 *      `raven-server-516053629173.europe-west1.run.app`.
 *      ── critical: the WEB client ID, not Android — Android needs
 *         a separate OAuth-2 client with the SHA-1 of the release
 *         signing keystore, but the ID token Google returns is
 *         requested with the Web client's audience.
 *   2. Drop the Web client ID into `local.properties`:
 *        `raven.google.webClientId=<the long .apps.googleusercontent.com value>`
 *      The `app/build.gradle.kts` reads this and exposes it via
 *      `BuildConfig.GOOGLE_WEB_CLIENT_ID`. We resolve at runtime
 *      so a missing config fails-loudly with an explicit error.
 *
 * Returns the raw ID token on success — caller (AuthViewModel
 * /AuthRepository) passes it to `POST /api/auth/oauth/google`.
 */
class GoogleSignInHelper(
    private val webClientId: String,
) {

    /** Caller surfaces these as toast / error states. */
    sealed interface Result {
        data class Success(val idToken: String) : Result
        data object Cancelled : Result
        data class Failure(val message: String) : Result
    }

    /**
     * Call from a Composable via
     *   `rememberCoroutineScope().launch { helper.signIn(context) }`
     *
     * Requires an Activity-context (the credential picker UI is
     * rendered as an overlay on top of the current activity).
     */
    suspend fun signIn(activityContext: Context): Result {
        if (webClientId.isBlank() || webClientId.startsWith("REPLACE_")) {
            return Result.Failure(
                "Google sign-in not configured. Set raven.google.webClientId in local.properties.",
            )
        }

        val option = GetGoogleIdOption.Builder()
            // `setFilterByAuthorizedAccounts(false)` makes the
            // credential UI also offer accounts the user has never
            // signed-in with before. Without it we'd only see
            // previously-authorized accounts — bad UX on first run.
            .setFilterByAuthorizedAccounts(false)
            .setServerClientId(webClientId)
            // Auto-select if only one account is on the device AND
            // the user has authorized it before.
            .setAutoSelectEnabled(true)
            .build()

        val request = GetCredentialRequest.Builder()
            .addCredentialOption(option)
            .build()

        val credentialManager = CredentialManager.create(activityContext)

        return try {
            val response = credentialManager.getCredential(activityContext, request)
            val cred = response.credential
            if (cred is CustomCredential &&
                cred.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
            ) {
                val google = GoogleIdTokenCredential.createFrom(cred.data)
                Result.Success(google.idToken)
            } else {
                Result.Failure("Unexpected credential type: ${cred.type}")
            }
        } catch (cancelled: GetCredentialCancellationException) {
            Result.Cancelled
        } catch (parse: GoogleIdTokenParsingException) {
            Result.Failure("Google credential parse error: ${parse.message}")
        } catch (e: GetCredentialException) {
            Result.Failure(e.message ?: "Google sign-in failed.")
        }
    }
}
