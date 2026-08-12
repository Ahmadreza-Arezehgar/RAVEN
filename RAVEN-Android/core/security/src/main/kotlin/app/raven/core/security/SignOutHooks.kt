package app.raven.core.security

/**
 * Extension point for modules that hold in-process crypto/session
 * caches that must be wiped on local sign-out (in addition to
 * [SecureStore] disk clears in [TokenStore.signOutLocally]).
 *
 * Bound via Hilt `@IntoSet` from feature modules (e.g. e2ee
 * [SessionStore] cache).
 */
fun interface SignOutHooks {
    fun onLocalSignOut()
}
