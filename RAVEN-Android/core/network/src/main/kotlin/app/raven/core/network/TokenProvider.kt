package app.raven.core.network

/**
 * Read-only contract the network layer uses to pull the current
 * access token + ask for a refresh. Implementation lives in
 * `:core:security` (which holds the Keystore-backed token store) so
 * `:core:network` doesn't need to know about Android Keystore at all.
 *
 * Mirrors the role of `TokenStore.swift` on iOS — the network layer
 * never reads tokens off disk directly; it asks an interface.
 */
interface TokenProvider {
    /** Most-recent access token, or null if the user is signed out. */
    suspend fun accessToken(): String?

    /**
     * Trigger a refresh-token exchange against `/api/auth/refresh`.
     * Returns the new access token on success; null on hard failure
     * (refresh token revoked / expired) — caller should redirect to
     * the auth gate.
     */
    suspend fun refreshAccessToken(): String?
}
